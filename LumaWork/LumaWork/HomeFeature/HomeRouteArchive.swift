import Foundation
import SwiftUI

struct RouteArchiveScreen: View {
    @Environment(\.dismiss) private var dismiss

    let store: RouteArchiveStore
    let gsmReportStore: GsmReportStore
    let routeStore: HomeRouteStore

    @State private var displayedMonth: Date
    @State private var selectedDayKey: String?
    @State private var monthPickerPresentation: RouteArchiveMonthPickerPresentation?
    @State private var isOdometerPresented = false

    init(
        store: RouteArchiveStore,
        gsmReportStore: GsmReportStore,
        routeStore: HomeRouteStore
    ) {
        self.store = store
        self.gsmReportStore = gsmReportStore
        self.routeStore = routeStore
        _displayedMonth = State(
            initialValue: RouteArchiveCalendar.calendar.monthStart(for: routeStore.selectedDate)
        )
    }

    var body: some View {
        AppScreen {
            gsmReportLink

            if let errorMessage = store.errorMessage {
                AppNoticeBanner(text: errorMessage, tint: AppTheme.dangerTint, isCritical: true)
            }

            RouteArchiveCalendar(
                records: displayedMonthRecords,
                displayedMonth: $displayedMonth,
                selectedDayKey: $selectedDayKey,
                onMonthTitleTap: presentMonthPicker
            )

            odometerCard

            if !selectedRecords.isEmpty {
                ForEach(selectedRecords, id: \.workType) { record in
                    RouteArchiveDayDetail(record: record)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if displayedMonthRecords.isEmpty {
                AppEmptyState(
                    title: "Маршрутов нет",
                    message: "За выбранный месяц записей пока нет.",
                    systemName: "calendar.badge.exclamationmark"
                )
            } else {
                Label("Выберите день с километражем, чтобы увидеть маршрут", systemImage: "hand.tap")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.mutedTint)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
        }
        .navigationTitle("Все маршруты")
        .navigationBarTitleDisplayMode(.inline)
        .appLoadingOverlay(
            isPresented: store.isLoading && store.records.isEmpty,
            title: "Загружаем маршруты"
        )
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ModalCloseButton(action: dismiss.callAsFunction)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    AppHaptics.trigger()
                    Task { await store.reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .task {
            await store.loadIfNeeded()
        }
        .onChange(of: displayedMonth) { _, _ in
            selectedDayKey = nil
        }
        .sheet(item: $monthPickerPresentation) { presentation in
            NavigationStack {
                RouteArchiveMonthPicker(
                    selectedMonth: $displayedMonth,
                    initialMonth: presentation.month,
                    yearRange: monthPickerYearRange
                )
            }
            .appEditorSheetStyle(initialHeight: 340)
        }
        .sheet(isPresented: $isOdometerPresented) {
            NavigationStack {
                HomeOdometerSheet(routeStore: routeStore)
            }
            .appEditorSheetStyle()
        }
        .task(id: store.errorMessage) {
            await appDismissTransientMessage(store.errorMessage) { value in
                if store.errorMessage == value {
                    store.errorMessage = nil
                }
            }
        }
    }

    private var gsmReportLink: some View {
        NavigationLink {
            GsmReportScreen(
                store: gsmReportStore,
                onFinished: dismiss.callAsFunction
            )
        } label: {
            AppCard {
                HStack(spacing: 12) {
                    Image(systemName: "paperplane.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(AppTheme.secondaryTint)
                        .frame(width: 36, height: 36)
                        .background(AppTheme.secondaryTint.opacity(0.12), in: Circle())

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Отправить ГСМ отчет")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(AppTheme.ink)
                        Text("Сформировать отчет за выбранный месяц")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.mutedTint)
                    }

                    Spacer(minLength: 12)

                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(AppTheme.mutedTint)
                }
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var odometerCard: some View {
        AppCard {
            if isDisplayedMonthEditable {
                Button {
                    AppHaptics.trigger()
                    isOdometerPresented = true
                } label: {
                    odometerContent(showsDisclosure: true)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Открывает ввод одометра на начало месяца")
            } else {
                odometerContent(showsDisclosure: false)
            }
        }
    }

    private func odometerContent(showsDisclosure: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.title3.weight(.semibold))
                .foregroundStyle(odometerValueTint)
                .frame(width: 38, height: 38)
                .background(odometerValueTint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text("Одометр месяца")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)

                Text(displayedMonthTitle)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedTint)
            }

            Spacer(minLength: 12)

            Text(odometerValueTitle)
                .font(.headline.weight(.bold).monospacedDigit())
                .foregroundStyle(odometerValueTint)

            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppTheme.mutedTint)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var selectedRecords: [RouteDayRecord] {
        guard let selectedDayKey else { return [] }
        return displayedMonthRecords
            .filter { $0.date == selectedDayKey }
            .sorted { $0.workType.rawValue > $1.workType.rawValue }
    }

    private var displayedMonthRecords: [RouteDayRecord] {
        store.records.filter { $0.date.hasPrefix("\(displayedMonthKey)-") }
    }

    private var displayedMonthKey: String {
        String(RouteDateFormatter.dayKey(from: displayedMonth).prefix(7))
    }

    private var displayedMonthTitle: String {
        Self.monthTitleFormatter.string(from: displayedMonth)
            .capitalized(with: AppLocale.russian)
    }

    private var displayedMonthOdometer: Int? {
        if displayedMonthKey == routeStore.selectedMonthKey {
            return routeStore.record.periodStartOdometer
        }

        return displayedMonthRecords.lazy.compactMap { record in
            record.reportedPeriodStartOdometer ?? record.periodStartOdometer
        }.first
    }

    private var isDisplayedMonthEditable: Bool {
        displayedMonthKey == routeStore.selectedMonthKey
    }

    private var odometerValueTitle: String {
        displayedMonthOdometer.map { "\($0) км" } ?? "Не задан"
    }

    private var odometerValueTint: Color {
        displayedMonthOdometer == nil ? AppTheme.secondaryTint : AppTheme.primaryTint
    }

    private var monthPickerYearRange: ClosedRange<Int> {
        let calendar = RouteArchiveCalendar.calendar
        let currentYear = calendar.component(.year, from: .now)
        let displayedYear = calendar.component(.year, from: displayedMonth)
        let recordYears = store.records.compactMap { record in
            RouteDateFormatter.storageFormatter.date(from: record.date)
        }.map { calendar.component(.year, from: $0) }
        let lowerBound = min(2020, recordYears.min() ?? currentYear, displayedYear)
        let upperBound = max(currentYear + 1, recordYears.max() ?? currentYear, displayedYear)
        return lowerBound ... upperBound
    }

    private func presentMonthPicker() {
        AppHaptics.trigger()
        monthPickerPresentation = RouteArchiveMonthPickerPresentation(month: displayedMonth)
    }

    private static let monthTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = AppLocale.russian
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "LLLL yyyy"
        return formatter
    }()
}

private struct HomeOdometerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let routeStore: HomeRouteStore
    @State private var odometerDraft: String

    init(routeStore: HomeRouteStore) {
        self.routeStore = routeStore
        _odometerDraft = State(
            initialValue: routeStore.record.periodStartOdometer.map(String.init) ?? ""
        )
    }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    HStack(spacing: 6) {
                        TextField("0", text: $odometerDraft)
                            .keyboardType(.numberPad)
                            .font(.body.weight(.semibold).monospacedDigit())
                            .multilineTextAlignment(.trailing)
                            .frame(width: 92)

                        Text("км")
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    Label("На начало месяца", systemImage: "gauge.with.dots.needle.33percent")
                }
            } footer: {
                Text("Значение применяется ко всем маршрутам выбранного месяца.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
        .navigationTitle("Одометр месяца")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Отмена") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                ModalConfirmButton(
                    action: {
                        routeStore.updatePeriodStartOdometer(odometerDraft)
                        AppHaptics.trigger()
                        dismiss()
                    },
                    isDisabled: !isDraftValid,
                    accessibilityLabel: "Сохранить пробег"
                )
            }
        }
    }

    private var isDraftValid: Bool {
        let value = odometerDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || Int(value) != nil
    }
}

