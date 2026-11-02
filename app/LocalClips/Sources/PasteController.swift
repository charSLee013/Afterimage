import AppKit
import CoreGraphics

enum RestoreResult {
    case success
    case failure(String)
}

enum PasteActionResult: Sendable {
    case clipboardPrepared
    case permissionNeeded
    case targetUnavailable
    case cancelled
    case eventSent
    case failed(String)

    var message: String {
        switch self {
        case .clipboardPrepared: "系统剪贴板已准备。请在目标应用中手动粘贴。"
        case .permissionNeeded: "系统剪贴板已准备；自动控制权限尚未授予。请在系统设置授权后再试。"
        case .targetUnavailable: "系统剪贴板已准备；原目标应用不可用。请手动粘贴。"
        case .cancelled: "目标或焦点已变化，自动粘贴已取消；剪贴板仍可手动使用。"
        case .eventSent: "已向原目标发送 ⌘V；请确认目标应用实际插入内容。"
        case .failed(let reason): reason
        }
    }
}

@MainActor
final class PasteController {
    private let recorder: ClipboardRecorder
    private let store: HistoryStore
    private var generation = UUID()
    private(set) var targetApplication: NSRunningApplication?
    private var targetWasInvalidated = false

    init(recorder: ClipboardRecorder, store: HistoryStore) {
        self.recorder = recorder
        self.store = store
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidActivate(_:)),
            name: NSNotification.Name("NSWorkspaceDidActivateApplicationNotification"),
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(cancelOnSystemTransition), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(cancelOnSystemTransition),
            name: NSNotification.Name("NSWorkspaceSessionDidResignActiveNotification"),
            object: nil
        )
    }

    func captureTargetApplication() {
        let app = NSWorkspace.shared.frontmostApplication
        targetApplication = app?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : app
        targetWasInvalidated = false
    }

    func cancelPendingPaste() {
        generation = UUID()
    }

    @objc private func cancelOnSystemTransition() { cancelPendingPaste() }

    @objc private func applicationDidActivate(_ notification: Notification) {
        guard let app = notification.userInfo?["NSWorkspaceApplicationKey"] as? NSRunningApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              let targetApplication,
              app.processIdentifier != targetApplication.processIdentifier else { return }
        targetWasInvalidated = true
        cancelPendingPaste()
    }

    func restoreTargetFocus() {
        guard !targetWasInvalidated, let target = targetApplication, !target.isTerminated else { return }
        target.activate(options: [])
    }

    var controlPermissionLabel: String {
        CGPreflightPostEventAccess() ? "自动控制已允许" : "自动控制需要权限"
    }

    func restore(_ row: ClipRow, plainTextOnly: Bool = false) -> RestoreResult {
        cancelPendingPaste()
        let snapshot = ClipboardSnapshot(items: row.items, sourceBundleID: nil, sourceName: nil, sourceConfidence: "unknown")
        guard !snapshot.items.isEmpty else { return .failure("历史内容为空") }
        var outputItems: [NSPasteboardItem] = []
        var restoredItems: [CapturedItem] = []
        for item in snapshot.items.sorted(by: { $0.position < $1.position }) {
            let output = NSPasteboardItem()
            var restoredRepresentations: [CapturedRepresentation] = []
            if plainTextOnly {
                guard let text = Self.text(for: item) else { return .failure("该内容没有可用文本") }
                guard output.setString(text, forType: .string) else { return .failure("纯文本剪贴板准备失败") }
                restoredRepresentations = [CapturedRepresentation(typeIdentifier: NSPasteboard.PasteboardType.string.rawValue, position: 0, data: Data(text.utf8), bookmarkData: nil)]
            } else {
                for representation in item.representations.sorted(by: { $0.position < $1.position }) {
                    var data = representation.data
                    if representation.typeIdentifier == "public.file-url" {
                        guard let url = Self.resolveFileURL(representation), FileManager.default.isReadableFile(atPath: url.path) else {
                            return .failure("文件引用已失效或不可访问")
                        }
                        data = Data(url.absoluteString.utf8)
                    }
                    guard output.setData(data, forType: NSPasteboard.PasteboardType(rawValue: representation.typeIdentifier)) else {
                        return .failure("剪贴板格式准备失败")
                    }
                    restoredRepresentations.append(CapturedRepresentation(
                        typeIdentifier: representation.typeIdentifier,
                        position: representation.position,
                        data: data,
                        bookmarkData: representation.bookmarkData
                    ))
                }
            }
            outputItems.append(output)
            restoredItems.append(CapturedItem(position: item.position, representations: restoredRepresentations))
        }
        guard !outputItems.isEmpty else { return .failure("没有可恢复的表示") }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects(outputItems) else { return .failure("系统剪贴板写入失败") }
        let changeCount = pasteboard.changeCount
        let restored = ClipboardSnapshot(items: restoredItems, sourceBundleID: nil, sourceName: nil, sourceConfidence: "unknown")
        recorder.noteOwnWrite(restored, changeCount: changeCount)
        store.markUsed(row.id)
        return .success
    }

    func perform(
        _ row: ClipRow,
        plainTextOnly: Bool,
        automatic: Bool,
        hidePanel: @escaping @MainActor @Sendable () -> Void,
        completion: @escaping @MainActor @Sendable (PasteActionResult) -> Void
    ) {
        switch restore(row, plainTextOnly: plainTextOnly) {
        case .failure(let reason):
            completion(.failed(reason))
            return
        case .success:
            break
        }
        guard automatic else {
            completion(.clipboardPrepared)
            return
        }
        guard let target = targetApplication, !target.isTerminated, !targetWasInvalidated else {
            completion(.targetUnavailable)
            return
        }
        if !CGPreflightPostEventAccess() {
            _ = CGRequestPostEventAccess()
            guard CGPreflightPostEventAccess() else {
                completion(.permissionNeeded)
                return
            }
        }
        let operation = UUID()
        generation = operation
        hidePanel()
        target.activate(options: [])
        Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(1.0)
            while Date() < deadline {
                guard self.generation == operation, !target.isTerminated else {
                    completion(.cancelled)
                    return
                }
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
                   Self.modifiersAreReleased {
                    break
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard self.generation == operation,
                  !target.isTerminated,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
                  Self.modifiersAreReleased else {
                completion(.cancelled)
                return
            }
            guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: false) else {
                completion(.failed("无法构造粘贴事件；剪贴板仍可手动使用。"))
                return
            }
            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand
            keyDown.postToPid(target.processIdentifier)
            keyUp.postToPid(target.processIdentifier)
            completion(.eventSent)
        }
    }

    private static func text(for item: CapturedItem) -> String? {
        ClipboardSnapshot.plainText(for: item)
    }

    private static func fileURL(from data: Data) -> URL? {
        let url = URL(dataRepresentation: data, relativeTo: nil)
            ?? String(data: data, encoding: .utf8).flatMap(URL.init(string:))
        return url?.isFileURL == true ? url : nil
    }

    private static func resolveFileURL(_ representation: CapturedRepresentation) -> URL? {
        if let bookmarkData = representation.bookmarkData {
            var isStale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), resolved.isFileURL, FileManager.default.isReadableFile(atPath: resolved.path) {
                return resolved
            }
        }
        guard let url = fileURL(from: representation.data), FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        return url
    }

    private static var modifiersAreReleased: Bool {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        return flags.intersection([.maskCommand, .maskAlternate, .maskShift, .maskControl]).isEmpty
    }
}
