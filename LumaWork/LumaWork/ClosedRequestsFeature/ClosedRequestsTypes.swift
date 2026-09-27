import Foundation


let multicardKnownInformationLabels = [
    "Номер заявки Мультикарты",
    "Принадлежность оборудования по заявке",
    "Серийный номер демонтируемого ТО",
    "Серийный номер демонтируемого PIN",
    "Производитель устанавливаемого ТО",
    "Модель устанавливаемого ТО",
    "Тип устанавливаемого ТО",
    "Согласованная дата и время проведения работ",
    "Согласованная дата и время предоставления доступа",
    "Тип заявки",
    "Категория обслуживания",
    "Город склада",
    "Адрес установки терминала",
    "Адрес ТСП",
    "ID терминал",
    "ID терминала",
    "Наименование юр.лица",
    "Наименование юр. лица",
    "Номер телефона ТСП",
    "Заказчик",
    "Kонтактное лицо",
    "Контактное лицо",
    "Оборудование POS",
    "Оборудование Pin Pad",
    "Доп. информация",
    "Доп информация",
    "Дополнительная информация",
    "ID СБП",
    "ИНН ТСП",
    "Код закрытия",
    "Решение",
    "Комментарий к результату выезда",
    "Комментарий инженера"
]

nonisolated func localizedClosedRequestStatus(_ raw: String) -> String {
    let status = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    switch status.lowercased() {
    case "completed":
        return "Выполнена"
    case "closed":
        return "Закрыта"
    default:
        return status.isEmpty ? "Закрыта" : status
    }
}

enum RequestDetailRoute: Identifiable {
    case closed(ClosedRequestRecord)
    case simpleOne(SimpleOneRequestRecord)
    case closedSimpleOne(SimpleOneRequestRecord)

    var id: String {
        switch self {
        case .closed(let record):
            return "closed:\(record.id)"
        case .simpleOne(let record):
            return "simple-one:\(record.id)"
        case .closedSimpleOne(let record):
            return "closed-simple-one:\(record.id)"
        }
    }
}

enum RequestsViewMode: String, CaseIterable, Identifiable {
    case active
    case closed
    case warehouse
    // Disabled experiment. Keep this case out of production flows until the screen is redesigned.
    case closedSimpleOne

    static let visibleCases: [RequestsViewMode] = [
        .active,
        .closed
    ]

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .active:
            return "Активные"
        case .closed:
            return "Закрытые"
        case .warehouse:
            return "Складские"
        case .closedSimpleOne:
            return "Закрытые SO"
        }
    }
}

struct WarehouseTerminalSelection: Identifiable {
    let terminalID: String

    var id: String {
        terminalID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .uppercased()
    }
}

enum ActiveRequestsSortOrder: String, CaseIterable, Identifiable {
    case deadline
    case registeredAt

    var id: String { rawValue }

    var title: String {
        switch self {
        case .deadline:
            return "По предельному сроку"
        case .registeredAt:
            return "По регистрации"
        }
    }
}

nonisolated enum ActiveRequestsStatusFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case available
    case inProgress
    case waiting

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "Все"
        case .available:
            return "Доступные"
        case .inProgress:
            return "В работе"
        case .waiting:
            return "В ожидании"
        }
    }

    var systemImage: String {
        switch self {
        case .all:
            return "tray.full.fill"
        case .available:
            return "checkmark.circle.fill"
        case .inProgress:
            return "hammer.fill"
        case .waiting:
            return "clock.fill"
        }
    }

    func contains(status rawStatus: String) -> Bool {
        let status = Self.normalizedStatus(rawStatus)
        switch self {
        case .all:
            return true
        case .available:
            return status == Self.normalizedStatus("Работа в приложении")
        case .waiting:
            return status == Self.normalizedStatus("В ожидании")
        case .inProgress:
            return status != Self.normalizedStatus("Работа в приложении")
                && status != Self.normalizedStatus("В ожидании")
        }
    }

    private static func normalizedStatus(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "ё", with: "е")
            .replacingOccurrences(of: "Ё", with: "Е")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}