private struct RouteArchiveCalendar: View {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = AppLocale.russian
        calendar.firstWeekday = 2
        return calendar
    }

    let records: [RouteDayRecord]
    @Binding var displayedMonth: Date
    @Binding var selectedDayKey: String?
    let onMonthTitleTap: () -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 7)
    private let weekdayTitles = ["ПН", "ВТ", "СР", "ЧТ", "ПТ", "СБ", "ВС"]

    var body: some View {
        AppCard {
            monthNavigation

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(weekdayTitles, id: \.self) { title in
                    Text(title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedTint)
                        .frame(maxWidth: .infinity)
                }

                ForEach(Array(monthCells.enumerated()), id: \.offset) { _, date in
                    if let date {
                        dayCell(date)
                    } else {
                        Color.clear.frame(height: 54)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: displayedMonth)
    }

    private var monthNavigation: some View {
        HStack {
            monthButton(systemName: "chevron.left") {
                changeMonth(by: -1)
            }

            Spacer()

            VStack(spacing: 2) {
                Button(action: onMonthTitleTap) {
                    HStack(spacing: 5) {
                        Text(displayedMonthTitle)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.bold))
                    }
                    .font(.headline.weight(.bold))
                    .foregroundStyle(AppTheme.ink)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Выбрать месяц и год")
                .accessibilityValue(displayedMonthTitle)
                .accessibilityHint("Открывает окно быстрого перехода")

                Text("Общий пробег за месяц: \(displayedMonthDistanceTitle)")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedTint)
            }

            Spacer()

            monthButton(systemName: "chevron.right") {
                changeMonth(by: 1)
            }
        }
        .padding(.bottom, 4)
    }

    private func dayCell(_ date: Date) -> some View {
        let key = RouteDateFormatter.dayKey(from: date)
        let dayRecords = recordsByDate[key] ?? []
        let record = dayRecords.first
        let isSelected = selectedDayKey == key

        return Button {
            guard record != nil else { return }
            AppHaptics.trigger()
            withAnimation(.easeInOut(duration: 0.22)) {
                selectedDayKey = isSelected ? nil : key
            }
        } label: {
            VStack(spacing: 4) {
                Text(date.formatted(.dateTime.day()))
                    .font(.subheadline.weight(isSelected ? .bold : .medium))

                Text(dayRecords.isEmpty ? "—" : distanceText(dayRecords))
                    .font(.caption2.weight(record == nil ? .regular : .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .foregroundStyle(cellForeground(record: record, selected: isSelected))
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(cellBackground(record: record, selected: isSelected), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                if Self.calendar.isDateInToday(date) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(AppTheme.primaryTint.opacity(0.55), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(record == nil)
        .accessibilityLabel(accessibilityTitle(date: date, records: dayRecords))
    }

    private var monthCells: [Date?] {
        let calendar = Self.calendar
        let month = calendar.monthStart(for: displayedMonth)
        guard let dayRange = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let firstWeekday = calendar.component(.weekday, from: month)
        let leadingEmptyCells = (firstWeekday - calendar.firstWeekday + 7) % 7
        var cells = Array<Date?>(repeating: nil, count: leadingEmptyCells)
        cells.append(contentsOf: dayRange.compactMap { day in
            calendar.date(byAdding: .day, value: day - 1, to: month)
        })
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }

    private var recordsByDate: [String: [RouteDayRecord]] {
        Dictionary(grouping: records, by: \.date)
    }

    private var displayedMonthTitle: String {
        Self.monthFormatter.string(from: displayedMonth)
            .capitalized(with: AppLocale.russian)
    }

    private var displayedMonthDistanceTitle: String {
        let monthKey = String(RouteDateFormatter.dayKey(from: displayedMonth).prefix(7))
        let distance = records.reduce(into: 0.0) { total, record in
            guard record.date.hasPrefix("\(monthKey)-") else { return }
            total += record.reportedDistanceKm ?? record.distanceKm.map(Double.init) ?? 0
        }
        return "\(AppFormatting.number(distance, maximumFractionDigits: 1)) км"
    }

    private func changeMonth(by value: Int) {
        guard let date = Self.calendar.date(byAdding: .month, value: value, to: displayedMonth) else { return }
        AppHaptics.trigger()
        withAnimation(.easeInOut(duration: 0.2)) {
            displayedMonth = Self.calendar.monthStart(for: date)
            selectedDayKey = nil
        }
    }

    private func monthButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.subheadline.weight(.bold))
                .frame(width: 36, height: 36)
                .background(AppTheme.cardSurface.opacity(0.72), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppTheme.primaryTint)
    }

    private func distanceText(_ records: [RouteDayRecord]) -> String {
        let distance = records.reduce(into: 0.0) { total, record in
            total += record.reportedDistanceKm ?? record.distanceKm.map(Double.init) ?? 0
        }
        return "\(AppFormatting.number(distance, maximumFractionDigits: 1)) км"
    }

    private func cellForeground(record: RouteDayRecord?, selected: Bool) -> Color {
        if selected { return .white }
        return record == nil ? AppTheme.mutedTint.opacity(0.65) : AppTheme.ink
    }

    private func cellBackground(record: RouteDayRecord?, selected: Bool) -> Color {
        if selected { return AppTheme.primaryTint }
        if record != nil { return AppTheme.primaryTint.opacity(0.11) }
        return .clear
    }

    private func accessibilityTitle(date: Date, records: [RouteDayRecord]) -> String {
        let dateTitle = RouteDateFormatter.humanDate(from: date)
        guard !records.isEmpty else { return "\(dateTitle), маршрута нет" }
        let typeTitle = records.map(\.workType.title).joined(separator: " и ")
        return "\(dateTitle), \(typeTitle), \(distanceText(records))"
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = AppLocale.russian
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "LLLL yyyy"
        return formatter
    }()
}

private struct RouteArchiveMonthPickerPresentation: Identifiable {
    let id = UUID()
    let month: Date
}

private struct RouteArchiveMonthPicker: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var selectedMonth: Date
    let yearRange: ClosedRange<Int>

    @State private var month: Int
    @State private var year: Int

    init(
        selectedMonth: Binding<Date>,
        initialMonth: Date,
        yearRange: ClosedRange<Int>
    ) {
        self._selectedMonth = selectedMonth
        self.yearRange = yearRange
        let components = RouteArchiveCalendar.calendar.dateComponents([.year, .month], from: initialMonth)
        self._month = State(initialValue: components.month ?? 1)
        self._year = State(initialValue: components.year ?? Calendar.current.component(.year, from: .now))
    }

    var body: some View {
        HStack(spacing: 12) {
            pickerColumn(title: "Месяц") {
                Picker("Месяц", selection: $month) {
                    ForEach(1 ... 12, id: \.self) { month in
                        Text(monthName(month)).tag(month)
                    }
                }
                .pickerStyle(.wheel)
            }

            pickerColumn(title: "Год") {
                Picker("Год", selection: $year) {
                    ForEach(yearRange, id: \.self) { year in
                        Text(String(year)).tag(year)
                    }
                }
                .pickerStyle(.wheel)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle("Месяц и год")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                ModalCloseButton(action: dismiss.callAsFunction)
            }

            ToolbarItem(placement: .confirmationAction) {
                ModalConfirmButton(
                    action: applySelection,
                    accessibilityLabel: "Перейти к выбранному месяцу"
                )
            }
        }
    }

    private func pickerColumn<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedTint)
            content()
        }
        .frame(maxWidth: .infinity)
    }

    private func applySelection() {
        var components = DateComponents()
        components.calendar = RouteArchiveCalendar.calendar
        components.year = year
        components.month = month
        components.day = 1
        guard let date = RouteArchiveCalendar.calendar.date(from: components) else { return }
        selectedMonth = date
        AppHaptics.trigger()
        dismiss()
    }

    private func monthName(_ month: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = AppLocale.russian
        return formatter.standaloneMonthSymbols[month - 1]
            .capitalized(with: AppLocale.russian)
    }
}

