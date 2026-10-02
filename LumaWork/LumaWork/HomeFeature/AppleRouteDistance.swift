import Foundation
import MapKit

nonisolated enum AppleRouteDistanceError: LocalizedError {
    case incompleteRoute
    case addressNotFound(String)
    case ambiguousAddress(String)
    case directionsUnavailable

    var errorDescription: String? {
        switch self {
        case .incompleteRoute:
            return "Заполните адреса всех точек маршрута."
        case .addressNotFound(let address):
            return "Apple Maps не нашёл адрес: \(address)."
        case .ambiguousAddress(let address):
            return "Уточните адрес для Apple Maps: \(address)."
        case .directionsUnavailable:
            return "Apple Maps не удалось построить автомобильный маршрут."
        }
    }
}

nonisolated struct AppleRoutePlan: Equatable {
    let addresses: [String]

    init(addresses: [String]) {
        self.addresses = addresses.map { $0.normalizedAddressCommaSpacing() }
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
        for (start, finish) in zip(addresses, addresses.dropFirst()) {
            try Task.checkCancellation()
            if start == finish { continue }
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
    let addresses: [String]
    let distanceKm: Int
    var stopCoordinates: [AppleRouteCoordinate]? = nil
    var legs: [AppleRouteLeg]? = nil

    var hasGeometry: Bool {
        stopCoordinates?.count == addresses.count && legs != nil
    }
}

@available(iOS 26.0, macOS 26.0, *)
@MainActor
final class AppleRouteDistanceCalculator {
    private struct Leg: Hashable {
        let start: String
        let finish: String
    }

    private var mapItems: [String: MKMapItem] = [:]
    private var routeLegs: [Leg: AppleRouteLeg] = [:]

    func route(for plan: AppleRoutePlan) async throws -> AppleRouteDistanceSnapshot {
        guard !plan.isEmpty else {
            return AppleRouteDistanceSnapshot(addresses: plan.addresses, distanceKm: 0)
        }
        guard plan.isComplete else { throw AppleRouteDistanceError.incompleteRoute }
        var stops: [AppleRouteCoordinate] = []
        for address in plan.addresses {
            let item = try await mapItem(for: address)
            stops.append(AppleRouteCoordinate(item.location.coordinate))
        }
        var legs: [AppleRouteLeg] = []
        let distanceKm = try await plan.distanceKm { start, finish in
            let leg = try await self.leg(from: start, to: finish)
            legs.append(leg)
            return leg.distanceMeters
        }
        return AppleRouteDistanceSnapshot(
            addresses: plan.addresses, distanceKm: distanceKm, stopCoordinates: stops, legs: legs
        )
    }

    private func leg(from start: String, to finish: String) async throws -> AppleRouteLeg {
        let leg = Leg(start: start, finish: finish)
        if let cached = routeLegs[leg] { return cached }
        let source = try await mapItem(for: start)
        let destination = try await mapItem(for: finish)
        try Task.checkCancellation()
        let sourceCoordinate = source.location.coordinate
        let destinationCoordinate = destination.location.coordinate
        if sourceCoordinate.latitude == destinationCoordinate.latitude,
           sourceCoordinate.longitude == destinationCoordinate.longitude {
            let result = AppleRouteLeg(distanceMeters: 0, coordinates: [AppleRouteCoordinate(sourceCoordinate)])
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

    private func mapItem(for address: String) async throws -> MKMapItem {
        if let cached = mapItems[address] { return cached }
        try Task.checkCancellation()
        guard let request = MKGeocodingRequest(addressString: address.qualifiedRouteAddress()) else {
            throw AppleRouteDistanceError.addressNotFound(address)
        }
        request.preferredLocale = Locale(identifier: "ru_RU")
        let items = try await withTaskCancellationHandler {
            try await request.mapItems
        } onCancel: {
            Task { @MainActor in request.cancel() }
        }
        try Task.checkCancellation()
        guard let item = items.first else {
            throw AppleRouteDistanceError.addressNotFound(address)
        }
        guard items.count == 1 else {
            throw AppleRouteDistanceError.ambiguousAddress(address)
        }
        mapItems[address] = item
        return item
    }
}
