import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

nonisolated private struct GroupClosedRequestsSnapshot: Codable, Sendable {
    let records: [SimpleOneRequestRecord]
    let refreshedIDs: Set<String>
    let nextPage: Int?
    let totalCount: Int?
    let updatedAt: Date?
    let isIncremental: Bool?
}

@MainActor
@Observable
final class CoordinationGroupClosedRequestsStore {
    private(set) var items: [GroupClosedRequestItem] = []
    private(set) var itemsRevision: UInt64 = 0
    private(set) var totalCount: Int?
    private(set) var loadedCount = 0
    private(set) var isRefreshing = false
    var isLoading: Bool { isRefreshing && didLoadCache && !hasCachedSnapshot }
    private(set) var isPaused = false
    private(set) var lastUpdatedAt: Date?
    var errorMessage: String?

    private let cacheKey: String
    private var sessionID: String?
    private(set) var didLoadCache = false
    private var hasCachedSnapshot = false
    private var isIncremental = false
    private var nextPage: Int?
    private var refreshedIDs = Set<String>()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshID: UUID?
    @ObservationIgnored private var cacheTask: Task<Void, Never>?
    #if canImport(UIKit)
    @ObservationIgnored private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    #endif

    init(cacheID: String? = nil) {
        cacheKey = AppOfflineSnapshotStore.scopedKey("coordination-group-closed", userID: cacheID)
    }

    func synchronizeSession(simpleOneStore: SimpleOneRequestsStore) {
        let currentID = simpleOneStore.isAuthorized ? makeCoordinationSessionID(for: simpleOneStore) : nil
        guard sessionID != currentID else { return }
        refreshTask?.cancel()
        refreshTask = nil
        refreshID = nil
        cacheTask?.cancel()
        cacheTask = nil
        endBackgroundTime()
        sessionID = currentID
        didLoadCache = false
        hasCachedSnapshot = false
        isIncremental = false
        items = []
        itemsRevision &+= 1
        totalCount = nil
        loadedCount = 0
        nextPage = nil
        refreshedIDs = []
        lastUpdatedAt = nil
        isRefreshing = false
        isPaused = false
        errorMessage = nil
    }

    // The store owns the task: cancellation of a screen's .task only stops its wait.
    func refresh(simpleOneStore: SimpleOneRequestsStore, forceFull: Bool = false) async {
        await loadCacheIfNeeded(simpleOneStore: simpleOneStore)
        guard didLoadCache, sessionID != nil else { return }
        let currentSessionID = sessionID
        if forceFull { await refreshTask?.value }
        guard simpleOneStore.isAuthorized,
              sessionID == currentSessionID,
              sessionID == makeCoordinationSessionID(for: simpleOneStore) else { return }
        startRefresh(simpleOneStore: simpleOneStore, forceFull: forceFull)
        await refreshTask?.value
    }

    func loadCacheIfNeeded(simpleOneStore: SimpleOneRequestsStore) async {
        synchronizeSession(simpleOneStore: simpleOneStore)
        guard !didLoadCache, let sessionID else { return }
        if let cacheTask {
            await cacheTask.value
            return
        }
        let key = AppOfflineSnapshotStore.scopedKey(cacheKey, userID: sessionID)
        cacheTask = Task {
            let cached = await Task.detached(priority: .userInitiated) {
                let snapshot = AppOfflineSnapshotStore.load(GroupClosedRequestsSnapshot.self, key: key)?.value
                return (snapshot, Self.sorted(Self.prepare(snapshot?.records ?? [])))
            }.value
            guard !Task.isCancelled, self.sessionID == sessionID,
                  simpleOneStore.isAuthorized,
                  sessionID == makeCoordinationSessionID(for: simpleOneStore) else { return }
            if let snapshot = cached.0 {
                publish(cached.1)
                hasCachedSnapshot = true
                totalCount = snapshot.totalCount
                lastUpdatedAt = snapshot.updatedAt
                nextPage = snapshot.nextPage
                refreshedIDs = snapshot.refreshedIDs
                loadedCount = nextPage == nil ? items.count : refreshedIDs.count
                isIncremental = snapshot.isIncremental ?? false
            }
            didLoadCache = true
            cacheTask = nil
        }
        await cacheTask?.value
    }

    func resumeIfNeeded(simpleOneStore: SimpleOneRequestsStore) {
        synchronizeSession(simpleOneStore: simpleOneStore)
        guard isPaused, sessionID != nil else { return }
        startRefresh(simpleOneStore: simpleOneStore)
    }

    private func startRefresh(simpleOneStore: SimpleOneRequestsStore, forceFull: Bool = false) {
        guard refreshTask == nil, let sessionID else { return }
        let requestID = UUID()
        refreshID = requestID
        isRefreshing = true
        isPaused = false
        errorMessage = nil
        beginBackgroundTime(requestID: requestID)
        refreshTask = Task {
            await load(sessionID: sessionID, requestID: requestID, simpleOneStore: simpleOneStore, forceFull: forceFull)
            guard refreshID == requestID else { return }
            refreshTask = nil
            isRefreshing = false
            if didLoadCache, nextPage == nil { isPaused = false }
            endBackgroundTime()
            #if canImport(UIKit)
            if isPaused, UIApplication.shared.applicationState == .active {
                resumeIfNeeded(simpleOneStore: simpleOneStore)
            }
            #endif
        }
    }

