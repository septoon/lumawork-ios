import Foundation

nonisolated extension SimpleOneRequestsService {
    func detailedRecords(
        _ records: [SimpleOneRequestRecord],
        authKey: String,
        maximumConcurrentRequests: Int = 4,
        allowsPartialResults: Bool = true
    ) async throws -> [SimpleOneRequestRecord] {
        @Sendable func fetchDetailedRecord(
            index: Int,
            record: SimpleOneRequestRecord
        ) async throws -> (Int, SimpleOneRequestRecord) {
            try Task.checkCancellation()
            guard !record.sysID.isEmpty else {
                return (index, record)
            }

            do {
                let detailedRecord = try await fetchRequest(
                    sysID: record.sysID,
                    fallback: record,
                    authKey: authKey
                )
                return (index, detailedRecord)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                guard allowsPartialResults else { throw error }
                return (index, record)
            }
        }

        return try await withThrowingTaskGroup(of: (Int, SimpleOneRequestRecord).self) { group in
            var iterator = records.enumerated().makeIterator()
            let concurrencyLimit = max(1, min(maximumConcurrentRequests, records.count))

            for _ in 0..<concurrencyLimit {
                guard let (index, record) = iterator.next() else { break }
                group.addTask {
                    try await fetchDetailedRecord(index: index, record: record)
                }
            }

            var indexedRecords: [(Int, SimpleOneRequestRecord)] = []
            indexedRecords.reserveCapacity(records.count)
            while let item = try await group.next() {
                indexedRecords.append(item)
                if let (index, record) = iterator.next() {
                    group.addTask {
                        try await fetchDetailedRecord(index: index, record: record)
                    }
                }
            }
            return indexedRecords
                .sorted { $0.0 < $1.0 }
                .map(\.1)
        }
    }

    func fetchRequest(
        sysID: String,
        fallback: SimpleOneRequestRecord,
        authKey: String
    ) async throws -> SimpleOneRequestRecord {
        let response = try await request(path: "/record/itsm_request/\(sysID)", authKey: authKey)
        guard let item = recordItem(from: response) else {
            throw SimpleOneServiceError.invalidResponse
        }
        let detailItem = flattenedRecordItem(from: item)
        let detailAssignedUserName = fieldDisplayString(
            detailItem,
            "assigned_user.c_full_name",
            "assigned_user",
            "Исполнитель",
            "Исполнитель.Имя Фамилия"
        )
        let detailAssignedUserID = fieldString(
            detailItem,
            "assigned_user.value",
            "assigned_user.database_value",
            "assigned_user.sys_id",
            "assigned_user"
        )
        var record = makeRequestRecord(
            from: mergedRecordItem(listItem: fallback, detailItem: detailItem),
            source: fallback.source
        )

        let resolvedDetailName = detailAssignedUserName.isEmpty ? record.assignedUser : detailAssignedUserName
        let normalizedDetailName = normalizedAssignedUser(resolvedDetailName)
        let normalizedDetailID = normalizedAssignedUser(detailAssignedUserID)
        let trimmedDetailID = detailAssignedUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        let detailHasDistinctID = !normalizedDetailID.isEmpty
            && (normalizedDetailID != normalizedDetailName
                || (trimmedDetailID.count == 18 && trimmedDetailID.allSatisfy(\.isNumber)))
        if detailHasDistinctID {
            record.assignedUserID = detailAssignedUserID
        } else if normalizedDetailName.isEmpty || normalizedDetailName == normalizedAssignedUser(fallback.assignedUser) {
            record.assignedUserID = fallback.assignedUserID
        } else {
            record.assignedUserID = nil
        }
        return record
    }

    func flattenedRecordItem(from item: [String: Any]) -> [String: Any] {
        guard let sections = item["sections"] as? [[String: Any]] else {
            return item
        }

        var flattened = item
        for section in sections {
            guard let elements = section["elements"] as? [[String: Any]] else { continue }
            for element in elements {
                guard let value = element["value"] else { continue }

                for keyName in ["sys_column_name", "system_name", "name"] {
                    guard let key = element[keyName] as? String, !key.isEmpty else { continue }
                    if fieldString(flattened, key).isEmpty {
                        setFieldValue(value, for: key, in: &flattened)
                    }
                }
            }
        }
        return flattened
    }

    func recordItem(from response: [String: Any]) -> [String: Any]? {
        if let data = response["data"] as? [String: Any] {
            if let item = data["item"] as? [String: Any] {
                return item
            }
            if let record = data["record"] as? [String: Any] {
                return record
            }
            if let fields = data["fields"] as? [String: Any] {
                return fields
            }
            return data
        }
        if let item = response["item"] as? [String: Any] {
            return item
        }
        if let record = response["record"] as? [String: Any] {
            return record
        }
        return nil
    }

    func mergedRecordItem(
        listItem fallback: SimpleOneRequestRecord,
        detailItem: [String: Any]
    ) -> [String: Any] {
        var item = detailItem
        let fallbackMulticardStatus = fallback.tableFields?
            .first { $0.key.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == "мк статус" }?
            .value ?? ""
        let fallbackDismantledPOSSerialNumber = fallback.tableFields?
            .first { normalizedInfoKey($0.key) == normalizedInfoKey("Серийный номер демонтируемого ТО") }?
            .value ?? ""
        let fallbackPOSSerialNumber = fallback.tableFields?
            .first { normalizedInfoKey($0.key) == normalizedInfoKey("Оборудование POS") }?
            .value ?? ""
        let fallbacks: [(String, String)] = [
            ("sys_id", fallback.sysID),
            ("number", fallback.number),
            ("incoming_number", fallback.incomingNumber),
            ("registered_at", fallback.registeredAt ?? ""),
            ("state", fallback.state),
            ("multicard_state", fallbackMulticardStatus),
            ("short_description", fallback.shortDescription),
            ("assignment_group", fallback.assignmentGroup),
            ("client_service_id.parent", fallback.clientServiceParent ?? ""),
            ("client_service_id", fallback.clientService ?? ""),
            ("multicard_request_type", fallback.requestType),
            ("multicard_terminal_address", fallback.address),
            ("multicard_name_client", fallback.customer),
            ("multicard_deadline", fallback.deadline),
            ("resolved_at", fallback.resolvedAt),
            ("completed_at", fallback.completedAt ?? ""),
            ("closed_at", fallback.closedAt ?? ""),
            ("assigned_user", fallback.assignedUser),
            ("assigned_user.c_full_name", fallback.assignedUser),
            ("sys_updated_at", fallback.sysUpdatedAt ?? ""),
            ("multicard_terminal_model", fallback.terminalModel),
            ("multicard_id_terminal", fallback.terminalID),
            ("multicard_pos", fallbackPOSSerialNumber),
            ("pb_sn_pos_uninstall", fallbackDismantledPOSSerialNumber),
            ("multicard_contact_person", fallback.contactPerson),
            ("multicard_contact_phone", fallback.contactPhone ?? ""),
            ("multicard_comment_ing", fallback.engineerComment),
            ("multicard_information", fallback.additionalInformation ?? ""),
            ("description", fallback.description)
        ]

        for (key, value) in fallbacks where fieldString(item, key).isEmpty && !value.isEmpty {
            setFieldValue(value, for: key, in: &item)
        }
        return item
    }

    func activeCondition(userID: String) -> String {
        guard let assignmentGroupID = AppConfig.resolveFirst("SIMPLEONE_PRIMARY_ASSIGNMENT_GROUP_ID"),
              let currentRegionGroupID = AppConfig.resolveFirst("SIMPLEONE_CURRENT_REGION_ASSIGNMENT_GROUP_ID"),
              let companyLocationID = AppConfig.resolveFirst("SIMPLEONE_CURRENT_COMPANY_LOCATION_ID") else {
            return "sys_idISEMPTY^sys_idISNOTEMPTY"
        }
        return [
            "((assignment_group=\(assignmentGroupID)^ORassignment_group=\(currentRegionGroupID))",
            "^related_inquiry.company_location=\(companyLocationID)",
            "^client_service_idLIKEСервисные заявки БЧ",
            "^client_service_idNOTLIKEЭкспертиза. Сервисные заявки БЧ",
            "^stateNOT INcancelled@closed@escalated@completed",
            "^assigned_user=\(userID))"
        ].joined()
    }

    func closedSimpleOneCondition(userID: String) -> String {
        _ = userID
        return ClosedRequestsArchiveQuery.fullCondition
    }

    func timeReportCondition() -> String {
        guard let currentUserDynamicID = AppConfig.resolveFirst("SIMPLEONE_CURRENT_USER_DYNAMIC_ID") else {
            return "sys_idISEMPTY^sys_idISNOTEMPTY"
        }
        return "(personDYNAMIC\(currentUserDynamicID))^ORDERBYDESCdate_of_work"
    }

    func mergedRequests(_ records: [SimpleOneRequestRecord]) -> [SimpleOneRequestRecord] {
        var seenIDs = Set<String>()
        return records
            .filter { record in
                let id = record.id.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty else { return true }
                return seenIDs.insert(id).inserted
            }
            .sorted { lhs, rhs in
                lhs.primaryDate.localizedStandardCompare(rhs.primaryDate) == .orderedDescending
            }
    }

    private func normalizedAssignedUser(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
