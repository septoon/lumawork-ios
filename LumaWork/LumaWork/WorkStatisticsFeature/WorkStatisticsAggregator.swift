import Foundation

nonisolated enum WorkStatisticsAggregator {
    static let timezone = TimeZone(identifier: "Europe/Moscow")!

    static func contribution(_ record: ClosedRequestRecord) -> WorkContribution {
        var metrics = WorkStatisticsMetrics()
        metrics.closedCount = 1
        let type = normalize(record.requestType)
        if type == "returnequip" || type == "return_equip" || type.contains("возврат то") {
            metrics.returnEquipmentCount = 1
        } else if record.isCompletedWithVisit {
            metrics.completedWithVisitCount = 1
            if let operation = ProfileWorkOperation(rawValue: record.requestType.trimmingCharacters(in: .whitespacesAndNewlines)),
               let category = ProfileWorkClassification.category(for: record, operation: operation) {
                metrics.byCategory[category.rawValue]![operation.rawValue] = 1
            } else {
                metrics.unclassifiedCompletedCount = 1
            }
        }
        let info: (String) -> String? = { key in record.infoFields.first { normalize($0.key).trimmingCharacters(in: CharacterSet(charactersIn: ":")) == normalize(key) }?.value }
        let dates = [record.completedAt, record.workStatisticsDate] + ["Выполнена", "Время Выполнена", "Время выполнения", "Время решения", "resolvedAt"].map(info) + [record.closedInMulticardAt, record.closedAt]
        let date = dates.compactMap { $0 }.compactMap(parseDate).first
        return WorkContribution(monthKey: date.map(monthKey), metrics: metrics)
    }

    /// Read raw source values before the archive's device-timezone display conversion.
    static func sourceDate(from row: [String: String], infoFields: [ClosedRequestInfoField]) -> String? {
        for label in ["completedAt", "Выполнена", "Время Выполнена", "Время \"Выполнена\"", "Время выполнения", "resolvedAt", "Время решения", "Дата закрытия в МК", "Дата закрытия МК", "Дата закрытия"] {
            if let entry = row.first(where: { normalize($0.key) == normalize(label) }),
               let raw = row["__workStatisticsUTC:" + entry.key] {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let canonical: String
                if trimmed.range(of: #"^\d{4}-\d{2}-\d{2}(?:[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?)?$"#, options: .regularExpression) != nil {
                    canonical = trimmed.count == 10 ? trimmed + "T00:00:00Z" : trimmed.replacingOccurrences(of: " ", with: "T") + "Z"
                } else { canonical = trimmed }
                if parseDate(canonical) != nil { return canonical }
            }
            let values = [row.first { normalize($0.key) == normalize(label) }?.value, infoFields.first { normalize($0.key) == normalize(label) }?.value]
            if let value = values.compactMap({ $0 }).first(where: { parseDate($0) != nil }) { return value }
        }
        return nil
    }

    static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ru_RU"))
    }

    static func parseDate(_ raw: String) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) { return date }
        iso.formatOptions.insert(.withFractionalSeconds)
        if let date = iso.date(from: value) { return date }
        if let serial = Double(value), serial.isFinite, serial >= 1, serial < 3_000_000 {
            // Excel serial is a wall-clock calendar, not elapsed time in Moscow.
            // Moscow's historical 1899 offset differs from today's offset.
            var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
            let base = utc.date(from: DateComponents(year: 1899, month: 12, day: 30))!
            let wallClock = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: base.addingTimeInterval(serial * 86_400))
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timezone
            return calendar.date(from: wallClock)
        }
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "dd.MM.yyyy HH:mm:ss", "dd.MM.yyyy HH:mm", "yyyy-MM-dd", "dd.MM.yyyy"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = timezone
            formatter.dateFormat = format
            formatter.isLenient = false
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    static func monthKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timezone
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year!, parts.month!)
    }
}
