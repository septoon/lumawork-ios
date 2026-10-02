import Foundation
import Observation
import OSLog

nonisolated private struct ClosedSimpleOneRequestsSnapshot: Codable, Hashable, Sendable {
    var userID: String
    var records: [SimpleOneRequestRecord]
    var isComplete: Bool
    var updatedAt: Date?
}

@MainActor
@Observable
final class ClosedSimpleOneRequestsStore {
    var records: [SimpleOneRequestRecord] = []
    var isLoading = false
    var loadedCount = 0
    var totalCount: Int?
    var progressFraction = 0.0
    var errorMessage: String?
    var lastUpdatedAt: Date?
    var hasLoaded = false
    var isCacheComplete = false
    let pageSize = 30
    private let syncPageSize = 100
    private let refreshInterval: TimeInterval = 60
    private var loadedUserID: String?
    private var loadingTask: Task<Void, Never>?

    var progressPercent: Int {
        min(100, max(0, Int((progressFraction * 100).rounded())))
    }

    var progressText: String {
        if let totalCount, totalCount > 0 {
            return "\(progressPercent)% - \(loadedCount) из \(totalCount)"
        }
        return "\(progressPercent)% - получено \(loadedCount)"
    }

    func load(using simpleOneStore: SimpleOneRequestsStore, force: Bool = false) async {
        let currentUserID = simpleOneStore.currentUser?.sysID
        if !force,
           let currentUserID,
           loadedUserID != currentUserID {
            loadCachedSnapshot(for: currentUserID)
        }

        if isLoading, !force {
            return
        }

        if force {
            loadingTask?.cancel()
            records = []
            loadedCount = 0
            totalCount = nil
            progressFraction = 0
            hasLoaded = false
            isCacheComplete = false
        } else if loadedUserID != currentUserID {
            loadingTask?.cancel()
            records = []
            loadedCount = 0
            totalCount = nil
            progressFraction = 0
            hasLoaded = false
            isCacheComplete = false
        } else if hasLoaded, isCacheComplete, !shouldRefresh {
            return
        }

        loadedUserID = currentUserID
        isLoading = true
        errorMessage = nil
        loadedCount = records.count
        totalCount = records.isEmpty ? nil : records.count
        progressFraction = records.isEmpty ? 0 : 1

        loadingTask = Task { [weak self, weak simpleOneStore] in
            guard let self, let simpleOneStore else { return }

            do {
                var page = 1
                var collected: [SimpleOneRequestRecord] = []
                var seenIDs = Set<String>()
                var knownTotal: Int?
                let hadVisibleCache = !records.isEmpty

                while !Task.isCancelled {
                    let pageResult = try await simpleOneStore.fetchClosedRequestsPageForCurrentUser(
                        page: page,
                        perPage: syncPageSize
                    )
                    guard !Task.isCancelled else { return }

                    knownTotal = pageResult.totalCount ?? knownTotal
                    let previousCount = collected.count
                    for record in pageResult.records {
                        let id = record.id.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard id.isEmpty || seenIDs.insert(id).inserted else {
                            continue
                        }
                        collected.append(record)
                    }

                    loadedCount = collected.count
                    totalCount = knownTotal
                    progressFraction = Self.progressFraction(
                        loadedCount: collected.count,
                        totalCount: knownTotal,
                        page: page,
                        hasMore: pageResult.hasMore
                    )

                    if !hadVisibleCache {
                        records = Self.sortedRecords(collected)
                        hasLoaded = true
                        if page == 1 || page.isMultiple(of: 5) || !pageResult.hasMore {
                            saveSnapshot(records: records, isComplete: false)
                        }
                    }

                    guard pageResult.hasMore, collected.count > previousCount else {
                        break
                    }
                    page += 1
                }

                guard !Task.isCancelled else { return }

                let syncedRecords = Self.sortedRecords(collected)
                records = syncedRecords
                loadedCount = syncedRecords.count
                totalCount = knownTotal ?? syncedRecords.count
                progressFraction = 1
                lastUpdatedAt = Date()
                loadedUserID = simpleOneStore.currentUser?.sysID ?? loadedUserID
                hasLoaded = true
                isCacheComplete = true
                saveSnapshot(records: syncedRecords, isComplete: true)
                isLoading = false
            } catch is CancellationError {
            } catch {
                errorMessage = appUserFacingErrorMessage(error)
                isLoading = false
                hasLoaded = !records.isEmpty
            }
        }
    }

    func loadAndWait(using simpleOneStore: SimpleOneRequestsStore, force: Bool = false) async {
        await load(using: simpleOneStore, force: force)
        await loadingTask?.value
    }

    private var shouldRefresh: Bool {
        guard let lastUpdatedAt else { return true }
        return Date().timeIntervalSince(lastUpdatedAt) > refreshInterval
    }

    private static func progressFraction(loadedCount: Int, totalCount: Int?, page: Int, hasMore: Bool) -> Double {
        if let totalCount, totalCount > 0 {
            return min(0.99, max(0.01, Double(loadedCount) / Double(totalCount)))
        }
        guard hasMore else { return 1 }
        return min(0.95, Double(page) / Double(page + 1))
    }

    private static func sortedRecords(_ records: [SimpleOneRequestRecord]) -> [SimpleOneRequestRecord] {
        records.sorted { lhs, rhs in
            lhs.primaryDate.localizedStandardCompare(rhs.primaryDate) == .orderedDescending
        }
    }

    private func loadCachedSnapshot(for userID: String) {
        guard let snapshot = Self.cachedSnapshot(),
              snapshot.userID == userID else {
            return
        }

        loadedUserID = snapshot.userID
        lastUpdatedAt = snapshot.updatedAt
        records = Self.sortedRecords(snapshot.records)
        loadedCount = records.count
        totalCount = records.count
        progressFraction = snapshot.isComplete ? 1 : 0
        hasLoaded = true
        isCacheComplete = snapshot.isComplete
    }

    /// Voice queries must not mistake a partial or another user's archive for
    /// a complete result, or start a long archive sync in the Siri runtime.
    nonisolated static func completeVoiceSnapshot(for userID: String) -> (records: [SimpleOneRequestRecord], updatedAt: Date)? {
        guard let snapshot = cachedSnapshot(), snapshot.userID == userID,
              snapshot.isComplete, let updatedAt = snapshot.updatedAt else { return nil }
        return (snapshot.records, updatedAt)
    }

    private func saveSnapshot(records snapshotRecords: [SimpleOneRequestRecord], isComplete: Bool) {
        guard let loadedUserID, !loadedUserID.isEmpty else { return }

        let snapshot = ClosedSimpleOneRequestsSnapshot(
            userID: loadedUserID,
            records: snapshotRecords,
            isComplete: isComplete,
            updatedAt: lastUpdatedAt
        )

        Task.detached(priority: .utility) {
            let url = Self.snapshotFileURL()
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: [.atomic])
            } catch {
                Logger(subsystem: "LumaWork", category: "ClosedSimpleOne").error("Closed SimpleOne cache save failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    nonisolated private static func cachedSnapshot() -> ClosedSimpleOneRequestsSnapshot? {
        guard let data = try? Data(contentsOf: snapshotFileURL()) else {
            return nil
        }
        return try? JSONDecoder().decode(ClosedSimpleOneRequestsSnapshot.self, from: data)
    }

    nonisolated private static func snapshotFileURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("LumaWork", isDirectory: true)
            .appendingPathComponent("closed-simpleone-requests-cache-v2.json", isDirectory: false)
    }
}