func uniqueSimpleOneRecords(_ records: [SimpleOneRequestRecord]) -> [SimpleOneRequestRecord] {
    var seenIDs = Set<String>()
    return records.filter { record in
        let id = record.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return true }
        return seenIDs.insert(id).inserted
    }
}

func isWarehouseRequest(_ record: SimpleOneRequestRecord) -> Bool {
    if isWarehouseRequestType(record.requestType) {
        return true
    }

    let tableText = (record.tableFields ?? [])
        .map { "\($0.key): \($0.value)" }
        .joined(separator: "\n")
    return containsWarehouseRequestMarker([
        record.shortDescription,
        record.assignmentGroup,
        record.clientServiceParent ?? "",
        record.clientService ?? "",
        record.additionalInformation ?? "",
        record.description,
        tableText
    ])
}

func isWarehouseRequest(_ record: ClosedRequestRecord) -> Bool {
    if isWarehouseRequestType(record.requestType) {
        return true
    }

    let fieldsText = record.infoFields
        .map { "\($0.key): \($0.value)" }
        .joined(separator: "\n")
    return containsWarehouseRequestMarker([
        record.shortDescription,
        record.workgroup,
        record.rawInfo,
        fieldsText
    ])
}

func warehouseInformationBlock(_ record: SimpleOneRequestRecord) -> String {
    let fields = warehouseInformationFields(record)
    let rows: [(String, String)] = [
        ("ID терминал", firstNonEmpty([
            value(for: ["ID терминал", "ID терминала"], in: fields),
            record.terminalID
        ])),
        ("Наименование юр.лица", firstNonEmpty([
            value(for: ["Наименование юр.лица", "Наименование юр. лица", "Заказчик"], in: fields),
            record.customer
        ])),
        ("Адрес ТСП", firstNonEmpty([
            value(for: ["Адрес ТСП", "Адрес установки терминала", "Адрес"], in: fields),
            record.address
        ])),
        ("Номер телефона ТСП", value(for: ["Номер телефона ТСП", "Телефон ТСП"], in: fields)),
        ("Kонтактное лицо", firstNonEmpty([
            value(for: ["Kонтактное лицо", "Контактное лицо", "ФИО контактного лица"], in: fields),
            record.contactPerson
        ])),
        ("Доп. информация", value(for: ["Доп. информация", "Доп информация", "Дополнительная информация"], in: fields)),
        ("Тип заявки", firstNonEmpty([
            value(for: ["Тип заявки", "Тип работ", "Вид заявки", "Тип обращения"], in: fields),
            record.requestType
        ]))
    ]

    return rows
        .compactMap { key, value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, normalizedEquipmentLabel(trimmed) != "информация отсутствует" else {
                return nil
            }
            return "\(key): \(trimmed)"
        }
        .joined(separator: "\n")
}

func warehouseInformationFields(_ record: SimpleOneRequestRecord) -> [ClosedRequestInfoField] {
    let tableFields = record.tableFields ?? []
    let tableTexts = tableFields.map(\.value)
    let texts = [
        record.additionalInformation ?? "",
        record.description,
        record.informationText
    ] + tableTexts

    return tableFields + parseWarehouseInformationFields(texts)
}

func parseWarehouseInformationFields(_ texts: [String]) -> [ClosedRequestInfoField] {
    texts.flatMap { text in
        normalizedMulticardInformationText(text)
            .components(separatedBy: .newlines)
            .compactMap { rawLine -> ClosedRequestInfoField? in
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty, let separator = line.firstIndex(of: ":") else {
                    return nil
                }

                let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { return nil }
                return ClosedRequestInfoField(key: key, value: value)
            }
    }
}

func value(for labels: [String], in fields: [ClosedRequestInfoField]) -> String {
    let normalizedLabels = labels.map(normalizedEquipmentLabel)
    return fields
        .compactMap { field -> String? in
            guard normalizedLabels.contains(normalizedEquipmentLabel(field.key)) else {
                return nil
            }
            let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, normalizedEquipmentLabel(value) != "информация отсутствует" else {
                return nil
            }
            return value
        }
        .first ?? ""
}

