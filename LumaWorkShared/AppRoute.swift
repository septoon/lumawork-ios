import Foundation

nonisolated enum AppRoute: Hashable, Sendable {
    case home
    case requests
    case request(id: String)
    case assistant
    case timeReport

    static let quickActionTypePrefix = "septon.LumaWork.quick-action."
    static let urlScheme = "lumawork"

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == Self.urlScheme,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil,
              let host = components.host?.lowercased() else {
            return nil
        }

        switch host {
        case "home":
            guard components.percentEncodedPath.isEmpty else { return nil }
            self = .home
        case "requests":
            let encodedPath = components.percentEncodedPath
            if encodedPath.isEmpty {
                self = .requests
                return
            }
            guard encodedPath.first == "/",
                  encodedPath.count > 1,
                  !encodedPath.dropFirst().contains("/"),
                  let requestID = String(encodedPath.dropFirst()).removingPercentEncoding,
                  !requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            self = .request(id: requestID)
        case "assistant":
            guard components.percentEncodedPath.isEmpty else { return nil }
            self = .assistant
        case "time-report":
            guard components.percentEncodedPath.isEmpty else { return nil }
            self = .timeReport
        default:
            return nil
        }
    }

    init?(quickActionType: String) {
        guard quickActionType.hasPrefix(Self.quickActionTypePrefix) else { return nil }
        switch String(quickActionType.dropFirst(Self.quickActionTypePrefix.count)) {
        case "home":
            self = .home
        case "requests":
            self = .requests
        case "assistant":
            self = .assistant
        case "time-report":
            self = .timeReport
        default:
            return nil
        }
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.urlScheme

        switch self {
        case .home:
            components.host = "home"
        case .requests:
            components.host = "requests"
        case .request(let id):
            components.host = "requests"
            var allowed = CharacterSet.urlPathAllowed
            allowed.remove(charactersIn: "/")
            let encodedID = id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
            components.percentEncodedPath = "/\(encodedID)"
        case .assistant:
            components.host = "assistant"
        case .timeReport:
            components.host = "time-report"
        }

        guard let url = components.url else {
            preconditionFailure("Unable to build LumaWork route URL")
        }
        return url
    }
}
