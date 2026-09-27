import SwiftUI

extension ClosedRequestsAnalyticsContent {
    struct TimeReportMonthGroup: Identifiable {
        let id: String
        let title: String
        let daySummaries: [TimeReportDaySummary]

        var workMinutes: Int {
            daySummaries.reduce(0) { $0 + $1.workMinutes }
        }

        var travelMinutes: Int {
            daySummaries.reduce(0) { $0 + $1.travelMinutes }
        }

        var totalMinutes: Int {
            workMinutes + travelMinutes
        }

        var entryCount: Int {
            daySummaries.reduce(0) { $0 + $1.entries.count }
        }
    }

    struct AnalyticsSummaryItem: Identifiable {
        let title: String
        let value: String
        let subtitle: String
        let tint: Color

        var id: String { title }
    }

    struct AnalyticsSummaryCard: View {
        let item: AnalyticsSummaryItem

        var body: some View {
            AppCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text(item.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.mutedTint)
                            .lineLimit(2)

                        Spacer(minLength: 0)

                        Circle()
                            .fill(item.tint.opacity(0.18))
                            .frame(width: 10, height: 10)
                    }

                    Text(item.value)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(AppTheme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(item.tint)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    struct AnalyticsBarRow: View {
        let title: String
        let count: Int
        let maxCount: Int
        var tint: Color = AppTheme.primaryTint
        var hidesTitle = false

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                if !hidesTitle {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 12)

                        Text("\(count)")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(tint)
                    }
                }