    private func load(
        sessionID: String,
        requestID: UUID,
        simpleOneStore: SimpleOneRequestsStore,
        forceFull: Bool
    ) async {
        let key = AppOfflineSnapshotStore.scopedKey(cacheKey, userID: sessionID)
        do {
            // Preserve partial passes. A completed archive only scans the recently updated head.
            if forceFull || nextPage == nil {
                isIncremental = !forceFull && hasCachedSnapshot && lastUpdatedAt != nil
                nextPage = 1
                refreshedIDs = []
                loadedCount = 0
            }
            var collected = items.filter { refreshedIDs.contains($0.id) }
            var seenIDs = refreshedIDs
            while let page = nextPage {
                try Task.checkCancellation()
                let result = try await simpleOneStore.fetchGroupClosedRequestsPage(
                    page: page, perPage: 100, newestFirst: isIncremental
                )
                guard isCurrent(requestID, simpleOneStore: simpleOneStore) else { return }
                let newRecords = result.records.filter { seenIDs.insert($0.id).inserted }
                let prepared = await Task.detached(priority: .userInitiated) {
                    Self.prepare(newRecords)
                }.value
                guard isCurrent(requestID, simpleOneStore: simpleOneStore) else { return }
                collected += prepared
                let existingItems = items
                let collectedItems = collected
                let incremental = isIncremental
                let merged = await Task.detached(priority: .userInitiated) {
                    let existing = Dictionary(existingItems.map { ($0.id, $0.source) }, uniquingKeysWith: { _, latest in latest })
                    let incoming = Dictionary(prepared.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
                    let updated = Self.sorted(
                        existingItems.map { incoming[$0.id] ?? $0 } + prepared.filter { existing[$0.id] == nil }
                    )
                    // Equal total protects against removals/reopened requests: those require reconciliation.
                    let reachedCachedPage = incremental && !result.records.isEmpty
                        && result.records.allSatisfy { existing[$0.id] == $0 }
                        && result.totalCount == updated.count
                    let hasMore = result.hasMore && !newRecords.isEmpty && !reachedCachedPage
                    return (hasMore || reachedCachedPage ? updated : Self.sorted(collectedItems), hasMore)
                }.value
                guard isCurrent(requestID, simpleOneStore: simpleOneStore) else { return }
                publish(merged.0)
                refreshedIDs = seenIDs
                loadedCount = seenIDs.count
                totalCount = result.totalCount ?? totalCount
                nextPage = merged.1 ? page + 1 : nil
                if !merged.1 {
                    lastUpdatedAt = Date()
                    refreshedIDs = []
                    hasCachedSnapshot = true
                }
                let snapshot = GroupClosedRequestsSnapshot(
                    records: items.map(\.source),
                    refreshedIDs: refreshedIDs,
                    nextPage: nextPage,
                    totalCount: totalCount,
                    updatedAt: lastUpdatedAt,
                    isIncremental: isIncremental
                )
                // Save each completed page off the main actor, including the continuation point.
                await Task.detached(priority: .utility) {
                    AppOfflineSnapshotStore.save(snapshot, key: key)
                }.value
                guard isCurrent(requestID, simpleOneStore: simpleOneStore) else { return }
            }
        } catch {
            guard isCurrent(requestID, simpleOneStore: simpleOneStore) else { return }
            errorMessage = appUserFacingErrorMessage(error)
        }
    }

    private func isCurrent(_ requestID: UUID, simpleOneStore: SimpleOneRequestsStore) -> Bool {
        refreshID == requestID && !Task.isCancelled && simpleOneStore.isAuthorized
            && sessionID == makeCoordinationSessionID(for: simpleOneStore)
    }

    private func publish(_ items: [GroupClosedRequestItem]) {
        guard self.items != items else { return }
        self.items = items
        itemsRevision &+= 1
    }

    nonisolated private static func sorted(_ items: [GroupClosedRequestItem]) -> [GroupClosedRequestItem] {
        items.sorted { ($0.display.date ?? .distantPast) > ($1.display.date ?? .distantPast) }
    }

    nonisolated private static func prepare(_ records: [SimpleOneRequestRecord]) -> [GroupClosedRequestItem] {
        let displayRecords = records.map(ClosedRequestsStore.closedRequestRecord(from:))
        let displays = ClosedRequestsIndexBuilder.build(records: displayRecords)
        return zip(records, displays).map { GroupClosedRequestItem(source: $0, display: $1.item) }
    }

    func pauseForBackgroundExpiration() {
        guard refreshTask != nil else { return }
        isPaused = true
        refreshTask?.cancel()
        endBackgroundTime()
    }

    private func beginBackgroundTime(requestID: UUID) {
        #if canImport(UIKit)
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Загрузка заявок группы") { [weak self] in
            Task { @MainActor in
                guard let self, self.refreshID == requestID else { return }
                self.pauseForBackgroundExpiration()
            }
        }
        #endif
    }

    private func endBackgroundTime() {
        #if canImport(UIKit)
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
        #endif
    }
}
