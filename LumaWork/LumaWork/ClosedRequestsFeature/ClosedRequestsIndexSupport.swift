import Foundation

nonisolated struct ClosedRequestPreparedSearchEntry: Sendable {
    let item: ClosedRequestPreparedListItem
    let searchText: String
}

nonisolated struct ClosedRequestPreparedListItem: Identifiable, Sendable {
    let record: ClosedRequestRecord
    let date: Date?
    let requestType: String
    let statusText: String
    let closedAtText: String
    let timeTitle: String
    let normalizedAddress: String
    let dayKey: String
    let dayTitle: String
    let dayCaption: String
    let searchText: String

    var id: String {
        record.id
    }
}

nonisolated struct ClosedRequestPreparedDayGroup: Identifiable, Sendable {
    let dayKey: String
    let title: String
    let caption: String
    var records: [ClosedRequestPreparedListItem]

    var id: String {
        dayKey
    }
}

nonisolated enum ClosedRequestsFilterSupport {
    static func defaultRange(
        availableDates: [Date],
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> ClosedRange<Date>? {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let days = availableDates.map { calendar.startOfDay(for: $0) }

        if days.contains(where: { $0 >= yesterday && $0 <= today }) {
            return yesterday...today
        }
        if let latestPastDay = days.filter({ $0 <= today }).max() {
            return latestPastDay...latestPastDay
        }
        guard let earliestFutureDay = days.filter({ $0 > today }).min() else {
            return nil
        }
        return earliestFutureDay...earliestFutureDay
    }

    static func normalizedRange(
        first: Date,
        second: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> ClosedRange<Date> {
        let firstDay = calendar.startOfDay(for: first)
        let secondDay = calendar.startOfDay(for: second)
        return min(firstDay, secondDay)...max(firstDay, secondDay)
    }
}

nonisolated enum ClosedRequestsIndexBuilder {
    static func build(records: [ClosedRequestRecord]) -> [ClosedRequestPreparedSearchEntry] {
        let formatters = parsingFormatters()
        let outputFormatter = formatter("dd.MM.yyyy HH:mm", locale: "ru_RU")
        let dayKeyFormatter = formatter("yyyy-MM-dd", locale: "en_US_POSIX")
        let dayTitleFormatter = formatter("d MMMM yyyy", locale: "ru_RU")
        let dayCaptionFormatter = formatter("EEEE", locale: "ru_RU")
        let searchFormatters = [
            formatter("d MMMM", locale: "ru_RU"),
            formatter("d MMMM yyyy", locale: "ru_RU"),
            formatter("dd.MM.yy", locale: "ru_RU"),
            formatter("dd MM yyyy", locale: "ru_RU")
        ]
        let calendar = Calendar.autoupdatingCurrent

        return records.map { record in
            let requestType = localizedRequestType(record.requestType)
            let isReturnEquipment = isReturnEquipment(record.requestType)
            let registeredAt = record.registeredAt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let effectiveTime = isReturnEquipment && parseDate(registeredAt, formatters: formatters) != nil
                ? registeredAt
                : record.closedAt
            let timeTitle = isReturnEquipment ? "Время регистрации" : "Выполнена"
            let date = parseDate(effectiveTime, formatters: formatters)
            let statusText = isReturnEquipment
                ? localizedStatus(record.status)
                : record.completionStatus.title
            let closedAtText = date.map(outputFormatter.string(from:)) ?? effectiveTime
            let dayKey = date.map(dayKeyFormatter.string(from:))
                ?? nonEmpty(effectiveTime, fallback: "unknown")
            let dayTitle: String
            if let date, calendar.isDateInToday(date) {
                dayTitle = "Сегодня"
            } else if let date, calendar.isDateInYesterday(date) {
                dayTitle = "Вчера"
            } else if let date {
                dayTitle = dayTitleFormatter.string(from: date)
            } else {
                dayTitle = nonEmpty(effectiveTime, fallback: "Дата не указана")
            }
            let dayCaption = date.map(dayCaptionFormatter.string(from:)) ?? ""
            let dateSearchText = date.map { date in
                (searchFormatters.map { $0.string(from: date) }
                    + [dayTitleFormatter.string(from: date), dayCaptionFormatter.string(from: date)])
                    .joined(separator: "\n")
            } ?? effectiveTime
            let searchText = [
                record.requestNumber,
                record.shortDescription,
                record.customer,
                record.contactPerson,
                record.address,
                record.terminalID,
                record.incomingNumber,
                record.engineerName,
                record.merchantTIN,
                record.posEquipment,
                record.dismantledEquipmentSerialNumber,
                record.installedFiscalStorageSerialNumber,
                record.ofdTariffActivationCode,
                record.usedSIMCard,
                record.closureCode,
                statusText,
                effectiveTime,
                closedAtText,
                dateSearchText,
                infoValue("ИНН ТСП", in: record),
                infoValue("Оборудование POS", in: record),
                infoValue("Серийный номер демонтируемого ТО", in: record),
                infoValue("Серийный номер установленного ФН", in: record),
                infoValue("Использованный код активации тарифа ОФД", in: record),
                infoValue("Использованная SIM карта", in: record)
            ]
            .compactMap { $0 }
            .joined(separator: "\n")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)

            let item = ClosedRequestPreparedListItem(
                record: record,
                date: date,
                requestType: requestType,
                statusText: statusText,
                closedAtText: closedAtText,
                timeTitle: timeTitle,
                normalizedAddress: record.address.normalizedAddressStartingFromAlushta(),
                dayKey: dayKey,
                dayTitle: dayTitle,
                dayCaption: dayCaption,
                searchText: searchText
            )
            return ClosedRequestPreparedSearchEntry(item: item, searchText: searchText)
        }
    }

    private static func parseDate(_ raw: String, formatters: [DateFormatter]) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let serial = Double(trimmed) {
            let excelBaseDate = Date(timeIntervalSince1970: -2_209_161_600)
            return excelBaseDate.addingTimeInterval(serial * 86_400)
        }
        return formatters.lazy.compactMap { $0.date(from: trimmed) }.first
    }

    private static func localizedRequestType(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstToken = trimmed.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? trimmed
        switch firstToken {
        case "install": return "Установка"
        case "dismounting": return "Демонтаж"
        case "returnEquip": return "Возврат ТО"
        case "serviceStd": return "Сервисная"
        case "replacement": return "Замена"
        default: return trimmed
        }
    }

    private static func isReturnEquipment(_ rawType: String) -> Bool {
        let type = rawType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return type == "returnequip"
            || type == "return_equip"
            || type.contains("возврат то")
            || type.contains("возврат")
    }

    private static func localizedStatus(_ raw: String) -> String {
        let status = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch status.lowercased() {
        case "completed": return "Выполнена"
        case "closed": return "Закрыта"
        default: return status.isEmpty ? "Закрыта" : status
        }
    }

    private static func infoValue(_ key: String, in record: ClosedRequestRecord) -> String? {
        let normalizedKey = normalizedInfoKey(key)
        let value = record.infoFields
            .first { normalizedInfoKey($0.key) == normalizedKey }?
            .value
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private static func normalizedInfoKey(_ raw: String) -> String {
        raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    private static func nonEmpty(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func parsingFormatters() -> [DateFormatter] {
        [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "dd.MM.yyyy HH:mm:ss",
            "dd.MM.yyyy HH:mm",
            "dd.MM.yyyy H:mm",
            "MM.dd.yyyy HH:mm:ss",
            "MM.dd.yyyy HH:mm",
            "MM.dd.yyyy H:mm",
            "yyyy-MM-dd",
            "dd.MM.yyyy",
            "MM.dd.yyyy"
        ].map { formatter($0, locale: "en_US_POSIX") }
    }

    private static func formatter(_ format: String, locale: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: locale)
        formatter.dateFormat = format
        return formatter
    }
}
