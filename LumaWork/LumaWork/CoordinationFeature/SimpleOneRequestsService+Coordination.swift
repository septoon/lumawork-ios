import Foundation

nonisolated extension SimpleOneRequestsService {
    func fetchGroupClosedRequestsPage(
        region: CoordinationRegion,
        authKey: String,
        page: Int,
        perPage: Int,
        newestFirst: Bool = false
    ) async throws -> SimpleOnePagedRequestRecords {
        return try await fetchRequestsPage(
            condition: groupClosedRequestsCondition(region: region, newestFirst: newestFirst),
            source: .closed,
            authKey: authKey,
            page: page,
            perPage: perPage,
            columns: Self.terminalSearchColumns
        )
    }

    func groupClosedRequestsCondition(region: CoordinationRegion, newestFirst: Bool = false) -> String {
        let locationID = region.companyLocationID
        guard !locationID.isEmpty, locationID.allSatisfy(\.isNumber) else {
            return "sys_idISEMPTY^sys_idISNOTEMPTY"
        }
        let order = newestFirst ? "^ORDERBYDESCsys_updated_at^ORDERBYDESCsys_id" : ""
        return "(company_location=\(locationID)^\(Self.groupClosedRequestsCriteria))\(order)"
    }

    static var groupClosedRequestsCriteria: String {
        let optionID = AppConfig.resolveFirst("SIMPLEONE_RESOLVED_DATE_OPTION_ID") ?? "167653141215593053"
        return "resolved_atNOTONopt:\(optionID)^stateNOT INon_hold@assigned@in_progress@escalated@returned_to_work@3@6@update_received"
    }

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
