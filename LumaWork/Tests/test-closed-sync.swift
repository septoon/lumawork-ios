import Foundation

private final class FixtureServer: @unchecked Sendable {
    let lock = NSLock()
    var paths: [String] = []
    var active = 0
    var maximumActive = 0
    var rows: [[String: Any]] = []
    var serialReadable = true
    var listVersion = false
    var failID: String?
    var versions: [String: String] = [:]
    var pageCap: Int?

    func response(_ request: URLRequest) throws -> (Data, Int) {
        lock.lock()
        defer { lock.unlock() }
        active += 1
        maximumActive = max(maximumActive, active)
        let path = request.url!.path
        paths.append(path)
        var data: [String: Any]
        if path.hasSuffix("/list/itsm_request") {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
            let page = Int(query.first { $0.name == "page" }?.value ?? "1")!
            let requestedPageSize = Int(query.first { $0.name == "per_page" }?.value ?? "20")!
            let perPage = min(requestedPageSize, pageCap ?? requestedPageSize)
            let start = min((page - 1) * perPage, rows.count)
            data = ["list": rows[start..<min(start + perPage, rows.count)].map { row in
                var row = row
                if listVersion, query.first(where: { $0.name == "columns" })?.value?.contains("sys_updated_at") == true {
                    row["sys_updated_at"] = ["value": "2026-11-05 12:00:00"]
                }
                return row
            }, "total": rows.count]
        } else if path.contains("/record/") {
            data = rows.first { ($0["sys_id"] as? String) == request.url!.lastPathComponent }!
        } else if path.contains("/pb_sn_pos_install/") {
            data = ["read_access": serialReadable, "value": "00001234"]
        } else if path.contains("/sys_updated_at/") {
            if request.url!.lastPathComponent == failID { return (Data(), 503) }
            data = ["read_access": true, "value": versions[request.url!.lastPathComponent] ?? "2026-11-05 12:00:00"]
        } else {
            throw TestFailure("Unexpected HTTP path: \(path)")
        }
        return (try JSONSerialization.data(withJSONObject: ["status": "OK", "data": data]), 200)
    }

    func finished() { lock.lock(); active -= 1; lock.unlock() }
}

private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var server = FixtureServer()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let server = Self.server
        do {
            let (data, status) = try server.response(request)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.025) { [self] in
                server.finished()
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            }
        } catch { server.finished(); client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private struct TestFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(message) }
}

private func fixture(_ id: String, omitSerial: Bool = false) -> [String: Any] {
    let keys = ["short_description", "multicard_terminal_address", "multicard_name_client", "multicard_terminal_model", "description", "multicard_id_terminal", "multicard_comment_ing", "multicard_additional_information", "assigned_user", "multicard_contact_person", "multicard_deadline", "pb_sn_pos_uninstall", "multicard_pos", "multicard_return_number_pos", "multicard_pin_pad", "multicard_return_number_pin", "multicard_closing_date", "resolved_at", "sys_created_at", "new_closure_code", "closure_notes"]
    var row = Dictionary(uniqueKeysWithValues: keys.map { ($0, "" as Any) })
    row["sys_id"] = id
    row["number"] = "REQ-\(id)"
    row["state"] = ["database_value": "closed", "value": "Закрыто"]
    row["multicard_request_type"] = "serviceStd"
    row["multicard_merchant_tin"] = "1234567890"
    row["resolved_at"] = "2026-11-05 12:00:00"
    if !omitSerial { row["pb_sn_pos_install"] = "00001234" }
    return row
}

private func service(_ server: FixtureServer) -> SimpleOneRequestsService {
    FixtureProtocol.server = server
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FixtureProtocol.self]
    return SimpleOneRequestsService(baseURL: URL(string: "https://fixture.test/v1")!, session: URLSession(configuration: config))
}

@main
struct ClosedSyncTests {
    @MainActor static func main() async throws {
        var failures: [String] = []
        let cases: [(String, () async throws -> Void)] = [
            ("rows overlap while preserving cursor order", parallelRows),
            ("list versions avoid per-row version requests", listVersions),
            ("missing serial is loaded from its readable cell", missingSerial),
            ("unreadable serial cannot erase an archived value", unreadableSerial),
            ("full reconciliation reuses only present owned records", knownVersions),
            ("a failed later page leaves an importable checkpoint without advancing its cursor", checkpoints),
            ("an error after the ordered stopping boundary is ignored", speculativeFailure),
            ("unchanged history uses list pages without per-record HTTP", unchangedHistory),
            ("a cancelled screen waiter does not cancel the shared store sync", sharedTask),
            ("authorization revocation cannot publish old in-flight results", revokedAuthorization),
            ("an older XLSX import invalidates overwritten content versions", importedVersions),
            ("a server page-size cap cannot truncate history", cappedPages)
        ]
        for (name, test) in cases {
            do { try await test(); print("PASS: \(name)") }
            catch { failures.append(name); print("FAIL: \(name): \(error)") }
        }
        if let path = ProcessInfo.processInfo.environment["LUMAWORK_CLOSED_BENCH_ARCHIVE"] {
            try benchmarkArchive(path)
        }
        fflush(nil)
        if !failures.isEmpty { throw TestFailure("\(failures.count) regression(s) failed") }
    }

