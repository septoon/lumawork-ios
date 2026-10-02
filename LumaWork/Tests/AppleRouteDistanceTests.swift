import Foundation

@main
struct AppleRouteDistanceTests {
    static func main() async throws {
        let plan = AppleRoutePlan(addresses: ["Склад", "A", "B", "C", "Склад"])
        let meters = ["Склад→A": 12_400.0, "A→B": 7_800.0, "B→C": 21_300.0, "C→Склад": 9_600.0]
        let total = try await plan.distanceKm { start, finish in
            guard let distance = meters["\(start)→\(finish)"] else {
                fatalError("Unexpected leg: \(start)→\(finish)")
            }
            return distance
        }
        expect(total == 52, "51.1 km includes return leg and rounds up once")

        let shortPlan = AppleRoutePlan(addresses: ["Склад", "A", "Склад"])
        let shortTotal = try await shortPlan.distanceKm { _, _ in 100 }
        expect(shortTotal == 1, "round total, not each 0.1 km leg")
        let exactTotal = try await shortPlan.distanceKm { _, _ in 500 }
        expect(exactTotal == 1, "whole kilometers do not gain an extra kilometer")
        let repeated = AppleRoutePlan(addresses: ["Склад", "A", "A", "Склад"])
        let repeatedTotal = try await repeated.distanceKm { start, finish in
            expect(start != finish, "same consecutive address must not request directions")
            return 500
        }
        expect(repeatedTotal == 1, "duplicate stop adds no extra distance")

        expect("Хромых,11".qualifiedRouteAddress() == "Алушта, Хромых, 11", "short address keeps route city")
        expect("Ялта,Ленина,1".qualifiedRouteAddress() == "Ялта, Ленина, 1", "explicit city is preserved")
        expect("Алушта, ул Набережная, д 9".qualifiedAppleRouteAddress() == "Алушта, улица Набережная, 9",
               "Apple query retains a recognizable house number instead of resolving the entire street")
        expect("Набережная улица, 9".qualifiedAppleRouteAddress() == "Алушта, Набережная улица, 9",
               "Apple query preserves an already complete street address")
        expect("Ялта, ул. Ленина, д. 1".qualifiedAppleRouteAddress() == "Ялта, улица Ленина, 1",
               "Apple query preserves the explicit city")
        expect("Алушта, ул Горького, д 6-в".qualifiedAppleRouteAddress() == "Алушта, улица Горького, 6-в",
               "Apple query preserves the building suffix")
        expect("Алушта, ул Партизанская, д 5б".qualifiedAppleRouteAddress() == "Алушта, улица Партизанская, 5б",
               "Apple query preserves a building letter without a separator")
        expect("Алушта, ул. В. Хромых, 11".qualifiedAppleRouteAddress() == "Алушта, улица В. Хромых, 11",
               "Apple query preserves initials in a street name")
        expect("Алушта, Набережная, 25".qualifiedAppleRouteAddress() == "Алушта, улица Набережная, 25",
               "bare street name must not resolve to the Satera road")
        expect("Хромых,11".qualifiedAppleRouteAddress() == "Алушта, улица Хромых, 11",
               "short route address gains the city and street type")
        expect("Ялта, Ленина, 1".qualifiedAppleRouteAddress() == "Ялта, улица Ленина, 1",
               "bare street name keeps the explicit city")
        expect("Алушта, Советский переулок, 3".qualifiedAppleRouteAddress() == "Алушта, Советский переулок, 3",
               "an explicit lane must not become a street")
        expect("Алушта, пр-т Ленина, 1".qualifiedAppleRouteAddress() == "Алушта, пр-т Ленина, 1",
               "an explicit avenue abbreviation must not become a street")
        expect("Алушта, набережная Ленина, 1".qualifiedAppleRouteAddress() == "Алушта, набережная Ленина, 1",
               "a named embankment must keep its type")
        let emptyTotal = try await AppleRoutePlan(addresses: ["Склад", "", "Склад"]).distanceKm { _, _ in
            fatalError("Empty day must not request directions")
        }
        expect(emptyTotal == 0, "empty day shows zero")

        do {
            _ = try await AppleRoutePlan(addresses: ["Склад", "A", " ", "Склад"]).distanceKm { _, _ in
                fatalError("Incomplete route must not request directions")
            }
            fatalError("Missing address was skipped")
        } catch AppleRouteDistanceError.incompleteRoute {}

        do {
            _ = try await shortPlan.distanceKm { start, _ in
                if start == "A" { throw FixtureError.noRoute }
                return 12_400
            }
            fatalError("Failed return leg produced a partial total")
        } catch FixtureError.noRoute {}

        do {
            _ = try await shortPlan.distanceKm { _, _ in .nan }
            fatalError("Invalid distance produced a total")
        } catch AppleRouteDistanceError.directionsUnavailable {}

        let cancelled = Task {
            try await shortPlan.distanceKm { _, _ in
                try await Task.sleep(for: .seconds(1))
                return 100
            }
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            fatalError("Cancelled calculation returned a total")
        } catch is CancellationError {}

        let decoder = JSONDecoder()
        let legacySettings = try decoder.decode(RouteSettings.self, from: Data("{\"warehouseAddress\":\"Склад\",\"homeAddress\":\"Дом\"}".utf8))
        expect(legacySettings.mapsProvider == .yandex, "existing settings default to Yandex")
        var settings = legacySettings
        settings.mapsProvider = .apple
        let restoredSettings = try decoder.decode(RouteSettings.self, from: JSONEncoder().encode(settings))
        expect(restoredSettings.mapsProvider == .apple, "Apple selection survives restart")
        expect(RouteLocalStorage.migrateLegacyOfficeAddress(in: settings).mapsProvider == .apple,
               "address migration must preserve the selected maps provider")

        let snapshot = AppleRouteDistanceSnapshot(addresses: shortPlan.addresses, distanceKm: 52)
        expect(RouteMapsProvider.yandex.reportDistanceKm(manualKm: 19, apple: snapshot, plan: shortPlan, isCalculating: false) == 19,
               "Yandex report uses only manual mileage")
        expect(RouteMapsProvider.apple.reportDistanceKm(manualKm: 19, apple: snapshot, plan: shortPlan, isCalculating: false) == 52,
               "Apple report replaces manual mileage")
        expect(RouteMapsProvider.apple.reportDistanceKm(manualKm: 19, apple: nil, plan: shortPlan, isCalculating: false) == nil,
               "Apple cannot fall back to manual mileage after an error")
        expect(RouteMapsProvider.apple.reportDistanceKm(manualKm: 19, apple: snapshot, plan: shortPlan, isCalculating: true) == nil,
               "Apple cannot send during recalculation")
        expect(RouteMapsProvider.apple.reportDistanceKm(manualKm: 19, apple: snapshot,
               plan: AppleRoutePlan(addresses: ["Склад", "B", "Склад"]), isCalculating: false) == nil,
               "Apple cannot send stale mileage after changing a point")

        let legacySnapshot = try decoder.decode(AppleRouteDistanceSnapshot.self, from: Data("{\"addresses\":[\"Склад\",\"A\",\"Склад\"],\"distanceKm\":52}".utf8))
        expect(!legacySnapshot.hasGeometry, "old distance-only cache must rebuild geometry before opening the map")

        let suiteName = "AppleRouteDistanceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storage = RouteLocalStorage(defaults: defaults)
        defaults.set(Data("[{\"date\":\"2026-10-02\",\"workType\":\"POS\"}]".utf8), forKey: "route.pwa.queue")
        expect(storage.loadQueue().first?.mapsProvider == .yandex, "legacy queued reports retain manual mileage")
        storage.enqueue("2026-10-02", mapsProvider: .apple)
        expect(storage.loadQueue().count == 1, "resending the same day updates its queue item")
        let restoredStorage = RouteLocalStorage(defaults: defaults)
        expect(restoredStorage.loadQueue().first?.mapsProvider == .apple, "queue retains Apple source even after switching settings")
        let oldGeometryCache = """
        {"2026-10-01":{"addresses":["Склад","A","Склад"],"distanceKm":22,"geocodingVersion":1,
        "stopCoordinates":[{"latitude":44.67,"longitude":34.41},
        {"latitude":44.67,"longitude":34.41},{"latitude":44.67,"longitude":34.41}],"legs":[]}}
        """
        defaults.set(Data(oldGeometryCache.utf8), forKey: "route.apple-map-mileages")
        expect(storage.loadAppleMileage(for: "2026-10-01") == nil,
               "old geocoding cache must not supply wrong coordinates or queued report mileage")
        defaults.set(Data(oldGeometryCache.replacingOccurrences(of: ",\"geocodingVersion\":1", with: "").utf8),
                     forKey: "route.apple-map-mileages")
        expect(storage.loadAppleMileage(for: "2026-10-01") == nil,
               "unversioned geocoding cache must also be recalculated")
        storage.saveAppleMileage(snapshot, for: "2026-10-02")
        let restoredSnapshot = restoredStorage.loadAppleMileage(for: "2026-10-02")
        expect(restoredSnapshot?.distanceKm == 52, "Apple mileage survives restart independently of manual mileage")
        print("Apple route distance tests passed")
    }

    enum FixtureError: Error { case noRoute }

    static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
    }
}

// The standalone test executable has no UIKit app theme.
nonisolated enum AppLocale {
    static let russian = Locale(identifier: "ru_RU")
}
