import Foundation

enum ActiveSimpleOneSection: String, CaseIterable, Identifiable {
    case task
    case closureCode
    case resolution
    case warehouse
    case client
    case install
    case dismantle
    case equipment

    var id: String { rawValue }

    var title: String {
        switch self {
        case .task:
            return "Задача"
        case .closureCode:
            return "Код закрытия"
        case .resolution:
            return "Решение"
        case .warehouse:
            return "Склад"
        case .client:
            return "Клиент"
        case .install:
            return "Установка"
        case .dismantle:
            return "Демонтаж"
        case .equipment:
            return "Оборудование"
        }
    }

    static let collapsible: [ActiveSimpleOneSection] = [.closureCode, .resolution, .warehouse, .client, .install, .dismantle, .equipment]
}

struct ActiveSimpleOneField: Identifiable {
    let id: String
    let title: String?
    let value: String
    var isLinkLike = false

    init(id: String? = nil, title: String?, value: String, isLinkLike: Bool = false) {
        self.id = id ?? "\(title ?? ""):\(value)"
        self.title = title
        self.value = value
        self.isLinkLike = isLinkLike
    }
}

struct ActiveSimpleOneRequestData {
    let record: SimpleOneRequestRecord
    private let allFields: [ClosedRequestInfoField]

    init(record: SimpleOneRequestRecord) {
        self.record = record

        var fields = record.tableFields ?? []
        fields.append(contentsOf: Self.parsedFields(from: record.description))
        if let additionalInformation = record.additionalInformation {
            fields.append(contentsOf: Self.parsedFields(from: additionalInformation))
        }
        self.allFields = fields
    }

    var requestNumber: String {
        firstMeaningful([
            record.incomingNumber,
            infoValue("Номер заявки Мультикарты"),
            record.shortDescription.hasPrefix("SUTS") ? record.shortDescription : nil,
            record.number
        ])
    }

    var deadlineText: String {
        formatDate(
            firstMeaningful([
                tableValue("Предельный срок СУТС"),
                record.deadline,
                record.primaryDate
            ]),
            format: "d MMM, HH:mm"
        )
    }

    var requestTypeText: String {
        localizedRequestType(firstMeaningful([
            tableValue("Тип заявки"),
            record.requestType,
            infoValue("Тип заявки")
        ]))
    }

    var multicardStatusText: String {
        firstMeaningful([
            tableValue("МК Статус"),
            record.state
        ])
    }

    var visibleSections: [ActiveSimpleOneSection] {
        ActiveSimpleOneSection.collapsible.filter { section in
            switch section {
            case .closureCode:
                return !closureCodeText.isEmpty
            case .resolution:
                return !resolutionText.isEmpty
            case .dismantle:
                return shouldShowDismantleSection
            default:
                return true
            }
        }
    }

    var terminalID: String {
        let primaryID = firstMeaningful([
            record.terminalID,
            tableValue("ID терминал"),
            infoValue("ID терминал"),
            infoValue("ID терминала")
        ])

        return joinedTerminalIDs([
            primaryID,
            tableValue("ID СБП"),
            infoValue("ID СБП")
        ])
    }

    var sla: ActiveSimpleOneSLA? {
        guard let start = parseDate(firstMeaningful([
            tableValue("Время создания в МК"),
            record.registeredAt
        ])),
              let end = parseDate(firstMeaningful([
                tableValue("Предельный срок СУТС"),
                record.deadline
              ])),
              end > start else {
            return nil
        }

        let now = Date()
        let total = end.timeIntervalSince(start)
        let elapsed = min(max(now.timeIntervalSince(start), 0), total)
        let remaining = end.timeIntervalSince(now)
        return ActiveSimpleOneSLA(
            progress: elapsed / total,
            remainingText: remaining < 0
                ? "Просрочено на \(remainingText(for: abs(remaining)))"
                : "Осталось \(remainingText(for: remaining))",
            isOverdue: remaining < 0
        )
    }

    var taskFields: [ActiveSimpleOneField] {
        compactFields([
            field("Дата создания:", formatDate(firstMeaningful([
                tableValue("Время создания в МК"),
                record.registeredAt
            ]), format: "dd/MM/yyyy HH:mm")),
            field("Статус:", firstMeaningful([
                multicardStatusText
            ])),
            field("Статус SimpleOne:", record.state),
            field("Код статуса:", record.stateRaw ?? ""),
            field("Исполнитель:", record.assignedUser),
            field("Рабочая группа:", record.assignmentGroup),
            field("Приоритет:", record.priority ?? ""),
            field("Причина ожидания:", record.waitingReason ?? ""),
            field("Телефон:", record.contactPhone ?? "", isLinkLike: true),
            field("Доп. инфо:", cleanedAdditionalInfo),
            field("Выполнена:", formatDate(record.completedAt ?? "", format: "dd/MM/yyyy HH:mm")),
            field("Закрыта:", formatDate(record.closedAt ?? "", format: "dd/MM/yyyy HH:mm"))
        ])
    }

