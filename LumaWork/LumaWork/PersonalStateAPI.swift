import Foundation

@MainActor struct PersonalStateAPI {
    let config: AppConfig
    let ownerID: String
    let collection: String

    func synchronize(seed: [PersonalStateEntry], changes: [PersonalStateEntry]) async throws -> [PersonalStateEntry] {
        let access = try SimpleOneProtectedAccess.capture(ownerID: ownerID)
        let origin = AppConfig.configuredURL(config.lumaWorkAPIOrigin)
        var request = URLRequest(url: origin.appendingPathComponent("api/v2/personal-state/\(collection)/sync"))
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Payload(seed: seed, changes: changes))
        let (data, response) = try await SimpleOneProtectedAccess.data(for: request, session: .shared, authToken: access.appToken)
        try SimpleOneProtectedAccess.validate(access, response: response)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AppServiceError.message("Не удалось синхронизировать личные данные.")
        }
        return try JSONDecoder().decode(SyncResponse.self, from: data).entries
    }

    private struct Payload: Encodable { var seed: [PersonalStateEntry]; var changes: [PersonalStateEntry] }
    private struct SyncResponse: Decodable { var entries: [PersonalStateEntry] }
}
