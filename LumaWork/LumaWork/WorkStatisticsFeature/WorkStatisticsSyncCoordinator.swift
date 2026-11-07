import Foundation
import Observation

/// Application-owned publishing. It never starts an SO import from a screen appearance.
@MainActor @Observable final class WorkStatisticsSyncCoordinator {
    private(set) var notice: String?
    @ObservationIgnored private let api: WorkStatisticsAPI
    @ObservationIgnored private var access: SimpleOneAccessSnapshot?
    @ObservationIgnored private var index: WorkStatisticsSourceIndex?
    @ObservationIgnored private var expectedRevision: Int?
    @ObservationIgnored private var uploadTask: Task<Void, Never>?
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var isSourcePassActive = false
    @ObservationIgnored private var sourcePassCanApplyDelta = false
    @ObservationIgnored private var uploadID: UUID?
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let cacheOwnerID: String?

    nonisolated struct Outbox: Codable, Sendable {
        var ownerID: String
        var sourceUserID: String
        var generation: UInt64
        var payload: WorkStatisticsUpload?
        // A candidate without preflight is deliberately unsendable.
        var needsNewSourcePass: Bool
    }

    init(config: AppConfig, directory: URL? = nil, ownerID: String? = nil, session: URLSession = .shared) {
        api = WorkStatisticsAPI(config: config, session: session)
        cacheOwnerID = ownerID
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WorkStatistics-v1", isDirectory: true)
    }

    var requiresAuthoritativeBaseline: Bool { index?.requiresAuthoritativeBaseline ?? true }
    var hasPendingPublication: Bool { notice != nil }

    func beginRefresh(sourceUserID: String) async {
        synchronizeAccess(sourceUserID: sourceUserID)
        expectedRevision = nil; notice = nil
        guard let access, index != nil, !isSourcePassActive else { return }
        let stamp = epoch
        do {
            let state = try await api.fetchMe()
            try validate(access, epoch: stamp)
            guard state.sourceUserId == sourceUserID, state.rulesVersion == 1 else { return }
            expectedRevision = state.serverRevision
        } catch {
            guard epoch == stamp, (try? SimpleOneProtectedAccess.capture()) == access else { return }
            notice = "Заявки обновлены. Статистика для рейтинга будет отправлена позже"
        }
    }