    func fields(for section: ActiveSimpleOneSection) -> [ActiveSimpleOneField] {
        switch section {
        case .task:
            return taskFields
        case .closureCode:
            return compactFields([
                field(nil, closureCodeText)
            ])
        case .resolution:
            return compactFields([
                field(nil, resolutionText)
            ])
        case .warehouse:
            return compactFields([
                field("Город склада:", infoValue("Город склада")),
                field("Сотрудник склада:", tableValue("МК Сотрудник склада"))
            ])
        case .client:
            return compactFields([
                field(nil, legalName),
                field("ИНН ТСП:", merchantTIN, isLinkLike: true),
                field("Адрес:", address),
                field("Контакт:", contactPerson),
                field("Терминал:", terminalID)
            ])
        case .install:
            return compactFields([
                field("Производитель:", installVendor),
                field("Модель терминала:", installModel.isEmpty ? "Информация отсутствует" : installModel),
                field("Тип терминала:", installType),
                field("S/N терминала:", installedSerial, isLinkLike: true),
                field("S/N PINPad:", installedPinPadSerial, isLinkLike: true),
                field("Модель PINPad:", installedPinPadModel),
                field("Тип PINPad:", installPinPadType)
            ])
        case .dismantle:
            return compactFields([
                field("Терминал:", dismantleVendor),
                field("Модель терминала:", dismantleModel),
                field("S/N терминала:", dismantleSerial, isLinkLike: true),
                field("PINPad:", dismantlePinPadVendor),
                field("Модель PINPad:", dismantlePinPadModel),
                field("S/N PINPad:", dismantlePinPadSerial, isLinkLike: true),
                field("Факт терминал:", dismantleFact)
            ])
        case .equipment:
            return compactFields([
                field("Оборудование POS:", firstMeaningful([
                    tableValue("Оборудование POS"),
                    infoValue("Оборудование POS")
                ]), isLinkLike: true),
                field("Оборудование Pin Pad:", firstMeaningful([
                    tableValue("Оборудование Pin Pad"),
                    infoValue("Оборудование Pin Pad")
                ]), isLinkLike: true),
                field("Принятое оборудование POS:", tableValue("Номер принятого оборудования POS"), isLinkLike: true),
                field("Принятое оборудование PIN:", tableValue("Номер принятого оборудования PIN"), isLinkLike: true)
            ])
        }
    }

    var legalName: String {
        let raw = firstMeaningful([
            record.customer,
            tableValue("Заказчик")
        ])
        return raw
            .replacingOccurrences(of: "OOO", with: "ООО")
            .replacingOccurrences(of: "OОO", with: "ООО")
    }

    private var merchantTIN: String {
        firstMeaningful([
            tableValue("ИНН ТСП"),
            infoValue("ИНН ТСП")
        ])
    }

    private var address: String {
        firstMeaningful([
            record.address,
            tableValue("Адрес установки терминала"),
            infoValue("Адрес установки терминала"),
            infoValue("Адрес ТСП")
        ]).normalizedAddressStartingFromAlushta()
    }

    private var contactPerson: String {
        firstMeaningful([
            record.contactPerson,
            tableValue("Kонтактное лицо"),
            tableValue("Контактное лицо")
        ])
    }

    private var installVendor: String {
        vendorText(firstMeaningful([
            infoValue("Производитель устанавливаемого ТО"),
            tableValue("Производитель устанавливаемого ТО"),
            tableValue("Терминал вендора POS")
        ]))
    }

    private var installModel: String {
        firstMeaningful([
            infoValue("Модель устанавливаемого ТО"),
            tableValue("Модель устанавливаемого ТО"),
            record.terminalModel,
            tableValue("Модель POS-терминала"),
            infoValue("Модель POS-терминала"),
            tableValue("Модель POS"),
            infoValue("Модель POS"),
            tableValue("Модель терминала"),
            infoValue("Модель терминала")
        ])
    }

    private var installType: String {
        localizedTerminalType(firstMeaningful([
            infoValue("Тип устанавливаемого ТО"),
            tableValue("Тип устанавливаемого ТО")
        ]))
    }

    private var installedSerial: String {
        firstMeaningful([
            tableValue("Оборудование POS"),
            infoValue("Оборудование POS")
        ])
    }

