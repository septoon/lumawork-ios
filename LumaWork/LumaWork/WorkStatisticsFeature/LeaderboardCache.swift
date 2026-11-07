import Foundation
import CryptoKit

nonisolated struct LeaderboardCache: Sendable {
    struct Key: Codable, Hashable, Sendable {
        var ownerID: String
        var sourceUserID: String
        var periodKey: String
        var period: LeaderboardPeriod
        var category: LeaderboardCategory
        var city: String
        var schemaVersion = 1
        var rulesVersion = 1
    }
    struct Value: Codable, Sendable {
        var key: Key
        var response: LeaderboardResponse
        var savedAt: Date
    }
    let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Leaderboard-v1", isDirectory: true)
    }
    func read(_ key: Key) -> Value? {
        guard let data = try? Data(contentsOf: url(key)), let value = try? JSONDecoder().decode(Value.self, from: data), value.key == key,
              value.response.periodKey == key.periodKey,
              (try? value.response.validate(period: key.period, category: key.category, city: key.city)) != nil else { return nil }
        return value
    }
    func save(_ response: LeaderboardResponse, key: Key, savedAt: Date = Date()) throws {
        try response.validate(period: key.period, category: key.category, city: key.city)
        guard response.periodKey == key.periodKey else { return }
        let file = url(key)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Value(key: key, response: response, savedAt: savedAt)).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func removeOwner(_ owner: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(hash(owner)))
    }
    private func url(_ key: Key) -> URL {
        let encoded = [key.sourceUserID, key.periodKey, key.period.rawValue, key.category.rawValue, key.city, String(key.schemaVersion), String(key.rulesVersion)].joined(separator: "\u{0}")
        return directory.appendingPathComponent(hash(key.ownerID), isDirectory: true).appendingPathComponent(hash(encoded) + ".json")
    }
    private func hash(_ string: String) -> String { SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined() }
}
