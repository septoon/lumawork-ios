import Foundation

@main
struct RouteDayDeletionTests {
    static func main() throws {
        try testClosedRequestsReimportAfterDeletion()
        testPreviousDayEndpoint()
        testScopedDeletion()
        testSameDayWorkTypeStart()
        let emptyRouteSuite = "route-stop-delete-tests-\(UUID().uuidString)"
        let emptyRouteDefaults = UserDefaults(suiteName: emptyRouteSuite)!
        defer { emptyRouteDefaults.removePersistentDomain(forName: emptyRouteSuite) }
        let emptyRouteStorage = RouteLocalStorage(defaults: emptyRouteDefaults)
        var emptyRoute = RouteLocalStorage.defaultDay(for: "2026-11-01", settings: .default)
        emptyRoute.stops.remove(at: 1)
        emptyRouteStorage.saveDay(emptyRoute, immediately: true)
        let reopenedRoute = RouteLocalStorage(defaults: emptyRouteDefaults).loadDay(emptyRoute.date)
        precondition(reopenedRoute.stops == emptyRoute.stops, "Deleting the last middle point must survive reloading")
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

    static func testClosedRequestsReimportAfterDeletion() throws {
        let requests = try JSONDecoder().decode([ClosedRequestRecord].self, from: Data(#"[{"requestNumber":"REQ","shortDescription":"","status":"Закрыто","engineerShift":"","workgroup":"","requestType":"","address":"Ялта, Ленина, 1","customer":"Клиент","engineerName":"","terminalModel":"","engineerComment":"","closedAt":"01.11.2026","terminalID":"001","incomingNumber":"000123","infoFields":[],"rawInfo":""}]"#.utf8))
        for deletedType: RouteWorkType? in [nil, .pos] {
            let suite = "route-reimport-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let storage = RouteLocalStorage(defaults: defaults)
            let date = "2026-11-01"
            var day = RouteLocalStorage.defaultDay(for: date, settings: .default)
            day.sent = true
            day.distanceKm = 30
            storage.saveDay(day, immediately: true)
            storage.deleteDay(date, workType: deletedType)
            let importer = RouteImportHarness(storage: storage, date: date)
            importer.isDeletingArchivedDay = true
            precondition(!importer.autoImportClosedRequestsIfEmpty(requests), "Do not import while deletion is in progress")
            importer.isDeletingArchivedDay = false
            importer.areArchiveExclusionsReady = false
            precondition(importer.autoImportClosedRequestsIfEmpty(requests), "Deleted routes must allow closed request reimport")
            precondition(importer.record.stops[1].address == "Ялта, Ленина, 1")
            precondition(importer.record.stops[1].requestNumber == "000123")
            precondition(!importer.record.sent && importer.record.distanceKm == nil)
            precondition(storage.isExcluded(date), "Reimporting a draft must not restore the deleted report")
            storage.syncExcludedDates([deletedType?.exclusionKey(for: date) ?? date])
            let reopened = RouteImportHarness(storage: RouteLocalStorage(defaults: defaults), date: date)
            precondition(reopened.record == importer.record, "Imported addresses and numbers must survive reentry and exclusion sync")
            precondition(!reopened.autoImportClosedRequestsIfEmpty(requests), "Do not duplicate or overwrite existing points")
            let arm = RouteImportHarness(storage: storage, date: date, workType: .arm)
            precondition(!arm.autoImportClosedRequestsIfEmpty(requests), "Closed requests remain POS-only")
        }
        print("PASS: whole-day/scoped deletion permits closed request reimport; draft survives reload and does not restore the sent report")
    }

    static func testSameDayWorkTypeStart() {
        for sourceType in RouteWorkType.allCases { for finish in ["Дом", "Склад"] {
            let suite = "same-day-route-start-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let storage = RouteLocalStorage(defaults: defaults)
            storage.saveSettings(RouteSettings(warehouseAddress: "Склад", homeAddress: "Дом"))
            let date = "2026-11-01"
            let targetType: RouteWorkType = sourceType == .pos ? .arm : .pos
            // The target may have been viewed before the source was sent.
            _ = storage.loadDay(date, workType: targetType)
            var source = RouteLocalStorage.defaultDay(for: date, workType: sourceType, settings: storage.loadSettings())
            source.stops[source.stops.count - 1].address = finish
            source.sent = true
            storage.saveDay(source, immediately: true)
            precondition(storage.loadDay(date, workType: targetType).stops.first?.address == finish,
                         "Same-day sent report must supply the other type's start, including an existing draft")
            var manual = storage.loadDay(date, workType: targetType)
            manual.stops[0].address = finish == "Дом" ? "Склад" : "Дом"
            manual.hasManualEndpointSelection = true
            storage.saveDay(manual, immediately: true)
            precondition(storage.loadDay(date, workType: targetType).stops[0].address == manual.stops[0].address)
        } }
        print("PASS: POS/ARM inherit same-day sent home/warehouse finish and preserve manual starts")
    }

    static func testScopedDeletion() {
        for deletedType in RouteWorkType.allCases {
            let suite = "scoped-route-delete-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            var storage: RouteLocalStorage? = RouteLocalStorage(defaults: defaults)
            let date = "2026-11-01"
            for type in RouteWorkType.allCases {
                var day = RouteLocalStorage.defaultDay(for: date, workType: type, settings: .default)
                day.distanceKm = 12
                day.periodStartOdometer = 1000
                day.sent = true
                storage!.saveDay(day, immediately: true)
                storage!.enqueue(date, workType: type)
                storage!.saveAppleMileage(AppleRouteDistanceSnapshot(addresses: [], distanceKm: 12), for: type.storageKey(for: date))
            }
            storage!.deleteDay(date, workType: deletedType)
            storage = nil
            let reloaded = RouteLocalStorage(defaults: defaults)
            let otherType: RouteWorkType = deletedType == .pos ? .arm : .pos
            precondition(reloaded.loadAllDays().values.map(\.workType) == [otherType])
            precondition(reloaded.loadQueue().map(\.workType) == [otherType])
            precondition(reloaded.loadDailyMileageByDate().values.reduce(0, +) == 12)
            precondition(reloaded.loadAppleMileage(for: deletedType.storageKey(for: date)) == nil)
            precondition(reloaded.loadAppleMileage(for: otherType.storageKey(for: date)) != nil)
            precondition(reloaded.loadPeriodStartOdometer(for: "2026-11") == 1000)
            precondition(reloaded.isExcluded(date, workType: deletedType))
            precondition(!reloaded.isExcluded(date, workType: otherType))
            reloaded.finishExplicitRestore(date, workType: otherType)
            precondition(reloaded.isExcluded(date, workType: deletedType), "Sending the other type must not undo deletion")
            reloaded.beginExplicitRestore(date, workType: deletedType)
            precondition(reloaded.isPendingRestore(date, workType: deletedType))
            reloaded.syncExcludedDates([deletedType.exclusionKey(for: date)])
            precondition(reloaded.loadQueue().map(\.workType) == [otherType])
            reloaded.finishExplicitRestore(date, workType: deletedType)
            precondition(!reloaded.isExcluded(date, workType: deletedType))
        }
        print("PASS: scoped POS/ARM deletion preserves the other type, queue, mileage, Apple cache and monthly odometer across reload")
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
