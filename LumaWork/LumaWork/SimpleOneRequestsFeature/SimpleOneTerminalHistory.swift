import Foundation

nonisolated enum SimpleOneTerminalHistory {
    static func normalizedTerminalID(_ raw: String) -> String {
        let value = raw.filter { !$0.isWhitespace }
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .uppercased()
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            return ""
        }
        return value
    }

    static func records(
        _ records: [SimpleOneRequestRecord],
        terminalID: String,
        excludingRequestID: String = "",
        showsReturnEquipment: Bool = true,
        showsExpertise: Bool = true
    ) -> [SimpleOneRequestRecord] {
        let target = normalizedTerminalID(terminalID)
        guard !target.isEmpty else { return [] }
        var seen = Set<String>()
        return records.filter { record in
            guard showsReturnEquipment || !isCoordinationReturnEquipmentRequestType(record.requestType),
                  showsExpertise || !isCoordinationExpertiseRequestType(record.requestType) else { return false }
            guard record.id != excludingRequestID, record.number != excludingRequestID,
                  seen.insert(record.id).inserted else { return false }
            let values = [record.terminalID] + (record.tableFields ?? []).filter {
                ["id терминал", "id терминала"].contains($0.key.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
            }.map(\.value)
            return values.contains { value in
                normalizedTerminalID(value) == target || value.components(separatedBy: CharacterSet(charactersIn: ",;|/\n\r\t "))
                    .contains { normalizedTerminalID($0) == target }
            }
        }.sorted { lhs, rhs in
            let lhsDate = date(for: lhs) ?? .distantPast
            let rhsDate = date(for: rhs) ?? .distantPast
            return lhsDate == rhsDate ? lhs.id > rhs.id : lhsDate > rhsDate
        }
    }

    static func date(for record: SimpleOneRequestRecord) -> Date? {
        [record.completedAt ?? "", record.resolvedAt, record.closedAt ?? ""]
            .lazy.compactMap(SimpleOneRequestRecord.parseSimpleOneDate).first
    }

    static func completionStatus(for record: SimpleOneRequestRecord) -> ClosedRequestCompletionStatus? {
        let code = (record.closureCode ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ru_RU"))
        // History describes the closure result, including work completed without a visit.
        // The personal archive's visit-counting rule has a different purpose.
        if code.hasPrefix("решено") { return .completed }
        if code.hasPrefix("отказ") { return .refusal }
        return nil
    }

    static func requestTypeTitle(for record: SimpleOneRequestRecord) -> String {
        let type = localizedSimpleOneRequestType(record.requestType)
        return type.isEmpty ? "Не указан" : type
    }
}

nonisolated extension SimpleOneRequestsService {
    func fetchTerminalHistory(terminalID: String, authKey: String) async throws -> [SimpleOneRequestRecord] {
        let terminalID = SimpleOneTerminalHistory.normalizedTerminalID(terminalID)
        guard !terminalID.isEmpty else { return [] }
        // The global keyword index omits service requests. Match the same column as the SO list.
        let condition = "(\(Self.groupClosedRequestsCriteria)^multicard_id_terminalLIKE\(terminalID))^ORDERBYDESCresolved_at^ORDERBYDESCsys_id"
        let columns = Self.terminalSearchColumns + ["new_closure_code", "closure_notes", "closed_at", "multicard_closing_date"]
        var records: [SimpleOneRequestRecord] = []
        var seen = Set<String>()
        var page = 1
        while true {
            try Task.checkCancellation()
            let result = try await fetchRequestsPage(
                condition: condition, source: .closed, authKey: authKey,
                page: page, perPage: 100, columns: columns, view: "Default"
            )
            let newRecords = result.records.filter { seen.insert($0.id).inserted }
            records += newRecords
            guard result.records.isEmpty || !newRecords.isEmpty else { throw SimpleOneServiceError.invalidResponse }
            if !result.hasMore {
                guard result.totalCount.map({ seen.count >= $0 }) ?? true else { throw SimpleOneServiceError.invalidResponse }
                break
            }
            // A repeated/empty page is an incomplete response, not a complete cached history.
            guard !newRecords.isEmpty else { throw SimpleOneServiceError.invalidResponse }
            page += 1
        }
        try Task.checkCancellation()
        return SimpleOneTerminalHistory.records(records, terminalID: terminalID)
    }
}
