import Foundation

nonisolated struct WorkScheduleWidgetLoadRequest {
    let url: URL
    let method: String
    let body: [String: Any]
}

nonisolated enum WorkScheduleEndpointError: Error {
    case invalidURL
}

nonisolated enum SimpleOneWorkScheduleEndpoint {
    private static var baseURL: URL {
        AppConfig.configuredURL(AppConfig().simpleOneAPIOrigin)
    }

    static func journals(page: Int, perPage: Int) throws -> URL {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("list/itsm_tchnsrv_accounting_journal"),
            resolvingAgainstBaseURL: false
        ) else {
            throw WorkScheduleEndpointError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: String(perPage))
        ]
        guard let url = components.url else {
            throw WorkScheduleEndpointError.invalidURL
        }
        return url
    }

    static func record(sysID: String) -> URL {
        baseURL
            .appendingPathComponent("record")
            .appendingPathComponent("itsm_tchnsrv_accounting_journal")
            .appendingPathComponent(sysID)
    }

    static func widgetLoad(
        widgetInstanceID: String,
        recordID: String
    ) throws -> WorkScheduleWidgetLoadRequest {
        guard !widgetInstanceID.isEmpty, !recordID.isEmpty else {
            throw WorkScheduleEndpointError.invalidURL
        }
        return WorkScheduleWidgetLoadRequest(
            url: baseURL
                .appendingPathComponent("widget/run-server-script")
                .appendingPathComponent(widgetInstanceID),
            method: "POST",
            body: [
                "recordID": recordID,
                "action": "load"
            ]
        )
    }
}
