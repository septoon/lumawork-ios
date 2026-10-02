import Foundation
import MapKit

nonisolated enum AppleRouteDistanceError: LocalizedError {
    case incompleteRoute
    case addressNotFound(String)
    case ambiguousAddress(String)
    case geocodingFailed(String)
    case directionsUnavailable
    case directionsFailed(String, String)

    static func geocodingFailure(for address: String, error: Error) -> Self {
        let nativeError = error as NSError
        if nativeError.domain == MKErrorDomain, nativeError.code == MKError.Code.placemarkNotFound.rawValue {
            return .addressNotFound(address)
        }
        return .geocodingFailed(address)
    }

    var errorDescription: String? {
        switch self {
        case .incompleteRoute:
            return "Заполните адреса всех точек маршрута."
        case .addressNotFound(let address):
            return "Apple Maps не нашёл адрес: \(address)."
        case .ambiguousAddress(let address):
            return "Уточните адрес для Apple Maps: \(address)."
        case .geocodingFailed(let address):
            return "Apple Maps не удалось определить положение точки: \(address). Повторите расчёт или уточните адрес."
        case .directionsUnavailable:
            return "Apple Maps не удалось построить автомобильный маршрут."
        case .directionsFailed(let source, let destination):
            return "Apple Maps не удалось построить автомобильный маршрут между точками «\(source)» и «\(destination)»."
        }
    }
}

nonisolated struct AppleRoutePlan: Equatable {
    let addresses: [String]
    let coordinateOverrides: [AppleRouteCoordinate?]

    init(addresses: [String], coordinateOverrides: [AppleRouteCoordinate?] = []) {
        self.addresses = addresses.map { $0.normalizedAddressCommaSpacing() }
        self.coordinateOverrides = addresses.indices.map { index in
            guard coordinateOverrides.indices.contains(index),
                  let coordinate = coordinateOverrides[index], coordinate.isValid else { return nil }
            return coordinate
        }
    }

    init(stops: [RouteStop], remembered: [String: AppleRouteCoordinate] = [:]) {
        self.init(addresses: stops.map(\.address), coordinateOverrides: stops.map {
            $0.coordinateOverride ?? remembered[$0.address.routeCoordinateKey]
        })
    }

    var isEmpty: Bool {
        addresses.count < 3 || addresses.dropFirst().dropLast().allSatisfy(\.isEmpty)
    }

    var isComplete: Bool {
        !isEmpty && addresses.allSatisfy { !$0.isEmpty }
    }

    // Keep the explicit final endpoint, even when it repeats the first one.
    func distanceKm(
        legDistance: (String, String) async throws -> Double
    ) async throws -> Int {
        try Task.checkCancellation()
        guard !isEmpty else { return 0 }
        guard isComplete else { throw AppleRouteDistanceError.incompleteRoute }
        var totalMeters = 0.0
        for index in 0..<(addresses.count - 1) {
            let start = addresses[index]
            let finish = addresses[index + 1]
            try Task.checkCancellation()
            if start == finish, coordinateOverrides[index] == coordinateOverrides[index + 1] { continue }
            let meters = try await legDistance(start, finish)
            try Task.checkCancellation()
            guard meters.isFinite, meters >= 0 else {
                throw AppleRouteDistanceError.directionsUnavailable
            }
            totalMeters += meters
        }
        return Int(ceil(totalMeters / 1_000))
    }
}

nonisolated struct AppleRouteCoordinate: Codable, Hashable, Sendable {
    let latitude: Double
    let longitude: Double

    var isValid: Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }
}

nonisolated struct AppleRouteLeg: Codable, Sendable {
    let distanceMeters: Double
    let coordinates: [AppleRouteCoordinate]
}

nonisolated struct AppleRouteDistanceSnapshot: Codable, Sendable {
    static let currentGeocodingVersion = 3

    let addresses: [String]
    let distanceKm: Int
    var stopCoordinates: [AppleRouteCoordinate]? = nil
    var legs: [AppleRouteLeg]? = nil
    var coordinateOverrides: [AppleRouteCoordinate?]? = nil
    var unverifiedStopIndices: [Int]? = nil
    var routingIncomplete: Bool? = nil
    var failedLegIndex: Int? = nil
    var geocodingVersion: Int? = currentGeocodingVersion

    var routingFailureDescription: String? {
        guard routingIncomplete == true else { return nil }
        guard let index = failedLegIndex, index >= 0, index < addresses.count - 1 else {
            return AppleRouteDistanceError.directionsUnavailable.localizedDescription
        }
        return AppleRouteDistanceError.directionsFailed(addresses[index], addresses[index + 1]).localizedDescription
    }

    func matches(_ plan: AppleRoutePlan) -> Bool {
        addresses == plan.addresses && (coordinateOverrides ?? addresses.map { _ in nil }) == plan.coordinateOverrides
    }

    var hasGeometry: Bool {
        stopCoordinates?.count == addresses.count && legs != nil
    }
}

