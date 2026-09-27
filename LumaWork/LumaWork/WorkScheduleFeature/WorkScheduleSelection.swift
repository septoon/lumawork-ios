import Foundation

nonisolated struct WorkScheduleSelectionState: Equatable, Sendable {
    let cityName: String
    let year: Int
    let month: Int
}

nonisolated enum WorkScheduleSelection {
    static func initial(
        journals: [WorkScheduleJournal],
        profileCity: String?,
        currentYear: Int,
        currentMonth: Int
    ) -> WorkScheduleSelectionState {
        let cities = cityNames(in: journals)
        let profileCity = profileCity?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let selectedCity = cities.first { normalized($0) == normalized(profileCity) }
            ?? cities.first
            ?? ""
        return WorkScheduleSelectionState(
            cityName: selectedCity,
            year: currentYear,
            month: currentMonth
        )
    }

    static func cityNames(in journals: [WorkScheduleJournal]) -> [String] {
        var namesByKey: [String: String] = [:]
        for journal in journals {
            namesByKey[normalized(journal.cityName)] = journal.cityName
        }
        return namesByKey.values.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    static func years(
        in journals: [WorkScheduleJournal],
        cityName: String
    ) -> [Int] {
        Array(Set(journals.lazy
            .filter { normalized($0.cityName) == normalized(cityName) }
            .map(\.year)))
            .sorted(by: >)
    }

    static func months(
        in journals: [WorkScheduleJournal],
        cityName: String,
        year: Int
    ) -> [Int] {
        Array(Set(journals.lazy
            .filter {
                normalized($0.cityName) == normalized(cityName) && $0.year == year
            }
            .map(\.month)))
            .sorted()
    }

    static func journal(
        in journals: [WorkScheduleJournal],
        matching selection: WorkScheduleSelectionState
    ) -> WorkScheduleJournal? {
        journals.first {
            normalized($0.cityName) == normalized(selection.cityName)
                && $0.year == selection.year
                && $0.month == selection.month
        }
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

nonisolated enum WorkScheduleViewport {
    static func currentDay(
        in journal: WorkScheduleJournal,
        now: Date,
        calendar: Calendar
    ) -> Int? {
        let components = calendar.dateComponents([.year, .month, .day], from: now)
        guard components.year == journal.year,
              components.month == journal.month else {
            return nil
        }
        return components.day
    }

    static func initialVisibleDay(
        in journal: WorkScheduleJournal,
        now: Date,
        calendar: Calendar
    ) -> Int {
        guard let currentDay = currentDay(in: journal, now: now, calendar: calendar) else {
            return 1
        }
        return max(1, currentDay - 1)
    }
}
