import AppKit
import CoreData
import Foundation

private enum TestFailure: Error {
    case assertion(String)
}

@MainActor
private func expect(_ condition: @autoclosure () -> Bool, _ name: String) throws {
    guard condition() else { throw TestFailure.assertion(name) }
}

@MainActor
private final class TestClipboardItem: ClipboardItemReading {
    let values: [String: Data]

    init(text: String) {
        values = [NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)]
    }

    var types: [String] { Array(values.keys) }
    func data(forType type: String) -> Data? { values[type] }
    func string(forType type: String) -> String? { values[type].flatMap { String(data: $0, encoding: .utf8) } }
}

@MainActor
private final class TestClipboard: ClipboardReading {
    var changeCount = 0
    var accessDenied = false
    var types: [String] = []
    private var storedItems: [TestClipboardItem] = []
    var items: [any ClipboardItemReading]? {
        storedItems.indices.map { TestClipboardItemProxy(source: self, index: $0) }
    }
    var reads = 0
    var onNextDataRead: (() -> Void)?

    func set(_ text: String) {
        changeCount += 1
        let item = TestClipboardItem(text: text)
        types = item.types
        storedItems = [item]
    }

    func string(forType type: String) -> String? { storedItems.first?.string(forType: type) }

    func itemTypes(at index: Int) -> [String] { storedItems.indices.contains(index) ? storedItems[index].types : [] }
    func itemString(at index: Int, type: String) -> String? { storedItems.indices.contains(index) ? storedItems[index].string(forType: type) : nil }

    func readData(_ item: Int, type: String) -> Data? {
        reads += 1
        let value = storedItems.indices.contains(item) ? storedItems[item].data(forType: type) : nil
        let hook = onNextDataRead
        onNextDataRead = nil
        hook?()
        return value
    }
}

@MainActor
private final class TestClipboardItemProxy: ClipboardItemReading {
    let source: TestClipboard
    let index: Int

    init(source: TestClipboard, index: Int) { self.source = source; self.index = index }
    var types: [String] { source.itemTypes(at: index) }
    func data(forType type: String) -> Data? { source.readData(index, type: type) }
    func string(forType type: String) -> String? { source.itemString(at: index, type: type) }
}

@MainActor
private final class ManualRetryScheduler {
    private var operations: [@MainActor () -> Void] = []

    var pendingCount: Int { operations.count }

    func schedule(_ delay: TimeInterval, _ operation: @escaping @MainActor () -> Void) -> ScheduledCaptureRetry {
        operations.append(operation)
        return ScheduledCaptureRetry()
    }

    func runNext() {
        guard !operations.isEmpty else { return }
        operations.removeFirst()()
    }
}

@MainActor
private final class HeldSaver {
    private(set) var snapshots: [ClipboardSnapshot] = []
    private var completions: [@MainActor @Sendable (SnapshotCommitResult) -> Void] = []

    func save(_ snapshot: ClipboardSnapshot, completion: @escaping @MainActor @Sendable (SnapshotCommitResult) -> Void) {
        snapshots.append(snapshot)
        completions.append(completion)
    }

    func complete(_ index: Int, with result: SnapshotCommitResult = .saved) {
        guard completions.indices.contains(index) else { return }
        completions.remove(at: index)(result)
    }
}

private final class ControlledQueryExecutor: @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [@Sendable () -> Void] = []

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return operations.count
    }

    func enqueue(_ operation: @escaping @Sendable () -> Void) {
        lock.lock()
        operations.append(operation)
        lock.unlock()
    }

    func run(_ index: Int) {
        lock.lock()
        guard operations.indices.contains(index) else { lock.unlock(); return }
        let operation = operations.remove(at: index)
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async(execute: operation)
    }
}

private struct StoreFixture {
    let store: HistoryStore
    let container: NSPersistentContainer
    let preferences: UserDefaults
    let suiteName: String
}

@MainActor
private func makeStore(
    model: NSManagedObjectModel,
    root: URL,
    name: String,
    queryExecutor: HistoryStore.QueryExecutor? = nil
) async throws -> StoreFixture {
    let directory = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let container = NSPersistentContainer(name: "LocalClips", managedObjectModel: model)
    let description = NSPersistentStoreDescription(url: directory.appendingPathComponent("LocalClips.sqlite"))
    description.type = NSSQLiteStoreType
    description.shouldMigrateStoreAutomatically = true
    description.shouldInferMappingModelAutomatically = true
    container.persistentStoreDescriptions = [description]
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        container.loadPersistentStores { _, error in
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume() }
        }
    }
    let suiteName = "LocalClips.ADR0002.\(UUID().uuidString)"
    guard let preferences = UserDefaults(suiteName: suiteName) else { throw TestFailure.assertion("isolated preferences") }
    preferences.set(true, forKey: "recordingStarted")
    preferences.set(false, forKey: "recordingPaused")
    preferences.set(10_000, forKey: "historyLimit")
    preferences.set(3650, forKey: "historyAgeDays")
    preferences.set(Int64.max, forKey: "payloadBudgetBytes")
    let store = HistoryStore(container: container, preferences: preferences, queryExecutor: queryExecutor)
    return StoreFixture(store: store, container: container, preferences: preferences, suiteName: suiteName)
}