@available(iOS 26.0, macOS 26.0, *)
@MainActor
final class AppleRouteDistanceCalculator {
    private struct Leg: Hashable {
        let start: AppleRouteCoordinate
        let finish: AppleRouteCoordinate
    }
    private struct ResolvedAddress {
        let item: MKMapItem
        let verified: Bool
    }
    private var mapItems: [String: ResolvedAddress] = [:]
    private var routeLegs: [Leg: AppleRouteLeg] = [:]

    func clearGeocodingCache() { mapItems.removeAll() }

    func route(for plan: AppleRoutePlan) async throws -> AppleRouteDistanceSnapshot {
        guard !plan.isEmpty else {
            return AppleRouteDistanceSnapshot(addresses: plan.addresses, distanceKm: 0)
        }
        guard plan.isComplete else { throw AppleRouteDistanceError.incompleteRoute }
        var items: [MKMapItem] = []
        var unverified: Set<Int> = []
        for index in plan.addresses.indices {
            try Task.checkCancellation()
            if let coordinate = plan.coordinateOverrides[index] {
                items.append(MKMapItem(location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), address: nil))
            } else {
                let result = try await mapItem(for: plan.addresses[index])
                items.append(result.item)
                if !result.verified { unverified.insert(index) }
            }
        }
        let stops = items.map { AppleRouteCoordinate($0.location.coordinate) }
        // Different addresses resolving to the same place deserve confirmation.
        for index in stops.indices where plan.coordinateOverrides[index] == nil {
            if stops.indices.contains(where: { other in
                other != index && plan.addresses[other].routeCoordinateKey != plan.addresses[index].routeCoordinateKey
                    && items[other].location.distance(from: items[index].location) < 10
            }) { unverified.insert(index) }
        }
        var legs: [AppleRouteLeg] = []
        var meters = 0.0
        for index in 0..<(items.count - 1) {
            do {
                let leg = try await leg(from: items[index], to: items[index + 1])
                legs.append(leg)
                meters += leg.distanceMeters
            } catch {
                try Task.checkCancellation()
                // Keep the points editable even if road directions fail.
                return AppleRouteDistanceSnapshot(addresses: plan.addresses, distanceKm: 0,
                    stopCoordinates: stops, legs: [], coordinateOverrides: plan.coordinateOverrides,
                    unverifiedStopIndices: unverified.sorted(), routingIncomplete: true, failedLegIndex: index)
            }
        }
        try Task.checkCancellation()
        return AppleRouteDistanceSnapshot(addresses: plan.addresses, distanceKm: Int(ceil(meters / 1_000)),
            stopCoordinates: stops, legs: legs, coordinateOverrides: plan.coordinateOverrides,
            unverifiedStopIndices: unverified.sorted())
    }

    private func leg(from source: MKMapItem, to destination: MKMapItem) async throws -> AppleRouteLeg {
        try Task.checkCancellation()
        let leg = Leg(start: AppleRouteCoordinate(source.location.coordinate), finish: AppleRouteCoordinate(destination.location.coordinate))
        if let cached = routeLegs[leg] { return cached }
        if leg.start == leg.finish {
            let result = AppleRouteLeg(distanceMeters: 0, coordinates: [leg.start])
            routeLegs[leg] = result
            return result
        }

        let request = MKDirections.Request()
        request.source = source
        request.destination = destination
        request.transportType = .automobile
        request.requestsAlternateRoutes = false
        let directions = MKDirections(request: request)
        let response = try await withTaskCancellationHandler {
            try await directions.calculate()
        } onCancel: {
            Task { @MainActor in directions.cancel() }
        }
        try Task.checkCancellation()
        guard let route = response.routes.first, route.distance.isFinite, route.distance >= 0 else {
            throw AppleRouteDistanceError.directionsUnavailable
        }
        let polyline = route.polyline
        var coordinates = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: polyline.pointCount)
        polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: polyline.pointCount))
        let result = AppleRouteLeg(distanceMeters: route.distance, coordinates: coordinates.map(AppleRouteCoordinate.init))
        routeLegs[leg] = result
        return result
    }

    private func mapItem(for address: String) async throws -> ResolvedAddress {
        let query = address.qualifiedAppleRouteAddress()
        if let cached = mapItems[query] { return cached }
        try Task.checkCancellation()
        var items: [MKMapItem]
        var searchQuery = query
        do {
            items = try await geocode(query)
        } catch {
            try Task.checkCancellation()
            let nativeError = error as NSError
            guard nativeError.domain == MKErrorDomain, nativeError.code == MKError.Code.placemarkNotFound.rawValue else {
                throw AppleRouteDistanceError.geocodingFailure(for: address, error: error)
            }
            items = []
        }
        if items.isEmpty, let fallback = address.appleRouteStreetFallbackAddress() {
            do {
                items = try await geocode(fallback).filter {
                    AppleRouteAddressValidation.matchesStreet(query: query, found: $0.address?.fullAddress ?? "")
                }
                searchQuery = fallback
            } catch {
                try Task.checkCancellation()
                throw AppleRouteDistanceError.geocodingFailure(for: address, error: error)
            }
        }
        try Task.checkCancellation()
        var candidates = items
        var verified = candidates.filter { AppleRouteAddressValidation.matches(query: query, found: $0.address?.fullAddress ?? "") }
        if verified.count != 1 {
            let searchRequest = MKLocalSearch.Request()
            searchRequest.naturalLanguageQuery = searchQuery
            searchRequest.resultTypes = .address
            if let location = items.first?.location {
                searchRequest.region = MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 30_000, longitudinalMeters: 30_000)
            }
            let search = MKLocalSearch(request: searchRequest)
            do {
                let response = try await withTaskCancellationHandler {
                    try await search.start()
                } onCancel: {
                    Task { @MainActor in search.cancel() }
                }
                try Task.checkCancellation()
                let searchItems = response.mapItems.filter {
                    searchQuery == query || AppleRouteAddressValidation.matchesStreet(query: query, found: $0.address?.fullAddress ?? "")
                }
                let matches = searchItems.filter { AppleRouteAddressValidation.matches(query: query, found: $0.address?.fullAddress ?? "") }
                if matches.count == 1 { verified = matches }
                if candidates.isEmpty { candidates = searchItems }
            } catch {
                try Task.checkCancellation()
                // Retain a suspect candidate so the user can correct it on the map.
            }
        }
        guard let item = verified.count == 1 ? verified.first : candidates.first else {
            throw AppleRouteDistanceError.addressNotFound(address)
        }
        let result = ResolvedAddress(item: item, verified: verified.count == 1)
        mapItems[query] = result
        return result
    }

    private func geocode(_ query: String) async throws -> [MKMapItem] {
        guard let request = MKGeocodingRequest(addressString: query) else { return [] }
        request.preferredLocale = Locale(identifier: "ru_RU")
        return try await withTaskCancellationHandler {
            try await request.mapItems
        } onCancel: {
            Task { @MainActor in request.cancel() }
        }
    }
}

