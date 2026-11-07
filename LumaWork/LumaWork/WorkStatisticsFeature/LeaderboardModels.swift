import Foundation

nonisolated enum LeaderboardPeriod: String, CaseIterable, Codable, Sendable {
    case all, year, month
    var title: String {
        switch self { case .all: "За всё время"; case .year: "За текущий год"; case .month: "За текущий месяц" }
    }
    func key(at date: Date = Date()) -> String {
        let month = WorkStatisticsAggregator.monthKey(date)
        return switch self { case .all: "all"; case .year: String(month.prefix(4)); case .month: month }
    }
}
nonisolated enum LeaderboardCategory: String, CaseIterable, Codable, Sendable {
    case all, portable, stationary, integration, fiscal
    var title: String {
        switch self { case .all: "Все"; case .portable: "Переносные"; case .stationary: "Стационарные"; case .integration: "Интеграции"; case .fiscal: "ККТ" }
    }
}
nonisolated struct LeaderboardCity: Codable, Hashable, Identifiable, Sendable {
    var key: String
    var title: String
    var id: String { key }
    static let all = Self(key: "all", title: "Все")
}
nonisolated struct LeaderboardEntry: Codable, Equatable, Identifiable, Sendable {
    var userId: String
    var displayName: String
    var avatarUrl: String?
    var rank: Int?
    var value: Int?
    var completedWithVisitCount: Int?
    var categoryCounts: [String: Int]
    var hasData: Bool
    var sourceSyncedAt: String?
    var receivedAt: String?
    var isCurrentUser: Bool
    var id: String { userId }
}
nonisolated struct LeaderboardResponse: Codable, Equatable, Sendable {
    var period: LeaderboardPeriod
    var category: LeaderboardCategory
    var city: LeaderboardCity
    var availableCities: [LeaderboardCity]
    var currentUserInScope: Bool
    var timezone: String
    var serverNow: String
    var periodKey: String
    var periodStart: String?
    var periodEndExclusive: String?
    var generatedAt: String
    var rulesVersion: Int
    var registeredUsersCount: Int
    var usersWithDataCount: Int
    var totalCount: Int
    var items: [LeaderboardEntry]
    var me: LeaderboardEntry?
    var nextOffset: Int?

    /// Apply to network and legacy cached responses without changing the wire contract.
    var participantsOnly: Self {
        var value = self
        value.items = items.filter(\.hasData)
        value.me = me.flatMap { $0.hasData ? $0 : nil }
        value.currentUserInScope = value.me != nil
        // Uploaded users, including real zeroes, precede rows without a snapshot on the server.
        value.nextOffset = nextOffset.flatMap { $0 < usersWithDataCount ? $0 : nil }
        return value
    }

    func validate(period: LeaderboardPeriod, category: LeaderboardCategory, city: String) throws {
        guard self.period == period, self.category == category, self.city.key == city, timezone == "Europe/Moscow", rulesVersion == 1,
              periodKey == period.key(at: WorkStatisticsAggregator.parseDate(serverNow) ?? .distantPast),
              registeredUsersCount >= 0, usersWithDataCount >= 0, usersWithDataCount <= registeredUsersCount, totalCount == registeredUsersCount,
              availableCities.first == .all, Set(availableCities.map(\.key)).count == availableCities.count,
              availableCities.contains(self.city), Set(items.map(\.userId)).count == items.count,
              currentUserInScope == (me != nil), nextOffset == nil || nextOffset! > 0 else { throw URLError(.cannotParseResponse) }
        for item in items + (me.map { [$0] } ?? []) {
            guard !item.userId.isEmpty, !item.displayName.isEmpty, Set(item.categoryCounts.keys) == Set(ProfileWorkCategory.allCases.map(\.rawValue)),
                  item.categoryCounts.values.allSatisfy({ $0 >= 0 }), item.rank == nil || item.rank! > 0,
                  item.hasData ? (item.value != nil && item.value! >= 0 && item.completedWithVisitCount != nil) : (item.value == nil && item.rank == nil),
                  (item.value ?? 0) > 0 || item.rank == nil else { throw URLError(.cannotParseResponse) }
        }
    }
}