@MainActor
private func dispose(_ fixture: StoreFixture) {
    fixture.preferences.removePersistentDomain(forName: fixture.suiteName)
}

@MainActor
private func responseForQuery(_ store: HistoryStore, id: UUID = UUID(), query: String = "", boardID: UUID? = nil) async -> HistoryQueryResponse {
    return await withCheckedContinuation { continuation in
        store.beginQuery(id: id, query: query, boardID: boardID) { continuation.resume(returning: $0) }
    }
}

@MainActor
private func responseForPage(_ store: HistoryStore, _ page: HistoryQueryPage, boardID: UUID? = nil) async -> HistoryQueryResponse {
    await withCheckedContinuation { continuation in
        store.loadNextPage(queryID: page.queryID, revision: page.revision, nextIndex: page.nextIndex, boardID: boardID) {
            continuation.resume(returning: $0)
        }
    }
}

private struct SeededRows {
    let ids: [UUID]
    let boardID: UUID
}

private func seedRows(_ container: NSPersistentContainer, count: Int, board: Bool) throws -> SeededRows {
    let context = container.newBackgroundContext()
    return try context.performAndWait {
        let now = Date()
        let boardID = UUID()
        let boardObject: NSManagedObject?
        if board {
            let object = NSEntityDescription.insertNewObject(forEntityName: "Pinboard", into: context)
            object.setValue(boardID, forKey: "id")
            object.setValue("Synthetic Board", forKey: "name")
            object.setValue(0, forKey: "position")
            boardObject = object
        } else {
            boardObject = nil
        }
        var ids: [UUID] = []
        ids.reserveCapacity(count)
        for index in 0..<count {
            let id = UUID()
            ids.append(id)
            let text = index == count - 1 ? "rare-only-token" : "synthetic-row-\(index)"
            let record = NSEntityDescription.insertNewObject(forEntityName: "ClipRecord", into: context)
            record.setValue(id, forKey: "id")
            record.setValue(now, forKey: "createdAt")
            record.setValue(now.addingTimeInterval(-Double(index)), forKey: "lastCapturedAt")
            record.setValue("digest-\(index)", forKey: "digest")
            record.setValue(1, forKey: "hashVersion")
            record.setValue("text", forKey: "kind")
            record.setValue(Int64(text.utf8.count), forKey: "byteCount")
            record.setValue(true, forKey: "inHistory")
            record.setValue(text, forKey: "title")
            record.setValue(text, forKey: "searchText")
            record.setValue("unknown", forKey: "sourceConfidence")
            let item = NSEntityDescription.insertNewObject(forEntityName: "SnapshotItem", into: context)
            item.setValue(0, forKey: "position")
            item.setValue(record, forKey: "record")
            let representation = NSEntityDescription.insertNewObject(forEntityName: "Representation", into: context)
            representation.setValue(0, forKey: "position")
            representation.setValue(NSPasteboard.PasteboardType.string.rawValue, forKey: "typeIdentifier")
            representation.setValue(Data(text.utf8), forKey: "data")
            representation.setValue(item, forKey: "item")
            if let boardObject {
                let membership = NSEntityDescription.insertNewObject(forEntityName: "Membership", into: context)
                membership.setValue(UUID(), forKey: "id")
                membership.setValue(now, forKey: "addedAt")
                membership.setValue(index == count - 1 ? 0 : index + 1, forKey: "position")
                membership.setValue(record, forKey: "record")
                membership.setValue(boardObject, forKey: "board")
            }
        }
        try context.save()
        return SeededRows(ids: ids, boardID: boardID)
    }
}

private func seedSearchRows(_ container: NSPersistentContainer) throws -> [UUID: String] {
    let context = container.newBackgroundContext()
    return try context.performAndWait {
        let samples = [
            ("项目启动会议记录", "项目启动会议记录", nil),
            ("%_literal-token", "%_literal-token", nil),
            ("Cafe\u{301} receipt", "Cafe\u{301} receipt", nil),
            ("visible title", "Visible title", nil),
            ("stored source display name", "Source row", "Stored Source Display Name"),
        ]
        var expected: [UUID: String] = [:]
        let now = Date()
        for (index, sample) in samples.enumerated() {
            let id = UUID()
            expected[id] = sample.0
            let record = NSEntityDescription.insertNewObject(forEntityName: "ClipRecord", into: context)
            record.setValue(id, forKey: "id")
            record.setValue(now, forKey: "createdAt")
            record.setValue(now.addingTimeInterval(-Double(index)), forKey: "lastCapturedAt")
            record.setValue("search-\(index)", forKey: "digest")
            record.setValue(1, forKey: "hashVersion")
            record.setValue("text", forKey: "kind")
            record.setValue(Int64(sample.0.utf8.count), forKey: "byteCount")
            record.setValue(true, forKey: "inHistory")
            record.setValue(sample.1, forKey: "title")
            record.setValue([sample.0, sample.2 ?? ""].joined(separator: "\n"), forKey: "searchText")
            record.setValue(sample.2, forKey: "sourceName")
            record.setValue("unknown", forKey: "sourceConfidence")
            let item = NSEntityDescription.insertNewObject(forEntityName: "SnapshotItem", into: context)
            item.setValue(0, forKey: "position")
            item.setValue(record, forKey: "record")
            let representation = NSEntityDescription.insertNewObject(forEntityName: "Representation", into: context)
            representation.setValue(0, forKey: "position")
            representation.setValue(NSPasteboard.PasteboardType.string.rawValue, forKey: "typeIdentifier")
            representation.setValue(Data(sample.0.utf8), forKey: "data")
            representation.setValue(item, forKey: "item")
        }
        try context.save()
        return expected
    }
}

