import AppKit
import Carbon.HIToolbox
import CoreGraphics
import SwiftUI

struct HotKeyBinding: Hashable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32

    var displayName: String {
        let prefix = [
            (UInt32(controlKey), "⌃"), (UInt32(optionKey), "⌥"), (UInt32(shiftKey), "⇧"), (UInt32(cmdKey), "⌘"),
        ].compactMap { modifiers & $0.0 == 0 ? nil : $0.1 }.joined()
        let key = keyCode == 49 ? "Space" : (KeyCaptureView.label(for: UInt16(keyCode)) ?? "Key \(keyCode)")
        return prefix + key
    }
}

enum HotKeyRegistration: String, Sendable {
    case registered = "已注册"
    case conflict = "快捷键冲突"
    case unavailable = "不可用"
}

extension Notification.Name {
    static let localClipsShowHotKey = Notification.Name("LocalClips.ShowHotKey")
    static let localClipsPreviousBoardHotKey = Notification.Name("LocalClips.PreviousBoardHotKey")
    static let localClipsNextBoardHotKey = Notification.Name("LocalClips.NextBoardHotKey")
}

@MainActor
final class HotKeyController {
    static let showID: UInt32 = 1
    static let previousBoardID: UInt32 = 2
    static let nextBoardID: UInt32 = 3
    private let signature: OSType = 0x4c434c50
    private var eventHandler: EventHandlerRef?
    private var references: [UInt32: EventHotKeyRef] = [:]
    private(set) var status: [UInt32: HotKeyRegistration] = [:]
    private(set) var registrationCodes: [UInt32: OSStatus] = [:]
    private(set) var bindings: [UInt32: HotKeyBinding] = [:]
    private(set) var lastPressedID = (UserDefaults.standard.object(forKey: "hotkey.lastPressedID") as? NSNumber)?.uint32Value
    private(set) var lastPressedAt = (UserDefaults.standard.object(forKey: "hotkey.lastPressedAt") as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
    var onChange: (() -> Void)?
    private var handlerInstallCode: OSStatus = noErr

    init() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        handlerInstallCode = InstallEventHandler(
            GetApplicationEventTarget(),
            localClipsHotKeyCallback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        if handlerInstallCode == noErr {
            refresh()
        } else {
            for id in [Self.showID, Self.previousBoardID, Self.nextBoardID] {
                status[id] = .unavailable
                registrationCodes[id] = handlerInstallCode
            }
        }
    }

    func refresh() {
        unregisterAll()
        let show = storedBinding("show", fallback: HotKeyBinding(keyCode: 49, modifiers: UInt32(controlKey | optionKey)))
        let previous = storedBinding("previousBoard", fallback: nil)
        let next = storedBinding("nextBoard", fallback: nil)
        register(show, id: Self.showID)
        register(previous, id: Self.previousBoardID)
        register(next, id: Self.nextBoardID)
        onChange?()
    }

    func setBinding(_ binding: HotKeyBinding?, for id: UInt32) {
        let key = Self.preferenceKey(for: id)
        if let binding {
            UserDefaults.standard.set(["keyCode": binding.keyCode, "modifiers": binding.modifiers], forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        refresh()
    }

    func status(for id: UInt32) -> HotKeyRegistration { status[id] ?? .unavailable }
    func binding(for id: UInt32) -> HotKeyBinding? { bindings[id] }

    func statusDetail(for id: UInt32) -> String {
        let value = status(for: id).rawValue
        if let code = registrationCodes[id], code != noErr { return "\(value) (OSStatus \(code))" }
        if handlerInstallCode != noErr { return "事件处理器失败 (OSStatus \(handlerInstallCode))" }
        return value
    }

    var lastPressLabel: String {
        guard let lastPressedID, let lastPressedAt else { return "尚无记录" }
        let name = binding(for: lastPressedID)?.displayName ?? "ID \(lastPressedID)"
        return "\(name) · \(lastPressedAt.formatted(date: .omitted, time: .standard))"
    }

    func noteHotKeyPressed(_ id: UInt32) {
        let now = Date()
        lastPressedID = id
        lastPressedAt = now
        UserDefaults.standard.set(id, forKey: "hotkey.lastPressedID")
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: "hotkey.lastPressedAt")
        onChange?()
    }

    private func register(_ binding: HotKeyBinding?, id: UInt32) {
        guard let binding else {
            status[id] = .unavailable
            return
        }
        bindings[id] = binding
        var reference: EventHotKeyRef?
        let identity = EventHotKeyID(signature: signature, id: id)
        let result = RegisterEventHotKey(binding.keyCode, binding.modifiers, identity, GetApplicationEventTarget(), 0, &reference)
        registrationCodes[id] = result
        if result == noErr, let reference {
            references[id] = reference
            status[id] = .registered
        } else {
            status[id] = .conflict
        }
    }

    private func unregisterAll() {
        for reference in references.values { UnregisterEventHotKey(reference) }
        references.removeAll()
        bindings.removeAll()
        status.removeAll()
        registrationCodes.removeAll()
    }

    private func storedBinding(_ name: String, fallback: HotKeyBinding?) -> HotKeyBinding? {
        guard let values = UserDefaults.standard.dictionary(forKey: Self.preferenceKey(named: name)),
              let keyCode = (values["keyCode"] as? NSNumber)?.uint32Value,
              let modifiers = (values["modifiers"] as? NSNumber)?.uint32Value else { return fallback }
        return HotKeyBinding(keyCode: keyCode, modifiers: modifiers)
    }

    private static func preferenceKey(for id: UInt32) -> String {
        switch id {
        case showID: preferenceKey(named: "show")
        case previousBoardID: preferenceKey(named: "previousBoard")
        default: preferenceKey(named: "nextBoard")
        }
    }

    private static func preferenceKey(named name: String) -> String { "hotkey.\(name)" }
}

private func localClipsHotKeyCallback(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return noErr }
    var identifier = EventHotKeyID()
    let result = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    )
    guard result == noErr else { return noErr }
    let controller = Unmanaged<HotKeyController>.fromOpaque(userData).takeUnretainedValue()
    let pressedID = identifier.id
    DispatchQueue.main.async {
        guard controller.status(for: pressedID) == .registered else { return }
        controller.noteHotKeyPressed(pressedID)
        let notification: Notification.Name
        switch pressedID {
        case HotKeyController.showID: notification = .localClipsShowHotKey
        case HotKeyController.previousBoardID: notification = .localClipsPreviousBoardHotKey
        default: notification = .localClipsNextBoardHotKey
        }
        NotificationCenter.default.post(name: notification, object: nil)
    }
    return noErr
}

