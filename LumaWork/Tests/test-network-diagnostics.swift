import Foundation

// Capture the emitted messages, leaving all production formatting/classification intact.
struct CapturedLogMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    enum Privacy { case `public` }
    var text: String
    init(stringLiteral value: String) { text = value }
    init(stringInterpolation: StringInterpolation) { text = stringInterpolation.text }
    struct StringInterpolation: StringInterpolationProtocol {
        var text = ""
        init(literalCapacity: Int, interpolationCount: Int) {}
        mutating func appendLiteral(_ value: String) { text += value }
        mutating func appendInterpolation<T>(_ value: T) { text += String(describing: value) }
        mutating func appendInterpolation<T>(_ value: T, privacy: Privacy) { text += String(describing: value) }
    }
}

struct Logger {
    nonisolated(unsafe) static var messages: [String] = []
    init(subsystem: String, category: String) {}
    func info(_ message: CapturedLogMessage) { Self.messages.append(message.text) }
    func debug(_ message: CapturedLogMessage) { Self.messages.append(message.text) }
    func error(_ message: CapturedLogMessage) { Self.messages.append(message.text) }
}

struct UnrenderableDiagnosticValue: CustomStringConvertible, LocalizedError {
    var description: String { fatalError("Diagnostics inspected a body value") }
    var errorDescription: String? { fatalError("Diagnostics inspected an error description") }
}

@main
struct NetworkDiagnosticsTests {
    static func main() {
        // All values are synthetic, including credentials and personal data.
        let privateValues = [
            "synthetic-token", "synthetic-password", "synthetic-cookie", "123987",
            "Synthetic Employee", "employee@example.test", "+70000000000",
            "Synthetic Street 10", "REQ-SYNTHETIC-42", "synthetic work comment"
        ]
        let url = URL(string: "https://synthetic-user:synthetic-password@example.test/users/REQ-SYNTHETIC-42?token=synthetic-token#synthetic-cookie")!
        let payload: [String: Any] = [
            "email": privateValues[5], "name": privateValues[4], "phone": privateValues[6],
            "address": privateValues[7], "request": privateValues[8], "comment": privateValues[9],
            "nested": [["Authorization": privateValues[0], "Cookie": privateValues[2]]],
            "code": privateValues[3], "password": privateValues[1]
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer synthetic-token", forHTTPHeaderField: "Authorization")
        request.setValue("synthetic-cookie", forHTTPHeaderField: "Cookie")
        request.httpBody = try! JSONSerialization.data(withJSONObject: payload)
        let original = request
        Logger.messages = []
        NetworkDiagnostics.logRequest(request, body: payload)
        NetworkDiagnostics.logResponse(url: url, statusCode: 403, data: request.httpBody!)
        let error = NSError(domain: "synthetic-token", code: 42, userInfo: [
            NSLocalizedDescriptionKey: privateValues.joined(separator: " "),
            NSURLErrorFailingURLErrorKey: url, "response": payload
        ])
        NetworkDiagnostics.logError(url: url, method: "POST", error: error)
        let emitted = Logger.messages.joined(separator: "\n")
        for value in privateValues + ["synthetic-user", "example.test", "Authorization", "Cookie"] {
            check(!emitted.contains(value), "Sensitive data reached diagnostics")
        }
        check(Logger.messages.count == 3, "Payload must not create an additional log entry")
        check(emitted.contains("POST") && emitted.contains("403"), "HTTP metadata was lost")
        check(request == original, "Diagnostics mutated the outgoing request")

        Logger.messages = []
        request.httpMethod = "synthetic-token"
        NetworkDiagnostics.logRequest(request, body: nil)
        NetworkDiagnostics.logError(url: url, method: "synthetic-token", error: error)
        check(!Logger.messages.joined().contains("synthetic-token"), "Unknown method reached diagnostics")

        Logger.messages = []
        let timeout = URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: privateValues[5]])
        NetworkDiagnostics.logError(url: url, method: "GET", error: timeout)
        check(Logger.messages.joined().contains("timeout"), "Timeout category was lost")
        check(!Logger.messages.joined().contains(privateValues[5]), "Network error description reached diagnostics")

        Logger.messages = []
        request.url = nil
        request.httpMethod = nil
        NetworkDiagnostics.logRequest(request, body: UnrenderableDiagnosticValue(), operation: .authentication)
        NetworkDiagnostics.logInvalidResponse(method: "PATCH", operation: .routes)
        NetworkDiagnostics.logFailure(operation: .offlineSnapshot, error: UnrenderableDiagnosticValue())
        check(Logger.messages.count == 3, "Safe events were dropped")
        check(Logger.messages[0].contains("authentication") && Logger.messages[0].contains("GET"), "Default method/operation lost")
        check(Logger.messages[1].contains("routes") && Logger.messages[1].contains("invalid-response"), "Invalid response metadata lost")
        check(Logger.messages[2].contains("offlineSnapshot") && Logger.messages[2].contains("other"), "Local error category lost")

        let context = DecodingError.Context(codingPath: [], debugDescription: privateValues.joined())
        let categories: [(Error, String)] = [
            (CancellationError(), "cancellation"), (URLError(.cancelled), "cancellation"),
            (URLError(.notConnectedToInternet), "connection"),
            (URLError(.secureConnectionFailed), "tls"),
            (URLError(.badServerResponse), "network"),
            (NSError(domain: NSURLErrorDomain, code: URLError.timedOut.rawValue,
                     userInfo: [NSLocalizedDescriptionKey: privateValues[5], NSURLErrorFailingURLErrorKey: url]), "timeout"),
            (DecodingError.dataCorrupted(context), "decoding"),
            (EncodingError.invalidValue(payload, .init(codingPath: [], debugDescription: privateValues.joined())), "encoding"),
            (CocoaError(.fileWriteNoPermission), "storage"),
            (NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteNoPermission.rawValue,
                     userInfo: [NSLocalizedDescriptionKey: privateValues[7], NSFilePathErrorKey: privateValues[8]]), "storage"),
            (error, "other")
        ]
        for (input, expected) in categories {
            Logger.messages = []
            NetworkDiagnostics.logError(url: url, method: "GET", error: input)
            check(Logger.messages.count == 1 && Logger.messages[0].contains("category=\(expected)"), "Incorrect technical error category")
            for value in privateValues { check(!Logger.messages[0].contains(value), "Error data reached diagnostics") }
        }

        for method in ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "CONNECT", "TRACE"] {
            Logger.messages = []
            request.httpMethod = method
            NetworkDiagnostics.logRequest(request, body: nil)
            check(Logger.messages.count == 1 && Logger.messages[0].contains("method=\(method)"), "Standard method metadata lost")
        }
        print("Network diagnostics regressions passed")
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
