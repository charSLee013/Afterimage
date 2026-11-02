import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LocalSettingsView: View {
    let store: HistoryStore
    let recorder: ClipboardRecorder
    let pasteController: PasteController
    let hotKeys: HotKeyController
    let loginController: LoginController
    @Binding var defaultAutoPaste: Bool
    @Binding var defaultPlainText: Bool
    @Binding var showMenuIcon: Bool
    let hotKeyRevision: Int
    let loginRevision: Int
    let onToggleMenuIcon: (Bool) -> Void

    @State private var stats: StorageStats?
    @State private var historyLimit = UserDefaults.standard.object(forKey: "historyLimit") as? Int ?? 1000
    @State private var historyAgeDays = UserDefaults.standard.object(forKey: "historyAgeDays") as? Int ?? 30
    @State private var budgetMiB = Int((UserDefaults.standard.object(forKey: "payloadBudgetBytes") as? Int64 ?? 1_073_741_824) / 1_048_576)
    @State private var ignoredBundleIDs = UserDefaults.standard.stringArray(forKey: "ignoredBundleIDs") ?? []
    @State private var ignoredNames = UserDefaults.standard.dictionary(forKey: "ignoredAppNames") as? [String: String] ?? [:]
    @State private var message: String?
    @State private var loginMessage: String?
    @State private var isChoosingApp = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                Text("状态")
                    .font(.headline)
                VStack(spacing: 8) {
                    StatusLine(title: "采集", value: captureState)
                    StatusLine(title: "剪贴板读取", value: recorder.readPermissionLabel)
                    StatusLine(title: "自动控制", value: pasteController.controlPermissionLabel)
                    StatusLine(title: "呼出快捷键", value: hotKeyText(HotKeyController.showID))
                    StatusLine(title: "快捷键最近触发", value: hotKeyRecentText)
                    StatusLine(title: "前一 Pinboard", value: hotKeyText(HotKeyController.previousBoardID))
                    StatusLine(title: "后一 Pinboard", value: hotKeyText(HotKeyController.nextBoardID))
                    StatusLine(title: "登录启动", value: loginText)
                    StatusLine(title: "存储", value: storageText)
                }
                HStack {
                    Button("重新检查") {
                        hotKeys.refresh()
                        loginController.refresh()
                        refreshStats()
                    }
                    Button("打开系统设置") { loginController.openSystemSettings() }
                }

                Divider()

                Text("操作")
                    .font(.headline)
                Toggle("默认自动粘贴", isOn: $defaultAutoPaste)
                    .onChange(of: defaultAutoPaste) { _, value in UserDefaults.standard.set(value, forKey: "defaultAutoPaste") }
                Toggle("默认使用纯文本", isOn: $defaultPlainText)
                    .onChange(of: defaultPlainText) { _, value in UserDefaults.standard.set(value, forKey: "defaultPlainText") }
                Toggle("显示菜单栏图标", isOn: $showMenuIcon)
                    .onChange(of: showMenuIcon) { _, value in
                        UserDefaults.standard.set(value, forKey: "showMenuBarIcon")
                        onToggleMenuIcon(value)
                    }
                Toggle("登录时启动", isOn: Binding(
                    get: { loginController.status == .enabled },
                    set: { loginController.setEnabled($0) }
                ))
                .onChange(of: loginRevision) { _, _ in
                    loginMessage = loginController.status == .requiresApproval ? "请在系统设置中批准 LocalClips 登录项。" : nil
                }
                if let loginMessage { Text(loginMessage).font(.caption).foregroundStyle(.secondary) }

                ShortcutEditor(title: "呼出历史", id: HotKeyController.showID, hotKeys: hotKeys, revision: hotKeyRevision)
                ShortcutEditor(title: "切换到前一 Pinboard", id: HotKeyController.previousBoardID, hotKeys: hotKeys, revision: hotKeyRevision)
                ShortcutEditor(title: "切换到后一 Pinboard", id: HotKeyController.nextBoardID, hotKeys: hotKeys, revision: hotKeyRevision)
                Text("快捷键冲突时保留菜单栏入口；应用不监听全局键盘输入。MacBook 默认需按 Fn+功能键，或在系统设置启用标准功能键。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Text("历史和存储")
                    .font(.headline)
                Stepper(value: $historyLimit, in: 0...50_000, step: 100) {
                    LabeledContent("历史条数", value: historyLimit == 0 ? "不限" : "\(historyLimit)")
                }
                Stepper(value: $historyAgeDays, in: 0...3_650, step: 1) {
                    LabeledContent("保留期限", value: historyAgeDays == 0 ? "不限" : "\(historyAgeDays) 天")
                }
                Stepper(value: $budgetMiB, in: 64...16_384, step: 64) {
                    LabeledContent("原始数据预算", value: "\(budgetMiB) MiB")
                }
                HStack {
                    Button("应用限制并清理") {
                        store.updateLimits(maxCount: historyLimit, maxAgeDays: historyAgeDays, budgetBytes: Int64(budgetMiB) * 1_048_576) { success in
                            message = success ? "限制已保存。清理不会删除仍被收藏的内容。" : "限制未应用；现有内容保留。收藏内容可能占满预算。"
                            refreshStats()
                        }
                    }
                    if let stats {
                        Text("\(stats.historyCount) 条历史 · 逻辑 \(format(stats.logicalBytes)) · 实际 \(format(stats.physicalBytes)) · 可用 \(format(stats.availableBytes))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }

                Divider()

                Text("排除应用")
                    .font(.headline)
                HStack {
                    Button("添加应用…", systemImage: "plus") { chooseApplication() }
                    Text("按 Bundle ID 匹配可识别来源；未知来源不能保证排除。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if ignoredBundleIDs.isEmpty {
                    Text("没有排除应用")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(ignoredBundleIDs, id: \.self) { bundleID in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ignoredNames[bundleID] ?? bundleID)
                                Text(bundleID).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { removeExcludedApp(bundleID) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain)
                                .help("移除排除应用")
                        }
                    }
                }

                Divider()

                Text("隐私与数据")
                    .font(.headline)
                StatusLine(title: "特殊标记", value: "保密、临时和自动生成内容始终跳过")
                StatusLine(title: "诊断", value: "本地；不记录正文、查询词、完整路径或原始 URL")
                StatusLine(title: "数据位置", value: "~/Library/Application Support/LocalClips")
                Text("仅保存文件引用，不归档文件。原文件移动时尝试书签定位；删除或无权访问时保留历史并提示不可用。删除数据库不承诺安全擦除。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("无应用级加密；本地数据仍受当前 macOS 用户账户权限保护。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(18)
        }
        .onAppear { refreshStats() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshStats() }
    }

    private var captureState: String {
        if !recorder.hasStartedRecording { return "未启动" }
        return recorder.status.label
    }

    private var loginText: String {
        _ = loginRevision
        return loginController.status.label
    }

    private var hotKeyRecentText: String {
        _ = hotKeyRevision
        return hotKeys.lastPressLabel
    }

    private var storageText: String {
        guard store.isReady else { return "不可用（错误码 \(store.loadErrorCode ?? -1)；已有数据库保留）" }
        guard let stats else { return "检查中" }
        return stats.writable ? "可写" : "低空间，已停止新增"
    }

    private func hotKeyText(_ id: UInt32) -> String {
        _ = hotKeyRevision
        let binding = hotKeys.binding(for: id)?.displayName ?? "未设置"
        return "\(binding) · \(hotKeys.statusDetail(for: id))"
    }

    private func refreshStats() {
        store.storageStats { stats = $0 }
    }

    private func chooseApplication() {
        guard !isChoosingApp else { return }
        isChoosingApp = true
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            defer { isChoosingApp = false }
            guard response == .OK, let url = panel.url,
                  let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else { return }
            guard !ignoredBundleIDs.contains(identifier) else { return }
            ignoredBundleIDs.append(identifier)
            ignoredNames[identifier] = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? identifier
            UserDefaults.standard.set(ignoredBundleIDs, forKey: "ignoredBundleIDs")
            UserDefaults.standard.set(ignoredNames, forKey: "ignoredAppNames")
        }
    }

    private func removeExcludedApp(_ bundleID: String) {
        ignoredBundleIDs.removeAll { $0 == bundleID }
        ignoredNames.removeValue(forKey: bundleID)
        UserDefaults.standard.set(ignoredBundleIDs, forKey: "ignoredBundleIDs")
        UserDefaults.standard.set(ignoredNames, forKey: "ignoredAppNames")
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct StatusLine: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .frame(width: 120, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .font(.system(size: 12))
    }
}

private struct ShortcutEditor: View {
    let title: String
    let id: UInt32
    let hotKeys: HotKeyController
    let revision: Int
    @State private var capturing = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .frame(width: 160, alignment: .leading)
            if capturing {
                HotKeyCaptureField { binding in
                    hotKeys.setBinding(binding, for: id)
                    capturing = false
                }
                .frame(width: 190, height: 34)
                Button("取消") { capturing = false }
            } else {
                Text(bindingText)
                    .frame(width: 190, alignment: .leading)
                    .foregroundStyle(.secondary)
                Button("录制") { capturing = true }
                if id != HotKeyController.showID, hotKeys.binding(for: id) != nil {
                    Button("清除") { hotKeys.setBinding(nil, for: id) }
                }
            }
            Text(registrationText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
    }

    private var bindingText: String {
        _ = revision
        return hotKeys.binding(for: id)?.displayName ?? (id == HotKeyController.showID ? "⌃⌥Space" : "未设置")
    }

    private var registrationText: String { hotKeys.statusDetail(for: id) }
}
