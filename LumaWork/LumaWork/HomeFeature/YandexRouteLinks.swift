import Foundation

nonisolated enum YandexRouteLinks {
    private static let defaultCity = "Алушта"
    private static let explicitCities = [
        "Алушта",
        "Ялта",
        "Севастополь",
        "Симферополь",
        "Джанкой"
    ]
    private static let badRoadAvoidance = "unpaved,poor_condition"

    static func webURL(baseURL: String?, addresses: [String]) -> URL? {
        guard let routePoints = routePoints(from: addresses),
              let baseURL,
              var components = URLComponents(string: baseURL) else {
            return nil
        }

        components.queryItems = routeQueryItems(routePoints: routePoints)
        return components.url
    }

    private static func routePoints(from addresses: [String]) -> [String]? {
        let points = addresses
            .map { $0.normalizedAddressCommaSpacing() }
            .filter { !$0.isEmpty }
            .map(qualifyCityIfNeeded)

        return points.count >= 2 ? points : nil
    }

    private static func qualifyCityIfNeeded(_ address: String) -> String {
        let hasExplicitCity = explicitCities.contains { city in
            address.localizedCaseInsensitiveContains(city)
        }
        return hasExplicitCity ? address : "\(defaultCity), \(address)"
    }

    private static func routeQueryItems(routePoints: [String]) -> [URLQueryItem] {
        [
            URLQueryItem(name: "rtext", value: routePoints.joined(separator: "~")),
            URLQueryItem(name: "rtt", value: "auto"),
            URLQueryItem(name: "routes[avoid]", value: badRoadAvoidance)
        ]
    }
}
