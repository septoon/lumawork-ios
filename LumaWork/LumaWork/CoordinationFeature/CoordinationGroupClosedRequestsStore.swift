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
}

@MainActor
@Observable
final class CoordinationGroupClosedRequestsStore {
    private(set) var items: [GroupClosedRequestItem] = []
    private(set) var itemsRevision: UInt64 = 0
    private(set) var totalCount: Int?
    private(set) var loadedCount = 0
    private(set) var isLoading = false
    private(set) var isPaused = false
    private(set) var lastUpdatedAt: Date?
    var errorMessage: String?

    private let cacheKey: String
    private var sessionID: String?
    private var didLoadCache = false
    private var nextPage: Int?
    private var refreshedIDs = Set<String>()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshID: UUID?
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
        endBackgroundTime()
        sessionID = currentID
        didLoadCache = false
        items = []
        itemsRevision &+= 1
        totalCount = nil
        loadedCount = 0
        nextPage = nil
        refreshedIDs = []
        lastUpdatedAt = nil
        isLoading = false
        isPaused = false
        errorMessage = nil
    }

    // The store owns the task: cancellation of a screen's .task only stops its wait.
    func refresh(simpleOneStore: SimpleOneRequestsStore) async {
        synchronizeSession(simpleOneStore: simpleOneStore)
        guard sessionID != nil else { return }
        startRefresh(simpleOneStore: simpleOneStore)
        await refreshTask?.value
    }

    func resumeIfNeeded(simpleOneStore: SimpleOneRequestsStore) {
        synchronizeSession(simpleOneStore: simpleOneStore)
        guard isPaused, sessionID != nil else { return }
        startRefresh(simpleOneStore: simpleOneStore)
    }

    private func startRefresh(simpleOneStore: SimpleOneRequestsStore) {
        guard refreshTask == nil, let sessionID else { return }
        let requestID = UUID()
        refreshID = requestID
        isLoading = true
        isPaused = false
        errorMessage = nil
        beginBackgroundTime(requestID: requestID)
        refreshTask = Task {
            await load(sessionID: sessionID, requestID: requestID, simpleOneStore: simpleOneStore)
            guard refreshID == requestID else { return }
            refreshTask = nil
            isLoading = false
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
        simpleOneStore: SimpleOneRequestsStore
    ) async {
        let key = AppOfflineSnapshotStore.scopedKey(cacheKey, userID: sessionID)
        do {
            if !didLoadCache {
                let cached = await Task.detached(priority: .userInitiated) {
                    let snapshot = AppOfflineSnapshotStore.load(GroupClosedRequestsSnapshot.self, key: key)?.value
                    return (snapshot, Self.sorted(Self.prepare(snapshot?.records ?? [])))
                }.value
                guard isCurrent(requestID, simpleOneStore: simpleOneStore) else { return }
                if let snapshot = cached.0 {
                    publish(cached.1)
                    totalCount = snapshot.totalCount
                    lastUpdatedAt = snapshot.updatedAt
                    nextPage = snapshot.nextPage
                    refreshedIDs = snapshot.refreshedIDs
                    loadedCount = refreshedIDs.count
                }
                didLoadCache = true
            }

            // A saved partial pass resumes at its next page; a completed pass starts a new refresh.
            if nextPage == nil {
                nextPage = 1
                refreshedIDs = []
                loadedCount = 0
            }
            var collected = items.filter { refreshedIDs.contains($0.id) }
            var seenIDs = refreshedIDs
            while let page = nextPage {
                try Task.checkCancellation()
                let result = try await simpleOneStore.fetchGroupClosedRequestsPage(page: page, perPage: 100)
                guard isCurrent(requestID, simpleOneStore: simpleOneStore) else { return }
                let newRecords = result.records.filter { seenIDs.insert($0.id).inserted }
                let prepared = await Task.detached(priority: .userInitiated) {
                    Self.prepare(newRecords)
                }.value
                guard isCurrent(requestID, simpleOneStore: simpleOneStore) else { return }
                collected += prepared
                let hasMore = result.hasMore && !newRecords.isEmpty
                let existingItems = items
                let collectedItems = collected
                let merged = await Task.detached(priority: .userInitiated) {
                    guard hasMore else { return Self.sorted(collectedItems) }
                    let incoming = Dictionary(prepared.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
                    let existingIDs = Set(existingItems.map(\.id))
                    return Self.sorted(
                        existingItems.map { incoming[$0.id] ?? $0 } + prepared.filter { !existingIDs.contains($0.id) }
                    )
                }.value
                guard isCurrent(requestID, simpleOneStore: simpleOneStore) else { return }
                publish(merged)
                refreshedIDs = seenIDs
                loadedCount = seenIDs.count
                totalCount = result.totalCount ?? totalCount
                nextPage = hasMore ? page + 1 : nil
                if !hasMore {
                    lastUpdatedAt = Date()
                    refreshedIDs = []
                }
                let snapshot = GroupClosedRequestsSnapshot(
                    records: items.map(\.source),
                    refreshedIDs: refreshedIDs,
                    nextPage: nextPage,
                    totalCount: totalCount,
                    updatedAt: lastUpdatedAt
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
