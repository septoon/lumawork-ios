import Foundation
import Observation

@MainActor
@Observable
final class SimpleOneTerminalHistoryStore {
    private(set) var records: [SimpleOneRequestRecord] = []
    private(set) var isLoading = false
    private(set) var hasSnapshot = false
    private(set) var errorMessage: String?
    private var scope: String?
    private var loadID = UUID()

    func isCurrentScope(terminalID: String, sessionID: String) -> Bool {
        scope == Self.cacheKey(terminalID: terminalID, sessionID: sessionID)
    }

    private static func cacheKey(terminalID: String, sessionID: String) -> String {
        AppOfflineSnapshotStore.scopedKey(
            "terminal-history-v2-\(SimpleOneTerminalHistory.normalizedTerminalID(terminalID))", userID: sessionID
        )
    }

    func load(
        terminalID: String,
        sessionID: String,
        fetch: () async throws -> [SimpleOneRequestRecord]
    ) async {
        let terminalID = SimpleOneTerminalHistory.normalizedTerminalID(terminalID)
        let key = Self.cacheKey(terminalID: terminalID, sessionID: sessionID)
        let canUseCache = !sessionID.isEmpty && sessionID != "authorized"
        let requestID = UUID()
        loadID = requestID
        if scope != key {
            scope = key
            records = []
            hasSnapshot = false
        }
        isLoading = false
        errorMessage = nil
        guard !terminalID.isEmpty, !sessionID.isEmpty else { return }
        isLoading = true
        defer { if loadID == requestID { isLoading = false } }

        if !hasSnapshot && canUseCache {
            let snapshot = await Task.detached(priority: .userInitiated) {
                AppOfflineSnapshotStore.load([SimpleOneRequestRecord].self, key: key)
            }.value
            guard !Task.isCancelled, loadID == requestID else { return }
            if let snapshot {
                records = SimpleOneTerminalHistory.records(snapshot.value, terminalID: terminalID)
                hasSnapshot = true
            }
        }
        do {
            let fetched = try await fetch()
            guard !Task.isCancelled, loadID == requestID else { return }
            let filtered = SimpleOneTerminalHistory.records(fetched, terminalID: terminalID)
            records = filtered
            hasSnapshot = true
            if canUseCache {
                await Task.detached(priority: .utility) {
                    AppOfflineSnapshotStore.save(filtered, key: key)
                }.value
            }
        } catch {
            guard !Task.isCancelled, loadID == requestID else { return }
            errorMessage = appUserFacingErrorMessage(error)
        }
    }
}
