import Foundation

nonisolated struct SimpleOneAccessSnapshot: Equatable, Sendable {
    let ownerID: String
    let appToken: String
    let authKey: String
}

nonisolated struct SimpleOneLoginAttempt: Sendable {
    let ownerID: String
    let appToken: String
    let generation: UUID
}

nonisolated struct SimpleOneAccessDenied: LocalizedError {
    var errorDescription: String? { "Доступ запрещен" }
}

/// Revocation can interrupt an export running outside the main actor.
nonisolated final class SimpleOneAccessLease: @unchecked Sendable {
    private let lock = NSLock()
    private var revoked = false
    func revoke() { lock.withLock { revoked = true } }
    func check() throws { if lock.withLock({ revoked }) { throw SimpleOneAccessDenied() } }
}

extension Notification.Name {
    static let simpleOneSessionChanged = Notification.Name("LumaWork.SimpleOneSessionChanged")
}

@MainActor enum SimpleOneProtectedAccess {
    static func loginAttempt() throws -> SimpleOneLoginAttempt {
        guard let session = LumaWorkSessionKeychain.readSession(), !session.token.isEmpty else { throw SimpleOneAccessDenied() }
        return SimpleOneLoginAttempt(ownerID: session.user.id, appToken: session.token, generation: SimpleOneSessionKeychain.generation)
    }
    static func validateLoginAttempt(_ attempt: SimpleOneLoginAttempt) throws {
        guard let session = LumaWorkSessionKeychain.readSession(), session.user.id == attempt.ownerID,
              session.token == attempt.appToken, SimpleOneSessionKeychain.generation == attempt.generation else { throw SimpleOneAccessDenied() }
        try Task.checkCancellation()
    }

    static func capture(ownerID: String? = nil, authToken: String? = nil) throws -> SimpleOneAccessSnapshot {
        guard let session = LumaWorkSessionKeychain.readSession(), !session.token.isEmpty,
              let key = SimpleOneSessionKeychain.readAuthKey(), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ownerID == nil || ownerID == session.user.id,
              authToken == nil || authToken == session.token else { throw SimpleOneAccessDenied() }
        return SimpleOneAccessSnapshot(ownerID: session.user.id, appToken: session.token, authKey: key)
    }

    @discardableResult static func authorize(_ request: inout URLRequest, authToken: String? = nil) throws -> SimpleOneAccessSnapshot {
        let access = try capture(authToken: authToken)
        request.setValue("Bearer \(access.appToken)", forHTTPHeaderField: "Authorization")
        request.setValue(access.authKey, forHTTPHeaderField: "X-SimpleOne-Auth")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return access
    }

    static func validate(_ access: SimpleOneAccessSnapshot, response: URLResponse? = nil) throws {
        if let response = response as? HTTPURLResponse, response.statusCode == 403,
           response.value(forHTTPHeaderField: "X-SimpleOne-Access") == "denied",
           SimpleOneSessionKeychain.readAuthKey() == access.authKey {
            SimpleOneSessionKeychain.deleteAuthKey()
        }
        guard try capture() == access else { throw SimpleOneAccessDenied() }
        try Task.checkCancellation()
    }

    static func data(for original: URLRequest, session: URLSession, authToken: String? = nil) async throws -> (Data, URLResponse) {
        var request = original
        let access = try authorize(&request, authToken: authToken)
        let result = try await session.data(for: request)
        try validate(access, response: result.1)
        return result
    }
}
