import Foundation
import OSLog

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

enum NetworkDiagnostics {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LumaWork", category: "network")

    static func logRequest(_ request: URLRequest, body: Any?) {
        let method = request.httpMethod ?? "GET"
        let url = request.url?.absoluteString ?? "<nil>"
        logger.info("HTTP request started: \(method, privacy: .public) \(url, privacy: .public)")

        if let body {
            let preview = String(describing: sanitizedForLogging(body)).prefix(400)
            logger.debug("HTTP request body: \(String(preview), privacy: .public)")
        }
    }

    private static func sanitizedForLogging(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues { keyValue in
                sanitizedForLogging(keyValue)
            }.reduce(into: [String: Any]()) { result, pair in
                let normalizedKey = pair.key.lowercased()
                if normalizedKey.contains("base64")
                    || normalizedKey.contains("password")
                    || normalizedKey.contains("token")
                    || normalizedKey == "code" {
                    result[pair.key] = "<redacted>"
                } else {
                    result[pair.key] = pair.value
                }
            }
        }
        if let values = value as? [Any] {
            return values.map(sanitizedForLogging)
        }
        return value
    }

    static func logResponse(url: URL, statusCode: Int, data: Data) {
        logger.info(
            "HTTP response received: \(url.absoluteString, privacy: .public) status=\(statusCode) bytes=\(data.count)"
        )
    }

    static func logError(url: URL, method: String, error: Error) {
        if let urlError = error as? URLError {
            logger.error(
                """
                HTTP request failed: \(method, privacy: .public) \(url.absoluteString, privacy: .public) \
                code=\(urlError.code.rawValue) \
                reason=\(urlError.localizedDescription, privacy: .public)
                """
            )
            return
        }

        logger.error(
            "HTTP request failed: \(method, privacy: .public) \(url.absoluteString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
        )
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
        allowEmpty: Bool = true
    ) async throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.timeoutInterval = 20
        AppBuildIdentity.apply(to: &request)

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
            NetworkDiagnostics.logger.error(
                "HTTP response casting failed: \(url.absoluteString, privacy: .public)"
            )
            throw AppServiceError.message("Сервер вернул неизвестный ответ.")
        }

        NetworkDiagnostics.logResponse(url: url, statusCode: httpResponse.statusCode, data: data)

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