                GeometryReader { proxy in
                    let width = proxy.size.width
                    let ratio = maxCount == 0 ? 0 : CGFloat(count) / CGFloat(maxCount)

                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(AppTheme.secondaryTint.opacity(0.12))
                            .frame(height: 10)

                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(tint)
                            .frame(width: max(count == 0 ? 0 : 10, width * ratio), height: 10)
                    }
                }
                .frame(height: 10)
            }
        }
    }

    struct MonthlyChartBar: View {
        let item: ClosedRequestsAnalyticsData.MonthlyAnalyticsItem
        let maxCount: Int
        let isHighlighted: Bool

        private var fill: Color {
            isHighlighted ? AppTheme.primaryTint : AppTheme.secondaryTint.opacity(0.7)
        }

        private var labelColor: Color {
            isHighlighted ? AppTheme.primaryTint : AppTheme.mutedTint
        }

        private var height: CGFloat {
            guard maxCount > 0 else { return 0 }
            let ratio = CGFloat(item.count) / CGFloat(maxCount)
            return max(16, 88 * ratio)
        }

        var body: some View {
            VStack(spacing: 8) {
                Text("\(item.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isHighlighted ? AppTheme.ink : AppTheme.mutedTint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AppTheme.secondaryTint.opacity(0.12))

                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(fill)
                        .frame(height: height)
                }
                .frame(height: 88)

                Text(item.shortTitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(labelColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, alignment: .bottom)
        }
    }

    struct CalendarDayCell: View {
        let day: ClosedRequestsAnalyticsData.MonthCalendarDay

        var body: some View {
            ZStack {
                if day.isPlaceholder {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.clear)
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(day.count > 0 ? AppTheme.secondaryTint.opacity(0.16) : AppTheme.secondaryTint.opacity(0.07))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(day.count > 0 ? AppTheme.primaryTint.opacity(0.18) : AppTheme.border, lineWidth: 1)
                        )

                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(day.dayNumber ?? 0)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(AppTheme.mutedTint)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Spacer(minLength: 0)

                        if day.count > 0 {
                            Text("\(day.count)")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(AppTheme.primaryTint)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(6)
                }
            }
            .frame(height: 50)
        }
    }

    struct MonthDistributionAccordion: View {
        let item: ClosedRequestsAnalyticsData.MonthlyAnalyticsItem
        let maxCount: Int
        let tint: Color
        let isExpanded: Bool
        let calendarColumns: [GridItem]
        let weekdaySymbols: [String]
        let days: [ClosedRequestsAnalyticsData.MonthCalendarDay]
        let onToggle: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Button(action: onToggle) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(item.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AppTheme.ink)
                                .fixedSize(horizontal: false, vertical: true)

                            Spacer(minLength: 8)

                            Text("\(item.count)")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(tint)

                            Image(systemName: isExpanded ? "chevron.up.circle.fill" : "chevron.down.circle")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(isExpanded ? tint : AppTheme.mutedTint)
                        }

                        AnalyticsBarRow(
                            title: "",
                            count: item.count,
                            maxCount: maxCount,
                            tint: tint,
                            hidesTitle: true
                        )
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("Календарь по дням")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.mutedTint)

                            Spacer(minLength: 8)

                            Text("За месяц: \(item.count)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(tint)
                        }

                        LazyVGrid(columns: calendarColumns, spacing: 6) {
                            ForEach(weekdaySymbols, id: \.self) { symbol in
                                Text(symbol)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(AppTheme.mutedTint)
                                    .frame(maxWidth: .infinity)
                            }

                            ForEach(days) { day in
                                CalendarDayCell(day: day)
                            }
                        }
                    }
                    .padding(.top, 2)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    ))
                }
            }
            .padding(.vertical, 2)
            .animation(.easeInOut(duration: 0.24), value: isExpanded)
        }
    }

    struct TimeReportMonthNavigationCard: View {
        let group: TimeReportMonthGroup

        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.title)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(AppTheme.ink)

                        Text("\(group.daySummaries.count) \(dayCountTitle) • \(group.entryCount) \(entryCountTitle)")
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedTint)
                    }

                    Spacer(minLength: 12)

                    Text(ClosedRequestsAnalyticsContent.formatDurationWords(group.totalMinutes))
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AppTheme.ink)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppTheme.mutedTint)
                }

                GeometryReader { proxy in
                    let fraction = group.totalMinutes == 0
                        ? 0
                        : CGFloat(group.workMinutes) / CGFloat(group.totalMinutes)

                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(AppTheme.primaryTint)
                            .frame(width: proxy.size.width * fraction)

                        Rectangle()
                            .fill(AppTheme.secondaryTint)
                    }
                }
                .frame(height: 8)
                .background(AppTheme.softFill)
                .clipShape(Capsule())

                HStack(spacing: 14) {
                    monthMetric(
                        title: "Работа",
                        value: ClosedRequestsAnalyticsContent.formatMinutes(group.workMinutes),
                        tint: AppTheme.primaryTint
                    )

                    Spacer(minLength: 8)

                    monthMetric(
                        title: "Дорога",
                        value: ClosedRequestsAnalyticsContent.formatMinutes(group.travelMinutes),
                        tint: AppTheme.secondaryTint
                    )
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.secondaryTint.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(AppTheme.border.opacity(0.7), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }

        private func monthMetric(title: String, value: String, tint: Color) -> some View {
            HStack(spacing: 7) {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)

                Text(title)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedTint)

                Text(value)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                    .monospacedDigit()
            }
        }

        private var dayCountTitle: String {
            Self.pluralized(group.daySummaries.count, one: "день", few: "дня", many: "дней")
        }

        private var entryCountTitle: String {
            Self.pluralized(group.entryCount, one: "запись", few: "записи", many: "записей")
        }

        private static func pluralized(_ value: Int, one: String, few: String, many: String) -> String {
            let remainder100 = value % 100
            let remainder10 = value % 10
            if (11...14).contains(remainder100) { return many }
            switch remainder10 {
            case 1: return one
            case 2...4: return few
            default: return many
            }
        }
    }

    struct TimeReportMonthDetailsScreen: View {
        let group: TimeReportMonthGroup
        let onOpenEntry: ((TimeReportEntry) -> Void)?

        @State private var expandedDayID: String?

        init(
            group: TimeReportMonthGroup,
            onOpenEntry: ((TimeReportEntry) -> Void)? = nil
        ) {
            self.group = group
            self.onOpenEntry = onOpenEntry
        }

        var body: some View {
            AppScreen {
                LazyVStack(alignment: .leading, spacing: 12) {
                    AppCard {
                        AppSectionHeader(title: group.title)

                        AppStatRow(
                            title: "Всего",
                            value: ClosedRequestsAnalyticsContent.formatMinutes(group.totalMinutes),
                            accent: AppTheme.primaryTint
                        )
                        AppStatRow(
                            title: "Работа",
                            value: ClosedRequestsAnalyticsContent.formatMinutes(group.workMinutes),
                            accent: AppTheme.primaryTint
                        )
                        AppStatRow(
                            title: "Дорога",
                            value: ClosedRequestsAnalyticsContent.formatMinutes(group.travelMinutes),
                            accent: AppTheme.secondaryTint
                        )
                        AppStatRow(
                            title: "Дней",
                            value: "\(group.daySummaries.count) • \(group.entryCount) строк",
                            accent: AppTheme.secondaryTint
                        )
                    }

                    AppCard {
                        AppSectionHeader(title: "Ежедневные трудозатраты")

                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(group.daySummaries) { summary in
                                TimeReportDayAccordion(
                                    summary: summary,
                                    isExpanded: expandedDayID == summary.id,
                                    onToggle: { toggleDay(summary.id) },
                                    onOpenEntry: onOpenEntry
                                )
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(group.title)
            .navigationBarTitleDisplayMode(.inline)
            .appSidebarBackButton()
        }

        private func toggleDay(_ dayID: String) {
            AppHaptics.trigger(.expandCollapse)
            withAnimation(.easeInOut(duration: 0.24)) {
                expandedDayID = expandedDayID == dayID ? nil : dayID
            }
        }
    }

    struct TimeReportDayAccordion: View {
        let summary: TimeReportDaySummary
        let isExpanded: Bool
        let onToggle: () -> Void
        let onOpenEntry: ((TimeReportEntry) -> Void)?

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Button(action: onToggle) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(summary.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AppTheme.ink)
                                .fixedSize(horizontal: false, vertical: true)

                            Spacer(minLength: 8)

                            Text(formatMinutes(summary.totalMinutes))
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(AppTheme.primaryTint)

                            Image(systemName: isExpanded ? "chevron.up.circle.fill" : "chevron.down.circle")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(isExpanded ? AppTheme.primaryTint : AppTheme.mutedTint)
                        }

                        HStack(spacing: 8) {
                            TimeReportMetricPill(title: "Работа", value: formatMinutes(summary.workMinutes), tint: AppTheme.primaryTint)
                            TimeReportMetricPill(title: "Дорога", value: formatMinutes(summary.travelMinutes), tint: AppTheme.secondaryTint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(summary.entries) { entry in
                            if let onOpenEntry {
                                Button {
                                    AppHaptics.trigger()
                                    onOpenEntry(entry)
                                } label: {
                                    TimeReportEntryRow(entry: entry, showsDisclosure: true)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("Открывает трудозатраты в SimpleOne")
                                .accessibilityIdentifier("timeReport.entry.\(entry.id)")
                            } else {
                                TimeReportEntryRow(entry: entry)
                            }
                        }
                    }
                    .padding(.top, 2)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    ))
                }
            }
            .padding(.vertical, 2)
            .animation(.easeInOut(duration: 0.24), value: isExpanded)
        }

        private func formatMinutes(_ minutes: Int) -> String {
            "\(minutes / 60):\(String(format: "%02d", minutes % 60))"
        }
    }

    struct TimeReportMonthSection<Content: View>: View {
        let group: TimeReportMonthGroup
        @ViewBuilder let content: Content

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.title)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(AppTheme.ink)
                        Text("\(group.daySummaries.count) дней • \(group.entryCount) строк")
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedTint)
                    }

                    Spacer(minLength: 12)

                    Text(formatMinutes(group.totalMinutes))
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AppTheme.primaryTint)
                }

                HStack(spacing: 8) {
                    TimeReportMetricPill(title: "Работа", value: formatMinutes(group.workMinutes), tint: AppTheme.primaryTint)
                    TimeReportMetricPill(title: "Дорога", value: formatMinutes(group.travelMinutes), tint: AppTheme.secondaryTint)
                }

                content
            }
            .padding(.top, 10)
            .padding(.bottom, 4)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(AppTheme.border)
                    .frame(height: 1)
            }
        }

        private func formatMinutes(_ minutes: Int) -> String {
            "\(minutes / 60):\(String(format: "%02d", minutes % 60))"
        }
    }

    struct TimeReportMetricPill: View {
        let title: String
        let value: String
        let tint: Color

        var body: some View {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedTint)
                Text(value)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(AppTheme.secondaryTint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    struct TimeReportEntryRow: View {
        let entry: TimeReportEntry
        var showsDisclosure = false

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(Self.timeFormatter.string(from: entry.effectiveWorkDate))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.primaryTint)

                    Spacer(minLength: 8)

                    Text("Работа \(formatMinutes(entry.workMinutes))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)

                    Text("Дорога \(formatMinutes(entry.travelMinutes))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.secondaryTint)
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.activity)
                        .font(.caption)
                        .foregroundStyle(AppTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)

                    if showsDisclosure {
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(AppTheme.mutedTint)
                    }
                }

                if !entry.notes.isEmpty {
                    Text(entry.notes)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.mutedTint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.secondaryTint.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }

        private func formatMinutes(_ minutes: Int) -> String {
            "\(minutes / 60):\(String(format: "%02d", minutes % 60))"
        }

        private static let timeFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ru_RU")
            formatter.dateFormat = "HH:mm"
            return formatter
        }()
    }

    static let importedAtFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter
    }()

    static func formatDurationWords(_ minutes: Int) -> String {
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        let formattedHours = hours.formatted(.number.grouping(.automatic))
        return "\(formattedHours) ч \(String(format: "%02d", remainingMinutes)) мин"
    }

    static let weekdaySymbols = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"]

    static let timeReportMonthKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()

    static let timeReportMonthTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "LLLL yyyy"
        return formatter
    }()
}
