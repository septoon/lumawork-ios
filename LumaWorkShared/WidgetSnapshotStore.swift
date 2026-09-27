import Foundation

nonisolated enum LumaWorkSharedConfiguration {
    static let appGroupIdentifier = "group.septon.LumaWork"
    static let widgetKind = "LumaWorkSummaryWidget"
    static let snapshotFileName = "widget-snapshot.json"
}

nonisolated struct WidgetSnapshotStore {
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    init?(appGroupIdentifier: String = LumaWorkSharedConfiguration.appGroupIdentifier) {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            return nil
        }
        fileURL = containerURL.appendingPathComponent(
            LumaWorkSharedConfiguration.snapshotFileName,
            isDirectory: false
        )
    }

    func load() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data),
              snapshot.version == WidgetSnapshot.currentVersion else {
            return nil
        }
        return snapshot
    }

    func save(_ snapshot: WidgetSnapshot) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }
}
