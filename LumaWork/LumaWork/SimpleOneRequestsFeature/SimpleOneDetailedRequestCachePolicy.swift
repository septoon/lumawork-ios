import Foundation

nonisolated enum SimpleOneDetailedRequestCachePolicy {
    static func isFresh(
        cachedAt: Date,
        cachedVersion: String,
        currentVersion: String,
        now: Date = Date(),
        lifetime: TimeInterval
    ) -> Bool {
        let normalizedCachedVersion = cachedVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCurrentVersion = currentVersion.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedCurrentVersion.isEmpty else { return false }

        return normalizedCachedVersion == normalizedCurrentVersion
    }
}