    static func parallelRows() async throws {
        let server = FixtureServer()
        server.rows = ["h", "g", "f", "e", "d", "c", "b", "a"].map { fixture($0) }
        let batch = try await service(server).fetchClosedSyncChanges(userID: "user", authKey: "test", scope: .narrow, since: nil, knownVersionsBySysID: [:])
        try expect(batch.changes.map(\.sysID) == ["h", "g", "f", "e", "d", "c", "b", "a"], "Lost or reordered rows")
        try expect(server.maximumActive > 1 && server.maximumActive <= 6, "Expected bounded overlapping HTTP requests, got \(server.maximumActive)")
    }

    static func listVersions() async throws {
        let server = FixtureServer(); server.rows = [fixture("one")]; server.listVersion = true
        let batch = try await service(server).fetchClosedSyncChanges(userID: "user", authKey: "test", scope: .narrow, since: nil, knownVersionsBySysID: [:])
        try expect(batch.changes.count == 1, "Lost complete list row")
        try expect(!server.paths.contains { $0.contains("list-cell-value") }, "A readable canonical list version needs no cell request")
    }

    static func missingSerial() async throws {
        let server = FixtureServer(); server.rows = [fixture("one", omitSerial: true)]
        let batch = try await service(server).fetchClosedSyncChanges(userID: "user", authKey: "test", scope: .narrow, since: nil, knownVersionsBySysID: [:])
        try expect(batch.changes.first?.record?.requestNumber == "REQ-one", "Readable serial fallback must not block importing the row")
        try expect(server.paths.contains { $0.contains("/pb_sn_pos_install/") }, "Missing form field must be read from its cell")
    }

    static func unreadableSerial() async throws {
        let server = FixtureServer(); server.rows = [fixture("one", omitSerial: true)]; server.serialReadable = false
        do {
            _ = try await service(server).fetchClosedSyncChanges(userID: "user", authKey: "test", scope: .narrow, since: nil, knownVersionsBySysID: [:])
            throw TestFailure("Unreadable serial was accepted")
        } catch is SimpleOneServiceError {}
    }

    @MainActor static func knownVersions() async throws {
        let record = XLSXRequestsParser.record(fromExportRow: ["Номер заявки": "REQ-present", "Статус": "closed"])!
        let state = ClosedRequestsSyncState(userID: "user", narrowWatermark: nil, wideWatermark: nil, lastNarrowSuccessAt: nil, lastWideSuccessAt: nil, isWideBaselineTrusted: false, requiresNarrowFullReconciliation: true, hasVerifiedReconciliationVersions: true, recordsBySysID: [
            "present": .init(requestNumber: "REQ-present", sysUpdatedAt: "2026-11-03 12:00:00", lastSeenAt: Date()),
            "deleted": .init(requestNumber: "REQ-deleted", sysUpdatedAt: "2026-11-03 12:00:00", lastSeenAt: Date())
        ])
        let store = SyncStoreHarness(snapshot: ClosedRequestsSnapshot(fileName: "test", importedAt: Date(), records: [record], syncState: state))
        let context = store.beginClosedRequestsSync(userID: "user", scope: .narrow)!
        try expect(context.watermark == nil, "Full reconciliation must still scan all rows")
        try expect(context.knownVersionsBySysID == ["present": "2026-11-03 12:00:00"], "Present owned records should skip unchanged details; deleted records must be recovered")
        let other = SyncStoreHarness(snapshot: store.snapshot!)
        try expect(other.beginClosedRequestsSync(userID: "other", scope: .narrow)!.knownVersionsBySysID.isEmpty, "Another user's metadata was reused")
        var legacy = store.snapshot!; legacy.syncState?.hasVerifiedReconciliationVersions = nil
        try expect(SyncStoreHarness(snapshot: legacy).beginClosedRequestsSync(userID: "user", scope: .narrow)!.knownVersionsBySysID.isEmpty, "Legacy manual-import metadata cannot vouch for imported content")
    }

