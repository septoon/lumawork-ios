import Foundation

struct AppUser { let id: String }
struct AppSession: Equatable {
    let token: String
    let user: AppUser
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.token == rhs.token && lhs.user.id == rhs.user.id }
}
@MainActor enum LumaWorkSessionKeychain { static var session: AppSession?; static func readSession() -> AppSession? { session } }
@MainActor enum SimpleOneSessionKeychain {
    static var generation = UUID()
    static var key: String?
    static func readAuthKey() -> String? { key }
    static func deleteAuthKey() { key = nil; generation = UUID() }
}

final class ProtectedAccessURLProtocol: URLProtocol, @unchecked Sendable {
    @MainActor static var calls = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Task { @MainActor in
            Self.calls += 1
            precondition(request.value(forHTTPHeaderField: "X-SimpleOne-Auth") == "so")
            SimpleOneSessionKeychain.key = nil
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("secret".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { }
}

@main struct ProtectedAccessTests {
    @MainActor static func main() async throws {
        LumaWorkSessionKeychain.session = AppSession(token: "app", user: AppUser(id: "owner"))
        func denied(_ action: () throws -> Void) {
            do { try action(); preconditionFailure("Protected access was allowed") }
            catch { precondition(error.localizedDescription == "Доступ запрещен") }
        }
        denied { _ = try SimpleOneProtectedAccess.capture() }
        SimpleOneSessionKeychain.key = "so"
        let login = try SimpleOneProtectedAccess.loginAttempt()
        try SimpleOneProtectedAccess.validateLoginAttempt(login)
        LumaWorkSessionKeychain.session = AppSession(token: "other", user: AppUser(id: "other"))
        denied { try SimpleOneProtectedAccess.validateLoginAttempt(login) }
        LumaWorkSessionKeychain.session = AppSession(token: "app", user: AppUser(id: "owner"))
        SimpleOneSessionKeychain.generation = UUID()
        denied { try SimpleOneProtectedAccess.validateLoginAttempt(login) }
        let snapshot = try SimpleOneProtectedAccess.capture(ownerID: "owner", authToken: "app")
        var request = URLRequest(url: URL(string: "https://example.test")!)
        try SimpleOneProtectedAccess.authorize(&request, authToken: "app")
        precondition(request.value(forHTTPHeaderField: "X-SimpleOne-Auth") == "so")
        denied { _ = try SimpleOneProtectedAccess.capture(ownerID: "other") }
        denied { _ = try SimpleOneProtectedAccess.capture(authToken: "old-app") }
        let ordinary403 = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: [:])!
        try SimpleOneProtectedAccess.validate(snapshot, response: ordinary403)
        precondition(SimpleOneSessionKeychain.key == "so")
        SimpleOneSessionKeychain.key = "new-so"
        denied { try SimpleOneProtectedAccess.validate(snapshot) }
        let lease = SimpleOneAccessLease()
        try lease.check()
        lease.revoke()
        denied { try lease.check() }
        let current = try SimpleOneProtectedAccess.capture()
        let so403 = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: ["X-SimpleOne-Access": "denied"])!
        denied { try SimpleOneProtectedAccess.validate(current, response: so403) }
        precondition(SimpleOneSessionKeychain.key == nil)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProtectedAccessURLProtocol.self]
        let session = URLSession(configuration: config)
        do {
            _ = try await SimpleOneProtectedAccess.data(for: request, session: session)
            preconditionFailure("Network allowed without SO")
        } catch { precondition(error is SimpleOneAccessDenied) }
        precondition(ProtectedAccessURLProtocol.calls == 0)
        SimpleOneSessionKeychain.key = "so"
        do {
            _ = try await SimpleOneProtectedAccess.data(for: request, session: session)
            preconditionFailure("Late response returned after SO logout")
        } catch { precondition(error is SimpleOneAccessDenied) }
        precondition(ProtectedAccessURLProtocol.calls == 1)
        print("Protected access: 13 checks passed")
    }
}
