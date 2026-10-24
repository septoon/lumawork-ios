import Foundation

@main
struct RouteDayDeletionTests {
    static func main() throws {
        let suite = "route-delete-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var storage: RouteLocalStorage? = RouteLocalStorage(defaults: defaults)
        let date = "2026-10-23"
        for workType in RouteWorkType.allCases {
            var day = RouteLocalStorage.defaultDay(for: date, workType: workType, settings: .default)
            day.distanceKm = 25
            day.periodStartOdometer = 1000
            day.sent = true
            storage!.saveDay(day, immediately: true)
            storage!.enqueue(date, workType: workType)
            storage!.saveAppleMileage(AppleRouteDistanceSnapshot(addresses: [], distanceKm: 25), for: workType.storageKey(for: date))
        }
        var other = RouteLocalStorage.defaultDay(for: "2026-10-22", settings: .default)
        other.distanceKm = 10
        storage!.saveDay(other, immediately: true)
        storage!.enqueue(other.date)
        storage!.deleteDay(date)
        precondition(storage!.loadAllDays().values.allSatisfy { $0.date != date })
        precondition(storage!.loadQueue().map(\.date) == [other.date])
        precondition(storage!.loadDailyMileageByDate().values.reduce(0, +) == 10)
        precondition(storage!.loadPeriodStartOdometer(for: "2026-10") == 1000)
        for type in RouteWorkType.allCases { precondition(storage!.loadAppleMileage(for: type.storageKey(for: date)) == nil) }
        // Deinit flush and a fresh storage instance must not restore the removed day.
        storage = nil
        let reloaded = RouteLocalStorage(defaults: defaults)
        precondition(reloaded.loadAllDays().count == 1)
        precondition(reloaded.isExcluded(date), "Automatic import must stay suppressed after reentry")
        precondition(reloaded.loadQueue().map(\.date) == [other.date])
        let restored = RouteLocalStorage.defaultDay(for: date, settings: .default)
        reloaded.saveDay(restored, immediately: true)
        precondition(reloaded.loadAllDays().values.contains { $0.date == date })
        reloaded.beginExplicitRestore(date)
        reloaded.enqueue(date)
        reloaded.syncExcludedDates([date])
        precondition(reloaded.loadAllDays().values.contains { $0.date == date }, "Explicit re-add must survive exclusion sync")
        precondition(reloaded.isPendingRestore(date), "Queued re-add must remain eligible for sending")
        precondition(reloaded.loadQueue().contains { $0.date == date })
        reloaded.finishExplicitRestore(date)
        precondition(!reloaded.isExcluded(date))
        precondition(!reloaded.isPendingRestore(date))
        print("PASS: date removes POS/ARM, queue, mileage and Apple cache; preserves other dates/month odometer; persists and permits re-add")
    }
}