    @MainActor static func checkpoints() async throws {
        let server = FixtureServer()
        server.rows = (0..<21).map { fixture(String(format: "%03d", 100 - $0)) }
        server.failID = "080"
        let oldCursor = ClosedRequestsSyncCursor(updatedAt: "2026-11-03 12:00:00", sysID: "old")
        let oldState = ClosedRequestsSyncState(userID: "user", narrowWatermark: oldCursor, wideWatermark: nil, lastNarrowSuccessAt: nil, lastWideSuccessAt: nil, isWideBaselineTrusted: false, requiresNarrowFullReconciliation: true, recordsBySysID: [:])
        let initial = ClosedRequestsSnapshot(fileName: "test", importedAt: Date(), records: [], syncState: oldState)
        let recorder = CheckpointRecorder(snapshot: initial)
        do {
            _ = try await service(server).fetchClosedSyncChanges(userID: "user", authKey: "test", scope: .narrow, since: nil, knownVersionsBySysID: [:], onProgress: { progress in
                try await recorder.receive(progress)
            })
            throw TestFailure("A failed second page must fail the full scan")
        } catch is SimpleOneServiceError {}
        let snapshot = await recorder.snapshot
        try expect(snapshot.records.count == 20, "The successful first page was lost")
        try expect(snapshot.syncState?.narrowWatermark == oldCursor, "Partial progress advanced the committed cursor")
        try expect(snapshot.syncState?.requiresNarrowFullReconciliation == true, "Incomplete reconciliation was marked complete")
        try expect(snapshot.syncState?.lastNarrowSuccessAt == nil, "Incomplete reconciliation was marked successful")
    }

    static func speculativeFailure() async throws {
        let server = FixtureServer(); server.rows = [fixture("z"), fixture("y"), fixture("x")]
        server.versions["y"] = "2026-11-02 12:00:00"; server.failID = "x"
        let boundary = ClosedRequestsSyncCursor(updatedAt: "2026-11-05 12:00:00", sysID: "z")
        let batch = try await service(server).fetchClosedSyncChanges(userID: "user", authKey: "test", scope: .narrow, since: boundary, knownVersionsBySysID: ["z": boundary.updatedAt])
        try expect(batch.changes.isEmpty && batch.watermark == boundary, "A speculative older error invalidated an already complete scan")
    }

    static func unchangedHistory() async throws {
        let server = FixtureServer(); server.listVersion = true
        let ids = (0..<120).map { String(format: "%03d", 999 - $0) }
        server.rows = ids.map { fixture($0) }
        let versions = Dictionary(uniqueKeysWithValues: ids.map { ($0, "2026-11-05 12:00:00") })
        let started = Date()
        let batch = try await service(server).fetchClosedSyncChanges(userID: "user", authKey: "test", scope: .wide, since: nil, knownVersionsBySysID: versions)
        try expect(batch.changes.isEmpty, "Unchanged history was unnecessarily hydrated")
        try expect(server.paths.count == 2, "Expected two list pages for 120 unchanged history rows, got \(server.paths.count) HTTP requests")
        print("BENCH: 120 unchanged rows, \(server.paths.count) HTTP requests, \(String(format: "%.3f", Date().timeIntervalSince(started)))s")
    }

    @MainActor static func sharedTask() async throws {
        let server = FixtureServer(); server.rows = [fixture("one")]
        let simpleOne = SyncSimpleOneHarness(service: service(server))
        let store = SyncStoreHarness(snapshot: ClosedRequestsSnapshot(fileName: "test", importedAt: Date(), records: []))
        let screen = Task { try await store.synchronizeFromSimpleOne(simpleOne, scope: .narrow) }
        try await Task.sleep(nanoseconds: 10_000_000)
        screen.cancel()
        let joined = try await store.synchronizeFromSimpleOne(simpleOne, scope: .narrow, waitsForCurrentSync: true)
        _ = try await screen.value
        try expect(joined == 1 && store.snapshot?.records.first?.requestNumber == "REQ-one", "Screen cancellation lost the shared sync result")
        try expect(server.paths.filter { $0.contains("/sys_updated_at/") }.count == 2, "Waiters duplicated the row scan")
        try expect(!store.isSynchronizingClosedRequests && store.closedSyncProgressText == nil, "Completed sync left a stale loading state")
    }

    @MainActor static func revokedAuthorization() async throws {
        let server = FixtureServer(); server.rows = [fixture("one")]
        let simpleOne = SyncSimpleOneHarness(service: service(server))
        let store = SyncStoreHarness(snapshot: ClosedRequestsSnapshot(fileName: "test", importedAt: Date(), records: []))
        let task = Task { try await store.synchronizeFromSimpleOne(simpleOne, scope: .narrow) }
        try await Task.sleep(nanoseconds: 10_000_000)
        simpleOne.browserAuthKey = nil
        store.cancelClosedRequestsSync()
        _ = try? await task.value
        try expect(store.snapshot?.records.isEmpty == true, "Revoked in-flight data reached the archive")
        try expect(!store.isSynchronizingClosedRequests, "Revocation left a stale loading state")
    }

