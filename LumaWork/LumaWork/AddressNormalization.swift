import Foundation

extension String {
    nonisolated private static let routeCities = ["Алушта", "Ялта", "Севастополь", "Симферополь", "Джанкой"]

    nonisolated func normalizedAddressStartingFromAlushta() -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)

        let firstMatchedRange = Self.routeCities
            .compactMap { city in
                trimmed.range(of: city, options: [.caseInsensitive])
            }
            .min { lhs, rhs in
                lhs.lowerBound < rhs.lowerBound
            }

        guard let cityRange = firstMatchedRange else {
            return trimmed
        }

        return String(trimmed[cityRange.lowerBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .normalizedAddressCommaSpacing()
    }

    nonisolated func normalizedAddressCommaSpacing() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: "\\s*,\\s*",
                with: ", ",
                options: .regularExpression
            )
    }

    nonisolated func qualifiedRouteAddress() -> String {
        let address = normalizedAddressCommaSpacing()
        guard !address.isEmpty else { return address }
        let hasExplicitCity = Self.routeCities.contains { address.localizedCaseInsensitiveContains($0) }
        return hasExplicitCity ? address : "Алушта, \(address)"
    }
}
