import OSLog
import WidgetKit

@MainActor
enum WidgetSnapshotPublisher {
    private static let logger = Logger(subsystem: "LumaWork", category: "WidgetSnapshot")

    static func publish(stores: AppDataStores, isAuthenticated: Bool) {
        guard let snapshotStore = WidgetSnapshotStore() else {
            logger.error("App Group container is unavailable")
            return
        }

        let requestCandidates = stores.simpleOneStore.activeRequests.map { record in
            WidgetRequestCandidate(
                id: record.id,
                number: record.number,
                state: record.state,
                deadline: record.deadlineDate,
                isOverdue: record.isOverdue
            )
        }

        let routeCandidate: WidgetRouteCandidate?
        if stores.homeStore.isToday {
            let record = stores.homeStore.record
            routeCandidate = WidgetRouteCandidate(
                workType: record.workType.title,
                stops: record.stops.map { stop in
                    WidgetRouteStopCandidate(status: widgetStatus(for: stop.status))
                },
                distanceKm: record.distanceKm,
                isSent: record.sent
            )
        } else {
            routeCandidate = nil
        }

        let builtSnapshot = WidgetSnapshotBuilder.make(
            isAuthenticated: isAuthenticated,
            sourceUpdatedAt: stores.simpleOneStore.lastUpdatedAt,
            requests: requestCandidates,
            route: routeCandidate
        )

        let snapshot: WidgetSnapshot
        if isAuthenticated, routeCandidate == nil, let previousRoute = snapshotStore.load()?.route {
            snapshot = WidgetSnapshot(
                version: builtSnapshot.version,
                generatedAt: builtSnapshot.generatedAt,
                sourceUpdatedAt: builtSnapshot.sourceUpdatedAt,
                isAuthenticated: builtSnapshot.isAuthenticated,
                activeRequestCount: builtSnapshot.activeRequestCount,
                overdueRequestCount: builtSnapshot.overdueRequestCount,
                requests: builtSnapshot.requests,
                route: previousRoute
            )
        } else {
            snapshot = builtSnapshot
        }

        persist(snapshot, to: snapshotStore)
    }

    static func publishSignedOut() {
        guard let snapshotStore = WidgetSnapshotStore() else {
            logger.error("App Group container is unavailable while signing out")
            return
        }
        let snapshot = WidgetSnapshotBuilder.make(
            isAuthenticated: false,
            sourceUpdatedAt: nil,
            requests: [],
            route: nil
        )
        persist(snapshot, to: snapshotStore)
    }

    private static func persist(
        _ snapshot: WidgetSnapshot,
        to snapshotStore: WidgetSnapshotStore
    ) {
        do {
            try snapshotStore.save(snapshot)
            WidgetCenter.shared.reloadTimelines(ofKind: LumaWorkSharedConfiguration.widgetKind)
        } catch {
            logger.error("Widget snapshot save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func widgetStatus(for status: RouteStopStatus) -> WidgetRouteStopStatus {
        switch status {
        case .pending:
            return .pending
        case .done:
            return .done
        case .declined:
            return .declined
        }
    }
}