@MainActor
private func assertPage(_ response: HistoryQueryResponse, _ name: String) throws -> HistoryQueryPage {
    guard case .page(let page) = response else { throw TestFailure.assertion(name) }
    return page
}

@MainActor
private func testRecorderR01R02(model: NSManagedObjectModel, root: URL) async throws {
    do {
        let fixture = try await makeStore(model: model, root: root, name: "R01")
        defer { dispose(fixture) }
        let clipboard = TestClipboard()
        let retries = ManualRetryScheduler()
        var commits = 0
        let recorder = ClipboardRecorder(
            store: fixture.store,
            clipboardReader: clipboard,
            preferences: fixture.preferences,
            retryScheduler: retries.schedule,
            snapshotSaver: { _, completion in commits += 1; completion(.saved) }
        )
        recorder.start()
        clipboard.set("race-base")
        clipboard.onNextDataRead = { clipboard.set("race-one") }
        recorder.pollNow()
        try expect(retries.pendingCount == 1, "R01 retry 1 is bounded")
        clipboard.onNextDataRead = { clipboard.set("race-two") }
        retries.runNext()
        try expect(retries.pendingCount == 1, "R01 retry 2 is bounded")
        clipboard.onNextDataRead = { clipboard.set("stable-after-races") }
        retries.runNext()
        try expect(recorder.status == .unstableClipboard, "R01 exhaustion is reported")
        try expect(recorder.lastHandledCount == 0 && commits == 0, "R01 unstable count remains unhandled")
        recorder.pollNow()
        try expect(commits == 1 && recorder.lastHandledCount == clipboard.changeCount, "R01 next tick commits stable content once")
        recorder.stop()
    }
    do {
        let fixture = try await makeStore(model: model, root: root, name: "R02")
        defer { dispose(fixture) }
        let clipboard = TestClipboard()
        let retries = ManualRetryScheduler()
        var commits = 0
        let recorder = ClipboardRecorder(
            store: fixture.store,
            clipboardReader: clipboard,
            preferences: fixture.preferences,
            retryScheduler: retries.schedule,
            snapshotSaver: { _, completion in commits += 1; completion(.saved) }
        )
        recorder.start()
        clipboard.set("first")
        clipboard.onNextDataRead = { clipboard.set("second") }
        recorder.pollNow()
        for _ in 0..<50 { recorder.pollNow() }
        try expect(retries.pendingCount == 1, "R02 only one delayed retry chain exists")
        retries.runNext()
        try expect(commits == 1 && retries.pendingCount == 0, "R02 stable read resumes without task growth")
        recorder.stop()
    }
}

