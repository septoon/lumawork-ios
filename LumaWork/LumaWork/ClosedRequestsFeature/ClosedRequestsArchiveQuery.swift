import Foundation

nonisolated enum ClosedRequestsArchiveQuery {
    static let revision = 2

    static var fullCondition: String {
        guard let currentUserDynamicID = AppConfig.resolveFirst("SIMPLEONE_CURRENT_USER_DYNAMIC_ID"),
              let assignedUserDynamicID = AppConfig.resolveFirst("SIMPLEONE_ASSIGNED_USER_DYNAMIC_ID"),
              let resolvedDateOptionID = AppConfig.resolveFirst("SIMPLEONE_RESOLVED_DATE_OPTION_ID") else {
            return "sys_idISEMPTY^sys_idISNOTEMPTY"
        }
        return [
            "((multicard_engineerDYNAMIC\(currentUserDynamicID)",
            "^ORassigned_userDYNAMIC\(assignedUserDynamicID)",
            "^ORengineer_schedule.employeeDYNAMIC\(currentUserDynamicID))",
            "^resolved_atNOTONopt:\(resolvedDateOptionID)",
            "^stateNOT INon_hold@assigned@in_progress@escalated@returned_to_work@3@6@update_received)"
        ].joined()
    }

    static func requiresWideRestart(storedRevision: Int?) -> Bool {
        storedRevision != revision
    }
}
