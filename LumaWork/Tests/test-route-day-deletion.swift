import Foundation

@main
struct RouteDayDeletionTests {
    static func main() throws {
        testPreviousDayEndpoint()
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

    static func testPreviousDayEndpoint() {
        let suite = "route-endpoint-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = RouteLocalStorage(defaults: defaults)
        let settings = RouteSettings(warehouseAddress: "Склад", homeAddress: "Дом")
        storage.saveSettings(settings)
        var previous = RouteLocalStorage.defaultDay(for: "2026-09-30", settings: settings)
        previous.stops[1].address = "Клиент"
        previous.stops[2].address = "Дом"
        storage.saveDay(previous, immediately: true)
        _ = storage.loadDay("2026-10-01") // Viewing an empty day must not turn it into a finished workday.
        var next = storage.loadDay("2026-10-02")
        precondition(next.stops.first?.address == "Дом", "New day must inherit the last working day's home finish")
        precondition(next.stops.last?.address == "Склад", "Automatic start must not change the finish")
        next.stops[0].address = "Склад"
        next.stops[2].address = "Дом"
        next.hasManualEndpointSelection = true
        storage.saveDay(next, immediately: true)
        let reloaded = RouteLocalStorage(defaults: defaults)
        let saved = reloaded.loadDay("2026-10-02")
        precondition(saved.stops.first?.address == "Склад", "Manual start must survive reentry")
        precondition(saved.stops.last?.address == "Дом", "Manual finish must survive reentry")
        precondition(saved.hasManualEndpointSelection, "Manual selection marker must survive normalization and decoding")
        previous.date = "2026-10-03"
        previous.stops[2].address = "Склад"
        reloaded.saveDay(previous, immediately: true)
        precondition(reloaded.loadDay("2026-10-05").stops.first?.address == "Склад", "Latest warehouse finish wins")
        reloaded.deleteDay("2026-10-03")
        precondition(reloaded.loadDay("2026-10-06").stops.first?.address == "Дом", "Deleted days must not supply the start")
        _ = reloaded.loadDay("2026-10-04")
        var remote = RouteLocalStorage.defaultDay(for: "2026-10-04", workType: .arm, settings: settings)
        remote.stops[1].address = "Клиент"
        precondition(reloaded.newDay(for: "2026-10-07", history: [remote]).stops.first?.address == "Склад",
            "Server history must beat an empty cached day and carry the physical finish between work types")
        print("PASS: new day inherits home/warehouse across gaps; manual endpoints survive reentry; deleted/empty days ignored")
    }
}