private struct RouteArchiveDayDetail: View {
    let record: RouteDayRecord

    var body: some View {
        AppCard {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(dateTitle)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(AppTheme.ink)
                    Text("Маршрут за день")
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedTint)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    AppBadge(text: record.workType.title, tint: AppTheme.primaryTint)
                    Text(distanceText)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AppTheme.primaryTint)
                    if !requestNumbers.isEmpty {
                        AppBadge(text: "\(requestNumbers.count) заявок", tint: AppTheme.secondaryTint)
                    }
                }
            }

            Divider()

            VStack(spacing: 0) {
                ForEach(Array(routeItems.enumerated()), id: \.element.id) { index, item in
                    RouteArchiveStopRow(
                        item: item,
                        isFirst: index == 0,
                        isLast: index == routeItems.count - 1
                    )
                }
            }

            if !requestNumbers.isEmpty {
                Label("ЗАЯВКИ", systemImage: "doc.text")
                    .font(.caption.weight(.bold))
                    .tracking(0.7)
                    .foregroundStyle(AppTheme.mutedTint)
                    .padding(.top, 2)

                LazyVGrid(columns: requestColumns, alignment: .leading, spacing: 8) {
                    ForEach(requestNumbers, id: \.self) { number in
                        Text(number)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.secondaryTint)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(AppTheme.secondaryTint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
        }
    }

    private let requestColumns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    private var routeItems: [RouteArchiveStopItem] {
        let summaryAddresses = parsedSummaryAddresses
        if !summaryAddresses.isEmpty {
            return summaryAddresses.enumerated().map { index, address in
                let matchingStop = record.stops.first { stop in
                    stop.address.trimmingCharacters(in: .whitespacesAndNewlines) == address
                }
                return RouteArchiveStopItem(
                    id: "summary-\(index)-\(address)",
                    address: address,
                    organization: matchingStop?.org.trimmingCharacters(in: .whitespacesAndNewlines),
                    requestNumber: requestNumbers.indices.contains(index) ? requestNumbers[index] : matchingStop?.requestNumber,
                    status: matchingStop?.status
                )
            }
        }

        return record.stops.enumerated().compactMap { index, stop in
            let address = stop.address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty else { return nil }
            return RouteArchiveStopItem(
                id: "stop-\(index)-\(stop.id)",
                address: address,
                organization: stop.org.trimmingCharacters(in: .whitespacesAndNewlines),
                requestNumber: stop.requestNumber.trimmingCharacters(in: .whitespacesAndNewlines),
                status: stop.status
            )
        }
    }

    private var parsedSummaryAddresses: [String] {
        guard let summary = record.routeSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty else {
            return []
        }
        return summary.components(separatedBy: " - ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var requestNumbers: [String] {
        if let summary = record.requestNumbersSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            return summary.split(whereSeparator: \.isWhitespace).map(String.init)
        }
        return record.stops.map(\.requestNumber)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var distanceText: String {
        if let distance = record.reportedDistanceKm {
            return "\(AppFormatting.number(distance, maximumFractionDigits: 1)) км"
        }
        if let distance = record.distanceKm { return "\(distance) км" }
        return "—"
    }

    private var dateTitle: String {
        guard let date = RouteDateFormatter.storageFormatter.date(from: record.date) else { return record.date }
        return Self.detailDateFormatter.string(from: date)
    }

    private static let detailDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = AppLocale.russian
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "d MMMM yyyy"
        return formatter
    }()
}