@MainActor
private func testRecorderR03R06(model: NSManagedObjectModel, root: URL) async throws {
    do {
        let fixture = try await makeStore(model: model, root: root, name: "R03")
        defer { dispose(fixture) }
        let clipboard = TestClipboard()
        let saver = HeldSaver()
        let recorder = ClipboardRecorder(store: fixture.store, clipboardReader: clipboard, preferences: fixture.preferences, snapshotSaver: saver.save)
        recorder.start()
        clipboard.set("commit-before-pause")
        recorder.pollNow()
        let baseline = recorder.lastHandledCount
        let readCount = clipboard.reads
        recorder.pause()
        saver.complete(0)
        recorder.pollNow()
        try expect(recorder.isPaused && recorder.status == .paused, "R03 old commit cannot clear pause")
        try expect(!recorder.isSaving && recorder.lastHandledCount == baseline, "R03 releases commit without changing paused baseline")
        try expect(clipboard.reads == readCount, "R03 paused recorder does not read")
        clipboard.set("paused-content")
        recorder.resume()
        recorder.pollNow()
        try expect(saver.snapshots.count == 1, "R03 resume baseline does not backfill paused content")
        clipboard.set("post-resume-content")
        recorder.pollNow()
        try expect(saver.snapshots.count == 2, "R03 one resume restores future capture")
        recorder.stop()
    }
    do {
        let fixture = try await makeStore(model: model, root: root, name: "R04")
        defer { dispose(fixture) }
        let clipboard = TestClipboard()
        let saver = HeldSaver()
        let recorder = ClipboardRecorder(store: fixture.store, clipboardReader: clipboard, preferences: fixture.preferences, snapshotSaver: saver.save)
        recorder.start()
        clipboard.set("A")
        recorder.pollNow()
        recorder.pause()
        clipboard.set("B-during-pause")
        recorder.resume()
        let resumeBaseline = recorder.lastHandledCount
        saver.complete(0)
        try expect(recorder.lastHandledCount == resumeBaseline, "R04 old callback preserves B baseline")
        recorder.pollNow()
        try expect(saver.snapshots.count == 1, "R04 paused B is not backfilled")
        clipboard.set("C-after-resume")
        recorder.pollNow()
        try expect(saver.snapshots.count == 2 && saver.snapshots[1].plainText == "C-after-resume", "R04 next stable C is captured")
        recorder.stop()
    }
    do {
        let fixture = try await makeStore(model: model, root: root, name: "R05")
        defer { dispose(fixture) }
        let clipboard = TestClipboard()
        let retries = ManualRetryScheduler()
        var commits = 0
        let recorder = ClipboardRecorder(
            store: fixture.store,
            clipboardReader: clipboard,
            preferences: fixture.preferences,
            retryScheduler: retries.schedule,
            snapshotSaver: { _, completion in commits += 1; completion(.saved) }
        )
        recorder.start()
        clipboard.set("retry-a")
        clipboard.onNextDataRead = { clipboard.set("retry-intermediate") }
        recorder.pollNow()
        try expect(retries.pendingCount == 1, "R05 retry scheduled")
        recorder.pause()
        clipboard.set("retry-paused")
        recorder.resume()
        let reads = clipboard.reads
        retries.runNext()
        try expect(clipboard.reads == reads && commits == 0, "R05 old retry is inert across epochs")
        clipboard.set("retry-new")
        recorder.pollNow()
        try expect(commits == 1, "R05 new epoch continues after stale retry")
        recorder.stop()
    }
    do {
        let fixture = try await makeStore(model: model, root: root, name: "R06")
        defer { dispose(fixture) }
        let clipboard = TestClipboard()
        let saver = HeldSaver()
        let recorder = ClipboardRecorder(store: fixture.store, clipboardReader: clipboard, preferences: fixture.preferences, snapshotSaver: saver.save)
        recorder.start()
        clipboard.set("commit-a")
        recorder.pollNow()
        clipboard.set("own-restore")
        let restored = ClipboardSnapshot(items: [
            CapturedItem(position: 0, representations: [CapturedRepresentation(
                typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
                position: 0,
                data: Data("own-restore".utf8),
                bookmarkData: nil
            )])
        ], sourceBundleID: nil, sourceName: nil, sourceConfidence: "unknown")
        recorder.noteOwnWrite(restored, changeCount: clipboard.changeCount)
        let restoreBaseline = recorder.lastHandledCount
        saver.complete(0)
        try expect(!recorder.isSaving && recorder.lastHandledCount == restoreBaseline, "R06 old callback releases commit without rolling back own-write baseline")
        recorder.pollNow()
        try expect(saver.snapshots.count == 1, "R06 own restore is not captured as new content")
        clipboard.set("after-restore")
        recorder.pollNow()
        try expect(saver.snapshots.count == 2, "R06 capture resumes after old callback")
        recorder.stop()
    }
}

@MainActor
private func testQueriesR07R10(model: NSManagedObjectModel, root: URL) async throws -> (StoreFixture, SeededRows) {
    let fixture = try await makeStore(model: model, root: root, name: "R07-R09")
    let seeded = try seedRows(fixture.container, count: 6001, board: true)
    let rare = try await assertPage(responseForQuery(fixture.store, query: "rare-only-token"), "R07 rare result page")
    try expect(rare.totalCount == 1 && rare.rows.first?.id == seeded.ids.last, "R07 oldest-only match is present in first page")

    var page = try await assertPage(responseForQuery(fixture.store), "R08 first page")
    var visited = Set<UUID>()
    var totalRows = 0
    while true {
        try expect(page.rows.count <= 100, "R08 page size <= 100")
        for row in page.rows { try expect(visited.insert(row.id).inserted, "R08 no duplicate id") }
        totalRows += page.rows.count
        if !page.hasMore { break }
        page = try await assertPage(responseForPage(fixture.store, page), "R08 next page")
    }
    try expect(totalRows == 6001 && visited == Set(seeded.ids), "R08 all 6001 IDs visited exactly once")

    let boardPage = try await assertPage(responseForQuery(fixture.store, boardID: seeded.boardID), "R09 board first page")
    try expect(boardPage.totalCount == 6001 && boardPage.rows.first?.id == seeded.ids.last, "R09 oldest record follows first membership position")
    try expect(boardPage.rows.first?.boardPosition == 0, "R09 board position retained")
    return (fixture, seeded)
}

