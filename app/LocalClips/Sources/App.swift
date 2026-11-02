import AppKit
import SwiftUI

@main
struct LocalClipsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var store: HistoryStore!
    private var recorder: ClipboardRecorder!
    private var pasteController: PasteController!
    private var hotKeys: HotKeyController!
    private var loginController: LoginController!
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var maintenanceTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        hotKeys = HotKeyController()
        loginController = LoginController()
        NotificationCenter.default.addObserver(self, selector: #selector(togglePanel), name: .localClipsShowHotKey, object: nil)
        createStatusItem()
        store = HistoryStore { [weak self] ready in
            guard let self else { return }
            self.recorder = ClipboardRecorder(store: self.store)
            self.pasteController = PasteController(recorder: self.recorder, store: self.store)
            if UserDefaults.standard.bool(forKey: "recordingPaused") {
                self.recorder.pause()
            } else {
                self.recorder.start()
            }
            if ready {
                self.store.pruneHistory()
                let timer = Timer(timeInterval: 6 * 60 * 60, target: self, selector: #selector(maintainHistory), userInfo: nil, repeats: true)
                self.maintenanceTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
            self.createPanel()
            self.showPanel()
            if !ready {
                self.panel.title = "LocalClips · 存储不可用"
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if panel == nil { createPanel() }
        showPanel()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        recorder?.stop()
        maintenanceTimer?.invalidate()
        pasteController?.cancelPendingPaste()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        pasteController.cancelPendingPaste()
        pasteController.restoreTargetFocus()
        return false
    }

    @objc private func openHistory() { showPanel() }

    @objc private func togglePanel() {
        guard panel != nil else { return }
        if panel.isVisible {
            pasteController.cancelPendingPaste()
            panel.orderOut(nil)
            pasteController.restoreTargetFocus()
        } else {
            showPanel()
        }
    }

    @objc private func toggleRecording() {
        if !recorder.hasStartedRecording || recorder.isPaused { recorder.resume() } else { recorder.pause() }
        pasteController.cancelPendingPaste()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func maintainHistory() { store.pruneHistory() }

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "LocalClips")
        statusItem.button?.toolTip = "LocalClips"
        statusItem.isVisible = UserDefaults.standard.object(forKey: "showMenuBarIcon") as? Bool ?? true
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "打开历史", action: #selector(openHistory), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "暂停 / 恢复记录", action: #selector(toggleRecording), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 LocalClips", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items { item.target = self }
        statusItem.menu = menu
    }

    private func createPanel() {
        guard store != nil, recorder != nil, pasteController != nil else { return }
        let root = ManagerView(
            store: store,
            recorder: recorder,
            pasteController: pasteController,
            hotKeys: hotKeys,
            loginController: loginController,
            onDismiss: { [weak self] in
                self?.panel.orderOut(nil)
                self?.pasteController.restoreTargetFocus()
            },
            onStatusMessage: { [weak self] message in self?.statusItem.button?.toolTip = message },
            onToggleMenuIcon: { [weak self] visible in self?.statusItem.isVisible = visible }
        )
        let host = NSHostingView(rootView: root)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 470), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "LocalClips"
        panel.contentView = host
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 780, height: 360)
        panel.delegate = self
        positionPanel()
    }

    private func positionPanel() {
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 16))
    }

    private func showPanel() {
        guard panel != nil else { return }
        if !panel.isVisible { pasteController.captureTargetApplication() }
        positionPanel()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
