import Foundation

nonisolated struct WorkStatisticsSourceIndex: Codable, Sendable {
    let ownerID: String
    let sourceUserID: String
    var rulesVersion = 1
    var queryRevision = ClosedRequestsArchiveQuery.revision
    var generation: UInt64 = 0
    var dirty = true
    var hasBaseline = false
    var wideComplete = false
    var sourceSyncedAt: Date?
    var narrowWatermark: ClosedRequestsSyncCursor?
    var wideWatermark: ClosedRequestsSyncCursor?
    // Device-only keys; only makeUpload's aggregate DTO is transmitted.
    var contributions: [String: WorkContribution] = [:]
    var numbersBySysID: [String: String] = [:]

    var requiresAuthoritativeBaseline: Bool {
        dirty || !hasBaseline || rulesVersion != 1 || queryRevision != ClosedRequestsArchiveQuery.revision
    }

    mutating func replaceBaseline(ownerID: String, sourceUserID: String, records: [ClosedRequestRecord], syncedAt: Date) throws {
        guard ownerID == self.ownerID, sourceUserID == self.sourceUserID else { throw WorkStatisticsIndexError.ownerMismatch }
        var replacement: [String: WorkContribution] = [:]
        for record in records {
            let number = Self.number(record.requestNumber)
            guard !number.isEmpty else { throw WorkStatisticsIndexError.conflictingIdentity }
            let contribution = WorkStatisticsAggregator.contribution(record)
            if let old = replacement[number], old != contribution { throw WorkStatisticsIndexError.conflictingIdentity }
            replacement[number] = contribution
        }
        contributions = replacement
        numbersBySysID = [:]
        hasBaseline = true; dirty = false; wideComplete = true
        sourceSyncedAt = syncedAt; generation &+= 1
    }

    mutating func applyCompletedBatch(ownerID: String, batch: SimpleOneClosedSyncBatch, syncedAt: Date, allowDirtyCurrentPass: Bool = false) throws {
        guard ownerID == self.ownerID, batch.userID == sourceUserID else { throw WorkStatisticsIndexError.ownerMismatch }
        guard hasBaseline, batch.isComplete, !dirty || allowDirtyCurrentPass else { dirty = true; throw WorkStatisticsIndexError.incompleteSource }
        var next = self
        for change in batch.changes {
            let number = Self.number(change.requestNumber)
            guard !number.isEmpty, !change.sysID.isEmpty else { throw WorkStatisticsIndexError.conflictingIdentity }
            if let previous = next.numbersBySysID[change.sysID], previous != number { throw WorkStatisticsIndexError.conflictingIdentity }
            if next.numbersBySysID.contains(where: { $0.key != change.sysID && $0.value == number }) { throw WorkStatisticsIndexError.conflictingIdentity }
            next.numbersBySysID[change.sysID] = number
            if change.excludedFromArchive || change.record == nil { next.contributions.removeValue(forKey: number) }
            else if let record = change.record {
                guard Self.number(record.requestNumber) == number else { throw WorkStatisticsIndexError.conflictingIdentity }
                next.contributions[number] = WorkStatisticsAggregator.contribution(record)
            }
        }
        if batch.scope == .wide { next.wideWatermark = batch.watermark; next.wideComplete = true }
        else { next.narrowWatermark = batch.watermark; next.wideComplete = false }
        next.dirty = false; next.sourceSyncedAt = syncedAt; next.generation &+= 1
        self = next
    }

    func makeUpload(expectedRevision: Int, requestId: String = UUID().uuidString.lowercased()) throws -> WorkStatisticsUpload {
        guard !requiresAuthoritativeBaseline, wideComplete, let sourceSyncedAt else { throw WorkStatisticsIndexError.incompleteSource }
        var months: [String: WorkStatisticsMetrics] = [:]
        var unknown = WorkStatisticsMetrics()
        for contribution in contributions.values {
            if let month = contribution.monthKey { months[month, default: WorkStatisticsMetrics()].add(contribution.metrics) }
            else { unknown.add(contribution.metrics) }
        }
        return WorkStatisticsUpload(requestId: requestId, expectedRevision: expectedRevision, sourceUserId: sourceUserID,
            sourceSyncedAt: ISO8601DateFormatter().string(from: sourceSyncedAt),
            months: months.keys.sorted().map { WorkStatisticsMonth(month: $0, metrics: months[$0]!) }, unknownDate: unknown)
    }

    private static func number(_ raw: String) -> String { raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
}