    private var installedPinPadSerial: String {
        firstMeaningful([
            tableValue("Оборудование Pin Pad"),
            infoValue("Оборудование Pin Pad")
        ])
    }

    private var pinPadVendor: String {
        vendorText(firstMeaningful([
            tableValue("Терминал вендора PIN"),
            infoValue("Терминал вендора PIN")
        ]))
    }

    private var pinPadModel: String {
        firstMeaningful([
            tableValue("Модель PIN-Pad"),
            infoValue("Модель PIN-Pad"),
            tableValue("Модель PINPad"),
            infoValue("Модель PINPad"),
            tableValue("Модель Пин-Пада"),
            infoValue("Модель Пин-Пада")
        ])
    }

    private var installPinPadType: String {
        installedPinPadSerial.isEmpty ? "" : "Внешняя PIN-клавиатура"
    }

    private var installedPinPadModel: String {
        installedPinPadSerial.isEmpty ? "" : pinPadModel
    }

    private var dismantleVendor: String {
        vendorText(firstMeaningful([
            tableValue("Терминал вендора POS"),
            installVendor
        ]))
    }

    private var dismantleModel: String {
        firstMeaningful([
            infoValue("Модель демонтируемого ТО"),
            tableValue("Модель демонтируемого ТО"),
            installModel
        ])
    }

    private var dismantleSerial: String {
        firstMeaningful([
            infoValue("Серийный номер демонтируемого ТО"),
            tableValue("Серийный номер демонтируемого ТО"),
            tableValue("Номер принятого оборудования POS"),
            infoValue("Номер принятого оборудования POS")
        ])
    }

    private var dismantlePinPadSerial: String {
        firstMeaningful([
            infoValue("Серийный номер демонтируемого PIN"),
            tableValue("Серийный номер демонтируемого PIN"),
            tableValue("Номер принятого оборудования PIN"),
            infoValue("Номер принятого оборудования PIN")
        ])
    }

    private var dismantlePinPadVendor: String {
        dismantlePinPadSerial.isEmpty ? "" : pinPadVendor
    }

    private var dismantlePinPadModel: String {
        dismantlePinPadSerial.isEmpty ? "" : pinPadModel
    }

    private var dismantleFact: String {
        vendorText(firstMeaningful([
            tableValue("Терминал вендора POS")
        ]))
    }

    private var cleanedAdditionalInfo: String {
        let raw = firstMeaningful([
            tableValue("Доп. информация"),
            record.additionalInformation,
            infoValue("Доп. информация")
        ])
        let cleaned = raw
            .replacingOccurrences(of: #"^null#CC\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"^null\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if record.source == .closed,
           isOpaqueNumericValue(cleaned) {
            let shortDescription = record.shortDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if !shortDescription.isEmpty {
                return shortDescription
            }
        }
        return cleaned
    }

    private func isOpaqueNumericValue(_ value: String) -> Bool {
        let compact = value.filter { !$0.isWhitespace }
        return compact.count >= 32 && compact.allSatisfy(\.isNumber)
    }

    private var closureCodeText: String {
        firstMeaningful([
            record.closureCode,
            tableValue("Код закрытия"),
            infoValue("Код закрытия")
        ])
    }

    private var resolutionText: String {
        firstMeaningful([
            record.resolution,
            tableValue("Решение"),
            infoValue("Решение")
        ])
    }

    private func tableValue(_ key: String) -> String {
        value(for: key, in: record.tableFields ?? [])
    }

    private func infoValue(_ key: String) -> String {
        value(for: key, in: allFields)
    }

    private func value(for key: String, in fields: [ClosedRequestInfoField]) -> String {
        let normalizedKey = normalizedLabel(key)
        return fields
            .first { normalizedLabel($0.key) == normalizedKey }?
            .value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfMeaningless ?? ""
    }

    private func field(_ title: String?, _ value: String, isLinkLike: Bool = false) -> ActiveSimpleOneField {
        ActiveSimpleOneField(title: title, value: value, isLinkLike: isLinkLike)
    }

    private func compactFields(_ fields: [ActiveSimpleOneField]) -> [ActiveSimpleOneField] {
        fields
            .filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .enumerated()
            .map { index, field in
                ActiveSimpleOneField(
                    id: "field-\(index)",
                    title: field.title,
                    value: field.value,
                    isLinkLike: field.isLinkLike
                )
            }
    }

    private static func parsedFields(from raw: String) -> [ClosedRequestInfoField] {
        normalizedInfoText(raw)
            .split(whereSeparator: \.isNewline)
            .compactMap { rawLine -> ClosedRequestInfoField? in
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty, let separator = line.firstIndex(of: ":") else { return nil }

                let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { return nil }
                return ClosedRequestInfoField(key: key, value: value)
            }
    }

    private static func normalizedInfoText(_ raw: String) -> String {
        let labels = [
            "Номер заявки Мультикарты",
            "Принадлежность оборудования по заявке",
            "Серийный номер демонтируемого ТО",
            "Серийный номер демонтируемого PIN",
            "Производитель устанавливаемого ТО",
            "Модель устанавливаемого ТО",
            "Модель POS-терминала",
            "Модель POS",
            "Модель терминала",
            "Тип устанавливаемого ТО",
            "Согласованная дата и время проведения работ",
            "Согласованная дата и время предоставления доступа",
            "Тип заявки",
            "Категория обслуживания",
            "Город склада",
            "Адрес установки терминала",
            "Адрес ТСП",
            "Заказчик",
            "Оборудование POS",
            "Оборудование Pin Pad",
            "Доп. информация",
            "ID СБП",
            "ИНН ТСП",
            "Код закрытия",
            "Решение"
        ]
        let normalized = raw
            .replacingOccurrences(of: "\\r\\n", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "&#xA;", with: "\n")
            .replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "</(div|p|li|tr)>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: [.regularExpression, .caseInsensitive])

        return labels.reduce(normalized) { result, label in
            result.replacingOccurrences(
                of: "([^\\n])\\s*(\(NSRegularExpression.escapedPattern(for: label))\\s*:)",
                with: "$1\n$2",
                options: [.regularExpression, .caseInsensitive, .diacriticInsensitive]
            )
        }
    }

    private func firstMeaningful(_ values: [String?]) -> String {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfMeaningless }
            .first { !$0.isEmpty } ?? ""
    }

