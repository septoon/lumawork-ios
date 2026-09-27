import Foundation

nonisolated extension SimpleOneRequestsService {
    func fetchCoordinationRequests(
        region: CoordinationRegion,
        authKey: String
    ) async throws -> [SimpleOneRequestRecord] {
        let records = try await fetchAllRequests(
            condition: coordinationCondition(region: region),
            source: .active,
            authKey: authKey,
            columns: Self.terminalSearchColumns
        )
        return mergedRequests(records)
    }

    func fetchReturnEquipmentRequests(
        userID: String,
        authKey: String
    ) async throws -> [SimpleOneRequestRecord] {
        let records = try await fetchAllRequests(
            condition: returnEquipmentCondition(userID: userID),
            source: .active,
            authKey: authKey,
            columns: Self.terminalSearchColumns
        )
        let returnRequests = mergedRequests(records).filter { record in
            isCoordinationReturnEquipmentRequestType(record.requestType)
        }
        return returnRequests
    }

    func coordinationCondition(region: CoordinationRegion) -> String {
        guard let primaryGroupID = AppConfig.resolveFirst("SIMPLEONE_PRIMARY_ASSIGNMENT_GROUP_ID"),
              !region.assignmentGroupID.isEmpty,
              !region.companyLocationID.isEmpty else {
            return "sys_idISEMPTY^sys_idISNOTEMPTY"
        }
        return [
            "((assignment_group=\(primaryGroupID)^ORassignment_group=\(region.assignmentGroupID))",
            "^related_inquiry.company_location=\(region.companyLocationID)",
            "^client_service_idLIKEСервисные заявки БЧ",
            "^client_service_idNOTLIKEЭкспертиза. Сервисные заявки БЧ",
            "^stateNOT INcancelled@closed@escalated@completed)"
        ].joined()
    }

    func returnEquipmentCondition(userID: String) -> String {
        [
            "(assigned_user=\(userID)",
            "^multicard_request_type=returnEquip",
            "^stateNOT INcancelled@closed_by_user@closed@escalated@completed)"
        ].joined()
    }
}