nonisolated enum AppleRouteAddressValidation {
    private static let ignored: Set<String> = ["улица", "ул", "д", "дом", "г", "город", "проспект", "пр", "т", "переулок", "пер", "шоссе", "ш", "площадь", "пл", "проезд", "бульвар", "б", "р", "набережная"]

    static func matches(query: String, found: String) -> Bool {
        let parts = query.qualifiedAppleRouteAddress().components(separatedBy: ", ")
        guard parts.count >= 3, parts.last?.first?.isNumber == true,
              matchesStreet(query: query, found: found) else { return false }
        let actual = Set(tokens(found))
        let house = tokens(parts.dropFirst(2).joined(separator: ", ")).filter { !ignored.contains($0) }
        return !house.isEmpty && house.allSatisfy { actual.contains($0) }
    }

    static func matchesStreet(query: String, found: String) -> Bool {
        let parts = query.qualifiedAppleRouteAddress().components(separatedBy: ", ")
        guard parts.count >= 2 else { return false }
        let actual = Set(tokens(found))
        let city = tokens(parts[0]).filter { !ignored.contains($0) }
        // Keep Набережная when it is the street name rather than the street type.
        let street = tokens(parts[1]).filter { !ignored.contains($0) || $0 == "набережная" }
        return !city.isEmpty && !street.isEmpty && (city + street).allSatisfy { actual.contains($0) }
    }

    private static func tokens(_ value: String) -> [String] {
        value.lowercased(with: Locale(identifier: "ru_RU"))
            .replacingOccurrences(of: "ё", with: "е")
            .replacingOccurrences(of: "(\\d)[-\\s]+([а-яa-z])(?=$|[,\\s])", with: "$1$2", options: .regularExpression)
            .split { !$0.isLetter && !$0.isNumber && $0 != "/" }.map(String.init)
    }
}
