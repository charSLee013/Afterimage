import CoreData
import Foundation
import OSLog

extension Notification.Name {
    static let localClipsHistoryChanged = Notification.Name("LocalClips.HistoryChanged")
}

struct PinboardRow: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let count: Int
}

struct StorageStats: Sendable {
    let historyCount: Int
    let logicalBytes: Int64
    let physicalBytes: Int64
    let availableBytes: Int64
    let writable: Bool
}

struct HistoryQueryPage: Sendable {
    let queryID: UUID
    let revision: UInt64
    let rows: [ClipRow]
    let totalCount: Int
    let nextIndex: Int
    let hasMore: Bool
}

enum HistoryQueryResponse: Sendable {
    case page(HistoryQueryPage)
    case invalidated
    case failed(Int)
}

private enum StoreFailure: Error {
    case budgetFull
}

final class HistoryStore: @unchecked Sendable {
    typealias QueryExecutor = @Sendable (@escaping @Sendable () -> Void) -> Void

    private struct StoredQuery {
        let ids: [UUID]
        let revision: UInt64
        var nextIndex: Int
    }

    private struct QueryCandidate {
        let id: UUID
        let capturedAt: Date
        let boardPosition: Int?
    }

    private enum MatchingIDsResult: Sendable {
        case success([UUID])
        case failure(Int)
    }

    private let logger = Logger(subsystem: "local.charslee.localclips", category: "storage")
    private let writerQueue = DispatchQueue(label: "local.charslee.localclips.store-writer")
    private let preferences: UserDefaults
    private let queryExecutor: QueryExecutor
    private var container: NSPersistentContainer?
    private var writerContext: NSManagedObjectContext?
    private var queryRevision: UInt64 = 0
    private var activeQueries: [UUID: StoredQuery] = [:]
    private var pendingQueryIDs: Set<UUID> = []
    private var cancelledQueryIDs: Set<UUID> = []
    private(set) var isReady = false
    private(set) var loadErrorCode: Int?

