import Foundation

@main struct PersonalStateTests {
    @MainActor static func main() async throws {
        let name = "personal-state-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let offline = PersonalStateStore(ownerID: "a", collection: "ftp-favorites", defaults: defaults,
            seed: ["/old": "selected"], synchronize: { _, _ in throw URLError(.notConnectedToInternet) })
        offline.set(nil, for: "/old")
        await offline.synchronize()
        let restored = PersonalStateStore(ownerID: "a", collection: "ftp-favorites", defaults: defaults, seed: ["/old": "selected"]) { seed, changes in
            precondition(seed.contains { $0.key == "/old" })
            precondition(changes.contains { $0.key == "/old" && $0.value == nil })
            return [PersonalStateEntry(key: "/remote", value: "selected"), PersonalStateEntry(key: "/old", value: nil)]
        }
        precondition(restored.values.isEmpty)
        await restored.synchronize()
        precondition(restored.values == ["/remote": "selected"])
        let other = PersonalStateStore(ownerID: "b", collection: "ftp-favorites", defaults: defaults, synchronize: { _, _ in [] })
        precondition(other.values.isEmpty)
        let data = try JSONEncoder().encode(PersonalStateEntry(key: "/old", value: nil))
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        precondition(object["value"] is NSNull)
        // A newer edit must survive completion of an older request.
        var resume: CheckedContinuation<[PersonalStateEntry], Error>?
        let racing = PersonalStateStore(ownerID: "a", collection: "backpack-locations", defaults: defaults) { _, _ in
            try await withCheckedThrowingContinuation { resume = $0 }
        }
        racing.set("home", for: "SN")
        let task = Task { await racing.synchronize() }
        while resume == nil { await Task.yield() }
        racing.set("car", for: "SN")
        resume?.resume(returning: [PersonalStateEntry(key: "SN", value: "home")])
        await task.value
        precondition(racing.values["SN"] == "car")
        print("Personal state: persistence, migration, deletion, account isolation, in-flight edits passed")
    }
}