    private func joinedTerminalIDs(_ values: [String]) -> String {
        var seen = Set<String>()
        return values
            .flatMap { value in
                value.components(separatedBy: CharacterSet(charactersIn: ",;\n\r"))
            }
            .compactMap { value in
                value.trimmingCharacters(in: .whitespacesAndNewlines).nilIfMeaningless
            }
            .filter { value in
                seen.insert(value.lowercased()).inserted
            }
            .joined(separator: ", ")
    }

    private func normalizedLabel(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "Cерийный", with: "Серийный")
            .replacingOccurrences(of: "cерийный", with: "серийный")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    private func localizedRequestType(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "install":
            return "Установка"
        case "dismounting":
            return "Демонтаж"
        case "returnEquip":
            return "Возврат ТО"
        case "serviceStd":
            return "Сервисная"
        case "replacement":
            return "Замена"
        default:
            return raw
        }
    }

    private var shouldShowDismantleSection: Bool {
        let rawType = firstMeaningful([
            tableValue("Тип заявки"),
            record.requestType,
            infoValue("Тип заявки")
        ])
        let normalized = rawType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let localized = localizedRequestType(rawType)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)

        return normalized == "replacement"
            || normalized == "dismounting"
            || localized == "замена"
            || localized == "демонтаж"
    }

    private func localizedTerminalType(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "portable_pos":
            return "Переносной POS-терминал"
        case "stationary_pos", "stat_pos":
            return "Стационарный POS-терминал"
        default:
            return raw
        }
    }

    private func vendorText(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= 4 ? trimmed.uppercased() : trimmed
    }

    private func formatDate(_ raw: String, format: String) -> String {
        guard let date = parseDate(raw) else { return raw }
        return Self.outputFormatters[format]?.string(from: date) ?? raw
    }

    private func parseDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        for formatter in Self.inputDateFormatters {
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return nil
    }

    private func remainingText(for interval: TimeInterval) -> String {
        let totalMinutes = max(0, Int(interval / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return "\(hours) ч. \(minutes) м."
    }

    private static let inputDateFormatters: [DateFormatter] = [
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd HH:mm",
        "dd.MM.yyyy HH:mm:ss",
        "dd.MM.yyyy HH:mm"
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    private static let outputFormatters: [String: DateFormatter] = [
        "d MMM, HH:mm",
        "dd/MM/yyyy HH:mm"
    ].reduce(into: [:]) { result, format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = format
        result[format] = formatter
    }
}

struct ActiveSimpleOneSLA {
    let progress: Double
    let remainingText: String
    let isOverdue: Bool
}

private extension String {
    var nilIfMeaningless: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)

        if normalized == "информация отсутствует" || normalized == "null" {
            return nil
        }
        return trimmed
    }
}
