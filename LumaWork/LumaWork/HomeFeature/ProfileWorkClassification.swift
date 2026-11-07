import Foundation

nonisolated enum ProfileWorkCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case portable, stationary, integration, fiscal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .portable: "Переносные"
        case .stationary: "Стационарные"
        case .integration: "Интеграции"
        case .fiscal: "Кассы"
        }
    }

    init?(terminalType: String) {
        switch terminalType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "portable_pos", "universal_pos": self = .portable
        case "stat_pos": self = .stationary
        case "intel_pin": self = .integration
        case "fiscal_pos": self = .fiscal
        default: return nil
        }
    }
}

nonisolated enum ProfileWorkOperation: String, CaseIterable, Identifiable, Codable, Sendable {
    case install, replacement, serviceStd, dismounting

    var id: String { rawValue }

    var title: String {
        switch self {
        case .install: "Установки"
        case .replacement: "Замены"
        case .serviceStd: "Сервис"
        case .dismounting: "Демонтаж"
        }
    }
}

nonisolated enum ProfileWorkClassification {
    static func category(for record: ClosedRequestRecord, operation: ProfileWorkOperation) -> ProfileWorkCategory? {
        let labels = operation == .dismounting
            ? ["Тип демонтируемого ТО", "Тип устанавливаемого ТО", "Тип терминала"]
            : ["Тип устанавливаемого ТО", "Тип терминала"]
        for label in labels {
            if let value = record.infoFields.first(where: {
                $0.key.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ":")))
                    .caseInsensitiveCompare(label) == .orderedSame
            })?.value, let category = ProfileWorkCategory(terminalType: value) {
                return category
            }
        }
        return nil
    }
}
