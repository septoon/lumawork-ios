import Foundation

nonisolated enum WidgetRouteStopStatus: String, Codable, Hashable, Sendable {
    case pending
    case done
    case declined
}

nonisolated struct WidgetRequestCandidate: Hashable, Sendable {
    let id: String
    let number: String
    let state: String
    let deadline: Date?
    let isOverdue: Bool
}

nonisolated struct WidgetRouteStopCandidate: Hashable, Sendable {
    let status: WidgetRouteStopStatus
}

nonisolated struct WidgetRouteCandidate: Hashable, Sendable {
    let workType: String
    let stops: [WidgetRouteStopCandidate]
    let distanceKm: Int?
    let isSent: Bool
}

nonisolated struct WidgetRequestItem: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let number: String
    let state: String
    let deadline: Date?
    let isOverdue: Bool
}

nonisolated struct WidgetRouteSummary: Codable, Hashable, Sendable {
    let workType: String
    let completedStops: Int
    let totalStops: Int
    let distanceKm: Int?
    let isSent: Bool
}

nonisolated struct WidgetSnapshot: Codable, Hashable, Sendable {
    static let currentVersion = 1

    let version: Int
    let generatedAt: Date
    let sourceUpdatedAt: Date?
    let isAuthenticated: Bool
    let activeRequestCount: Int
    let overdueRequestCount: Int
    let requests: [WidgetRequestItem]
    let route: WidgetRouteSummary?
}

nonisolated enum WidgetSnapshotBuilder {
    static func make(
        isAuthenticated: Bool,
        sourceUpdatedAt: Date?,
        requests: [WidgetRequestCandidate],
        route: WidgetRouteCandidate?,
        generatedAt: Date = Date(),
        requestLimit: Int = 5
    ) -> WidgetSnapshot {
        guard isAuthenticated else {
            return WidgetSnapshot(
                version: WidgetSnapshot.currentVersion,
                generatedAt: generatedAt,
                sourceUpdatedAt: sourceUpdatedAt,
                isAuthenticated: false,
                activeRequestCount: 0,
                overdueRequestCount: 0,
                requests: [],
                route: nil
            )
        }

        let sortedRequests = requests.sorted(by: requestPrecedes)
        let items = sortedRequests.prefix(max(0, requestLimit)).map { candidate in
            WidgetRequestItem(
                id: candidate.id,
                number: candidate.number,
                state: candidate.state,
                deadline: candidate.deadline,
                isOverdue: candidate.isOverdue
            )
        }

        return WidgetSnapshot(
            version: WidgetSnapshot.currentVersion,
            generatedAt: generatedAt,
            sourceUpdatedAt: sourceUpdatedAt,
            isAuthenticated: true,
            activeRequestCount: requests.count,
            overdueRequestCount: requests.lazy.filter(\.isOverdue).count,
            requests: items,
            route: route.map(makeRouteSummary)
        )
    }

    static func makeRouteSummary(_ route: WidgetRouteCandidate) -> WidgetRouteSummary {
        let workStops = route.stops.count > 2 ? route.stops.dropFirst().dropLast() : []
        return WidgetRouteSummary(
            workType: route.workType,
            completedStops: workStops.lazy.filter { $0.status == .done }.count,
            totalStops: workStops.count,
            distanceKm: route.distanceKm,
            isSent: route.isSent
        )
    }

    private static func requestPrecedes(
        _ lhs: WidgetRequestCandidate,
        _ rhs: WidgetRequestCandidate
    ) -> Bool {
        if lhs.isOverdue != rhs.isOverdue {
            return lhs.isOverdue
        }

        switch (lhs.deadline, rhs.deadline) {
        case let (lhsDeadline?, rhsDeadline?) where lhsDeadline != rhsDeadline:
            return lhsDeadline < rhsDeadline
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            if lhs.number != rhs.number {
                return lhs.number < rhs.number
            }
            return lhs.id < rhs.id
        }
    }
}