@MainActor
private func testSearchR10(model: NSManagedObjectModel, root: URL) async throws {
    let fixture = try await makeStore(model: model, root: root, name: "R10")
    defer { dispose(fixture) }
    let ids = try seedSearchRows(fixture.container)
    let chinese = try await assertPage(responseForQuery(fixture.store, query: "启动会议"), "R10 Chinese substring")
    try expect(chinese.totalCount == 1 && chinese.rows.first?.searchText.contains("项目启动会议记录") == true, "R10 Chinese substring matches")
    let literal = try await assertPage(responseForQuery(fixture.store, query: "%_literal"), "R10 literal punctuation")
    try expect(literal.totalCount == 1, "R10 percent and underscore are literal")
    let folded = try await assertPage(responseForQuery(fixture.store, query: "CAFÉ"), "R10 Unicode fold")
    try expect(folded.totalCount == 1 && ids[folded.rows[0].id] == "Cafe\u{301} receipt", "R10 composed query matches decomposed text")
    let title = try await assertPage(responseForQuery(fixture.store, query: "Visible title"), "R10 title search")
    try expect(title.totalCount == 1, "R10 title is searchable")
    let source = try await assertPage(responseForQuery(fixture.store, query: "Stored Source Display Name"), "R10 source search")
    try expect(source.totalCount == 1, "R10 source display name is searchable")
}

@MainActor
private func testQueriesR11(model: NSManagedObjectModel, root: URL) async throws {
    let executor = ControlledQueryExecutor()
    let fixture = try await makeStore(model: model, root: root, name: "R11", queryExecutor: executor.enqueue)
    defer { dispose(fixture) }
    _ = try seedRows(fixture.container, count: 12, board: false)
    let idA = UUID()
    let idB = UUID()
    let taskA = Task { await responseForQuery(fixture.store, id: idA, query: "") }
    try await waitUntil { executor.pendingCount == 1 }
    let taskB = Task { await responseForQuery(fixture.store, id: idB, query: "rare-only-token") }
    try await waitUntil { executor.pendingCount == 2 }
    executor.run(1)
    let fast = try assertPage(await taskB.value, "R11 fast query")
    try expect(fast.queryID == idB && fast.totalCount == 1, "R11 B query returns before A")
    executor.run(0)
    let slow = try assertPage(await taskA.value, "R11 delayed query")
    try expect(slow.queryID == idA && slow.totalCount == 12, "R11 late A result retains its own identity")

    let cancelledID = UUID()
    let cancelledTask = Task { await responseForQuery(fixture.store, id: cancelledID, query: "") }
    try await waitUntil { executor.pendingCount == 1 }
    fixture.store.cancelQuery(cancelledID)
    executor.run(0)
    let cancelled = await cancelledTask.value
    if case .invalidated = cancelled {} else { throw TestFailure.assertion("R11 cancelled query must not publish results") }

    let firstTask = Task { await responseForQuery(fixture.store) }
    try await waitUntil { executor.pendingCount == 1 }
    executor.run(0)
    let first = try assertPage(await firstTask.value, "R11 invalidation first page")
    let deleteResult: Bool = await withCheckedContinuation { continuation in
        fixture.store.deleteRecord(first.rows[0].id) { continuation.resume(returning: $0) }
    }
    try expect(deleteResult, "R11 synthetic delete commits")
    let stalePage = await responseForPage(fixture.store, first)
    if case .invalidated = stalePage {
    } else {
        throw TestFailure.assertion("R11 stale page must report invalidation")
    }
}

@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<500 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw TestFailure.assertion("asynchronous regression operation timed out")
}

@MainActor
private func commitContent(_ snapshot: ClipboardSnapshot, to store: HistoryStore) async throws {
    let result = await withCheckedContinuation { continuation in
        store.save(snapshot) { continuation.resume(returning: $0) }
    }
    guard case .saved = result else { throw TestFailure.assertion("content commit") }
}

private func contentSnapshot(_ text: String, html: String?, source: String) -> ClipboardSnapshot {
    var representations: [CapturedRepresentation] = []
    if let html {
        representations.append(CapturedRepresentation(typeIdentifier: "public.html", position: 0, data: Data(html.utf8), bookmarkData: nil))
    }
    representations.append(CapturedRepresentation(typeIdentifier: NSPasteboard.PasteboardType.string.rawValue, position: representations.count, data: Data(text.utf8), bookmarkData: nil))
    return ClipboardSnapshot(items: [CapturedItem(position: 0, representations: representations)], sourceBundleID: "test." + source, sourceName: source, sourceConfidence: "declared")
}

