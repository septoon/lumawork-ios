import Foundation

nonisolated struct WorkScheduleJournal: Codable, Hashable, Identifiable, Sendable {
    let sysID: String
    let cityID: String
    let cityName: String
    let year: Int
    let month: Int

    var id: String { sysID }
}

nonisolated struct WorkScheduleDayValue: Codable, Hashable, Identifiable, Sendable {
    let day: Int
    let hours: Double
    let isActive: Bool

    var id: Int { day }
}

nonisolated struct WorkScheduleEmployee: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let login: String
    let totalHours: Double
    let dayValues: [WorkScheduleDayValue]

    func value(for day: Int) -> WorkScheduleDayValue? {
        dayValues.first { $0.day == day }
    }
}

nonisolated struct WorkScheduleDailyTotal: Codable, Hashable, Identifiable, Sendable {
    let day: Int
    let count: Int

    var id: Int { day }
}

nonisolated struct WorkScheduleAuditInfo: Codable, Hashable, Sendable {
    let createdBy: String?
    let createdAt: Date?
    let updatedBy: String?
    let updatedAt: Date?

    var hasContent: Bool {
        createdBy != nil || createdAt != nil || updatedBy != nil || updatedAt != nil
    }
}

nonisolated struct WorkSchedule: Codable, Hashable, Sendable {
    let journal: WorkScheduleJournal
    let daysInMonth: Int
    let employees: [WorkScheduleEmployee]
    let dailyTotals: [WorkScheduleDailyTotal]
    let auditInfo: WorkScheduleAuditInfo?
}

nonisolated enum WorkScheduleCachePolicy {
    static func canReuse(_ schedule: WorkSchedule, forceRefresh: Bool) -> Bool {
        !forceRefresh && schedule.auditInfo?.hasContent == true
    }
}

nonisolated enum WorkScheduleParsingError: Error, Equatable {
    case missingJournalItems
    case missingScheduleData
    case missingWidgetInstanceID
}
