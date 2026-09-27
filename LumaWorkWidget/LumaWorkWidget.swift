import SwiftUI
import WidgetKit

struct LumaWorkWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct LumaWorkWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> LumaWorkWidgetEntry {
        LumaWorkWidgetEntry(date: Date(), snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (LumaWorkWidgetEntry) -> Void) {
        completion(LumaWorkWidgetEntry(date: Date(), snapshot: loadSnapshot() ?? .preview))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LumaWorkWidgetEntry>) -> Void) {
        let now = Date()
        let entry = LumaWorkWidgetEntry(date: now, snapshot: loadSnapshot())
        completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(30 * 60))))
    }

    private func loadSnapshot() -> WidgetSnapshot? {
        WidgetSnapshotStore()?.load()
    }
}

@main
struct LumaWorkSummaryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: LumaWorkSharedConfiguration.widgetKind,
            provider: LumaWorkWidgetProvider()
        ) { entry in
            LumaWorkWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("LumaWork")
        .description("Активные заявки и маршрут на сегодня.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private extension WidgetSnapshot {
    static var preview: WidgetSnapshot {
        let now = Date()
        return WidgetSnapshot(
            version: currentVersion,
            generatedAt: now,
            sourceUpdatedAt: now,
            isAuthenticated: true,
            activeRequestCount: 7,
            overdueRequestCount: 2,
            requests: [
                WidgetRequestItem(
                    id: "preview-request",
                    number: "DEMO-0001",
                    state: "В работе",
                    deadline: now.addingTimeInterval(90 * 60),
                    isOverdue: true
                )
            ],
            route: WidgetRouteSummary(
                workType: "Заявки",
                completedStops: 3,
                totalStops: 6,
                distanceKm: 42,
                isSent: false
            )
        )
    }
}
