import Foundation

nonisolated struct WorkStatisticsMetrics: Codable, Equatable, Sendable {
    var closedCount = 0
    var completedWithVisitCount = 0
    var returnEquipmentCount = 0
    var unclassifiedCompletedCount = 0
    var byCategory: [String: [String: Int]] = Dictionary(uniqueKeysWithValues: ProfileWorkCategory.allCases.map { category in
        (category.rawValue, Dictionary(uniqueKeysWithValues: ProfileWorkOperation.allCases.map { ($0.rawValue, 0) }))
    })

    mutating func add(_ other: Self) {
        closedCount += other.closedCount
        completedWithVisitCount += other.completedWithVisitCount
        returnEquipmentCount += other.returnEquipmentCount
        unclassifiedCompletedCount += other.unclassifiedCompletedCount
        for category in ProfileWorkCategory.allCases {
            for operation in ProfileWorkOperation.allCases {
                byCategory[category.rawValue]![operation.rawValue]! += other.byCategory[category.rawValue]?[operation.rawValue] ?? 0
            }
        }
    }
}
nonisolated struct WorkStatisticsMonth: Codable, Equatable, Sendable {
    var month: String
    var metrics: WorkStatisticsMetrics
}
nonisolated struct WorkStatisticsUpload: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var rulesVersion = 1
    var requestId: String
    var expectedRevision: Int
    var sourceUserId: String
    var sourceSyncedAt: String
    var timezone = "Europe/Moscow"
    var months: [WorkStatisticsMonth]
    var unknownDate: WorkStatisticsMetrics
}
nonisolated struct WorkStatisticsMe: Codable, Sendable {
    var serverRevision: Int
    var hasSnapshot: Bool
    var sourceUserId: String
    var sourceSyncedAt: String?
    var receivedAt: String?
    var rulesVersion: Int
}
nonisolated struct WorkStatisticsReceipt: Codable, Sendable {
    var accepted: Bool
    var serverRevision: Int
    var requestId: String
    var sourceSyncedAt: String
    var receivedAt: String
}
nonisolated struct WorkContribution: Codable, Equatable, Sendable {
    var monthKey: String?
    var metrics: WorkStatisticsMetrics
}
nonisolated enum WorkStatisticsIndexError: Error {
    case ownerMismatch, conflictingIdentity, incompleteSource
}