    @MainActor static func importedVersions() async throws {
        let record = XLSXRequestsParser.record(fromExportRow: ["Номер заявки": "REQ-present", "Статус": "closed", "Заказчик": "Current"] )!
        var older = record; older.customer = "Old XLSX"
        let state = ClosedRequestsSyncState(userID: "user", narrowWatermark: nil, wideWatermark: nil, lastNarrowSuccessAt: nil, lastWideSuccessAt: nil, isWideBaselineTrusted: true, requiresNarrowFullReconciliation: false, recordsBySysID: ["present": .init(requestNumber: "REQ-present", sysUpdatedAt: "2026-11-05 12:00:00", lastSeenAt: Date())])
        let existing = ClosedRequestsSnapshot(fileName: "test", importedAt: Date(), records: [record], syncState: state)
        let imported = SyncStoreHarness.importing(ClosedRequestsSnapshot(fileName: "old", importedAt: Date(), records: [older]), into: existing)
        let context = SyncStoreHarness(snapshot: imported).beginClosedRequestsSync(userID: "user", scope: .narrow)!
        try expect(context.knownVersionsBySysID["present"] != "2026-11-05 12:00:00", "A stale imported row retained the current server version and will never be repaired")
    }

    static func cappedPages() async throws {
        let server = FixtureServer(); server.pageCap = 20; server.listVersion = true
        server.rows = (0..<120).map { fixture(String(format: "%03d", 999 - $0)) }
        let batch = try await service(server).fetchClosedSyncChanges(userID: "user", authKey: "test", scope: .wide, since: nil, knownVersionsBySysID: [:])
        try expect(batch.changes.count == 120, "Server-capped pages lost \(120 - batch.changes.count) history rows")
    }

    static func benchmarkArchive(_ path: String) throws {
        let original = try JSONDecoder().decode(ClosedRequestsSnapshot.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let metadata = original.syncState?.recordsBySysID ?? [:]
        let changes = original.records.prefix(20).map { record in
            var updated = record
            updated.engineerComment += " benchmark"
            let id = metadata.first { $0.value.requestNumber == record.requestNumber }?.key ?? "bench-\(record.requestNumber)"
            return SimpleOneClosedSyncChange(sysID: id, requestNumber: record.requestNumber, cursor: .init(updatedAt: "2026-11-06 00:00:00", sysID: id), record: updated, excludedFromArchive: false)
        }
        let batch = SimpleOneClosedSyncBatch(userID: original.syncState?.userID ?? "user", scope: .narrow, changes: changes, watermark: nil, totalCount: nil, isComplete: false)
        let started = Date()
        let merged = try SyncStoreHarness.apply(batch, to: original)
        let bytes = try JSONEncoder().encode(merged).count
        try expect(merged.records.count == original.records.count, "Checkpoint dropped real archive records")
        print("BENCH: real archive \(original.records.count) rows, 20-row merge + sort + JSON encode, \(String(format: "%.3f", Date().timeIntervalSince(started)))s, \(bytes) bytes")
    }
}

@MainActor final class SyncSimpleOneHarness {
    let service: SimpleOneRequestsService
    var browserAuthKey: String? = "test"
    var isAuthorized: Bool { browserAuthKey != nil }
    init(service: SimpleOneRequestsService) { self.service = service }
    func closedSyncUserID() async throws -> String { "user" }
    func fetchClosedSyncChanges(scope: ClosedRequestsSyncScope, since: ClosedRequestsSyncCursor?, knownVersionsBySysID: [String: String], onProgress: @escaping @Sendable (SimpleOneClosedSyncProgress) async throws -> Void) async throws -> SimpleOneClosedSyncBatch {
        try await service.fetchClosedSyncChanges(userID: "user", authKey: browserAuthKey ?? "", scope: scope, since: since, knownVersionsBySysID: knownVersionsBySysID, onProgress: onProgress)
    }
}

private actor CheckpointRecorder {
    var snapshot: ClosedRequestsSnapshot
    init(snapshot: ClosedRequestsSnapshot) { self.snapshot = snapshot }
    func receive(_ progress: SimpleOneClosedSyncProgress) throws {
        let batch = SimpleOneClosedSyncBatch(userID: "user", scope: .narrow, changes: progress.changes, watermark: nil, totalCount: progress.totalCount, isComplete: false)
        snapshot = try SyncStoreHarness.apply(batch, to: snapshot)
    }
}