@MainActor
private func testCrossApplicationContent(model: NSManagedObjectModel, root: URL) async throws {
    let fixture = try await makeStore(model: model, root: root, name: "content-dedupe")
    defer { dispose(fixture) }
    let first = contentSnapshot("same copied content", html: "<b>same copied content</b>", source: "Tabby")
    let latest = contentSnapshot("same copied content", html: "<div style='color:red'>same copied content</div>", source: "Edge")
    try await commitContent(first, to: fixture.store)
    let original = try assertPage(await responseForQuery(fixture.store), "original content").rows[0]
    let metadata = fixture.container.newBackgroundContext()
    let createdAt = try metadata.performAndWait { () throws -> Date in
        let request = NSFetchRequest<NSManagedObject>(entityName: "ClipRecord")
        request.predicate = NSPredicate(format: "id == %@", original.id as CVarArg)
        return try metadata.fetch(request)[0].value(forKey: "createdAt") as! Date
    }
    try await commitContent(contentSnapshot("another item", html: nil, source: "Other"), to: fixture.store)
    try await Task.sleep(for: .milliseconds(20))
    try await commitContent(latest, to: fixture.store)
    let result = try assertPage(await responseForQuery(fixture.store), "cross-application content")
    try expect(result.totalCount == 2, "same text from different apps and HTML must reuse one record")
    let merged = result.rows[0]
    try expect(merged.id == original.id && merged.capturedAt > original.capturedAt, "duplicate preserves UUID and refreshes lastCapturedAt to the front")
    try expect(merged.sourceName == "Edge" && merged.items == latest.items, "latest source and complete latest representations are retained")
    let refreshed = fixture.container.newBackgroundContext()
    let preservedCreatedAt = try refreshed.performAndWait { () throws -> Date in
        let request = NSFetchRequest<NSManagedObject>(entityName: "ClipRecord")
        request.predicate = NSPredicate(format: "id == %@", original.id as CVarArg)
        return try refreshed.fetch(request)[0].value(forKey: "createdAt") as! Date
    }
    try expect(preservedCreatedAt == createdAt, "first creation date is unchanged")
    try await commitContent(contentSnapshot("same copied content", html: nil, source: "PlainEditor"), to: fixture.store)
    let plain = try assertPage(await responseForQuery(fixture.store), "plain text equivalent")
    try expect(plain.totalCount == 2 && plain.rows[0].id == original.id, "plain and rich copies share text identity")
    try await commitContent(contentSnapshot("same copied content ", html: nil, source: "PlainEditor"), to: fixture.store)
    let whitespace = try assertPage(await responseForQuery(fixture.store), "distinct whitespace")
    try expect(whitespace.totalCount == 3, "meaningful whitespace is not trimmed")
    try await commitContent(contentSnapshot("line one\r\nCafe\u{301}", html: nil, source: "WindowsEditor"), to: fixture.store)
    let normalizedFirst = try assertPage(await responseForQuery(fixture.store), "normalized first")
    let normalizedID = normalizedFirst.rows[0].id
    try await commitContent(contentSnapshot("line one\nCafé", html: "<div>ignored source markup</div>", source: "MacEditor"), to: fixture.store)
    let normalized = try assertPage(await responseForQuery(fixture.store), "normalized latest")
    try expect(normalized.totalCount == 4 && normalized.rows[0].id == normalizedID, "line endings and canonical Unicode do not split identical text")
}

@MainActor
private func testRepeatedFileReference(model: NSManagedObjectModel, root: URL) async throws {
    let fixture = try await makeStore(model: model, root: root, name: "file-dedupe")
    defer { dispose(fixture) }
    let file = root.appendingPathComponent("same-reference.txt")
    try Data("synthetic file".utf8).write(to: file)
    var firstID: UUID?
    for index in 0..<10 {
        let reps = [
            CapturedRepresentation(typeIdentifier: "public.file-url", position: index % 2, data: Data(file.absoluteString.utf8), bookmarkData: try file.bookmarkData()),
            CapturedRepresentation(typeIdentifier: NSPasteboard.PasteboardType.string.rawValue, position: 2, data: Data("file label \(index)".utf8), bookmarkData: nil),
        ]
        try await commitContent(ClipboardSnapshot(items: [CapturedItem(position: 0, representations: reps)], sourceBundleID: "test.\(index)", sourceName: "Source \(index)", sourceConfidence: "declared"), to: fixture.store)
        let page = try assertPage(await responseForQuery(fixture.store), "file repetition")
        try expect(page.totalCount == 1, "same file reference remains one row across copies")
        if let firstID { try expect(page.rows[0].id == firstID, "file identity remains stable") }
        else { firstID = page.rows[0].id }
    }
    let otherFolder = root.appendingPathComponent("other-reference", isDirectory: true)
    try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)
    let otherFile = otherFolder.appendingPathComponent(file.lastPathComponent)
    try Data("synthetic file".utf8).write(to: otherFile)
    let other = ClipboardSnapshot(items: [CapturedItem(position: 0, representations: [
        CapturedRepresentation(typeIdentifier: "public.file-url", position: 0, data: Data(otherFile.absoluteString.utf8), bookmarkData: try otherFile.bookmarkData())
    ])], sourceBundleID: "test.other", sourceName: "Other", sourceConfidence: "declared")
    try await commitContent(other, to: fixture.store)
    let separate = try assertPage(await responseForQuery(fixture.store), "same name different file")
    try expect(separate.totalCount == 2, "different file references do not merge merely because names or bytes match")
}

