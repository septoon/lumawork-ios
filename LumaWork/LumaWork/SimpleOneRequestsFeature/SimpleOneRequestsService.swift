import Foundation

nonisolated struct SimpleOneRequestsService: Sendable {
    let baseURL: URL
    let session: URLSession
    static let multicardStatusColumns = [
        "multicard_state",
        "multicard_status",
        "multicard_mk_status",
        "u_multicard_state",
        "u_multicard_status",
        "u_mk_status",
        "mk_status",
        "multicard_request_state"
    ]
    static let terminalSearchColumns = [
        "sys_id",
        "number",
        "incoming_number",
        "registered_at",
        "opened_at",
        "sys_created_at",
        "sys_updated_at",
        "state",
    ] + Self.multicardStatusColumns + [
        "short_description",
        "assignment_group",
        "client_service_id.parent",
        "client_service_id",
        "multicard_request_type",
        "itsm_request_type",
        "multicard_terminal_address",
        "multicard_name_client",
        "multicard_merchant_tin",
        "multicard_tsp_inn",
        "merchant_tin",
        "inn_tsp",
        "multicard_phone_tsp",
        "multicard_tsp_phone",
        "multicard_terminal_phone",
        "multicard_contact_phone",
        "multicard_phone_client",
        "multicard_merchant_phone",
        "multicard_deadline",
        "resolved_at",
        "completed_at",
        "assigned_user",
        "assigned_user.c_full_name",
        "multicard_terminal_model",
        "multicard_id_terminal",
        "multicard_pos",
        "pb_sn_pos_uninstall",
        "multicard_contact_person",
        "multicard_comment_ing",
        "multicard_information",
        "multicard_additional_information",
        "additional_information",
        "description"
    ]
    init(config: AppConfig = AppConfig()) {
        self.baseURL = AppConfig.configuredURL(config.simpleOneAPIOrigin)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration)
    }

    func login(username: String, password: String) async throws -> String {
        let payload: [String: Any] = [
            "username": username,
            "password": password,
            "language": "ru"
        ]
        let response = try await request(
            path: "/auth/login",
            method: "POST",
            body: payload,
            authKey: nil
        )

        guard let data = response["data"] as? [String: Any],
              let authKey = data["auth_key"] as? String,
              !authKey.isEmpty else {
            throw serverError(from: response) ?? SimpleOneServiceError.invalidResponse
        }

        return authKey
    }

    func fetchCurrentUser(authKey: String) async throws -> SimpleOneUser {
        let response = try await request(path: "/user/me", authKey: authKey)
        guard let data = response["data"] as? [String: Any] else {
            throw serverError(from: response) ?? SimpleOneServiceError.invalidResponse
        }

        let user = SimpleOneUser(
            sysID: stringValue(data["sys_id"]),
            username: stringValue(data["username"]),
            firstName: stringValue(data["first_name"]),
            lastName: stringValue(data["last_name"])
        )
        guard !user.sysID.isEmpty else {
            throw SimpleOneServiceError.invalidResponse
        }
        return user
    }

    func fetchActiveRequests(userID: String, authKey: String) async throws -> [SimpleOneRequestRecord] {
        try await fetchAllRequests(
            condition: activeCondition(userID: userID),
            source: .active,
            authKey: authKey,
            perPage: 100,
            columns: Self.terminalSearchColumns
        )
    }

    func fetchRequestDetails(
        record: SimpleOneRequestRecord,
        authKey: String
    ) async throws -> SimpleOneRequestRecord {
        guard !record.sysID.isEmpty else {
            return record
        }
        return try await fetchRequest(sysID: record.sysID, fallback: record, authKey: authKey)
    }

    func issueEquipment(
        record: SimpleOneRequestRecord,
        authKey: String
    ) async throws -> SimpleOneRequestRecord {
        guard !record.sysID.isEmpty else {
            throw SimpleOneServiceError.invalidResponse
        }

        try await updateRequest(
            sysID: record.sysID,
            authKey: authKey,
            fields: ["multicard_state": "storeEquipIssued"]
        )
        return try await fetchRequest(sysID: record.sysID, fallback: record, authKey: authKey)
    }

    func fetchClosedRequests(
        userID: String,
        authKey: String,
        onProgress: @escaping @Sendable (Int) -> Void = { _ in }
    ) async throws -> [SimpleOneRequestRecord] {
        let closedRequests = try await fetchAllRequests(
            condition: closedSimpleOneCondition(userID: userID),
            source: .closed,
            authKey: authKey,
            columns: Self.terminalSearchColumns,
            onProgress: onProgress
        )

        return mergedRequests(closedRequests)
    }

    func fetchClosedRequestsPage(
        userID: String,
        authKey: String,
        page: Int,
        perPage: Int
    ) async throws -> SimpleOnePagedRequestRecords {
        try await fetchRequestsPage(
            condition: closedSimpleOneCondition(userID: userID),
            source: .closed,
            authKey: authKey,
            page: page,
            perPage: perPage,
            columns: Self.terminalSearchColumns
        )
    }

    func fetchTimeReportEntries(
        authKey: String,
        onProgress: @escaping @Sendable (Int) -> Void = { _ in }
    ) async throws -> [TimeReportEntry] {
        let items = try await fetchAllTimeReportItems(
            condition: timeReportCondition(),
            authKey: authKey,
            onProgress: onProgress
        )

        var seenIDs = Set<String>()
        return items
            .compactMap(makeTimeReportEntry(from:))
            .filter { entry in
                seenIDs.insert(entry.stableID).inserted
            }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt > rhs.createdAt
                }
                return lhs.activity.localizedStandardCompare(rhs.activity) == .orderedAscending
            }
    }

    func fetchRequests(
        terminalID: String,
        authKey: String,
        includeDetails: Bool = false
    ) async throws -> [SimpleOneRequestRecord] {
        let trimmedTerminalID = terminalID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTerminalID.isEmpty else {
            return []
        }

        // This is the indexed condition used by the SimpleOne list itself.
        // OR-ing several large text fields with LIKE makes the request time out.
        let terminalCondition = "keywordsARE\(trimmedTerminalID)"

        let records = try await fetchRequests(
            condition: "(\(terminalCondition))",
            source: .active,
            authKey: authKey,
            page: 1,
            perPage: 10,
            columns: Self.terminalSearchColumns
        )
        guard includeDetails else {
            return records
        }

        return try await detailedRecords(records, authKey: authKey)
    }
}
