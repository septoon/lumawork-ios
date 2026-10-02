import Foundation
import OSLog

nonisolated struct AppOfflineSnapshot<Value: Codable>: Codable {
    let updatedAt: Date
    let value: Value
}

nonisolated enum AppOfflineSnapshotStore {
    private struct SnapshotMetadata: Decodable {
        let updatedAt: Date
    }

    static func load<Value: Codable>(
        _ type: Value.Type,
        key: String
    ) -> AppOfflineSnapshot<Value>? {
        guard let data = try? Data(contentsOf: fileURL(for: key)) else { return nil }
        return try? JSONDecoder().decode(AppOfflineSnapshot<Value>.self, from: data)
    }

    static func save<Value: Codable>(_ value: Value, key: String) {
        let snapshot = AppOfflineSnapshot(updatedAt: Date(), value: value)
        let url = fileURL(for: key)

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(snapshot).write(to: url, options: [.atomic])
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        } catch {
            NetworkDiagnostics.logger.error(
                "Offline snapshot save failed: \(key, privacy: .public) \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    static func scopedKey(_ name: String, userID: String?) -> String {
        let normalizedUserID = normalizedUserID(userID)
        guard let normalizedUserID, !normalizedUserID.isEmpty else { return name }
        return "\(name)-\(normalizedUserID)"
    }

    static func latestUpdatedAt(userID: String?) -> Date? {
        let directoryURL = snapshotsDirectoryURL()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let userSuffix = normalizedUserID(userID).map { "-\($0).json" }
        let decoder = JSONDecoder()

        return files.compactMap { fileURL in
            if let userSuffix,
               !fileURL.lastPathComponent.hasSuffix(userSuffix) {
                return nil
            }
            guard let data = try? Data(contentsOf: fileURL),
                  let metadata = try? decoder.decode(SnapshotMetadata.self, from: data) else {
                return nil
            }
            return metadata.updatedAt
        }
        .max()
    }

    private static func fileURL(for key: String) -> URL {
        let safeKey = key.replacingOccurrences(
            of: #"[^a-zA-Z0-9._-]"#,
            with: "-",
            options: .regularExpression
        )
        return snapshotsDirectoryURL()
            .appendingPathComponent("\(safeKey).json", isDirectory: false)
    }

    private static func snapshotsDirectoryURL() -> URL {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("LumaWork", isDirectory: true)
            .appendingPathComponent("OfflineSnapshots", isDirectory: true)
    }

    private static func normalizedUserID(_ userID: String?) -> String? {
        userID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"[^a-zA-Z0-9._-]"#,
                with: "-",
                options: .regularExpression
            )
    }
}