@MainActor
private func testLegacyContentMerge(model: NSManagedObjectModel, root: URL) async throws {
    let fixture = try await makeStore(model: model, root: root, name: "legacy-content")
    defer { dispose(fixture) }
    let snapshots = [
        contentSnapshot("legacy same text", html: "<b>legacy same text</b>", source: "Tabby"),
        contentSnapshot("legacy same text", html: "<div>legacy same text</div>", source: "Edge"),
    ]
    let survivorID = UUID()
    let boardIDs = [UUID(), UUID()]
    let context = fixture.container.newBackgroundContext()
    try context.performAndWait {
        var boards: [NSManagedObject] = []
        for (index, id) in boardIDs.enumerated() {
            let board = NSEntityDescription.insertNewObject(forEntityName: "Pinboard", into: context)
            board.setValue(id, forKey: "id"); board.setValue("Board \(index)", forKey: "name"); board.setValue(index, forKey: "position")
            boards.append(board)
        }
        for (index, snapshot) in snapshots.enumerated() {
            let record = NSEntityDescription.insertNewObject(forEntityName: "ClipRecord", into: context)
            let values: [String: Any] = [
                "id": index == 0 ? survivorID : UUID(), "digest": snapshot.digest, "hashVersion": 1,
                "createdAt": Date(timeIntervalSince1970: Double(100 + index)), "lastCapturedAt": Date(timeIntervalSince1970: Double(200 + index)),
                "lastUsedAt": Date(timeIntervalSince1970: Double(150 + index)), "inHistory": true, "byteCount": snapshot.byteCount,
                "kind": snapshot.kind, "title": snapshot.title, "searchText": snapshot.plainText ?? "",
                "sourceBundleID": snapshot.sourceBundleID!, "sourceName": snapshot.sourceName!, "sourceConfidence": "declared",
            ]
            for (key, value) in values { record.setValue(value, forKey: key) }
            let item = NSEntityDescription.insertNewObject(forEntityName: "SnapshotItem", into: context)
            item.setValue(0, forKey: "position"); item.setValue(record, forKey: "record")
            for rep in snapshot.items[0].representations {
                let object = NSEntityDescription.insertNewObject(forEntityName: "Representation", into: context)
                object.setValue(rep.typeIdentifier, forKey: "typeIdentifier"); object.setValue(rep.position, forKey: "position")
                object.setValue(rep.data, forKey: "data"); object.setValue(item, forKey: "item")
            }
            for boardIndex in (index == 0 ? [0] : [0, 1]) {
                let member = NSEntityDescription.insertNewObject(forEntityName: "Membership", into: context)
                member.setValue(UUID(), forKey: "id"); member.setValue(Date(), forKey: "addedAt")
                member.setValue(index == 0 ? 5 : 2, forKey: "position")
                member.setValue(record, forKey: "record"); member.setValue(boards[boardIndex], forKey: "board")
            }
        }
        try context.save()
    }
    let reopened = HistoryStore(container: fixture.container, preferences: fixture.preferences)
    try expect(reopened.isReady, "legacy merge prepares store")
    let merged = try assertPage(await responseForQuery(reopened), "legacy consolidation")
    try expect(merged.totalCount == 1 && merged.rows[0].id == survivorID, "legacy duplicates consolidate into earliest stable UUID")
    try expect(merged.rows[0].sourceName == "Edge" && merged.rows[0].items == snapshots[1].items, "legacy consolidation retains latest copied representations")
    try expect(Set(merged.rows[0].boardIDs) == Set(boardIDs), "legacy consolidation preserves all pinboards")
    let pinned = try assertPage(await responseForQuery(reopened, boardID: boardIDs[0]), "merged membership")
    try expect(pinned.totalCount == 1 && pinned.rows[0].boardPosition == 2, "duplicate memberships preserve earliest visible position")
    let again = HistoryStore(container: fixture.container, preferences: fixture.preferences)
    let repeated = try assertPage(await responseForQuery(again), "idempotent migration")
    try expect(repeated.totalCount == 1, "reopening does not create duplicates")
}

