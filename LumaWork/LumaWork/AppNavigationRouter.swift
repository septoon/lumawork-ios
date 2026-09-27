import Observation

@MainActor
@Observable
final class AppNavigationRouter {
    static let shared = AppNavigationRouter()

    private(set) var pendingRoute: AppRoute?

    func open(_ route: AppRoute) {
        pendingRoute = route
    }

    @discardableResult
    func consume() -> AppRoute? {
        defer { pendingRoute = nil }
        return pendingRoute
    }
}
