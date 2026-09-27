import Foundation

extension String {
    nonisolated func normalizedAddressStartingFromAlushta() -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        let cities = ["Алушта", "Ялта", "Севастополь", "Симферополь", "Джанкой"]

        let firstMatchedRange = cities
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
}