@MainActor
private func testIncompleteLegacyContent(model: NSManagedObjectModel, root: URL) async throws {
    let fixture = try await makeStore(model: model, root: root, name: "legacy-incomplete")
    defer { dispose(fixture) }
    let boardID = UUID()
    let recordIDs = [UUID(), UUID()]
    let digests = ["legacy-empty-items", "legacy-empty-representations"]
    let capturedAt = Date(timeIntervalSince1970: 400)
    let context = fixture.container.newBackgroundContext()
    try context.performAndWait {
        let board = NSEntityDescription.insertNewObject(forEntityName: "Pinboard", into: context)
        board.setValue(boardID, forKey: "id")
        board.setValue("Preserved Board", forKey: "name")
        board.setValue(0, forKey: "position")

        for index in recordIDs.indices {
            let record = NSEntityDescription.insertNewObject(forEntityName: "ClipRecord", into: context)
            record.setValue(recordIDs[index], forKey: "id")
            record.setValue(digests[index], forKey: "digest")
            record.setValue(1, forKey: "hashVersion")
            record.setValue(Date(timeIntervalSince1970: 300 + Double(index)), forKey: "createdAt")
            record.setValue(capturedAt, forKey: "lastCapturedAt")
            record.setValue(0, forKey: "byteCount")
            record.setValue(true, forKey: "inHistory")
            record.setValue("text", forKey: "kind")
            record.setValue("Legacy item \(index)", forKey: "title")
            record.setValue("", forKey: "searchText")
            record.setValue("unknown", forKey: "sourceConfidence")

            if index == 1 {
                let item = NSEntityDescription.insertNewObject(forEntityName: "SnapshotItem", into: context)
                item.setValue(0, forKey: "position")
                item.setValue(record, forKey: "record")
            }

            let membership = NSEntityDescription.insertNewObject(forEntityName: "Membership", into: context)
            membership.setValue(UUID(), forKey: "id")
            membership.setValue(capturedAt, forKey: "addedAt")
            membership.setValue(index, forKey: "position")
            membership.setValue(record, forKey: "record")
            membership.setValue(board, forKey: "board")
        }
        try context.save()
    }

    let migrated = HistoryStore(container: fixture.container, preferences: fixture.preferences)
    try expect(migrated.isReady, "incomplete legacy rows do not block store readiness")
    let allRows = try await assertPage(responseForQuery(migrated), "incomplete legacy rows remain queryable")
    let boardRows = try await assertPage(responseForQuery(migrated, boardID: boardID), "incomplete legacy memberships remain")
    try expect(allRows.totalCount == 2 && Set(allRows.rows.map(\.id)) == Set(recordIDs), "incomplete legacy records are preserved separately")
    try expect(boardRows.totalCount == 2 && Set(boardRows.rows.map(\.id)) == Set(recordIDs), "incomplete legacy Pinboard relations are preserved")
    let emptyItems = allRows.rows.first { $0.id == recordIDs[0] }
    let emptyRepresentations = allRows.rows.first { $0.id == recordIDs[1] }
    try expect(emptyItems?.items.isEmpty == true, "empty legacy item structure remains unchanged")
    try expect(emptyRepresentations?.items.count == 1 && emptyRepresentations?.items.first?.representations.isEmpty == true, "empty legacy representation structure remains unchanged")

    let verify = fixture.container.newBackgroundContext()
    let stored = try verify.performAndWait { () throws -> [(Int, String, Date)] in
        try recordIDs.indices.map { index in
            let request = NSFetchRequest<NSManagedObject>(entityName: "ClipRecord")
            request.predicate = NSPredicate(format: "id == %@", recordIDs[index] as CVarArg)
            let record = try verify.fetch(request)[0]
            return (
                record.value(forKey: "hashVersion") as? Int ?? -1,
                record.value(forKey: "digest") as? String ?? "",
                record.value(forKey: "lastCapturedAt") as? Date ?? .distantPast
            )
        }
    }
    for index in stored.indices {
        try expect(stored[index].0 == 0, "unhashable legacy record receives terminal version")
        try expect(stored[index].1 == digests[index], "legacy digest remains unchanged")
        try expect(stored[index].2 == capturedAt, "legacy capture time remains unchanged")
    }

    let reopened = HistoryStore(container: fixture.container, preferences: fixture.preferences)
    try expect(reopened.isReady, "terminal legacy rows do not block a later open")
    let afterReopen = try await assertPage(responseForQuery(reopened), "terminal legacy rows remain after reopen")
    try expect(afterReopen.totalCount == 2 && Set(afterReopen.rows.map(\.id)) == Set(recordIDs), "later open preserves terminal legacy rows")
}

@main
private struct ADR0002Regression {
    @MainActor
    static func main() async {
        do {
            guard CommandLine.arguments.count == 3,
                  let model = NSManagedObjectModel(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])) else {
                throw TestFailure.assertion("compiled Core Data model unavailable")
            }
            let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            try await testCrossApplicationContent(model: model, root: root)
            try await testRepeatedFileReference(model: model, root: root)
            try await testLegacyContentMerge(model: model, root: root)
            try await testIncompleteLegacyContent(model: model, root: root)
            if ProcessInfo.processInfo.environment["LOCALCLIPS_CONTENT_ONLY"] == "1" {
                print("LocalClips regression tests passed (content and migration).")
                return
            }
            try await testRecorderR01R02(model: model, root: root)
            try await testRecorderR03R06(model: model, root: root)
            let largeFixture = try await testQueriesR07R10(model: model, root: root)
            dispose(largeFixture.0)
            try await testSearchR10(model: model, root: root)
            try await testQueriesR11(model: model, root: root)
            print("LocalClips ADR-0002 regressions passed (content, migration, R01-R11).")
        } catch {
            print("ADR-0002 regression failure: \(error)")
            Foundation.exit(EXIT_FAILURE)
        }
    }
}
