import Foundation
import Observation

nonisolated struct PersonalStateEntry: Codable, Sendable {
    var key: String
    var value: String?

    private enum CodingKeys: String, CodingKey { case key, value }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        if let value { try container.encode(value, forKey: .value) }
        else { try container.encodeNil(forKey: .value) }
    }
}

nonisolated private struct PendingPersonalStateEntry: Codable {
    var value: String?
    var id: UUID = UUID()
}

nonisolated private struct PersonalStateSnapshot: Codable {
    var values: [String: String]
    var seed: [String: String]
    var pending: [String: PendingPersonalStateEntry]
}

/// Account-scoped cache and durable edits. A response acknowledges only the edits it sent.
@MainActor @Observable final class PersonalStateStore {
    private(set) var values: [String: String]
    private let defaults: UserDefaults
    private let storageKey: String
    private var seed: [String: String]
    private var pending: [String: PendingPersonalStateEntry]
    private var isSynchronizing = false
    private let transport: ([PersonalStateEntry], [PersonalStateEntry]) async throws -> [PersonalStateEntry]

    init(ownerID: String, collection: String, defaults: UserDefaults = .standard,
         seed: [String: String] = [:],
         synchronize: @escaping ([PersonalStateEntry], [PersonalStateEntry]) async throws -> [PersonalStateEntry]) {
        self.defaults = defaults
        storageKey = "personal-state-v1.\(collection).\(ownerID)"
        transport = synchronize
        if let data = defaults.data(forKey: storageKey),
           let stored = try? JSONDecoder().decode(PersonalStateSnapshot.self, from: data) {
            values = stored.values; self.seed = stored.seed; pending = stored.pending
        } else {
            values = seed; self.seed = seed; pending = [:]
            persist()
        }
    }

    func set(_ value: String?, for key: String) {
        values[key] = value
        pending[key] = PendingPersonalStateEntry(value: value)
        persist()
    }

    func synchronize() async {
        guard !isSynchronizing else { return }
        isSynchronizing = true
        defer { isSynchronizing = false }
        let sent = pending
        do {
            let entries = try await transport(seed.map { PersonalStateEntry(key: $0.key, value: $0.value) },
                sent.map { PersonalStateEntry(key: $0.key, value: $0.value.value) })
            try Task.checkCancellation()
            pending = pending.filter { sent[$0.key]?.id != $0.value.id }
            var merged = [String: String]()
            for entry in entries { merged[entry.key] = entry.value }
            for (key, entry) in pending { merged[key] = entry.value }
            values = merged
            seed = [:]
            persist()
        } catch { /* Retain local data and edits for the next foreground retry. */ }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(PersonalStateSnapshot(values: values, seed: seed, pending: pending)) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
