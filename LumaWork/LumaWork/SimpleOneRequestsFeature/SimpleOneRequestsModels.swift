import Foundation

nonisolated enum SimpleOneRequestSource: String, Codable, Hashable, Sendable {
    case active
    case closed
}

nonisolated struct SimpleOneRequestRecord: Codable, Hashable, Identifiable, Sendable {
    var id: String {
        sysID.isEmpty ? number : sysID
    }

    var source: SimpleOneRequestSource
    var sysID: String
    var number: String
    var incomingNumber: String
    var registeredAt: String? = nil
    var waitingReason: String? = nil
    var state: String
    var stateRaw: String? = nil
    var shortDescription: String
    var assignmentGroup: String
    var initiator: String? = nil
    var priority: String? = nil
    var clientServiceParent: String? = nil
    var clientService: String? = nil
    var requestType: String
    var address: String
    var customer: String
    var deadline: String
    var resolvedAt: String
    var completedAt: String? = nil
    var closedAt: String? = nil
    var assignedUser: String
    var assignedUserID: String? = nil
    var sysUpdatedAt: String? = nil
    var terminalModel: String
    var terminalID: String
    var contactPerson: String
    var contactPhone: String? = nil
    var engineerComment: String
    var closureCode: String? = nil
    var resolution: String? = nil
    var additionalInformation: String? = nil
    var description: String
    var installedFiscalStorageSerialNumber: String? = nil
    var ofdTariffActivationCode: String? = nil
    var usedSIMCard: String? = nil
    var tableFields: [ClosedRequestInfoField]? = nil

    var primaryDate: String {
        source == .active ? deadline : resolvedAt
    }

    var informationText: String {
        [
            additionalInformation ?? "",
            description
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    var searchText: String {
        let primaryValues: [String] = [
            number,
            incomingNumber,
            registeredAt ?? "",
            waitingReason ?? "",
            state,
            stateRaw ?? "",
            shortDescription,
            assignmentGroup,
            initiator ?? "",
            priority ?? "",
            clientServiceParent ?? "",
            clientService ?? "",
            requestType,
            address,
            customer,
            deadline,
            resolvedAt,
            completedAt ?? "",
            closedAt ?? "",
            assignedUser,
            terminalModel,
            terminalID,
            contactPerson,
            contactPhone ?? ""
        ]
        let secondaryValues: [String] = [
            engineerComment,
            closureCode ?? "",
            resolution ?? "",
            additionalInformation ?? "",
            description,
            installedFiscalStorageSerialNumber ?? "",
            ofdTariffActivationCode ?? "",
            usedSIMCard ?? ""
        ]
        let tableValues = (tableFields ?? [])
            .flatMap { [$0.key, $0.value] }
        let values = primaryValues + secondaryValues + tableValues
        return values
            .joined(separator: "\n")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }
}

extension SimpleOneRequestRecord {
    var deadlineDate: Date? {
        Self.parseSimpleOneDate(deadline)
    }

    var registeredDate: Date? {
        Self.parseSimpleOneDate(registeredAt ?? "")
    }

    var isOverdue: Bool {
        guard source == .active, let deadlineDate else { return false }
        return deadlineDate < Date()
    }

    var slaStatusText: String? {
        guard let deadlineDate else { return nil }
        let interval = deadlineDate.timeIntervalSinceNow
        let prefix = interval < 0 ? "Просрочено на" : "Осталось"
        let absolute = abs(interval)
        let hours = Int(absolute) / 3_600
        let minutes = (Int(absolute) % 3_600) / 60

        if hours >= 24 {
            let days = hours / 24
            let remainingHours = hours % 24
            return "\(prefix) \(days) дн. \(remainingHours) ч."
        }
        if hours > 0 {
            return "\(prefix) \(hours) ч. \(minutes) мин."
        }
        return "\(prefix) \(max(minutes, 1)) мин."
    }

    private static func parseSimpleOneDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let date = simpleOneDateFormatters.lazy.compactMap({ $0.date(from: trimmed) }).first else {
            return nil
        }

        // SimpleOne uses the Unix epoch as an empty date in some request fields.
        guard Calendar(identifier: .gregorian).component(.year, from: date) > 1970 else {
            return nil
        }

        return date
    }

    private static let simpleOneDateFormatters: [DateFormatter] = [
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd HH:mm",
        "dd.MM.yyyy HH:mm:ss",
        "dd.MM.yyyy HH:mm",
        "MM.dd.yyyy HH:mm:ss",
        "MM.dd.yyyy HH:mm"
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }
}

nonisolated struct SimpleOneUser: Codable, Hashable, Sendable {
    var sysID: String
    var username: String
    var firstName: String
    var lastName: String

    var displayName: String {
        [firstName, lastName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

nonisolated struct SimpleOnePagedRequestRecords: Sendable {
    var records: [SimpleOneRequestRecord]
    var totalCount: Int?
    var hasMore: Bool
}

nonisolated struct SimpleOneArchiveSnapshot: Codable, Hashable, Sendable {
    var currentUser: SimpleOneUser?
    var activeRequests: [SimpleOneRequestRecord]
    var closedRequests: [SimpleOneRequestRecord]
    var updatedAt: Date?
}

nonisolated private struct SimpleOneActiveArchiveSnapshot: Codable, Hashable, Sendable {
    var currentUser: SimpleOneUser?
    var activeRequests: [SimpleOneRequestRecord]
    var updatedAt: Date?
}

nonisolated private struct SimpleOneDetailedRequestCacheEntry: Codable, Hashable, Sendable {
    var record: SimpleOneRequestRecord
    var cachedAt: Date
}

nonisolated private struct SimpleOneDetailedRequestCacheSnapshot: Codable, Hashable, Sendable {
    var entries: [String: SimpleOneDetailedRequestCacheEntry]
}

enum SimpleOneServiceError: LocalizedError {
    case missingCredentials
    case unauthorized
    case invalidResponse
    case server(String)
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "Войдите в SimpleOne, чтобы загрузить заявки."
        case .unauthorized:
            return "Сессия SimpleOne истекла. Войдите снова."
        case .invalidResponse:
            return "SimpleOne вернул неожиданный ответ."
        case .server(let message):
            return message
        case .invalidURL:
            return "Не удалось собрать URL запроса SimpleOne."
        }
    }
}
