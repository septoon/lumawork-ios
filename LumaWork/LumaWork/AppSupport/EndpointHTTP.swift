import Foundation
import OSLog
import UIKit

enum AppServiceError: LocalizedError {
    case message(String)
    case http(status: Int?, fallback: String)

    var errorDescription: String? {
        switch self {
        case .message(let message):
            return message
        case .http(let status, let fallback):
            if let status {
                return "\(fallback) (\(status))"
            }
            return fallback
        }
    }
}

struct HTTPResponse {
    let statusCode: Int
    let json: Any?
}

enum AppBuildIdentity {
    static let version: String = {
        let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? "0.0" : normalized
    }()
    static let build: String = {
        let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? "0" : normalized
    }()
    static var display: String { "\(version) (\(build))" }

    static func apply(to request: inout URLRequest) {
        request.setValue(version, forHTTPHeaderField: "X-LumaWork-Version")
        request.setValue(build, forHTTPHeaderField: "X-LumaWork-Build")
    }
}

enum AppDeviceIdentity {
    private static let deviceID: String = {
        if let vendorID = UIDevice.current.identifierForVendor {
            return vendorID.uuidString
        }
        let key = "lumawork.app-device-id"
        if let stored = UserDefaults.standard.string(forKey: key), UUID(uuidString: stored) != nil {
            return stored
        }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: key)
        return value
    }()

    private static let deviceInfo = FeedbackDeviceInfo.current

    static func apply(to request: inout URLRequest) {
        request.setValue(deviceID, forHTTPHeaderField: "X-LumaWork-Device-ID")
        request.setValue(
            ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? deviceInfo.deviceModel,
            forHTTPHeaderField: "X-LumaWork-Device-Model"
        )
        request.setValue(deviceInfo.osVersion, forHTTPHeaderField: "X-LumaWork-Device-OS")
        #if targetEnvironment(simulator)
        request.setValue("iOS Simulator", forHTTPHeaderField: "X-LumaWork-Device-Platform")
        #else
        request.setValue("iOS", forHTTPHeaderField: "X-LumaWork-Device-Platform")
        #endif
    }
}

nonisolated enum NetworkDiagnostics {
    enum Operation: String {
        case http, authentication, routes, offlineSnapshot, fuelMileage
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LumaWork", category: "network")

    // Allowlisted metadata only, in every build. Never inspect bodies, URLs or headers.
    static func logRequest(_ request: URLRequest, body _: Any?, operation: Operation = .http) {
        logger.info("HTTP request started: operation=\(operation.rawValue, privacy: .public) method=\(safeMethod(request.httpMethod), privacy: .public)")
    }

    static func logResponse(url _: URL, statusCode: Int, data: Data, method: String = "GET", operation: Operation = .http) {
        logger.info("HTTP response received: operation=\(operation.rawValue, privacy: .public) method=\(safeMethod(method), privacy: .public) status=\(statusCode) bytes=\(data.count)")
    }

    static func logError(url _: URL, method: String, error: Error, operation: Operation = .http) {
        logger.error("HTTP request failed: operation=\(operation.rawValue, privacy: .public) method=\(safeMethod(method), privacy: .public) category=\(errorCategory(error), privacy: .public)")
    }

    static func logInvalidResponse(method: String, operation: Operation = .http) {
        logger.error("HTTP response casting failed: operation=\(operation.rawValue, privacy: .public) method=\(safeMethod(method), privacy: .public) category=invalid-response")
    }

    static func logFailure(operation: Operation, error: Error) {
        logger.error("Operation failed: operation=\(operation.rawValue, privacy: .public) category=\(errorCategory(error), privacy: .public)")
    }

    static func errorCategory(_ error: Error) -> String {
        if error is CancellationError { return "cancellation" }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled: return "cancellation"
            case .timedOut: return "timeout"
            case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost,
                 .dnsLookupFailed, .networkConnectionLost: return "connection"
            case .secureConnectionFailed, .serverCertificateHasBadDate,
                 .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid, .clientCertificateRejected,
                 .clientCertificateRequired: return "tls"
            default: return "network"
            }
        }
        if error is DecodingError { return "decoding" }
        if error is EncodingError { return "encoding" }
        if error is CocoaError { return "storage" }
        // Descriptions, reflected types, domains and userInfo can contain server/user data.
        return "other"
    }

    private static func safeMethod(_ method: String?) -> String {
        let method = method ?? "GET"
        switch method {
        case "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "CONNECT", "TRACE": return method
        default: return "OTHER"
        }
    }
}

struct HTTPClient {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    func request(
        _ url: URL,
        method: String = "GET",
        body: Any? = nil,
        authToken: String? = nil,
        allowEmpty: Bool = true,
        timeoutInterval: TimeInterval = 20
    ) async throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.timeoutInterval = timeoutInterval
        AppBuildIdentity.apply(to: &request)
        if authToken != nil { AppDeviceIdentity.apply(to: &request) }

        if let authToken, !authToken.isEmpty {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        NetworkDiagnostics.logRequest(request, body: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            NetworkDiagnostics.logError(url: url, method: method, error: error)
            throw error
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            NetworkDiagnostics.logInvalidResponse(method: method)
            throw AppServiceError.message("Сервер вернул неизвестный ответ.")
        }

        NetworkDiagnostics.logResponse(url: url, statusCode: httpResponse.statusCode, data: data, method: method)

        if method != "GET" {
            URLCache.shared.removeCachedResponse(for: request)
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) || httpResponse.statusCode == 204 else {
            throw AppServiceError.http(status: httpResponse.statusCode, fallback: "Ошибка сервера")
        }

        if data.isEmpty {
            return HTTPResponse(statusCode: httpResponse.statusCode, json: nil)
        }

        let json = try JSONSerialization.jsonObject(with: data)
        return HTTPResponse(statusCode: httpResponse.statusCode, json: json)
    }
}
