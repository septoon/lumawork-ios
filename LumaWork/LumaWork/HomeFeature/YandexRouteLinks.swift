import Foundation

nonisolated enum YandexRouteLinks {
    private static let badRoadAvoidance = "unpaved,poor_condition"

    static func webURL(baseURL: String?, addresses: [String], coordinateOverrides: [AppleRouteCoordinate?] = []) -> URL? {
        guard let routePoints = routePoints(from: addresses, coordinateOverrides: coordinateOverrides),
              let baseURL,
              var components = URLComponents(string: baseURL) else {
            return nil
        }

        components.queryItems = routeQueryItems(routePoints: routePoints)
        return components.url
    }

    private static func routePoints(from addresses: [String], coordinateOverrides: [AppleRouteCoordinate?]) -> [String]? {
        let points = addresses.indices.compactMap { index -> String? in
            let address = addresses[index].normalizedAddressCommaSpacing()
            guard !address.isEmpty else { return nil }
            if coordinateOverrides.indices.contains(index), let coordinate = coordinateOverrides[index], coordinate.isValid {
                return "\(coordinate.latitude),\(coordinate.longitude)"
            }
            return address.qualifiedRouteAddress()
        }
        return points.count >= 2 ? points : nil
    }

    private static func routeQueryItems(routePoints: [String]) -> [URLQueryItem] {
        [
            URLQueryItem(name: "rtext", value: routePoints.joined(separator: "~")),
            URLQueryItem(name: "rtt", value: "auto"),
            URLQueryItem(name: "routes[avoid]", value: badRoadAvoidance)
        ]
    }
}