    func synchronizeAccess(sourceUserID: String) {
        guard let current = try? SimpleOneProtectedAccess.capture(), !sourceUserID.isEmpty else { clearProtectedState(); return }
        guard current != access || index?.sourceUserID != sourceUserID else { return }
        if access != nil || index != nil { clearProtectedState() }
        access = current
        let url = fileURL("index", owner: current.ownerID, source: sourceUserID)
        index = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(WorkStatisticsSourceIndex.self, from: $0) }
        if index?.ownerID != current.ownerID || index?.sourceUserID != sourceUserID { index = nil }
        if index == nil { index = WorkStatisticsSourceIndex(ownerID: current.ownerID, sourceUserID: sourceUserID) }
    }

    /// Must succeed before the archive is allowed to commit its first checkpoint.
    func markSourcePassDirty() throws {
        guard let access, var next = index else { throw SimpleOneAccessDenied() }
        try validate(access, epoch: epoch)
        uploadTask?.cancel(); uploadTask = nil
        try removeOutbox()
        sourcePassCanApplyDelta = !next.requiresAuthoritativeBaseline
        next.dirty = true; next.wideComplete = false
        try saveIndex(next)
        index = next; isSourcePassActive = true
    }

    func commitBaseline(records: [ClosedRequestRecord], narrow: ClosedRequestsSyncCursor?, wide: ClosedRequestsSyncCursor?) async {
        guard let access, let index else { return }
        let stamp = epoch
        do {
            let next = try await Task.detached(priority: .utility) {
                var next = index
                try next.replaceBaseline(ownerID: access.ownerID, sourceUserID: index.sourceUserID, records: records, syncedAt: Date())
                next.narrowWatermark = narrow; next.wideWatermark = wide
                return next
            }.value
            try validate(access, epoch: stamp)
            try saveIndex(next); self.index = next; isSourcePassActive = false
            await stageCandidate()
        } catch { if epoch == stamp, (try? SimpleOneProtectedAccess.capture()) == access { publishingFailed() } }
    }

    func commitBatch(_ batch: SimpleOneClosedSyncBatch) async {
        guard let access, let index, batch.isComplete else { return }
        let stamp = epoch
        let allowDirty = sourcePassCanApplyDelta
        do {
            let next = try await Task.detached(priority: .utility) {
                var next = index
                try next.applyCompletedBatch(ownerID: access.ownerID, batch: batch, syncedAt: Date(), allowDirtyCurrentPass: allowDirty)
                return next
            }.value
            try validate(access, epoch: stamp)
            try saveIndex(next); self.index = next; isSourcePassActive = false
            if batch.scope == .wide { await stageCandidate() }
        } catch { if epoch == stamp, (try? SimpleOneProtectedAccess.capture()) == access { publishingFailed() } }
    }

    func endRefresh() {
        expectedRevision = nil
        if isSourcePassActive { publishingFailed() }
        finishSourcePass()
    }

    func finishSourcePass() {
        isSourcePassActive = false
        sourcePassCanApplyDelta = false
    }

    func resumePending(sourceUserID: String) {
        synchronizeAccess(sourceUserID: sourceUserID)
        guard !isSourcePassActive, let access, let index, !index.requiresAuthoritativeBaseline,
              let data = try? Data(contentsOf: fileURL("outbox", owner: access.ownerID, source: sourceUserID)),
              let outbox = try? JSONDecoder().decode(Outbox.self, from: data),
              outbox.ownerID == access.ownerID, outbox.sourceUserID == sourceUserID,
              outbox.generation == index.generation, !outbox.needsNewSourcePass else { return }
        send(outbox)
    }

    func clearProtectedState() {
        epoch = UUID(); uploadTask?.cancel(); uploadTask = nil
        // Pending payload from the previous authorization is never replayed under a new one.
        if let owner = access?.ownerID ?? cacheOwnerID,
           let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let file as URL in files where file.lastPathComponent == "outbox.json" {
                if let data = try? Data(contentsOf: file), let pending = try? JSONDecoder().decode(Outbox.self, from: data), pending.ownerID == owner {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
        access = nil; index = nil; expectedRevision = nil; notice = nil; isSourcePassActive = false
    }

    private func stageCandidate() async {
        guard let access, let index, !index.requiresAuthoritativeBaseline, index.wideComplete else { return }
        let payload = expectedRevision.flatMap { try? index.makeUpload(expectedRevision: $0) }
        let outbox = Outbox(ownerID: access.ownerID, sourceUserID: index.sourceUserID, generation: index.generation, payload: payload, needsNewSourcePass: payload == nil)
        do {
            try atomicSave(outbox, to: fileURL("outbox", owner: access.ownerID, source: index.sourceUserID))
            if payload != nil { send(outbox) } else { publishingFailed() }
        } catch { publishingFailed() }
    }

    private func send(_ outbox: Outbox) {
        guard uploadTask == nil, let payload = outbox.payload, let access else { return }
        let stamp = epoch
        let taskID = UUID(); uploadID = taskID
        uploadTask = Task { [weak self] in
            guard let self else { return }
            defer { if epoch == stamp, uploadID == taskID { uploadTask = nil; uploadID = nil } }
            for attempt in 0..<3 {
                do {
                    try validate(access, epoch: stamp)
                    guard !isSourcePassActive, index?.generation == outbox.generation else { return }
                    let receipt = try await api.replaceSnapshot(payload)
                    try validate(access, epoch: stamp)
                    guard receipt.accepted, receipt.requestId == payload.requestId, index?.generation == outbox.generation, !isSourcePassActive else { return }
                    try removeOutbox(); notice = nil
                    return
                } catch is CancellationError { return }
                catch {
                    guard epoch == stamp, (try? SimpleOneProtectedAccess.capture()) == access else { return }
                    publishingFailed()
                    if let error = error as? WorkStatisticsAPIError, !error.canRetry {
                        // In particular, never rebase an old payload onto a new server revision.
                        try? removeOutbox()
                        if error.code == "REVISION_CONFLICT" { expectedRevision = nil }
                        return
                    }
                    if attempt < 2 { do { try await Task.sleep(for: .seconds(attempt == 0 ? 2 : 8)) } catch { return } }
                }
            }
        }
    }

    private func publishingFailed() {
        notice = "Заявки обновлены. Статистика для рейтинга будет отправлена позже"
    }
    private func validate(_ access: SimpleOneAccessSnapshot, epoch stamp: UUID) throws {
        try SimpleOneProtectedAccess.validate(access)
        guard epoch == stamp else { throw CancellationError() }
    }
    private func saveIndex(_ index: WorkStatisticsSourceIndex) throws {
        try atomicSave(index, to: fileURL("index", owner: index.ownerID, source: index.sourceUserID))
    }
    private func removeOutbox() throws {
        guard let access, let index else { return }
        let url = fileURL("outbox", owner: access.ownerID, source: index.sourceUserID)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    private func fileURL(_ name: String, owner: String, source: String) -> URL {
        let key = Data((owner + "\u{0}" + source).utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent(key, isDirectory: true).appendingPathComponent(name + ".json")
    }
    private func atomicSave<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
