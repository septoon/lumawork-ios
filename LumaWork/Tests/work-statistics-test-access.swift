import Foundation

struct TestSession { struct User { var id: String }; var user: User; var token: String }
@MainActor enum LumaWorkSessionKeychain {
    static var session: TestSession? = TestSession(user: .init(id: "fixture-owner"), token: "fixture-bearer")
    static func readSession() -> TestSession? { session }
}
@MainActor enum SimpleOneSessionKeychain {
    static var generation = UUID()
    static var auth: String? = "fixture-so-auth"
    static func readAuthKey() -> String? { auth }
    static func deleteAuthKey() { auth = nil; generation = UUID() }
}

final class StatisticsURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data, Double))?
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data, delay) = try Self.handler!(request)
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
                guard !lock.withLock({ stopped }) else { return }
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { lock.withLock { stopped = true } }
}
final class StatisticsRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [URLRequest] = []
    func append(_ request: URLRequest) { lock.withLock { records.append(request) } }
    var all: [URLRequest] { lock.withLock { records } }
}

func statisticsRequestBody(_ request: URLRequest) -> Data {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open(); defer { stream.close() }
    var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let length = stream.read(&buffer, maxLength: buffer.count)
        if length <= 0 { break }; result.append(buffer, count: length)
    }
    return result
}
final class StatisticsPayloadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var payloads: [WorkStatisticsUpload] = []
    func append(_ value: WorkStatisticsUpload) { lock.withLock { payloads.append(value) } }
    var all: [WorkStatisticsUpload] { lock.withLock { payloads } }
}
