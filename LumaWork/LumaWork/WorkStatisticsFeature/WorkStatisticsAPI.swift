import Foundation

nonisolated struct WorkStatisticsAPIError: Error, LocalizedError, Sendable {
    var status: Int
    var code: String
    var availableCities: [LeaderboardCity]?
    var errorDescription: String? {
        switch code {
        case "CITY_NOT_AVAILABLE": "Этот город больше недоступен. Выберите другой город."
        case "REVISION_CONFLICT": "Статистика обновлена на другом устройстве. Обновите закрытые заявки ещё раз."
        case "SOURCE_ACCOUNT_CHANGED", "SOURCE_ACCOUNT_ALREADY_LINKED": "SO-учётная запись уже связана с другой статистикой. Обратитесь в поддержку."
        case "STATISTICS_DISABLED": "Рейтинг временно недоступен."
        default: "Не удалось обновить рейтинг. Повторите попытку."
        }
    }
    var canRetry: Bool { status >= 500 && code != "STATISTICS_DISABLED" }
}

@MainActor struct WorkStatisticsAPI {
    let config: AppConfig
    var session: URLSession = .shared

    func fetchMe() async throws -> WorkStatisticsMe {
        try await request("api/v2/work-statistics/me")
    }

    func replaceSnapshot(_ payload: WorkStatisticsUpload) async throws -> WorkStatisticsReceipt {
        try await request("api/v2/work-statistics/me", method: "PUT", body: JSONEncoder().encode(payload))
    }

    func leaderboard(period: LeaderboardPeriod, category: LeaderboardCategory, city: String, offset: Int = 0) async throws -> LeaderboardResponse {
        try await request("api/v2/leaderboard", query: [
            URLQueryItem(name: "period", value: period.rawValue), URLQueryItem(name: "category", value: category.rawValue),
            URLQueryItem(name: "city", value: city), URLQueryItem(name: "limit", value: "50"), URLQueryItem(name: "offset", value: String(offset))
        ])
    }

    private struct Failure: Decodable { var error: String; var availableCities: [LeaderboardCity]? }

    private func request<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil, query: [URLQueryItem] = []) async throws -> T {
        let base = AppConfig.configuredURL(config.lumaWorkAPIOrigin)
        guard base.scheme == "https" || base.scheme == "http" else { throw URLError(.badURL) }
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("iOS", forHTTPHeaderField: "X-LumaWork-Device-Platform")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await SimpleOneProtectedAccess.data(for: request, session: session)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(response.statusCode) else {
            let failure = try? JSONDecoder().decode(Failure.self, from: data)
            throw WorkStatisticsAPIError(status: response.statusCode, code: failure?.error ?? "HTTP_ERROR", availableCities: failure?.availableCities)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