    init(onReady: @escaping @MainActor (Bool) -> Void) {
        preferences = .standard
        queryExecutor = { work in DispatchQueue.global(qos: .userInitiated).async(execute: work) }
        guard let modelURL = Bundle.main.url(forResource: "LocalClips", withExtension: "momd"),
              let model = NSManagedObjectModel(contentsOf: modelURL) else {
            loadErrorCode = -1
            Task { @MainActor in onReady(false) }
            return
        }
        let container = NSPersistentContainer(name: "LocalClips", managedObjectModel: model)
        self.container = container
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalClips", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        } catch {
            loadErrorCode = (error as NSError).code
            Task { @MainActor in onReady(false) }
            return
        }
        let description = NSPersistentStoreDescription(url: support.appendingPathComponent("LocalClips.sqlite"))
        description.type = NSSQLiteStoreType
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        container.persistentStoreDescriptions = [description]
        load(container, onReady: onReady)
    }

    init(container: NSPersistentContainer, preferences: UserDefaults = .standard, queryExecutor: QueryExecutor? = nil) {
        self.preferences = preferences
        self.queryExecutor = queryExecutor ?? { work in DispatchQueue.global(qos: .userInitiated).async(execute: work) }
        self.container = container
        isReady = configureContexts(in: container)
    }

    private func load(_ container: NSPersistentContainer, onReady: @escaping @MainActor (Bool) -> Void) {
        container.loadPersistentStores { [weak self] _, error in
            guard let self, let container = self.container else { return }
            if let error {
                self.loadErrorCode = (error as NSError).code
                self.logger.error("store load failed code=\(self.loadErrorCode ?? -1, privacy: .public)")
            } else {
                self.isReady = self.configureContexts(in: container)
            }
            let ready = self.isReady
            Task { @MainActor in onReady(ready) }
        }
    }

    private func configureContexts(in container: NSPersistentContainer) -> Bool {
        writerContext = container.newBackgroundContext()
        writerContext?.mergePolicy = NSMergePolicy(merge: .mergeByPropertyStoreTrumpMergePolicyType)
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
        guard let context = writerContext else { return false }
        do {
            try context.performAndWait { try self.migrateContentIdentities(in: context) }
            return true
        } catch {
            context.performAndWait { context.rollback() }
            loadErrorCode = (error as NSError).code
            logger.error("content identity migration failed code=\(self.loadErrorCode ?? -1, privacy: .public)")
            return false
        }
    }

    func save(_ snapshot: ClipboardSnapshot, completion: @escaping @MainActor @Sendable (SnapshotCommitResult) -> Void) {
        guard isReady, writerContext != nil else {
            Task { @MainActor in completion(.failed) }
            return
        }
        guard Self.availableSpace(at: Self.dataDirectory) >= 512 * 1024 * 1024 else {
            Task { @MainActor in completion(.lowSpace) }
            return
        }
        writerQueue.async { [weak self] in
            guard let self, let context = self.writerContext else {
                Task { @MainActor in completion(.failed) }
                return
            }
            let result = context.performAndWait { () -> SnapshotCommitResult in
                do {
                    let existing = try self.matchingRecord(for: snapshot, in: context)
                    let record = existing ?? NSEntityDescription.insertNewObject(forEntityName: "ClipRecord", into: context)
                    let now = Date()
                    if existing == nil {
                        record.setValue(UUID(), forKey: "id")
                        record.setValue(now, forKey: "createdAt")
                    }
                    self.writeContent(snapshot, to: record, in: context)
                    record.setValue(now, forKey: "lastCapturedAt")
                    record.setValue(true, forKey: "inHistory")
                    guard try self.prune(context, preserving: record) else {
                        context.rollback()
                        return .budgetFull
                    }
                    try context.save()
                    return .saved
                } catch {
                    context.rollback()
                    self.logger.error("snapshot transaction failed code=\((error as NSError).code, privacy: .public)")
                    return .failed
                }
            }
            if case .saved = result { self.invalidateQueries() }
            Task { @MainActor in completion(result) }
        }
    }

    func storageStats(completion: @escaping @MainActor @Sendable (StorageStats) -> Void) {
        let available = Self.availableSpace(at: Self.dataDirectory)
        let physical = Self.physicalSize(at: Self.dataDirectory)
        guard isReady, let container else {
            Task { @MainActor in completion(StorageStats(historyCount: 0, logicalBytes: 0, physicalBytes: physical, availableBytes: available, writable: false)) }
            return
        }
        let context = container.newBackgroundContext()
        context.perform {
            let historyRequest = NSFetchRequest<NSManagedObject>(entityName: "ClipRecord")
            historyRequest.predicate = NSPredicate(format: "inHistory == YES")
            let history = (try? context.fetch(historyRequest)) ?? []
            let allRequest = NSFetchRequest<NSManagedObject>(entityName: "ClipRecord")
            let all = (try? context.fetch(allRequest)) ?? []
            let stats = StorageStats(
                historyCount: history.count,
                logicalBytes: all.reduce(Int64(0)) { $0 + ($1.value(forKey: "byteCount") as? Int64 ?? 0) },
                physicalBytes: physical,
                availableBytes: available,
                writable: available >= 512 * 1024 * 1024
            )
            Task { @MainActor in completion(stats) }
        }
    }

    @discardableResult
    func beginQuery(id queryID: UUID = UUID(), query: String = "", boardID: UUID? = nil, completion: @escaping @MainActor @Sendable (HistoryQueryResponse) -> Void) -> UUID {
        guard isReady, let container else {
            Task { @MainActor in completion(.failed(loadErrorCode ?? -1)) }
            return queryID
        }
        writerQueue.async { [weak self] in
            guard let self, self.isReady else {
                Task { @MainActor in completion(.failed(-1)) }
                return
            }
            self.pendingQueryIDs.insert(queryID)
            let revision = self.queryRevision
            self.queryExecutor { [weak self] in
                guard let self else { return }
                let context = container.newBackgroundContext()
                let ids = context.performAndWait { () -> MatchingIDsResult in
                    do { return .success(try self.matchingIDs(query: query, boardID: boardID, in: context)) }
                    catch { return .failure((error as NSError).code) }
                }
                self.writerQueue.async { [weak self] in
                    guard let self, self.pendingQueryIDs.remove(queryID) != nil else { return }
                    if self.cancelledQueryIDs.remove(queryID) != nil {
                        Task { @MainActor in completion(.invalidated) }
                        return
                    }
                    guard revision == self.queryRevision else {
                        Task { @MainActor in completion(.invalidated) }
                        return
                    }
                    guard case .success(let values) = ids else {
                        let code: Int
                        if case .failure(let value) = ids { code = value } else { code = -1 }
                        Task { @MainActor in completion(.failed(code)) }
                        return
                    }
                    let stored = StoredQuery(ids: values, revision: revision, nextIndex: 0)
                    self.activeQueries[queryID] = stored
                    let response = context.performAndWait {
                        try? self.materializePage(queryID: queryID, stored: stored, boardID: boardID, at: 0, in: context)
                    } ?? .failed(-1)
                    if case .failed = response { self.activeQueries.removeValue(forKey: queryID) }
                    Task { @MainActor in completion(response) }
                }
            }
        }
        return queryID
    }

    func loadNextPage(queryID: UUID, revision: UInt64, nextIndex: Int, boardID: UUID?, completion: @escaping @MainActor @Sendable (HistoryQueryResponse) -> Void) {
        writerQueue.async { [weak self] in
            guard let self, self.isReady, let stored = self.activeQueries[queryID],
                  stored.revision == revision, revision == self.queryRevision,
                  stored.nextIndex == nextIndex else {
                Task { @MainActor in completion(.invalidated) }
                return
            }
            guard let container = self.container else {
                Task { @MainActor in completion(.failed(-1)) }
                return
            }
            let context = container.newBackgroundContext()
            let result = context.performAndWait { () -> HistoryQueryResponse in
                do {
                    return try self.materializePage(queryID: queryID, stored: stored, boardID: boardID, at: nextIndex, in: context)
                } catch {
                    return .failed((error as NSError).code)
                }
            }
            Task { @MainActor in completion(result) }
        }
    }

    func cancelQuery(_ queryID: UUID) {
        writerQueue.async { [weak self] in
            guard let self else { return }
            self.activeQueries.removeValue(forKey: queryID)
            if self.pendingQueryIDs.contains(queryID) { self.cancelledQueryIDs.insert(queryID) }
        }
    }

    private func matchingIDs(query: String, boardID: UUID?, in context: NSManagedObjectContext) throws -> [UUID] {
        let folded = Self.fold(query)
        var candidates: [QueryCandidate] = []
        if let boardID {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Membership")
            request.predicate = NSPredicate(format: "board.id == %@", boardID as CVarArg)
            request.sortDescriptors = [NSSortDescriptor(key: "position", ascending: true)]
            request.fetchBatchSize = 256
            for membership in try context.fetch(request) {
                guard let record = membership.value(forKey: "record") as? NSManagedObject,
                      let id = record.value(forKey: "id") as? UUID,
                      let capturedAt = record.value(forKey: "lastCapturedAt") as? Date else { continue }
                let text = record.value(forKey: "searchText") as? String ?? ""
                guard folded.isEmpty || Self.fold(text).contains(folded) else { continue }
                candidates.append(QueryCandidate(
                    id: id,
                    capturedAt: capturedAt,
                    boardPosition: membership.value(forKey: "position") as? Int
                ))
            }
            var firstPositionByID: [UUID: QueryCandidate] = [:]
            for candidate in candidates {
                if let old = firstPositionByID[candidate.id], (old.boardPosition ?? .max) <= (candidate.boardPosition ?? .max) { continue }
                firstPositionByID[candidate.id] = candidate
            }
            candidates = Array(firstPositionByID.values)
        } else {
            let request = NSFetchRequest<NSManagedObject>(entityName: "ClipRecord")
            request.predicate = NSPredicate(format: "inHistory == YES")
            request.sortDescriptors = [
                NSSortDescriptor(key: "lastCapturedAt", ascending: false),
                NSSortDescriptor(key: "id", ascending: true),
            ]
            request.fetchBatchSize = 256
            for record in try context.fetch(request) {
                guard let id = record.value(forKey: "id") as? UUID,
                      let capturedAt = record.value(forKey: "lastCapturedAt") as? Date else { continue }
                let text = record.value(forKey: "searchText") as? String ?? ""
                guard folded.isEmpty || Self.fold(text).contains(folded) else { continue }
                candidates.append(QueryCandidate(id: id, capturedAt: capturedAt, boardPosition: nil))
            }
        }
        candidates.sort {
            if boardID != nil, $0.boardPosition != $1.boardPosition {
                return ($0.boardPosition ?? .max) < ($1.boardPosition ?? .max)
            }
            if $0.capturedAt != $1.capturedAt { return $0.capturedAt > $1.capturedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        return candidates.map(\.id)
    }

    private func materializePage(queryID: UUID, stored: StoredQuery, boardID: UUID?, at index: Int, in context: NSManagedObjectContext) throws -> HistoryQueryResponse {
        guard stored.revision == queryRevision, activeQueries[queryID]?.revision == stored.revision else { return .invalidated }
        guard index == stored.nextIndex, index >= 0, index <= stored.ids.count else { return .invalidated }
        let end = min(index + 100, stored.ids.count)
        let pageIDs = Array(stored.ids[index..<end])
        var rowsByID: [UUID: ClipRow] = [:]
        if !pageIDs.isEmpty {
            let request = NSFetchRequest<NSManagedObject>(entityName: "ClipRecord")
            request.predicate = NSPredicate(format: "id IN %@", pageIDs)
            for record in try context.fetch(request) {
                guard let id = record.value(forKey: "id") as? UUID,
                      let row = Self.makeRow(record, boardID: boardID) else { continue }
                rowsByID[id] = row
            }
            guard rowsByID.count == pageIDs.count else { return .invalidated }
        }
        let rows = pageIDs.compactMap { rowsByID[$0] }
        let updatedNextIndex = end
        activeQueries[queryID]?.nextIndex = updatedNextIndex
        return .page(HistoryQueryPage(
            queryID: queryID,
            revision: stored.revision,
            rows: rows,
            totalCount: stored.ids.count,
            nextIndex: updatedNextIndex,
            hasMore: updatedNextIndex < stored.ids.count
        ))
    }

    private func invalidateQueries() {
        queryRevision &+= 1
        activeQueries.removeAll(keepingCapacity: true)
        Task { @MainActor in
            NotificationCenter.default.post(name: .localClipsHistoryChanged, object: nil)
        }
    }

    func pinboards(completion: @escaping @MainActor @Sendable ([PinboardRow]) -> Void) {
        guard isReady, let container else {
            Task { @MainActor in completion([]) }
            return
        }
        let context = container.newBackgroundContext()
        context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Pinboard")
            request.sortDescriptors = [NSSortDescriptor(key: "position", ascending: true)]
            let boards = (try? context.fetch(request)) ?? []
            let rows = boards.compactMap { object -> PinboardRow? in
                guard let id = (object.value(forKey: "id") as? UUID),
                      let name = object.value(forKey: "name") as? String else { return nil }
                let memberships = object.value(forKey: "memberships") as? Set<NSManagedObject> ?? []
                return PinboardRow(id: id, name: name, count: memberships.count)
            }
            Task { @MainActor in completion(rows) }
        }
    }

    func createPinboard(name: String, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        mutate({ context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Pinboard")
            request.sortDescriptors = [NSSortDescriptor(key: "position", ascending: false)]
            request.fetchLimit = 1
            let last = try context.fetch(request).first?.value(forKey: "position") as? Int ?? -1
            let board = NSEntityDescription.insertNewObject(forEntityName: "Pinboard", into: context)
            board.setValue(UUID(), forKey: "id")
            board.setValue(name, forKey: "name")
            board.setValue(last + 1, forKey: "position")
        }, completion: completion)
    }

    func renamePinboard(_ id: UUID, name: String, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        mutate({ context in
            if let board = try self.object(id: id, entity: "Pinboard", context: context) {
                board.setValue(name, forKey: "name")
            }
        }, invalidatesQueries: false, completion: completion)
    }

    func deletePinboard(_ id: UUID, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        mutate({ context in
            if let board = try self.object(id: id, entity: "Pinboard", context: context) {
                context.delete(board)
                try self.deleteOrphans(in: context)
            }
        }, completion: completion)
    }

    func reorderPinboards(_ ids: [UUID], completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        mutate({ context in
            for (position, id) in ids.enumerated() {
                try self.object(id: id, entity: "Pinboard", context: context)?.setValue(position, forKey: "position")
            }
        }, invalidatesQueries: false, completion: completion)
    }

    func toggleMembership(recordID: UUID, boardID: UUID, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        mutate({ context in
            guard let record = try self.object(id: recordID, entity: "ClipRecord", context: context),
                  let board = try self.object(id: boardID, entity: "Pinboard", context: context) else { return }
            let existing = (record.value(forKey: "memberships") as? Set<NSManagedObject> ?? [])
                .first { (($0.value(forKey: "board") as? NSManagedObject)?.value(forKey: "id") as? UUID) == boardID }
            if let existing {
                context.delete(existing)
                try self.deleteOrphans(in: context)
            } else {
                let current = board.value(forKey: "memberships") as? Set<NSManagedObject> ?? []
                let lastPosition = current.compactMap { $0.value(forKey: "position") as? Int }.max() ?? -1
                let membership = NSEntityDescription.insertNewObject(forEntityName: "Membership", into: context)
                membership.setValue(UUID(), forKey: "id")
                membership.setValue(Date(), forKey: "addedAt")
                membership.setValue(lastPosition + 1, forKey: "position")
                membership.setValue(record, forKey: "record")
                membership.setValue(board, forKey: "board")
            }
        }, completion: completion)
    }

    func reorderMemberships(boardID: UUID, recordIDs: [UUID], completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        mutate({ context in
            guard let board = try self.object(id: boardID, entity: "Pinboard", context: context) else { return }
            let memberships = board.value(forKey: "memberships") as? Set<NSManagedObject> ?? []
            var byRecordID: [UUID: NSManagedObject] = [:]
            for membership in memberships {
                guard let record = membership.value(forKey: "record") as? NSManagedObject,
                      let id = record.value(forKey: "id") as? UUID,
                      byRecordID[id] == nil else { continue }
                byRecordID[id] = membership
            }
            for (position, id) in recordIDs.enumerated() {
                byRecordID[id]?.setValue(position, forKey: "position")
            }
        }, completion: completion)
    }

    func clearHistory(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        mutate({ context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "ClipRecord")
            request.predicate = NSPredicate(format: "inHistory == YES")
            for record in try context.fetch(request) { record.setValue(false, forKey: "inHistory") }
            try self.deleteOrphans(in: context)
        }, completion: completion)
    }

    func deleteRecord(_ id: UUID, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        mutate({ context in
            if let record = try self.object(id: id, entity: "ClipRecord", context: context) {
                context.delete(record)
            }
        }, completion: completion)
    }

    func markUsed(_ recordID: UUID) {
        mutate({ context in
            try self.object(id: recordID, entity: "ClipRecord", context: context)?.setValue(Date(), forKey: "lastUsedAt")
        }, invalidatesQueries: false, completion: { _ in })
    }

    func pruneHistory(completion: @escaping @MainActor @Sendable (Bool) -> Void = { _ in }) {
        mutate({ context in
            guard try self.prune(context) else { throw StoreFailure.budgetFull }
        }, completion: completion)
    }

    func updateLimits(maxCount: Int, maxAgeDays: Int, budgetBytes: Int64, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard isReady, writerContext != nil else {
            Task { @MainActor in completion(false) }
            return
        }
        writerQueue.async { [weak self] in
            guard let self, let context = self.writerContext else {
                Task { @MainActor in completion(false) }
                return
            }
            let succeeded = context.performAndWait { () -> Bool in
                do {
                    guard try self.prune(context, limits: (maxCount, maxAgeDays, budgetBytes)) else {
                        context.rollback()
                        return false
                    }
                    if context.hasChanges { try context.save() }
                    return true
                } catch {
                    context.rollback()
                    self.logger.error("limit update failed code=\((error as NSError).code, privacy: .public)")
                    return false
                }
            }
            if succeeded {
                self.invalidateQueries()
                self.preferences.set(maxCount, forKey: "historyLimit")
                self.preferences.set(maxAgeDays, forKey: "historyAgeDays")
                self.preferences.set(budgetBytes, forKey: "payloadBudgetBytes")
            }
            Task { @MainActor in completion(succeeded) }
        }
    }

    private func mutate(
        _ body: @escaping @Sendable (NSManagedObjectContext) throws -> Void,
        invalidatesQueries: Bool = true,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        guard isReady, writerContext != nil else {
            Task { @MainActor in completion(false) }
            return
        }
        writerQueue.async { [weak self] in
            guard let self, let context = self.writerContext else {
                Task { @MainActor in completion(false) }
                return
            }
            let succeeded = context.performAndWait { () -> Bool in
                do {
                    try body(context)
                    if context.hasChanges { try context.save() }
                    return true
                } catch {
                    context.rollback()
                    self.logger.error("store operation failed code=\((error as NSError).code, privacy: .public)")
                    return false
                }
            }
            if succeeded, invalidatesQueries { self.invalidateQueries() }
            Task { @MainActor in completion(succeeded) }
        }
    }

    private func matchingRecord(for snapshot: ClipboardSnapshot, in context: NSManagedObjectContext) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "ClipRecord")
        request.predicate = NSPredicate(format: "digest == %@ AND hashVersion == %d", snapshot.contentDigest, ClipboardSnapshot.contentHashVersion)
        for candidate in try context.fetch(request)
        where Self.snapshot(candidate).contentIdentity == snapshot.contentIdentity {
            return candidate
        }
        return nil
    }

    private static func snapshot(_ record: NSManagedObject) -> ClipboardSnapshot {
        ClipboardSnapshot(
            items: payload(record),
            sourceBundleID: record.value(forKey: "sourceBundleID") as? String,
            sourceName: record.value(forKey: "sourceName") as? String,
            sourceConfidence: record.value(forKey: "sourceConfidence") as? String ?? "unknown"
        )
    }

    private func writeContent(_ snapshot: ClipboardSnapshot, to record: NSManagedObject, in context: NSManagedObjectContext) {
        let existingPayload = Self.payload(record)
        if Self.payloadEquals(existingPayload, snapshot.items) {
            refreshBookmarks(snapshot.items, for: record)
        } else {
            let existingItems = record.value(forKey: "items") as? Set<NSManagedObject> ?? []
            for item in existingItems { context.delete(item) }
            context.processPendingChanges()
            insert(snapshot.items, for: record, into: context)
        }
        record.setValue(snapshot.contentDigest, forKey: "digest")
        record.setValue(ClipboardSnapshot.contentHashVersion, forKey: "hashVersion")
        record.setValue(snapshot.kind, forKey: "kind")
        record.setValue(snapshot.title, forKey: "title")
        record.setValue(snapshot.sourceBundleID, forKey: "sourceBundleID")
        record.setValue(snapshot.sourceName, forKey: "sourceName")
        record.setValue(snapshot.sourceConfidence, forKey: "sourceConfidence")
        record.setValue(searchText(for: snapshot), forKey: "searchText")
        let storedBytes = Self.payload(record).reduce(Int64(0)) { total, item in
            total + item.representations.reduce(0) { $0 + Int64($1.data.count + ($1.bookmarkData?.count ?? 0)) }
        }
        record.setValue(storedBytes, forKey: "byteCount")
    }

    private func migrateContentIdentities(in context: NSManagedObjectContext) throws {
        let legacy = NSFetchRequest<NSManagedObject>(entityName: "ClipRecord")
        legacy.predicate = NSPredicate(format: "hashVersion > 0 AND hashVersion < %d", ClipboardSnapshot.contentHashVersion)
        legacy.fetchLimit = 1
        guard try context.count(for: legacy) > 0 else { return }

        let request = NSFetchRequest<NSManagedObject>(entityName: "ClipRecord")
        request.sortDescriptors = [
            NSSortDescriptor(key: "createdAt", ascending: true),
            NSSortDescriptor(key: "id", ascending: true)
        ]
        request.fetchBatchSize = 100
        var groups: [String: [NSManagedObject]] = [:]
        for record in try context.fetch(request) {
            let content = Self.snapshot(record)
            // Do not collapse unreadable or incomplete legacy records into an empty payload.
            guard !content.items.isEmpty, content.items.allSatisfy({ !$0.representations.isEmpty }) else {
                let version = record.value(forKey: "hashVersion") as? Int ?? 0
                if version > 0, version < ClipboardSnapshot.contentHashVersion {
                    // Version 0 preserves this row while keeping future launches off the migration scan.
                    record.setValue(0, forKey: "hashVersion")
                }
                continue
            }
            let key = content.contentDigest
            if let survivor = groups[key]?.first(where: { Self.snapshot($0).contentIdentity == content.contentIdentity }) {
                let latest = record.value(forKey: "lastCapturedAt") as? Date ?? .distantPast
                let previous = survivor.value(forKey: "lastCapturedAt") as? Date ?? .distantPast
                if latest > previous {
                    writeContent(content, to: survivor, in: context)
                    survivor.setValue(latest, forKey: "lastCapturedAt")
                }
                if record.value(forKey: "inHistory") as? Bool == true { survivor.setValue(true, forKey: "inHistory") }
                if let usedAt = record.value(forKey: "lastUsedAt") as? Date,
                   usedAt > (survivor.value(forKey: "lastUsedAt") as? Date ?? .distantPast) {
                    survivor.setValue(usedAt, forKey: "lastUsedAt")
                }
                mergeMemberships(from: record, into: survivor, in: context)
                context.delete(record)
            } else {
                record.setValue(key, forKey: "digest")
                record.setValue(ClipboardSnapshot.contentHashVersion, forKey: "hashVersion")
                groups[key, default: []].append(record)
            }
        }
        context.processPendingChanges()
        if context.hasChanges { try context.save() }
    }

    private func mergeMemberships(from duplicate: NSManagedObject, into survivor: NSManagedObject, in context: NSManagedObjectContext) {
        let memberships = duplicate.value(forKey: "memberships") as? Set<NSManagedObject> ?? []
        for membership in memberships {
            guard let board = membership.value(forKey: "board") as? NSManagedObject else { continue }
            let existing = (survivor.value(forKey: "memberships") as? Set<NSManagedObject> ?? []).first {
                !$0.isDeleted && ($0.value(forKey: "board") as? NSManagedObject)?.objectID == board.objectID
            }
            if let existing {
                let position = min(existing.value(forKey: "position") as? Int ?? 0, membership.value(forKey: "position") as? Int ?? 0)
                existing.setValue(position, forKey: "position")
                if let addedAt = membership.value(forKey: "addedAt") as? Date,
                   addedAt < (existing.value(forKey: "addedAt") as? Date ?? .distantFuture) {
                    existing.setValue(addedAt, forKey: "addedAt")
                }
                context.delete(membership)
            } else {
                membership.setValue(survivor, forKey: "record")
            }
        }
    }

    private func insert(_ items: [CapturedItem], for record: NSManagedObject, into context: NSManagedObjectContext) {
        for item in items {
            let itemObject = NSEntityDescription.insertNewObject(forEntityName: "SnapshotItem", into: context)
            itemObject.setValue(item.position, forKey: "position")
            itemObject.setValue(record, forKey: "record")
            for representation in item.representations {
                let representationObject = NSEntityDescription.insertNewObject(forEntityName: "Representation", into: context)
                representationObject.setValue(representation.typeIdentifier, forKey: "typeIdentifier")
                representationObject.setValue(representation.position, forKey: "position")
                representationObject.setValue(representation.data, forKey: "data")
                representationObject.setValue(representation.bookmarkData, forKey: "bookmarkData")
                representationObject.setValue(itemObject, forKey: "item")
            }
        }
    }

    private func searchText(for snapshot: ClipboardSnapshot) -> String {
        [snapshot.title, snapshot.plainText ?? "", snapshot.sourceName ?? ""].joined(separator: "\n")
    }

    private func prune(
        _ context: NSManagedObjectContext,
        preserving incoming: NSManagedObject? = nil,
        limits: (maxCount: Int, maxAgeDays: Int, budgetBytes: Int64)? = nil
    ) throws -> Bool {
        let request = NSFetchRequest<NSManagedObject>(entityName: "ClipRecord")
        request.predicate = NSPredicate(format: "inHistory == YES")
        request.sortDescriptors = [NSSortDescriptor(key: "lastCapturedAt", ascending: false)]
        let records = try context.fetch(request)
        let configuredLimit = limits?.maxCount ?? (preferences.object(forKey: "historyLimit") as? Int ?? 1000)
        let maxCount = configuredLimit
        let ageDays = limits?.maxAgeDays ?? (preferences.object(forKey: "historyAgeDays") as? Int ?? 30)
        let budget = limits?.budgetBytes ?? (preferences.object(forKey: "payloadBudgetBytes") as? Int64 ?? 1_073_741_824)
        let cutoff = ageDays <= 0 ? nil : Calendar.current.date(byAdding: .day, value: -ageDays, to: Date())
        for (index, record) in records.enumerated() {
            let date = record.value(forKey: "lastCapturedAt") as? Date ?? .distantPast
            let isOverCount = maxCount > 0 && index >= maxCount
            let isExpired = cutoff.map { date < $0 } ?? false
            if isExpired || isOverCount {
                record.setValue(false, forKey: "inHistory")
            }
        }
        try deleteOrphans(in: context)
        let allRequest = NSFetchRequest<NSManagedObject>(entityName: "ClipRecord")
        allRequest.sortDescriptors = [NSSortDescriptor(key: "lastCapturedAt", ascending: true)]
        let allRecords = try context.fetch(allRequest)
        var totalBytes = allRecords.reduce(Int64(0)) { $0 + ($1.value(forKey: "byteCount") as? Int64 ?? 0) }
        if totalBytes <= budget { return true }
        let protectedBytes = allRecords.reduce(Int64(0)) { total, record in
            let memberships = record.value(forKey: "memberships") as? Set<NSManagedObject> ?? []
            return total + (memberships.isEmpty ? 0 : (record.value(forKey: "byteCount") as? Int64 ?? 0))
        }
        guard protectedBytes <= budget else { return false }
        let incomingID = incoming?.value(forKey: "id") as? UUID
        for record in allRecords {
            let memberships = record.value(forKey: "memberships") as? Set<NSManagedObject> ?? []
            let id = record.value(forKey: "id") as? UUID
            guard memberships.isEmpty,
                  (record.value(forKey: "inHistory") as? Bool ?? false),
                  id != incomingID else { continue }
            let size = record.value(forKey: "byteCount") as? Int64 ?? 0
            record.setValue(false, forKey: "inHistory")
            context.delete(record)
            totalBytes -= size
            if totalBytes <= budget { break }
        }
        return totalBytes <= budget
    }

    private func deleteOrphans(in context: NSManagedObjectContext) throws {
        let request = NSFetchRequest<NSManagedObject>(entityName: "ClipRecord")
        request.predicate = NSPredicate(format: "inHistory == NO")
        for record in try context.fetch(request) {
            let memberships = record.value(forKey: "memberships") as? Set<NSManagedObject> ?? []
            if memberships.isEmpty { context.delete(record) }
        }
    }

    private func object(id: UUID, entity: String, context: NSManagedObjectContext) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: entity)
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    private static func makeRow(_ record: NSManagedObject, boardID: UUID? = nil) -> ClipRow? {
        guard let id = record.value(forKey: "id") as? UUID,
              let digest = record.value(forKey: "digest") as? String,
              let title = record.value(forKey: "title") as? String else { return nil }
        let itemObjects = (record.value(forKey: "items") as? Set<NSManagedObject> ?? []).sorted {
            ($0.value(forKey: "position") as? Int ?? 0) < ($1.value(forKey: "position") as? Int ?? 0)
        }
        let items = itemObjects.map { item in
            let representations = (item.value(forKey: "representations") as? Set<NSManagedObject> ?? []).sorted {
                ($0.value(forKey: "position") as? Int ?? 0) < ($1.value(forKey: "position") as? Int ?? 0)
            }.compactMap { object -> CapturedRepresentation? in
                guard let type = object.value(forKey: "typeIdentifier") as? String,
                      let data = object.value(forKey: "data") as? Data else { return nil }
                return CapturedRepresentation(
                    typeIdentifier: type,
                    position: object.value(forKey: "position") as? Int ?? 0,
                    data: data,
                    bookmarkData: object.value(forKey: "bookmarkData") as? Data
                )
            }
            return CapturedItem(position: item.value(forKey: "position") as? Int ?? 0, representations: representations)
        }
        let memberships = record.value(forKey: "memberships") as? Set<NSManagedObject> ?? []
        let boards = memberships.compactMap { ($0.value(forKey: "board") as? NSManagedObject)?.value(forKey: "name") as? String }
        let boardIDs = memberships.compactMap { ($0.value(forKey: "board") as? NSManagedObject)?.value(forKey: "id") as? UUID }
        let boardPosition = memberships.first(where: {
            (($0.value(forKey: "board") as? NSManagedObject)?.value(forKey: "id") as? UUID) == boardID
        })?.value(forKey: "position") as? Int
        return ClipRow(
            id: id,
            digest: digest,
            title: title,
            searchText: record.value(forKey: "searchText") as? String ?? title,
            kind: record.value(forKey: "kind") as? String ?? "text",
            capturedAt: record.value(forKey: "lastCapturedAt") as? Date ?? .distantPast,
            sourceName: record.value(forKey: "sourceName") as? String,
            sourceBundleID: record.value(forKey: "sourceBundleID") as? String,
            sourceConfidence: record.value(forKey: "sourceConfidence") as? String ?? "unknown",
            byteCount: record.value(forKey: "byteCount") as? Int64 ?? 0,
            items: items,
            boards: boards,
            boardIDs: boardIDs,
            boardPosition: boardPosition
        )
    }

    private static func payload(_ record: NSManagedObject) -> [CapturedItem] {
        guard let row = makeRow(record) else { return [] }
        return row.items
    }

    private func refreshBookmarks(_ items: [CapturedItem], for record: NSManagedObject) {
        let storedItems = record.value(forKey: "items") as? Set<NSManagedObject> ?? []
        let byPosition = Dictionary(uniqueKeysWithValues: storedItems.compactMap { item -> (Int, NSManagedObject)? in
            guard let position = item.value(forKey: "position") as? Int else { return nil }
            return (position, item)
        })
        for item in items {
            guard let storedItem = byPosition[item.position] else { continue }
            let storedRepresentations = storedItem.value(forKey: "representations") as? Set<NSManagedObject> ?? []
            for representation in item.representations where representation.bookmarkData != nil {
                if let stored = storedRepresentations.first(where: {
                    ($0.value(forKey: "typeIdentifier") as? String) == representation.typeIdentifier &&
                    ($0.value(forKey: "position") as? Int) == representation.position
                }) {
                    stored.setValue(representation.bookmarkData, forKey: "bookmarkData")
                }
            }
        }
    }

    private static func payloadEquals(_ lhs: [CapturedItem], _ rhs: [CapturedItem]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (left, right) in zip(lhs.sorted(by: { $0.position < $1.position }), rhs.sorted(by: { $0.position < $1.position })) {
            guard left.position == right.position, left.representations.count == right.representations.count else { return false }
            for (leftRep, rightRep) in zip(left.representations.sorted(by: { $0.position < $1.position }), right.representations.sorted(by: { $0.position < $1.position })) {
                guard leftRep.position == rightRep.position,
                      leftRep.typeIdentifier == rightRep.typeIdentifier,
                      leftRep.data == rightRep.data else { return false }
            }
        }
        return true
    }

    private static func fold(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static var dataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalClips", isDirectory: true)
    }

    private static func availableSpace(at url: URL) -> Int64 {
        let values = try? FileManager.default.attributesOfFileSystem(forPath: url.path)
        return (values?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }

    private static func physicalSize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

}
