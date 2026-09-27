import SwiftUI

struct WorkScheduleScreen: View {
    let simpleOneStore: SimpleOneRequestsStore
    let profileCity: String?

    @State private var store: WorkScheduleStore

    init(
        simpleOneStore: SimpleOneRequestsStore,
        store: WorkScheduleStore,
        profileCity: String?
    ) {
        self.simpleOneStore = simpleOneStore
        self.profileCity = profileCity
        _store = State(initialValue: store)
    }

    private var selectionTaskID: String {
        guard store.didBootstrap else { return "bootstrap" }
        return store.selectedJournal?.sysID ?? "\(store.selectedCityName)|\(store.selectedYear)|\(store.selectedMonth)"
    }

    var body: some View {
        AppScreen {
            if !simpleOneStore.isAuthorized {
                AppEmptyState(
                    title: "SimpleOne не подключён",
                    message: "Войдите в SimpleOne на экране «Заявки», затем вернитесь к графику.",
                    systemName: "calendar.badge.exclamationmark"
                )
            } else if store.isInitialLoading {
                WorkScheduleSkeletonView()
            } else {
                WorkScheduleFilters(store: store)

                if let errorMessage = store.errorMessage {
                    AppNoticeBanner(
                        text: errorMessage,
                        tint: AppTheme.dangerTint,
                        isCritical: true
                    )

                    Button("Повторить", systemImage: "arrow.clockwise") {
                        Task {
                            await store.retry(
                                authKey: simpleOneStore.browserAuthKey,
                                profileCity: profileCity
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }

                if let schedule = store.schedule, !schedule.employees.isEmpty {
                    WorkScheduleTable(schedule: schedule)
                    WorkScheduleLegend(schedule: schedule)
                    if let auditInfo = schedule.auditInfo, auditInfo.hasContent {
                        WorkScheduleAuditInfoCard(info: auditInfo)
                    }
                } else if store.schedule != nil {
                    AppEmptyState(
                        title: "Сотрудников в графике нет",
                        message: "SimpleOne вернул пустой график за выбранный период.",
                        systemName: "person.2.slash"
                    )
                } else if store.errorMessage == nil {
                    AppEmptyState(
                        title: "График не найден",
                        message: "Для выбранного города и месяца график пока не опубликован.",
                        systemName: "calendar.badge.minus"
                    )
                }
            }
        }
        .navigationTitle("График работы")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await store.retry(
                authKey: simpleOneStore.browserAuthKey,
                profileCity: profileCity
            )
        }
        .task(id: simpleOneStore.isAuthorized) {
            guard simpleOneStore.isAuthorized else { return }
            await store.bootstrap(
                authKey: simpleOneStore.browserAuthKey,
                profileCity: profileCity
            )
        }
        .task(id: selectionTaskID) {
            guard simpleOneStore.isAuthorized, store.didBootstrap else { return }
            await store.loadSelectedSchedule(authKey: simpleOneStore.browserAuthKey)
        }
    }
}

private struct WorkScheduleFilters: View {
    let store: WorkScheduleStore

    var body: some View {
        AppCard {
            HStack(spacing: 10) {
                filterMenu(
                    title: store.selectedCityName.isEmpty ? "Город" : store.selectedCityName,
                    systemName: "mappin.and.ellipse"
                ) {
                    ForEach(store.cityNames, id: \.self) { city in
                        Button(city) {
                            AppHaptics.trigger(.expandCollapse)
                            store.selectCity(city)
                        }
                    }
                }

                filterMenu(
                    title: periodTitle,
                    systemName: "calendar"
                ) {
                    ForEach(store.availableYears, id: \.self) { year in
                        Menu(String(year)) {
                            ForEach(
                                WorkScheduleSelection.months(
                                    in: store.journals,
                                    cityName: store.selectedCityName,
                                    year: year
                                ),
                                id: \.self
                            ) { month in
                                Button(WorkScheduleFormatting.monthName(month)) {
                                    AppHaptics.trigger(.expandCollapse)
                                    store.selectYear(year)
                                    store.selectMonth(month)
                                }
                            }
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Фильтры графика работы")
    }

    private var periodTitle: String {
        guard store.selectedYear > 0 else { return "Месяц и год" }
        return "\(WorkScheduleFormatting.monthName(store.selectedMonth)) \(store.selectedYear)"
    }

    private func filterMenu<Content: View>(
        title: String,
        systemName: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu(content: content) {
            HStack(spacing: 8) {
                Image(systemName: systemName)
                    .foregroundStyle(AppTheme.primaryTint)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppTheme.mutedTint)
            }
            .padding(.horizontal, 13)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(AppTheme.ghostFill, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }
}

private struct WorkScheduleTable: View {
    let schedule: WorkSchedule

    private let employeeWidth: CGFloat = 164
    private let dayWidth: CGFloat = 48
    private let totalWidth: CGFloat = 72
    private let headerHeight: CGFloat = 58
    private let rowHeight: CGFloat = 68
    private let footerHeight: CGFloat = 54

    private var currentDay: Int? {
        WorkScheduleViewport.currentDay(
            in: schedule.journal,
            now: Date(),
            calendar: .autoupdatingCurrent
        )
    }

    private var initialVisibleDay: Int {
        WorkScheduleViewport.initialVisibleDay(
            in: schedule.journal,
            now: Date(),
            calendar: .autoupdatingCurrent
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            employeeColumn
                .frame(width: employeeWidth)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: true) {
                    calendarGrid
                }
                .scrollEdgeEffectHidden(true, for: .horizontal)
                .task(id: "\(schedule.journal.sysID)-\(currentDay ?? 0)") {
                    await Task.yield()
                    proxy.scrollTo(
                        WorkScheduleDayAnchor(day: initialVisibleDay),
                        anchor: .leading
                    )
                }
            }
            .frame(maxWidth: .infinity)
        }
        .background(
            AppTheme.panelSurface,
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: AppTheme.shadow.opacity(0.55), radius: 10, x: 0, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("График работы за \(WorkScheduleFormatting.monthName(schedule.journal.month)) \(schedule.journal.year)")
    }

    private var employeeColumn: some View {
        VStack(spacing: 0) {
            Text("Сотрудники")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AppTheme.ink)
                .frame(maxWidth: .infinity, minHeight: headerHeight, alignment: .leading)
                .padding(.horizontal, 12)
                .background(AppTheme.ghostFill.opacity(0.55), in: Rectangle())

            ForEach(schedule.employees) { employee in
                HStack(spacing: 9) {
                    Text(WorkScheduleFormatting.initials(employee.name))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(AppTheme.secondaryTint, in: Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        Text(employee.name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.ink)
                            .lineLimit(2)
                        if !employee.login.isEmpty {
                            Text(employee.login)
                                .font(.caption2.monospaced())
                                .foregroundStyle(AppTheme.mutedTint)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
                .padding(.horizontal, 10)
                .overlay(alignment: .bottom) { Divider() }
            }

            Label("Работают", systemImage: "person.2.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedTint)
                .frame(maxWidth: .infinity, minHeight: footerHeight, alignment: .leading)
                .padding(.horizontal, 12)
                .background(AppTheme.ghostFill.opacity(0.4), in: Rectangle())
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(AppTheme.border).frame(width: 1)
        }
    }

    private var calendarGrid: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(1...schedule.daysInMonth, id: \.self) { day in
                    VStack(spacing: 3) {
                        Text(WorkScheduleFormatting.weekday(day: day, journal: schedule.journal))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(AppTheme.mutedTint)
                        Text(String(day))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(AppTheme.ink)
                    }
                    .frame(width: dayWidth, height: headerHeight)
                    .background(
                        WorkScheduleFormatting.isWeekend(day: day, journal: schedule.journal) ? AppTheme.ghostFill : Color.clear,
                        in: Rectangle()
                    )
                    .overlay(columnHighlight(for: day))
                    .overlay(alignment: .trailing) { Rectangle().fill(AppTheme.border).frame(width: 1) }
                    .id(WorkScheduleDayAnchor(day: day))
                }

                Text("Часы")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppTheme.mutedTint)
                    .frame(width: totalWidth, height: headerHeight)
                    .background(AppTheme.ghostFill.opacity(0.55), in: Rectangle())
            }

            ForEach(schedule.employees) { employee in
                HStack(spacing: 0) {
                    ForEach(1...schedule.daysInMonth, id: \.self) { day in
                        WorkScheduleDayCell(
                            value: employee.value(for: day),
                            employeeName: employee.name,
                            day: day,
                            journal: schedule.journal
                        )
                            .frame(width: dayWidth, height: rowHeight)
                            .overlay(columnHighlight(for: day))
                            .overlay(alignment: .trailing) { Rectangle().fill(AppTheme.border).frame(width: 1) }
                    }

                    Text(WorkScheduleFormatting.hours(employee.totalHours))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AppTheme.ink)
                        .frame(width: totalWidth, height: rowHeight)
                        .background(AppTheme.ghostFill.opacity(0.3), in: Rectangle())
                }
                .overlay(alignment: .bottom) { Divider() }
            }

            HStack(spacing: 0) {
                ForEach(schedule.dailyTotals) { total in
                    Text(String(total.count))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppTheme.ink)
                        .frame(width: dayWidth, height: footerHeight)
                        .overlay(columnHighlight(for: total.day))
                        .overlay(alignment: .trailing) { Rectangle().fill(AppTheme.border).frame(width: 1) }
                }

                Text("")
                    .frame(width: totalWidth, height: footerHeight)
            }
            .background(AppTheme.ghostFill.opacity(0.4), in: Rectangle())
        }
    }

    private func columnHighlight(for day: Int) -> some View {
        Rectangle()
            .fill(currentDay == day ? AppTheme.primaryTint.opacity(0.10) : .clear)
    }
}

private struct WorkScheduleDayAnchor: Hashable {
    let day: Int
}

private struct WorkScheduleDayCell: View {
    let value: WorkScheduleDayValue?
    let employeeName: String
    let day: Int
    let journal: WorkScheduleJournal

    var body: some View {
        Group {
            if let value {
                Text(WorkScheduleFormatting.hours(value.hours))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(value.isActive ? foreground(for: value.hours) : .white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(background(for: value), in: Rectangle())
            } else {
                Text("–")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedTint.opacity(0.65))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppTheme.ghostFill.opacity(0.42), in: Rectangle())
            }
        }
        .accessibilityLabel(accessibilityText)
    }

    private func background(for value: WorkScheduleDayValue) -> Color {
        guard value.isActive else { return AppTheme.mutedTint.opacity(0.7) }
        return value.hours >= 24 ? Color.green.opacity(0.88) : Color.yellow.opacity(0.78)
    }

    private func foreground(for hours: Double) -> Color {
        hours >= 24 ? .white : AppTheme.ink
    }

    private var accessibilityText: String {
        let date = "\(day) \(WorkScheduleFormatting.monthName(journal.month).lowercased()) \(journal.year)"
        guard let value else { return "\(employeeName), \(date): нет в графике" }
        return "\(employeeName), \(date): \(WorkScheduleFormatting.hours(value.hours)) часов"
    }
}

private struct WorkScheduleLegend: View {
    let schedule: WorkSchedule

    private var hourValues: [Double] {
        Array(Set(schedule.employees.flatMap(\.dayValues).map(\.hours))).sorted()
    }

    var body: some View {
        AppCard {
            Text("Обозначения")
                .font(.headline.weight(.semibold))
                .foregroundStyle(AppTheme.ink)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 10)], spacing: 10) {
                ForEach(hourValues, id: \.self) { hours in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(hours >= 24 ? Color.green.opacity(0.88) : Color.yellow.opacity(0.78))
                            .frame(width: 30, height: 30)
                            .overlay {
                                Text(WorkScheduleFormatting.hours(hours))
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(hours >= 24 ? .white : AppTheme.ink)
                            }
                        Text("\(WorkScheduleFormatting.hours(hours)) ч")
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedTint)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(AppTheme.ghostFill)
                        .frame(width: 30, height: 30)
                        .overlay { Text("–").foregroundStyle(AppTheme.mutedTint) }
                    Text("Нет в графике")
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedTint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct WorkScheduleAuditInfoCard: View {
    let info: WorkScheduleAuditInfo

    private var hasCreatedInfo: Bool {
        info.createdBy != nil || info.createdAt != nil
    }

    private var hasUpdatedInfo: Bool {
        info.updatedBy != nil || info.updatedAt != nil
    }

    var body: some View {
        AppCard {
            Text("Информация о графике")
                .font(.headline.weight(.semibold))
                .foregroundStyle(AppTheme.ink)

            if hasCreatedInfo {
                auditRow(title: "Создано", person: info.createdBy, date: info.createdAt)
            }

            if hasCreatedInfo, hasUpdatedInfo {
                Divider()
            }

            if hasUpdatedInfo {
                auditRow(title: "Изменено", person: info.updatedBy, date: info.updatedAt)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Информация о графике")
    }

    private func auditRow(title: String, person: String?, date: Date?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedTint)

            if let person {
                Text(person)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
            }

            if let date {
                Text(WorkScheduleFormatting.auditDate(date))
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedTint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WorkScheduleSkeletonView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AppCard {
                HStack(spacing: 10) {
                    SkeletonPlaceholder(cornerRadius: 15).frame(maxWidth: .infinity).frame(height: 44)
                    SkeletonPlaceholder(cornerRadius: 15).frame(maxWidth: .infinity).frame(height: 44)
                }
            }

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    SkeletonPlaceholder(cornerRadius: 8).frame(width: 132, height: 20)
                    ForEach(0..<4, id: \.self) { _ in
                        SkeletonPlaceholder(cornerRadius: 8).frame(width: 40, height: 40)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)

                ForEach(0..<6, id: \.self) { _ in
                    HStack(spacing: 10) {
                        SkeletonPlaceholder(cornerRadius: 18).frame(width: 36, height: 36)
                        SkeletonPlaceholder(cornerRadius: 6).frame(width: 92, height: 16)
                        Spacer(minLength: 2)
                        ForEach(0..<3, id: \.self) { _ in
                            SkeletonPlaceholder(cornerRadius: 10).frame(width: 40, height: 48)
                        }
                    }
                    .frame(height: 68)
                    .padding(.horizontal, 10)
                    .overlay(alignment: .bottom) { Divider() }
                }
            }
            .background(AppTheme.panelSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Загружается график работы")
    }
}

private enum WorkScheduleFormatting {
    private static let monthNames = [
        "Январь", "Февраль", "Март", "Апрель", "Май", "Июнь",
        "Июль", "Август", "Сентябрь", "Октябрь", "Ноябрь", "Декабрь"
    ]
    private static let weekdayNames = ["Вс", "Пн", "Вт", "Ср", "Чт", "Пт", "Сб"]

    static let russianCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "ru_RU")
        return calendar
    }()

    static func monthName(_ month: Int) -> String {
        guard (1...12).contains(month) else { return "Месяц" }
        return monthNames[month - 1]
    }

    static func weekday(day: Int, journal: WorkScheduleJournal) -> String {
        guard let date = date(day: day, journal: journal) else { return "" }
        let weekday = russianCalendar.component(.weekday, from: date)
        return weekdayNames[weekday - 1]
    }

    static func isWeekend(day: Int, journal: WorkScheduleJournal) -> Bool {
        guard let date = date(day: day, journal: journal) else { return false }
        return russianCalendar.isDateInWeekend(date)
    }

    static func hours(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : value.formatted(.number.precision(.fractionLength(1)))
    }

    static func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased(with: AppLocale.russian)
    }

    static func auditDate(_ date: Date) -> String {
        auditDateFormatter.string(from: date)
    }

    private static let auditDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = AppLocale.russian
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter
    }()

    private static func date(day: Int, journal: WorkScheduleJournal) -> Date? {
        russianCalendar.date(from: DateComponents(year: journal.year, month: journal.month, day: day))
    }
}
