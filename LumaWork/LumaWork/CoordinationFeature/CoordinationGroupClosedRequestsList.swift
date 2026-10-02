import Foundation

nonisolated struct GroupClosedRequestItem: Identifiable, Sendable, Equatable {
    let source: SimpleOneRequestRecord
    let display: ClosedRequestPreparedListItem
    let typeKey: String

    var id: String { source.id }

    init(source: SimpleOneRequestRecord, display: ClosedRequestPreparedListItem) {
        self.source = source
        self.display = display
        typeKey = source.requestType.split(whereSeparator: \.isWhitespace).first
            .map(String.init)?.lowercased() ?? ""
    }
}

nonisolated struct GroupClosedRequestDay: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let caption: String
    let startIndex: Int
    var items: [GroupClosedRequestItem]
}

nonisolated struct GroupClosedRequestType: Sendable, Equatable {
    let key: String
    let title: String
}

nonisolated struct GroupClosedRequestsList: Sendable, Equatable {
    var days: [GroupClosedRequestDay] = []
    var availableTypes: [GroupClosedRequestType] = []
    var count = 0

    static func build(
        items: [GroupClosedRequestItem],
        query: String,
        excludedTypes: Set<String>,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> Self {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        var result = Self()
        var titles: [String: String] = [:]

        for item in items {
            titles[item.typeKey] = item.display.requestType.isEmpty
                ? "Тип не указан" : item.display.requestType
            guard let date = item.display.date,
                  date >= yesterday, date < tomorrow,
                  !excludedTypes.contains(item.typeKey),
                  query.isEmpty || item.display.searchText.contains(query) else { continue }

            if let last = result.days.indices.last, result.days[last].id == item.display.dayKey {
                result.days[last].items.append(item)
            } else {
                result.days.append(GroupClosedRequestDay(
                    id: item.display.dayKey,
                    title: date >= today ? "Сегодня" : "Вчера",
                    caption: item.display.dayCaption,
                    startIndex: result.count,
                    items: [item]
                ))
            }
            result.count += 1
        }
        result.availableTypes = titles.map { GroupClosedRequestType(key: $0.key, title: $0.value) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return result
    }
}