struct HotKeyCaptureField: NSViewRepresentable {
    let onCapture: (HotKeyBinding) -> Void

    func makeNSView(context: Context) -> KeyCaptureView {
        let view = KeyCaptureView()
        view.onCapture = onCapture
        return view
    }

    func updateNSView(_ view: KeyCaptureView, context: Context) {
        view.onCapture = onCapture
    }
}

final class KeyCaptureView: NSView {
    var onCapture: ((HotKeyBinding) -> Void)?
    private var pendingBinding: HotKeyBinding?
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.isKeyWindow == true else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasShortcutModifier = !flags.intersection([.command, .control, .option, .shift]).isEmpty
        guard hasShortcutModifier || Self.isFunctionKey(event.keyCode) else { return }
        guard pendingBinding == nil else { return }
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        let binding = HotKeyBinding(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        pendingBinding = binding
        needsDisplay = true
        Task { @MainActor [weak self] in
            for _ in 0..<100 {
                guard let self else { return }
                if Self.modifiersAreReleased {
                    self.pendingBinding = nil
                    self.onCapture?(binding)
                    return
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
            self?.pendingBinding = nil
            self?.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        let text = pendingBinding.map { "释放 \($0.displayName) 以注册" } ?? "按下快捷键组合"
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]
        text.draw(at: NSPoint(x: 9, y: (bounds.height - 14) / 2), withAttributes: attributes)
        NSColor.separatorColor.setStroke()
        bounds.insetBy(dx: 0.5, dy: 0.5).frame()
    }

    nonisolated static func label(for keyCode: UInt16) -> String? {
        let map: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B",
            12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P",
            37: "L", 38: "J", 40: "K", 45: "N", 46: "M", 36: "Return", 48: "Tab", 49: "Space", 51: "Delete",
            53: "Escape", 123: "←", 124: "→", 125: "↓", 126: "↑",
            UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3", UInt16(kVK_F4): "F4",
            UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6", UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8",
            UInt16(kVK_F9): "F9", UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
        ]
        return map[keyCode]
    }

    private nonisolated static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case UInt16(kVK_F1), UInt16(kVK_F2), UInt16(kVK_F3), UInt16(kVK_F4),
             UInt16(kVK_F5), UInt16(kVK_F6), UInt16(kVK_F7), UInt16(kVK_F8),
             UInt16(kVK_F9), UInt16(kVK_F10), UInt16(kVK_F11), UInt16(kVK_F12):
            true
        default:
            false
        }
    }

    private nonisolated static var modifiersAreReleased: Bool {
        CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskAlternate, .maskShift, .maskControl]).isEmpty
    }
}
