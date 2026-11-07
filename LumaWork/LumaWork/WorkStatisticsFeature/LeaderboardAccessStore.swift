import Foundation
import Observation

extension Notification.Name { static let leaderboardAccessChanged = Notification.Name("LumaWork.LeaderboardAccessChanged") }

/// Visibility only. Aggregate publishing has its own independent SO provenance and authorization.
@MainActor @Observable final class LeaderboardAccessStore {
    private(set) var isEnabled = false
    @ObservationIgnored var onDisabled: (() -> Void)?
    @ObservationIgnored private let config: AppConfig
    @ObservationIgnored private let ownerID: String?
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?

    init(config: AppConfig, ownerID: String?, session: URLSession = .shared) {
        self.config = config; self.ownerID = ownerID; self.session = session
    }

    func refresh() async {
        if let task { await task.value; return }
        guard let current = LumaWorkSessionKeychain.readSession(), current.user.id == ownerID, !current.token.isEmpty else {
            clearProtectedState(); return
        }
        let owner = current.user.id, token = current.token, stamp = generation
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if generation == stamp { self.task = nil } }
            do {
                let base = AppConfig.configuredURL(config.lumaWorkAPIOrigin)
                guard base.scheme == "https" || base.scheme == "http" else { throw URLError(.badURL) }
                var request = URLRequest(url: base.appendingPathComponent("api/v2/leaderboard-access"))
                request.cachePolicy = .reloadIgnoringLocalCacheData; request.timeoutInterval = 10
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue("iOS", forHTTPHeaderField: "X-LumaWork-Device-Platform")
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                guard generation == stamp, let active = LumaWorkSessionKeychain.readSession(), active.user.id == owner, active.token == token else { return }
                guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                if response.statusCode == 401 || response.statusCode == 403 { markDisabled(); return }
                guard response.statusCode == 200 else { throw URLError(.badServerResponse) }
                let value = try JSONDecoder().decode(Capability.self, from: data)
                isEnabled = value.enabled
                if !value.enabled { onDisabled?() }
            } catch {
                // Unconfirmed starts stay hidden; outages retain this owner's last confirmed decision.
                // Never turn a failure into a grant or reuse a decision for a different owner.
            }
        }
        self.task = task
        await task.value
    }

    func markDisabled() {
        generation = UUID(); task?.cancel(); task = nil
        isEnabled = false; onDisabled?()
    }
    func pauseForBackground() {
        generation = UUID(); task?.cancel(); task = nil
    }
    func clearProtectedState() { markDisabled() }

    nonisolated private struct Capability: Decodable {
        var enabled: Bool
        var updatedAt: String?
    }
}
