import Foundation
import SwiftUI

struct ClosedRequestsAnalyticsContent: View {
    let snapshot: ClosedRequestsSnapshot?
    let records: [ClosedRequestRecord]
    let showsCloseButton: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var selectedMonthID: String?
    @State private var analytics: ClosedRequestsAnalyticsData

    private let summaryColumns = [
        GridItem(.flexible(minimum: 0), spacing: 10),
        GridItem(.flexible(minimum: 0), spacing: 10)
    ]
    private let calendarColumns = Array(repeating: GridItem(.flexible(minimum: 0), spacing: 6), count: 7)

    init(
        snapshot: ClosedRequestsSnapshot?,
        records: [ClosedRequestRecord],
        showsCloseButton: Bool = true
    ) {
        self.snapshot = snapshot
        self.records = records
        self.showsCloseButton = showsCloseButton
        _analytics = State(initialValue: ClosedRequestsAnalyticsData(records: records))
    }

    var body: some View {
        AppScreen {
            LazyVStack(alignment: .leading, spacing: 12) {
                summaryCards
                sourceCard
                monthlyChartCard
                monthlyDistributionCard
                requestTypeDistributionCard
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Аналитика")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .topBarTrailing) {
                    ModalCloseButton(action: dismiss.callAsFunction)
                }
            }
        }
        .onChange(of: records) { _, newValue in
            analytics = ClosedRequestsAnalyticsData(records: newValue)
            if let selectedMonthID, analytics.monthlyItem(id: selectedMonthID) == nil {
                self.selectedMonthID = nil
            }
        }
    }

    private var summaryCards: some View {
        LazyVGrid(columns: summaryColumns, spacing: 10) {
            ForEach(summaryItems) { item in
                AnalyticsSummaryCard(item: item)
            }
        }
    }

    @ViewBuilder
    private var sourceCard: some View {
        if let snapshot {
            AppCard {
                AppSectionHeader(
                    title: "Сводка"
                )
                AppStatRow(title: "Последнее обновление", value: Self.importedAtFormatter.string(from: snapshot.importedAt))
                AppStatRow(title: "Возврат ТО", value: "\(analytics.returnEquipCount)", accent: AppTheme.secondaryTint)
                AppStatRow(title: "Топ месяц", value: topMonthSummary, accent: AppTheme.primaryTint)
                AppStatRow(title: "Топ день", value: topDaySummary, accent: AppTheme.primaryTint)
            }
        }
    }

    private var monthlyChartCard: some View {
        AppCard {
            AppSectionHeader(
                title: "График по месяцам",
                caption: "Динамика выполненных заявок по месяцам"
            )

            if analytics.monthlyChartStats.isEmpty {
                analyticsEmptyState("Нет данных для построения графика по месяцам.")
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .bottom, spacing: 8) {
                            ForEach(analytics.monthlyChartStats) { item in
                                MonthlyChartBar(
                                    item: item,
                                    maxCount: analytics.chartMaxCount,
                                    isHighlighted: item.id == analytics.latestMonthID
                                )
                                .frame(width: 58)
                                .id(item.id)
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                    .onAppear {
                        if let latestMonthID = analytics.latestMonthID {
                            proxy.scrollTo(latestMonthID, anchor: .trailing)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private var monthlyDistributionCard: some View {
        AppCard {
            AppSectionHeader(
                title: "Распределение по месяцам",
                caption: "Сколько выполненных заявок закрыто в каждом месяце"
            )

            if analytics.monthlyStats.isEmpty {
                analyticsEmptyState("Нет данных для построения распределения по месяцам.")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Нажмите на месяц, чтобы открыть календарь дней.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedTint)

                    ForEach(analytics.monthlyStats) { item in
                        MonthDistributionAccordion(
                            item: item,
                            maxCount: analytics.maxMonthCount,
                            tint: item.id == analytics.latestMonthID ? AppTheme.primaryTint : AppTheme.primaryTint.opacity(0.8),
                            isExpanded: item.id == selectedMonthID,
                            calendarColumns: calendarColumns,
                            weekdaySymbols: Self.weekdaySymbols,
                            days: item.id == selectedMonthID ? analytics.monthCalendarDays(for: item.id) : [],
                            onToggle: { toggleMonthSelection(item.id) }
                        )
                    }
                }
            }
        }
    }

    private var requestTypeDistributionCard: some View {
        AppCard {
            AppSectionHeader(
                title: "Распределение по типам заявок",
                caption: "Только выполненные заявки без возврата ТО"
            )

            if analytics.requestTypeStats.isEmpty {
                analyticsEmptyState("Нет данных для распределения по типам заявок.")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(analytics.requestTypeStats) { item in
                        AnalyticsBarRow(
                            title: item.title,
                            count: item.count,
                            maxCount: analytics.maxTypeCount
                        )
                    }
                }
            }
        }
    }

    private func analyticsEmptyState(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(AppTheme.mutedTint)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summaryItems: [AnalyticsSummaryItem] {
        [
            AnalyticsSummaryItem(
                title: "Выполнено",
                value: "\(analytics.completedCount)",
                subtitle: "без возврата ТО",
                tint: AppTheme.primaryTint
            ),
            AnalyticsSummaryItem(
                title: "Месяцев",
                value: "\(analytics.monthlyStats.count)",
                subtitle: "в истории",
                tint: AppTheme.secondaryTint
            ),
            AnalyticsSummaryItem(
                title: "Последний месяц",
                value: latestMonthCountText,
                subtitle: latestMonthTitle,
                tint: AppTheme.primaryTint
            ),
            AnalyticsSummaryItem(
                title: "Топ тип",
                value: topRequestTypeCountText,
                subtitle: topRequestTypeTitle,
                tint: AppTheme.secondaryTint
            )
        ]
    }

    private var latestMonthTitle: String {
        analytics.latestMonth?.title ?? "Нет данных"
    }

    private var latestMonthCountText: String {
        guard let count = analytics.latestMonth?.count else { return "—" }
        return "\(count)"
    }

    private var topRequestTypeTitle: String {
        analytics.topRequestType?.title ?? "Нет данных"
    }

    private var topRequestTypeCountText: String {
        guard let count = analytics.topRequestType?.count else { return "—" }
        return "\(count)"
    }

    private var topMonthSummary: String {
        guard let item = analytics.topMonth else { return "Нет данных" }
        return "\(item.title) • \(item.count)"
    }

    private var topDaySummary: String {
        guard let item = analytics.topDay else { return "Нет данных" }
        return "\(item.title) • \(item.count)"
    }

    private func toggleMonthSelection(_ monthID: String) {
        AppHaptics.trigger(.expandCollapse)
        withAnimation(.easeInOut(duration: 0.24)) {
            if selectedMonthID == monthID {
                selectedMonthID = nil
            } else {
                selectedMonthID = monthID
            }
        }
    }

    static func formatMinutes(_ minutes: Int) -> String {
        "\(minutes / 60):\(String(format: "%02d", minutes % 60))"
    }

    private func formatMinutes(_ minutes: Int) -> String {
        Self.formatMinutes(minutes)
    }

    static func timeReportMonthTitle(from monthID: String) -> String {
        guard let date = timeReportMonthKeyFormatter.date(from: monthID) else {
            return monthID
        }
        return timeReportMonthTitleFormatter.string(from: date).capitalized
    }
}