private struct RouteArchiveStopItem: Identifiable {
    let id: String
    let address: String
    let organization: String?
    let requestNumber: String?
    let status: RouteStopStatus?
}

private struct RouteArchiveStopRow: View {
    let item: RouteArchiveStopItem
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Image(systemName: markerSystemName)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(markerTint)
                    .frame(width: 26, height: 26)
                    .background(markerTint.opacity(0.12), in: Circle())

                if !isLast {
                    Rectangle()
                        .fill(AppTheme.border)
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 28)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.address)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)

                if let organization = item.organization?.nilIfBlank {
                    Text(organization)
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedTint)
                }

                if let requestNumber = item.requestNumber?.nilIfBlank {
                    Label(requestNumber, systemImage: "doc.text")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppTheme.secondaryTint)
                }
            }
            .padding(.bottom, isLast ? 2 : 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var markerSystemName: String {
        if isFirst { return "location.fill" }
        if isLast { return "flag.checkered" }
        return "circle.fill"
    }

    private var markerTint: Color {
        switch item.status {
        case .declined: AppTheme.dangerTint
        case .done: AppTheme.primaryTint
        default: isFirst || isLast ? AppTheme.primaryTint : AppTheme.mutedTint
        }
    }
}

private extension Calendar {
    func monthStart(for date: Date) -> Date {
        self.date(from: dateComponents([.year, .month], from: date)) ?? startOfDay(for: date)
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
