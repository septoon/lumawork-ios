import Foundation

nonisolated enum CoordinationSection: String, CaseIterable, Identifiable, Sendable {
    case distribution
    case returnEquipment

    var id: String { rawValue }

    var title: String {
        switch self {
        case .distribution:
            "На группу"
        case .returnEquipment:
            "Возврат ТО"
        }
    }
}

nonisolated enum CoordinationRegion: String, CaseIterable, Codable, Identifiable, Sendable {
    case simferopol
    case alushta
    case yalta
    case evpatoria
    case krasnoperekopsk
    case dzhankoy
    case feodosia
    case kerch
    case sevastopol

    static let defaultRegion: CoordinationRegion = .alushta

    init?(profileCity: String?) {
        var city = (profileCity ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ru_RU"))
        for prefix in ["город ", "г. ", "г.", "г "] where city.hasPrefix(prefix) {
            city = String(city.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        guard let region = Self.allCases.first(where: {
            $0.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ru_RU")) == city
        }) else { return nil }
        self = region
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .simferopol:
            "Симферополь"
        case .alushta:
            "Алушта"
        case .yalta:
            "Ялта"
        case .evpatoria:
            "Евпатория"
        case .krasnoperekopsk:
            "Красноперекопск"
        case .dzhankoy:
            "Джанкой"
        case .feodosia:
            "Феодосия"
        case .kerch:
            "Керчь"
        case .sevastopol:
            "Севастополь"
        }
    }

    var assignmentGroupID: String {
        AppConfig.resolveFirst("SIMPLEONE_\(rawValue.uppercased())_ASSIGNMENT_GROUP_ID") ?? ""
    }

    var companyLocationID: String {
        AppConfig.resolveFirst("SIMPLEONE_\(rawValue.uppercased())_COMPANY_LOCATION_ID") ?? ""
    }

}

nonisolated func isCoordinationReturnEquipmentRequestType(_ raw: String) -> Bool {
    let normalized = raw
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .lowercased()
        .replacingOccurrences(of: "_", with: "")
        .replacingOccurrences(of: "-", with: "")
        .replacingOccurrences(of: " ", with: "")

    return normalized == "returnequip" || normalized.contains("возвратто")
}

nonisolated func isCoordinationExpertiseRequestType(_ raw: String) -> Bool {
    let normalized = raw
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .lowercased()
        .replacingOccurrences(of: "_", with: "")
        .replacingOccurrences(of: "-", with: "")
        .replacingOccurrences(of: " ", with: "")

    return normalized.contains("экспертиз") || normalized.contains("expert")
}

nonisolated struct CoordinationEngineer: Hashable, Identifiable, Sendable {
    static let unassignedID = "coordination:unassigned"

    let id: String
    let name: String
    let requestCount: Int

    var isUnassigned: Bool {
        id == Self.unassignedID
    }
}
