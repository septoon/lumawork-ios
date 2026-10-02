import AppIntents
import CryptoKit
import Foundation

@MainActor
enum EngineerVoiceRequestIndex {
    private struct Snapshot: Codable, Equatable {
        let authFingerprint: String
        let requests: [EngineerRequestEntity]
    }

    private static func fingerprint(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func suggestions() -> [EngineerRequestEntity] {
        guard let session = LumaWorkSessionKeychain.readSession(),
              let key = SimpleOneSessionKeychain.readAuthKey(),
              let snapshot = AppOfflineSnapshotStore.load(
                Snapshot.self,
                key: AppOfflineSnapshotStore.scopedKey("voice-request-index", userID: session.user.id)
              ), snapshot.value.authFingerprint == fingerprint(key) else { return [] }
        return snapshot.value.requests
    }

    static func publish(store: SimpleOneRequestsStore, userID: String?) {
        guard let userID, LumaWorkSessionKeychain.readSession()?.user.id == userID,
              let key = store.browserAuthKey, store.currentUser != nil else {
            EngineerAppShortcuts.updateAppShortcutParameters()
            return
        }
        let requests = store.activeRequests.sorted {
            ($0.deadlineDate ?? .distantFuture) < ($1.deadlineDate ?? .distantFuture)
        }.prefix(100).map(EngineerRequestEntity.init)
        let snapshot = Snapshot(authFingerprint: fingerprint(key), requests: requests)
        let cacheKey = AppOfflineSnapshotStore.scopedKey("voice-request-index", userID: userID)
        guard AppOfflineSnapshotStore.load(Snapshot.self, key: cacheKey)?.value != snapshot else { return }
        AppOfflineSnapshotStore.save(snapshot, key: cacheKey)
        EngineerAppShortcuts.updateAppShortcutParameters()
    }

    static func invalidateSuggestions() {
        EngineerAppShortcuts.updateAppShortcutParameters()
    }
}
