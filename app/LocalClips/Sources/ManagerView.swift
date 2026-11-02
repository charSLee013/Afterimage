import AppKit
import ImageIO
import SwiftUI

private enum ManagerSection: String, CaseIterable, Identifiable {
    case history = "历史"
    case pinboards = "Pinboard"
    case settings = "设置"
    var id: String { rawValue }
}

private enum ManagerFocus: Hashable {
    case search
    case cards
}

struct ManagerView: View {
    let store: HistoryStore
    let recorder: ClipboardRecorder
    let pasteController: PasteController
    let hotKeys: HotKeyController
    let loginController: LoginController
    let onDismiss: @MainActor @Sendable () -> Void
    let onStatusMessage: @MainActor @Sendable (String) -> Void
    let onToggleMenuIcon: @MainActor @Sendable (Bool) -> Void

    @State private var section: ManagerSection = .history
    @State private var rows: [ClipRow] = []
    @State private var queryID: UUID?
    @State private var queryRevision: UInt64?
    @State private var queryTotalCount = 0
    @State private var queryNextIndex = 0
    @State private var queryHasMore = false
    @State private var queryLoading = true
    @State private var queryError: String?
    @State private var loadingMore = false
    @State private var boards: [PinboardRow] = []
    @State private var selectedBoardID: UUID?
    @State private var searchText = ""
    @State private var status: CaptureStatus = .waiting
    @State private var selectedID: UUID?
    @State private var queryGeneration = 0
    @State private var alertMessage: String?
    @State private var actionMessage: String?
    @State private var boardName = ""
    @State private var showCreateBoard = false
    @State private var showRenameBoard = false
    @State private var showDeleteBoard = false
    @State private var showDeleteRecord = false
    @State private var rowToDelete: ClipRow?
    @State private var showClearHistory = false
    @State private var hotKeyRevision = 0
    @State private var loginRevision = 0
    @State private var defaultAutoPaste = UserDefaults.standard.object(forKey: "defaultAutoPaste") as? Bool ?? true
    @State private var defaultPlainText = UserDefaults.standard.bool(forKey: "defaultPlainText")
    @State private var showMenuIcon = UserDefaults.standard.object(forKey: "showMenuBarIcon") as? Bool ?? true
    @FocusState private var focusedArea: ManagerFocus?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            Group {
                switch section {
                case .history: historyContent
                case .pinboards: pinboardContent
                case .settings:
                    LocalSettingsView(
                        store: store,
                        recorder: recorder,
                        pasteController: pasteController,
                        hotKeys: hotKeys,
                        loginController: loginController,
                        defaultAutoPaste: $defaultAutoPaste,
                        defaultPlainText: $defaultPlainText,
                        showMenuIcon: $showMenuIcon,
                        hotKeyRevision: hotKeyRevision,
                        loginRevision: loginRevision,
                        onToggleMenuIcon: onToggleMenuIcon
                    )
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 780, idealWidth: 1040, maxWidth: 1400, minHeight: 360, idealHeight: 470, maxHeight: 700)
        .background(.regularMaterial)
        .onAppear {
            recorder.onStatusChange = { nextStatus in
                status = nextStatus
            }
            hotKeys.onChange = { hotKeyRevision += 1 }
            loginController.onChange = { loginRevision += 1 }
            status = recorder.status
            refreshBoards()
        }
        .task(id: "\(searchText)|\(selectedBoardID?.uuidString ?? "")|\(section.rawValue)") {
            queryGeneration += 1
            let generation = queryGeneration
            cancelCurrentQuery()
            rows = []
            selectedID = nil
            queryRevision = nil
            queryTotalCount = 0
            queryNextIndex = 0
            queryHasMore = false
            queryError = nil
            queryLoading = true
            let query = searchText
            let boardID = section == .pinboards ? selectedBoardID : nil
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            beginQuery(query: query, boardID: boardID, generation: generation)
        }
        .onReceive(NotificationCenter.default.publisher(for: .localClipsHistoryChanged)) { _ in restartQuery() }
        .onReceive(NotificationCenter.default.publisher(for: .localClipsPreviousBoardHotKey)) { _ in cycleBoard(-1) }
        .onReceive(NotificationCenter.default.publisher(for: .localClipsNextBoardHotKey)) { _ in cycleBoard(1) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginController.refresh()
        }
        .onExitCommand {
            pasteController.cancelPendingPaste()
            onDismiss()
        }
        .alert("新建 Pinboard", isPresented: $showCreateBoard) {
            TextField("名称", text: $boardName)
            Button("创建") { createBoard() }
            Button("取消", role: .cancel) { boardName = "" }
        }
        .alert("重命名 Pinboard", isPresented: $showRenameBoard) {
            TextField("名称", text: $boardName)
            Button("保存") { renameBoard() }
            Button("取消", role: .cancel) { boardName = "" }
        }
        .confirmationDialog("删除此 Pinboard？", isPresented: $showDeleteBoard, titleVisibility: .visible) {
            Button("删除收藏夹", role: .destructive) { deleteBoard() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除该收藏夹及其关系；其他收藏夹和历史记录保留。")
        }
        .confirmationDialog("清空历史？", isPresented: $showClearHistory, titleVisibility: .visible) {
            Button("清空历史", role: .destructive) {
                store.clearHistory { success in
                    alertMessage = success ? "历史已清空；收藏内容保留。" : "清理失败；已有内容未确认变更。"
                    refreshRows()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("收藏内容不会删除。此操作不会清理系统备份或承诺安全擦除。")
        }
        .confirmationDialog("删除此记录？", isPresented: $showDeleteRecord, titleVisibility: .visible) {
            Button("删除记录", role: .destructive) { deleteRecord() }
            Button("取消", role: .cancel) { rowToDelete = nil }
        } message: {
            Text(deleteRecordMessage)
        }
        .alert("LocalClips", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("确定", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "clipboard")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.tint)
            Text("LocalClips")
                .font(.headline)
            Picker("视图", selection: $section) {
                ForEach(ManagerSection.allCases) { item in Text(item.rawValue).tag(item) }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
            Spacer(minLength: 6)
            if section != .settings {
                TextField("搜索正文、标题或来源", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 170, idealWidth: 250, maxWidth: 320)
                    .accessibilityLabel("搜索历史")
                    .focused($focusedArea, equals: .search)
            }
            Button {
                if !recorder.hasStartedRecording || recorder.isPaused { recorder.resume() } else { recorder.pause() }
                pasteController.cancelPendingPaste()
                status = recorder.status
            } label: {
                Label(
                    !recorder.hasStartedRecording ? "开始记录" : (recorder.isPaused ? "恢复记录" : "暂停记录"),
                    systemImage: !recorder.hasStartedRecording ? "record.circle" : (recorder.isPaused ? "play.fill" : "pause.fill")
                )
            }
            .help(!recorder.hasStartedRecording ? "开始记录后续剪贴板变化" : (recorder.isPaused ? "恢复记录" : "暂停记录"))
            if section == .history {
                Button { showClearHistory = true } label: { Image(systemName: "trash") }
                    .help("清空历史，保留收藏")
                    .accessibilityLabel("清空历史")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var historyContent: some View {
        if !store.isReady {
            ContentUnavailableView("存储不可用", systemImage: "externaldrive.badge.exclamationmark", description: Text("现有数据库保留；检查存储状态后重试。"))
        } else if !recorder.hasStartedRecording {
            ContentUnavailableView {
                Label("剪贴板历史", systemImage: "clipboard")
            } description: {
                Text("开始记录后，后续复制内容会保存在此 Mac。可随时暂停；首次访问剪贴板时，macOS 可能询问是否允许。")
            } actions: {
                Button("开始记录") { recorder.resume() }
                    .buttonStyle(.borderedProminent)
            }
        } else if queryLoading {
            ProgressView("读取历史…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if rows.isEmpty, let queryError {
            ContentUnavailableView("查询失败", systemImage: "exclamationmark.triangle", description: Text(queryError))
        } else if rows.isEmpty {
            ContentUnavailableView("暂无历史", systemImage: "clipboard", description: Text("复制内容后，支持的格式会显示在这里。"))
        } else {
            cards(for: rows, inBoard: false)
        }
    }

    private var pinboardContent: some View {
        HStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Button { boardName = ""; showCreateBoard = true } label: { Image(systemName: "plus") }
                        .help("新建 Pinboard")
                    Button { prepareRename() } label: { Image(systemName: "pencil") }
                        .disabled(selectedBoardID == nil)
                        .help("重命名")
                    Button { showDeleteBoard = true } label: { Image(systemName: "trash") }
                        .disabled(selectedBoardID == nil)
                        .help("删除 Pinboard")
                    Button { moveBoard(-1) } label: { Image(systemName: "arrow.up") }
                        .disabled(boardIndex <= 0)
                        .help("上移收藏夹")
                    Button { moveBoard(1) } label: { Image(systemName: "arrow.down") }
                        .disabled(boardIndex < 0 || boardIndex >= boards.count - 1)
                        .help("下移收藏夹")
                }
                .buttonStyle(.bordered)
                List(selection: $selectedBoardID) {
                    ForEach(boards) { board in
                        HStack {
                            Text(board.name).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(board.count, format: .number)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .tag(Optional(board.id))
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(width: 210)
            .padding(10)
            Divider()
            Group {
                if selectedBoardID == nil {
                    ContentUnavailableView("选择 Pinboard", systemImage: "pin", description: Text("创建收藏夹后，可将同一条记录加入多个收藏夹。"))
                } else if queryLoading {
                    ProgressView("读取收藏…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if rows.isEmpty, let queryError {
                    ContentUnavailableView("查询失败", systemImage: "exclamationmark.triangle", description: Text(queryError))
                } else if rows.isEmpty {
                    ContentUnavailableView("收藏夹为空", systemImage: "pin", description: Text("从历史条目的固定菜单添加内容。"))
                } else {
                    cards(for: rows, inBoard: true)
                }
            }
        }
    }

    private func cards(for rows: [ClipRow], inBoard: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 10) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        ClipCard(
                            row: row,
                            selected: selectedID == row.id,
                            boards: boards,
                            automaticByDefault: defaultAutoPaste,
                            plainTextByDefault: defaultPlainText,
                            onPrimary: { run(row, automatic: defaultAutoPaste, plainText: defaultPlainText) },
                            onRestore: { run(row, automatic: false, plainText: false) },
                            onPlainText: { run(row, automatic: false, plainText: true) },
                            onToggleBoard: { boardID in
                                store.toggleMembership(recordID: row.id, boardID: boardID) { _ in
                                    refreshBoards()
                                    refreshRows()
                                }
                            },
                            onCreateBoard: { boardName = ""; showCreateBoard = true },
                            onDelete: {
                                rowToDelete = row
                                showDeleteRecord = true
                            },
                            onMoveUp: { moveRecord(row, by: -1, rows: rows) },
                            onMoveDown: { moveRecord(row, by: 1, rows: rows) },
                            canMoveUp: inBoard && searchText.isEmpty && index > 0,
                            canMoveDown: inBoard && searchText.isEmpty && index < rows.count - 1,
                            onSelect: {
                                selectedID = row.id
                                focusedArea = .cards
                            }
                        )
                        .id(row.id)
                    }
                    if queryHasMore {
                        Button(action: loadMore) {
                            VStack(spacing: 8) {
                                if loadingMore { ProgressView() }
                                Text(loadingMore ? "正在加载" : "加载更多")
                                Text("\(rows.count) / \(queryTotalCount)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 150, height: 278)
                        }
                        .buttonStyle(.bordered)
                        .disabled(loadingMore)
                        .accessibilityLabel("加载更多，已加载 \(rows.count)，共 \(queryTotalCount) 条")
                    }
                }
                .padding(14)
            }
            .background {
                CardsKeyboardInput(
                    onMove: { moveSelection($0, rows: rows) },
                    onSubmit: submitSelectedItem
                )
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
                .focused($focusedArea, equals: .cards)
            }
            .scrollIndicators(.automatic)
            .onChange(of: selectedID) { _, id in
                guard let id, rows.contains(where: { $0.id == id }) else { return }
                withAnimation(.easeInOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(status == .paused ? Color.orange : (store.isReady ? Color.green : Color.red))
                .frame(width: 7, height: 7)
            Text(status.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if let actionMessage {
                Text(actionMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("action-status")
            }
            Spacer(minLength: 8)
            Text("\(rows.count) / \(queryTotalCount) 条")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
    }

    private var boardIndex: Int { boards.firstIndex { $0.id == selectedBoardID } ?? -1 }

    private var deleteRecordMessage: String {
        guard let rowToDelete else { return "此记录及其收藏关系将被删除。" }
        let boardNote = rowToDelete.boardIDs.isEmpty ? "" : "同时从 \(rowToDelete.boardIDs.count) 个 Pinboard 移除。"
        return "从 LocalClips 删除此记录的历史和原始表示。\(boardNote)文件只保存引用，不删除原文件。"
    }

    private func refreshBoards() {
        store.pinboards { values in
            boards = values
            if selectedBoardID == nil, let first = values.first { selectedBoardID = first.id }
            if let selectedBoardID, !values.contains(where: { $0.id == selectedBoardID }) { self.selectedBoardID = values.first?.id }
        }
    }

    private func refreshRows() {
        restartQuery()
    }

    private func cancelCurrentQuery() {
        if let queryID { store.cancelQuery(queryID) }
        queryID = nil
    }

    private func beginQuery(query: String, boardID: UUID?, generation: Int) {
        guard generation == queryGeneration, query == searchText else { return }
        guard section != .settings, section != .pinboards || boardID != nil else {
            queryLoading = false
            return
        }
        let id = UUID()
        queryID = id
        store.beginQuery(id: id, query: query, boardID: boardID) { response in
            guard generation == queryGeneration, queryID == id, query == searchText else { return }
            apply(response, appending: false, queryID: id)
        }
    }

    private func restartQuery() {
        queryGeneration += 1
        let generation = queryGeneration
        cancelCurrentQuery()
        rows = []
        selectedID = nil
        queryRevision = nil
        queryTotalCount = 0
        queryNextIndex = 0
        queryHasMore = false
        queryError = nil
        queryLoading = true
        loadingMore = false
        guard section != .settings, section != .pinboards || selectedBoardID != nil else {
            queryLoading = false
            return
        }
        beginQuery(query: searchText, boardID: section == .pinboards ? selectedBoardID : nil, generation: generation)
    }

    private func loadMore() {
        guard !loadingMore, queryHasMore,
              let queryID, let queryRevision else { return }
        loadingMore = true
        let generation = queryGeneration
        let nextIndex = queryNextIndex
        let boardID = section == .pinboards ? selectedBoardID : nil
        store.loadNextPage(queryID: queryID, revision: queryRevision, nextIndex: nextIndex, boardID: boardID) { response in
            guard generation == queryGeneration, self.queryID == queryID else { return }
            apply(response, appending: true, queryID: queryID)
        }
    }

    private func apply(_ response: HistoryQueryResponse, appending: Bool, queryID: UUID) {
        switch response {
        case .page(let page):
            guard page.queryID == queryID else { return }
            if appending {
                var known = Set(rows.map(\.id))
                rows.append(contentsOf: page.rows.filter { known.insert($0.id).inserted })
            } else {
                rows = page.rows
            }
            queryRevision = page.revision
            queryTotalCount = page.totalCount
            queryNextIndex = page.nextIndex
            queryHasMore = page.hasMore
            queryLoading = false
            loadingMore = false
            queryError = nil
            if let selectedID, !rows.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
        case .invalidated:
            restartQuery()
        case .failed(let code):
            rows = []
            queryLoading = false
            loadingMore = false
            queryHasMore = false
            queryError = "本地查询失败（错误码 \(code)）。"
        }
    }

    private func submitSelectedItem() {
        guard focusedArea == .cards,
              section != .settings,
              !queryLoading,
              queryID != nil,
              queryRevision != nil,
              let selectedID,
              let row = rows.first(where: { $0.id == selectedID }) else { return }
        run(row, automatic: defaultAutoPaste, plainText: defaultPlainText)
    }

    private func run(_ row: ClipRow, automatic: Bool, plainText: Bool) {
        pasteController.perform(row, plainTextOnly: plainText, automatic: automatic, hidePanel: onDismiss) { result in
            onStatusMessage(result.message)
            switch result {
            case .eventSent, .cancelled:
                break
            default:
                actionMessage = result.message
            }
        }
    }

    private func createBoard() {
        let name = boardName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { alertMessage = "Pinboard 名称不能为空。"; return }
        store.createPinboard(name: name) { success in
            boardName = ""
            if !success { alertMessage = "Pinboard 创建失败。" }
            refreshBoards()
        }
    }

    private func prepareRename() {
        guard let selectedBoardID, let board = boards.first(where: { $0.id == selectedBoardID }) else { return }
        boardName = board.name
        showRenameBoard = true
    }

    private func renameBoard() {
        guard let selectedBoardID else { return }
        let name = boardName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { alertMessage = "Pinboard 名称不能为空。"; return }
        store.renamePinboard(selectedBoardID, name: name) { success in
            boardName = ""
            if !success { alertMessage = "重命名失败。" }
            refreshBoards()
        }
    }

    private func deleteBoard() {
        guard let selectedBoardID else { return }
        store.deletePinboard(selectedBoardID) { success in
            if !success { alertMessage = "删除收藏夹失败。" }
            self.selectedBoardID = nil
            refreshBoards()
        }
    }

    private func deleteRecord() {
        guard let rowToDelete else { return }
        store.deleteRecord(rowToDelete.id) { success in
            if !success { alertMessage = "删除失败；现有记录保留。" }
            self.rowToDelete = nil
            refreshBoards()
        }
    }

    private func moveBoard(_ offset: Int) {
        let target = boardIndex + offset
        guard boardIndex >= 0, boards.indices.contains(target) else { return }
        var updated = boards.map(\.id)
        updated.swapAt(boardIndex, target)
        store.reorderPinboards(updated) { _ in refreshBoards() }
    }

    private func moveRecord(_ row: ClipRow, by offset: Int, rows: [ClipRow]) {
        guard let selectedBoardID, let index = rows.firstIndex(where: { $0.id == row.id }) else { return }
        let target = index + offset
        guard rows.indices.contains(target) else { return }
        var ids = rows.map(\.id)
        ids.swapAt(index, target)
        store.reorderMemberships(boardID: selectedBoardID, recordIDs: ids) { _ in refreshRows() }
    }

    private func moveSelection(_ direction: MoveCommandDirection, rows: [ClipRow]) {
        guard !rows.isEmpty else { return }
        let offset: Int
        switch direction {
        case .left, .up: offset = -1
        case .right, .down: offset = 1
        @unknown default: return
        }
        let index = rows.firstIndex(where: { $0.id == selectedID }) ?? (offset > 0 ? -1 : rows.count)
        let next = min(max(index + offset, 0), rows.count - 1)
        selectedID = rows[next].id
    }

    private func cycleBoard(_ offset: Int) {
        guard !boards.isEmpty else { return }
        section = .pinboards
        let current = boardIndex < 0 ? 0 : boardIndex
        selectedBoardID = boards[(current + offset + boards.count) % boards.count].id
    }
}

private struct CardsKeyboardInput: NSViewRepresentable {
    let onMove: (MoveCommandDirection) -> Void
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> CardsKeyboardInputView {
        let view = CardsKeyboardInputView()
        view.onMove = onMove
        view.onSubmit = onSubmit
        return view
    }

    func updateNSView(_ view: CardsKeyboardInputView, context: Context) {
        view.onMove = onMove
        view.onSubmit = onSubmit
    }
}

private final class CardsKeyboardInputView: NSView {
    var onMove: ((MoveCommandDirection) -> Void)?
    var onSubmit: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else {
            super.keyDown(with: event)
            return
        }
        if let textInput = window?.firstResponder as? NSTextInputClient, textInput.hasMarkedText() {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 36, 76:
            if !event.isARepeat { onSubmit?() }
        case 123: onMove?(.left)
        case 124: onMove?(.right)
        case 125: onMove?(.down)
        case 126: onMove?(.up)
        default: super.keyDown(with: event)
        }
    }
}

private struct ClipCard: View {
    let row: ClipRow
    let selected: Bool
    let boards: [PinboardRow]
    let automaticByDefault: Bool
    let plainTextByDefault: Bool
    let onPrimary: () -> Void
    let onRestore: () -> Void
    let onPlainText: () -> Void
    let onToggleBoard: (UUID) -> Void
    let onCreateBoard: () -> Void
    let onDelete: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onSelect: () -> Void

    private var preview: String {
        if let text = ClipboardSnapshot(items: row.items, sourceBundleID: nil, sourceName: nil, sourceConfidence: "unknown").plainText {
            return text.isEmpty ? "空文本" : text
        }
        return switch row.kind {
        case "image": "图片内容"
        case "file": "文件引用"
        case "link": "链接内容"
        default: "剪贴板项目"
        }
    }

    private var hasPlainText: Bool {
        !row.items.isEmpty && row.items.allSatisfy { ClipboardSnapshot.plainText(for: $0) != nil }
    }

    private var imageData: Data? {
        let imageTypes: Set<String> = ["public.png", "public.tiff", "public.jpeg", "public.heic", "public.gif"]
        for item in row.items.sorted(by: { $0.position < $1.position }) {
            if let image = item.representations.first(where: { imageTypes.contains($0.typeIdentifier) || $0.typeIdentifier.hasPrefix("public.image") }) {
                return image.data
            }
        }
        return nil
    }

    private var sourceLabel: String {
        switch row.sourceConfidence {
        case "declared": "\(row.sourceName ?? row.sourceBundleID ?? "来源声明") · 声明"
        case "foregroundHeuristic": "\(row.sourceName ?? "来源未知") · 推断"
        default: "来源未知"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 23, height: 23)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                Spacer(minLength: 2)
                Menu {
                    if boards.isEmpty {
                        Button("新建 Pinboard", action: onCreateBoard)
                    } else {
                        ForEach(boards) { board in
                            Button {
                                onToggleBoard(board.id)
                            } label: {
                                Label(board.name, systemImage: row.boardIDs.contains(board.id) ? "checkmark" : "pin")
                            }
                        }
                    }
                    Divider()
                    Button(role: .destructive, action: onDelete) {
                        Label("删除记录", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: row.boardIDs.isEmpty ? "pin" : "pin.fill")
                        .foregroundStyle(row.boardIDs.isEmpty ? Color.secondary : Color.orange)
                }
                .menuStyle(.borderlessButton)
                .help("固定到 Pinboard")
                .accessibilityLabel("固定到 Pinboard")
                if canMoveUp {
                    Button(action: onMoveUp) { Image(systemName: "arrow.left") }
                        .buttonStyle(.plain)
                        .help("在收藏夹中上移")
                }
                if canMoveDown {
                    Button(action: onMoveDown) { Image(systemName: "arrow.right") }
                        .buttonStyle(.plain)
                        .help("在收藏夹中下移")
                }
            }
            Text(row.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onTapGesture(perform: onSelect)
            if let imageData {
                ClipboardImagePreview(data: imageData)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture(perform: onSelect)
            } else {
                Text(preview)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .onTapGesture(perform: onSelect)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(sourceLabel)
                    .help(row.sourceConfidence == "declared" ? "来源应用声明可被伪造，仅用于显示和排除匹配。" : "来源依据可用前台线索推断。")
                Text(row.capturedAt, format: .dateTime.year().month().day().hour().minute())
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            HStack(spacing: 6) {
                Button(automaticByDefault ? "粘贴" : "恢复", action: onPrimary)
                    .buttonStyle(.borderedProminent)
                    .disabled(automaticByDefault && plainTextByDefault && !hasPlainText)
                Button(action: onRestore) {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .help("仅恢复到系统剪贴板")
                .accessibilityLabel("仅恢复到系统剪贴板")
                Button(action: onPlainText) {
                    Image(systemName: "text.alignleft")
                }
                .buttonStyle(.bordered)
                .disabled(!hasPlainText)
                .help("单次仅恢复纯文本")
                .accessibilityLabel("单次仅恢复纯文本")
            }
        }
        .padding(10)
        .frame(width: 205, height: 278)
        .background(selected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected ? Color.accentColor.opacity(0.7) : Color(nsColor: .separatorColor), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }

    private var icon: String {
        switch row.kind {
        case "image": "photo"
        case "file": "doc"
        case "link": "link"
        case "richText": "textformat"
        default: "text.alignleft"
        }
    }
}

private struct ClipboardImagePreview: View {
    let data: Data
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("剪贴板图片预览")
            } else {
                ContentUnavailableView("图片预览不可用", systemImage: "photo")
            }
        }
        .task {
            guard image == nil,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 720,
                    kCGImageSourceShouldCache: false,
                  ] as CFDictionary) else { return }
            image = NSImage(cgImage: cgImage, size: .zero)
        }
    }
}