func isWarehouseRequestType(_ raw: String) -> Bool {
    let normalized = normalizedWarehouseText(raw)
    return normalized == "returnequip"
        || normalized == "return_equip"
        || normalized.contains("возврат то")
        || normalized.contains("возврат")
        || normalized.contains("возврат оборудования")
}

func containsWarehouseRequestMarker(_ texts: [String]) -> Bool {
    texts
        .map(normalizedWarehouseText)
        .contains { text in
            text.contains("город склада")
                || text.contains("складская заявка")
                || text.contains("складские заявки")
                || text.contains("номер принятого оборудования")
        }
}

func normalizedWarehouseText(_ raw: String) -> String {
    raw
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
        .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
}

nonisolated func firstNonEmpty(_ values: [String?]) -> String {
    values
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
}

func extractedLabeledValue(from texts: [String], labels: [String]) -> String {
    for text in texts where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let normalizedText = normalizedMulticardInformationText(text)
        for label in labels {
            if let value = extractedKnownLabeledValue(label: label, from: normalizedText) {
                return value
            }
        }

        let normalizedLabels = labels.map(normalizedEquipmentLabel)
        let chunks = normalizedText.components(separatedBy: CharacterSet(charactersIn: "\n;\r"))
        for chunk in chunks {
            let trimmedChunk = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedChunk = normalizedEquipmentLabel(trimmedChunk)

            for (index, normalizedLabel) in normalizedLabels.enumerated() where normalizedChunk.hasPrefix(normalizedLabel) {
                let label = labels[index]
                guard trimmedChunk.count >= label.count else { continue }

                var value = String(trimmedChunk.dropFirst(label.count))
                value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: ":-–—"))
                value = value.trimmingCharacters(in: .whitespacesAndNewlines)

                if !value.isEmpty {
                    return value
                }
            }
        }
    }

    return ""
}

func extractedKnownLabeledValue(label: String, from text: String) -> String? {
    let marker = "\(label):"
    guard let markerRange = text.range(of: marker, options: [.caseInsensitive, .diacriticInsensitive]) else {
        return nil
    }

    let suffix = String(text[markerRange.upperBound...])
    let endIndex = multicardKnownInformationLabels
        .compactMap { nextLabel -> String.Index? in
            suffix.range(
                of: "(?:^|\\n|\\s)\(NSRegularExpression.escapedPattern(for: nextLabel))\\s*:",
                options: [.regularExpression, .caseInsensitive, .diacriticInsensitive]
            )?.lowerBound
        }
        .min()
    let rawValue = endIndex.map { String(suffix[..<$0]) } ?? suffix
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, normalizedEquipmentLabel(value) != "информация отсутствует" else {
        return nil
    }
    return value
}

func normalizedMulticardInformationText(_ raw: String) -> String {
    let normalized = raw
        .replacingOccurrences(of: "\\r\\n", with: "\n")
        .replacingOccurrences(of: "\\n", with: "\n")
        .replacingOccurrences(of: "&#xA;", with: "\n")
        .replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        .replacingOccurrences(of: "</(div|p|li|tr)>", with: "\n", options: [.regularExpression, .caseInsensitive])
        .replacingOccurrences(of: "<[^>]+>", with: "", options: [.regularExpression, .caseInsensitive])

    return multicardKnownInformationLabels.reduce(normalized) { result, label in
        result.replacingOccurrences(
            of: "([^\\n])\\s*(\(NSRegularExpression.escapedPattern(for: label))\\s*:)",
            with: "$1\n$2",
            options: [.regularExpression, .caseInsensitive, .diacriticInsensitive]
        )
    }
}

func normalizedEquipmentLabel(_ raw: String) -> String {
    raw
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "Cерийный", with: "Серийный")
        .replacingOccurrences(of: "cерийный", with: "серийный")
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
        .lowercased()
}
