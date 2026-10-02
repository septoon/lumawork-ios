import SwiftUI
import UniformTypeIdentifiers

struct TimeReportScreen: View {
    let store: TimeReportStore
    let simpleOneStore: SimpleOneRequestsStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var simpleOnePassword = ""
    @State private var isRefreshingFromSimpleOne = false
    @State private var simpleOneProgressFraction = 0.0
    @State private var simpleOneProgressText = ""
    @State private var isSpreadsheetImporterPresented = false
    @State private var isSpreadsheetExporterPresented = false
    @State private var exportDocument = XLSXExportDocument()
    @State private var exportFileName = "Инженер-time-report.xlsx"
    @State private var cleanupRangeSelection: LocalArchiveCleanupRange?
    @State private var isDeleteAllConfirmationPresented = false
    @State private var browserDestination: SimpleOneBrowserDestination?
    @State private var selectedMonthID: String?

    var body: some View {
        AppScreen {
            VStack(alignment: .leading, spacing: 12) {
                if let errorMessage = store.errorMessage {
                    AppNoticeBanner(text: errorMessage, tint: AppTheme.dangerTint, isCritical: true)
                }

                if let errorMessage = simpleOneStore.errorMessage {
                    AppNoticeBanner(text: errorMessage, tint: AppTheme.dangerTint, isCritical: true)
                }

                if !simpleOneStore.isAuthorized {
                    simpleOneConnectionCard
                }

                if isRefreshingFromSimpleOne {
                    simpleOneProgressCard
                }

                summaryCard
                    .depthStackPrimary(reduceMotion: reduceMotion)

                if store.snapshot == nil {
                    AppEmptyState(
                        title: "Трудозатраты не загружены",
                        message: "Загрузите XLSX-файл, чтобы увидеть сводку по работе и дороге.",
                        systemName: "clock.badge.exclamationmark"
                    )
                } else if store.daySummaries.isEmpty {
                    AppEmptyState(
                        title: "Нет строк для отображения",
                        message: "В загруженной таблице нет трудозатрат, сгруппированных по дням.",
                        systemName: "clock"
                    )
                } else {
                    monthGroupsCard
                        .depthStackSecondary()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .scrollBounceBehavior(.always, axes: .vertical)
        .refreshable {
            if simpleOneStore.isAuthorized {
                await refreshTimeReportFromSimpleOne()
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                monthPicker
            }

            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        AppHaptics.trigger()
                        openSimpleOne(url: Self.timeReportURL(), title: "Создать трудозатраты")
                    } label: {
                        Label("Создать", systemImage: "plus")
                    }

                    Button {
                        AppHaptics.trigger()
                        Task {
                            await refreshTimeReportFromSimpleOne()
                        }
                    } label: {
                        Label("Обновить из SimpleOne", systemImage: "arrow.down.doc")
                    }
                    .disabled(!simpleOneStore.isAuthorized || store.isImporting || isRefreshingFromSimpleOne)

                    Button {
                        AppHaptics.trigger()
                        isSpreadsheetImporterPresented = true
                    } label: {
                        Label(store.snapshot == nil ? "Загрузить XLSX" : "Обновить XLSX", systemImage: "clock.arrow.circlepath")
                    }
                    .disabled(store.isImporting || isRefreshingFromSimpleOne)

                    Button {
                        AppHaptics.trigger()
                        exportTimeReport()
                    } label: {
                        Label("Экспорт XLSX", systemImage: "square.and.arrow.up")
                    }
                    .disabled(store.entries.isEmpty)

                    Divider()

                    Button {
                        AppHaptics.trigger()
                        if let range = store.deletionDateRange {
                            cleanupRangeSelection = LocalArchiveCleanupRange(bounds: range)
                        }
                    } label: {
                        Label("Удалить за период…", systemImage: "calendar.badge.minus")
                    }
                    .disabled(
                        store.deletionDateRange == nil
                            || store.isLoadingSnapshot
                            || store.isDeleting
                            || isRefreshingFromSimpleOne
                    )

                    Button(role: .destructive) {
                        AppHaptics.trigger()
                        isDeleteAllConfirmationPresented = true
                    } label: {
                        Label("Удалить все трудозатраты", systemImage: "trash")
                    }
                    .disabled(
                        store.entries.isEmpty
                            || store.isLoadingSnapshot
                            || store.isDeleting
                            || isRefreshingFromSimpleOne
                    )
                } label: {
                    Label("Действия", systemImage: "ellipsis.circle")
                }
                .disabled(store.isImporting || store.isLoadingSnapshot || store.isDeleting || isRefreshingFromSimpleOne)
            }
        }
        .fileImporter(
            isPresented: $isSpreadsheetImporterPresented,
            allowedContentTypes: [.xlsxSpreadsheet],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else {
                if case .failure(let error) = result {
                    store.errorMessage = appUserFacingErrorMessage(error)
                }
                return
            }

            Task {
                await store.importSpreadsheet(from: url)
            }
        }
        .fileExporter(
            isPresented: $isSpreadsheetExporterPresented,
            document: exportDocument,
            contentType: .xlsxSpreadsheet,
            defaultFilename: exportFileName
        ) { result in
            switch result {
            case .success:
                store.notice = "Экспорт трудозатрат XLSX готов."
            case .failure(let error):
                store.errorMessage = appUserFacingErrorMessage(error)
            }
        }
        .sheet(item: $cleanupRangeSelection) { selection in
            LocalArchivePeriodCleanupSheet(
                title: "Удалить трудозатраты",
                itemCountTitle: "Строк к удалению",
                availableRange: selection.bounds,
                itemCount: { startDate, endDate in
                    store.entryCount(from: startDate, through: endDate)
                },
                deleteAction: { startDate, endDate in
                    let deletedCount = await store.deleteEntries(from: startDate, through: endDate)
                    guard deletedCount > 0 else {
                        return .failure(
                            store.errorMessage
                                ?? store.notice
                                ?? "Не удалось удалить трудозатраты. Повторите попытку."
                        )
                    }
                    return .success
                }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .presentationBackground(AppTheme.modalSurface)
        }
        .fullScreenCover(item: $browserDestination) { destination in
            SimpleOneEmbeddedBrowser(destination: destination)
        }
        .confirmationDialog(
            "Удалить все трудозатраты с устройства?",
            isPresented: $isDeleteAllConfirmationPresented
        ) {
            Button("Удалить все (\(store.entries.count))", role: .destructive) {
                Task {
                    await store.deleteAllEntries()
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Локальный архив будет удалён. Данные в SimpleOne не изменятся и могут загрузиться снова при следующем обновлении.")
        }
        .background {
            if let notice = store.notice {
                AppNoticeBanner(
                    text: notice,
                    tint: AppTheme.primaryTint,
                    style: .success
                )
            }
        }
        .task(id: store.notice) {
            await appDismissTransientMessage(store.notice) { value in
                if store.notice == value {
                    store.notice = nil
                }
            }
        }
        .task(id: store.errorMessage) {
            await appDismissTransientMessage(store.errorMessage) { value in
                if store.errorMessage == value {
                    store.errorMessage = nil
                }
            }
        }
        .task(id: simpleOneStore.errorMessage) {
            await appDismissTransientMessage(simpleOneStore.errorMessage) { value in
                if simpleOneStore.errorMessage == value {
                    simpleOneStore.errorMessage = nil
                }
            }
        }
    }

    private var simpleOneConnectionCard: some View {
        @Bindable var simpleOneBinding = simpleOneStore
        return AppCard {
            VStack(alignment: .leading, spacing: 12) {
                AppSectionHeader(
                    title: "Вход в SimpleOne",
                    caption: "Нужен для обновления трудозатрат."
                )

                TextField("Логин", text: $simpleOneBinding.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
                    .padding(12)
                    .background(AppTheme.buttonFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                SecureField("Пароль", text: $simpleOnePassword)
                    .textContentType(.password)
                    .padding(12)
                    .background(AppTheme.buttonFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                Button {
                    Task {
                        await simpleOneStore.signIn(password: simpleOnePassword)
                        if simpleOneStore.isAuthorized {
                            simpleOnePassword = ""
                            await refreshTimeReportFromSimpleOne()
                        }
                    }
                } label: {
                    HStack {
                        if simpleOneStore.isSigningIn || store.isImporting || store.isLoadingSnapshot || store.isDeleting || isRefreshingFromSimpleOne {
                            ProgressView()
                                .tint(AppTheme.ink)
                        }
                        Text(simpleOneStore.isSigningIn || store.isImporting || store.isLoadingSnapshot || store.isDeleting || isRefreshingFromSimpleOne ? "Загрузка..." : "Войти и обновить")
                    }
                }
                .buttonStyle(AppActionButtonStyle())
                .disabled(simpleOneStore.isSigningIn || store.isImporting || store.isLoadingSnapshot || store.isDeleting || isRefreshingFromSimpleOne)
            }
        }
    }

    private var simpleOneProgressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            AppLoadingView(title: "Обновляю трудозатраты")
            HStack(spacing: 10) {
                ProgressView(value: simpleOneProgressFraction)
                    .tint(AppTheme.primaryTint)
                Text("\(simpleOneProgressPercent)%")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryTint)
            }
            Text(simpleOneProgressText.isEmpty ? "Читаю трудозатраты из SimpleOne." : simpleOneProgressText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedTint)
        }
    }

    private var summaryCard: some View {
        AppCard {
            if store.isImporting {
                AppLoadingView(title: "Импортируем трудозатраты")
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(selectedMonthID == nil ? "За выбранный период" : "За выбранный месяц")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(AppTheme.mutedTint)

                        Text(formatDuration(totalMinutes))
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(AppTheme.ink)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.68)
                    }

                    TimeReportDistributionBar(
                        workMinutes: totalWorkMinutes,
                        travelMinutes: totalTravelMinutes
                    )

                    HStack(alignment: .top, spacing: 16) {
                        TimeReportCategoryMetric(
                            title: "Работа",
                            value: formatDuration(totalWorkMinutes),
                            percent: workPercent,
                            tint: AppTheme.primaryTint
                        )

                        Divider()
                            .overlay(AppTheme.border)

                        TimeReportCategoryMetric(
                            title: "Дорога",
                            value: formatDuration(totalTravelMinutes),
                            percent: travelPercent,
                            tint: AppTheme.secondaryTint
                        )
                    }

                    HStack(spacing: 0) {
                        TimeReportCompactMetric(value: "\(visibleDaySummaries.count)", title: dayCountTitle)
                        metricDivider
                        TimeReportCompactMetric(value: "\(timeReportEntryCount)", title: entryCountTitle)
                        metricDivider
                        TimeReportCompactMetric(value: formatDuration(averageMinutesPerDay), title: "в среднем")
                    }
                    .padding(.vertical, 12)
                    .background(AppTheme.secondaryTint.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(AppTheme.border.opacity(0.72), lineWidth: 1)
                    )

                    if let snapshot = store.snapshot {
                        HStack(spacing: 8) {
                            Label(
                                "Обновлено \(ClosedRequestsAnalyticsContent.importedAtFormatter.string(from: snapshot.importedAt))",
                                systemImage: "clock"
                            )
                            .lineLimit(1)
                            .minimumScaleFactor(0.76)

                            Spacer(minLength: 8)

                            Text(snapshot.fileName == "SimpleOne" ? "Источник: SimpleOne" : "Источник: отчёт XLSX")
                                .lineLimit(1)
                                .minimumScaleFactor(0.76)
                        }
                        .font(.caption2)
                        .foregroundStyle(AppTheme.mutedTint)
                    }
                }
            }
        }
    }

    private var monthGroupsCard: some View {
        AppCard {
            HStack(alignment: .firstTextBaseline) {
                AppSectionHeader(title: "По месяцам")

                Spacer(minLength: 12)

                if selectedMonthID != nil {
                    Button("Показать все") {
                        AppHaptics.trigger(.expandCollapse)
                        selectedMonthID = nil
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryTint)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(visibleMonthGroups) { group in
                    NavigationLink {
                        ClosedRequestsAnalyticsContent.TimeReportMonthDetailsScreen(
                            group: group,
                            onOpenEntry: openTimeReportEntry
                        )
                    } label: {
                        ClosedRequestsAnalyticsContent.TimeReportMonthNavigationCard(group: group)
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            AppHaptics.trigger()
                        }
                    )
                }
            }
        }
    }

    private var monthPicker: some View {
        Menu {
            Button {
                AppHaptics.trigger(.expandCollapse)
                selectedMonthID = nil
            } label: {
                Label("Весь период", systemImage: selectedMonthID == nil ? "checkmark" : "calendar")
            }

            if !timeReportMonthGroups.isEmpty {
                Divider()
            }

            ForEach(timeReportMonthGroups) { group in
                Button {
                    AppHaptics.trigger(.expandCollapse)
                    selectedMonthID = group.id
                } label: {
                    Label(group.title, systemImage: selectedMonthID == group.id ? "checkmark" : "calendar")
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "calendar")
                    .foregroundStyle(AppTheme.primaryTint)

                Text(monthPickerTitle)
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppTheme.mutedTint)
            }
            .font(.headline.weight(.semibold))
        }
        .accessibilityLabel("Выбрать месяц трудозатрат")
        .accessibilityValue(monthPickerTitle)
        .accessibilityIdentifier("timeReport.monthPicker")
    }

    private var totalWorkMinutes: Int {
        visibleDaySummaries.reduce(0) { $0 + $1.workMinutes }
    }

    private var totalTravelMinutes: Int {
        visibleDaySummaries.reduce(0) { $0 + $1.travelMinutes }
    }

    private var totalMinutes: Int {
        totalWorkMinutes + totalTravelMinutes
    }

    private var timeReportEntryCount: Int {
        visibleDaySummaries.reduce(0) { $0 + $1.entries.count }
    }

    private var averageMinutesPerDay: Int {
        guard !visibleDaySummaries.isEmpty else { return 0 }
        return Int((Double(totalMinutes) / Double(visibleDaySummaries.count)).rounded())
    }

    private var workPercent: Int {
        percentage(for: totalWorkMinutes)
    }

    private var travelPercent: Int {
        percentage(for: totalTravelMinutes)
    }

    private var visibleDaySummaries: [TimeReportDaySummary] {
        visibleMonthGroups.flatMap(\.daySummaries)
    }

    private var visibleMonthGroups: [ClosedRequestsAnalyticsContent.TimeReportMonthGroup] {
        guard let selectedMonthID,
              let group = timeReportMonthGroups.first(where: { $0.id == selectedMonthID }) else {
            return timeReportMonthGroups
        }
        return [group]
    }

    private var monthPickerTitle: String {
        if let selectedMonthID,
           let group = timeReportMonthGroups.first(where: { $0.id == selectedMonthID }) {
            return group.title
        }

        guard let newest = timeReportMonthGroups.first,
              let oldest = timeReportMonthGroups.last else {
            return "Выбрать месяц"
        }
        guard newest.id != oldest.id else { return newest.title }

        let newestParts = newest.id.split(separator: "-")
        let oldestParts = oldest.id.split(separator: "-")
        let newestYear = newestParts.first.map(String.init) ?? ""
        let oldestYear = oldestParts.first.map(String.init) ?? ""
        let newestMonth = Self.shortMonthTitle(from: newest.id)
        let oldestMonth = Self.shortMonthTitle(from: oldest.id)

        if newestYear == oldestYear {
            return "\(oldestMonth) — \(newestMonth) \(newestYear)"
        }
        return "\(oldestMonth) \(oldestYear) — \(newestMonth) \(newestYear)"
    }

    private var dayCountTitle: String {
        let remainder100 = visibleDaySummaries.count % 100
        let remainder10 = visibleDaySummaries.count % 10
        if (11...14).contains(remainder100) { return "дней" }
        switch remainder10 {
        case 1: return "день"
        case 2...4: return "дня"
        default: return "дней"
        }
    }

    private var entryCountTitle: String {
        let remainder100 = timeReportEntryCount % 100
        let remainder10 = timeReportEntryCount % 10
        if (11...14).contains(remainder100) { return "записей" }
        switch remainder10 {
        case 1: return "запись"
        case 2...4: return "записи"
        default: return "записей"
        }
    }

    private var metricDivider: some View {
        Divider()
            .overlay(AppTheme.border)
            .frame(height: 38)
    }

    private var timeReportMonthGroups: [ClosedRequestsAnalyticsContent.TimeReportMonthGroup] {
        var groupsByID: [String: [TimeReportDaySummary]] = [:]
        for summary in store.daySummaries {
            let monthID = String(summary.dateKey.prefix(7))
            groupsByID[monthID, default: []].append(summary)
        }

        return groupsByID
            .map { monthID, summaries in
                let sortedSummaries = summaries.sorted { $0.dateKey > $1.dateKey }
                return ClosedRequestsAnalyticsContent.TimeReportMonthGroup(
                    id: monthID,
                    title: ClosedRequestsAnalyticsContent.timeReportMonthTitle(from: monthID),
                    daySummaries: sortedSummaries
                )
            }
            .sorted { $0.id > $1.id }
    }

    private func exportTimeReport() {
        do {
            let data = try XLSXArchiveExporter.makeTimeReportWorkbook(entries: store.entries)
            exportFileName = "Инженер-time-report-\(Self.exportDateFormatter.string(from: Date())).xlsx"
            exportDocument = XLSXExportDocument(data: data)
            isSpreadsheetExporterPresented = true
        } catch {
            store.errorMessage = appUserFacingErrorMessage(error)
        }
    }

    private func refreshTimeReportFromSimpleOne() async {
        guard !store.isDeleting, !store.isImporting, !store.isLoadingSnapshot else { return }
        guard simpleOneStore.isAuthorized else {
            simpleOneStore.errorMessage = SimpleOneServiceError.missingCredentials.errorDescription
            return
        }

        isRefreshingFromSimpleOne = true
        simpleOneProgressFraction = 0.08
        simpleOneProgressText = "Читаю список SimpleOne."
        store.errorMessage = nil
        store.notice = nil
        defer {
            isRefreshingFromSimpleOne = false
            simpleOneProgressFraction = 0
            simpleOneProgressText = ""
        }

        do {
            let entries = try await simpleOneStore.fetchTimeReportEntries { count in
                Task { @MainActor in
                    simpleOneProgressText = "Получено строк: \(count)"
                    simpleOneProgressFraction = min(0.86, 0.18 + Double(count) / 800)
                }
            }
            guard !entries.isEmpty else {
                throw SimpleOneServiceError.server("SimpleOne не вернул строки трудозатрат.")
            }

            simpleOneProgressFraction = 0.9
            simpleOneProgressText = "Сохраняю локальный архив."
            await store.mergeSimpleOneTimeReportEntries(entries)
            if store.errorMessage == nil {
                simpleOneProgressFraction = 1
                simpleOneProgressText = "Готово."
            }
        } catch {
            guard let message = appUserFacingErrorMessage(error) else { return }
            await refreshTimeReportFromSimpleOneXLSXFallback(originalErrorMessage: message)
        }
    }

    private func refreshTimeReportFromSimpleOneXLSXFallback(originalErrorMessage: String) async {
        store.errorMessage = nil
        store.notice = nil

        do {
            simpleOneProgressFraction = 0.38
            simpleOneProgressText = "JSON недоступен. Жду XLSX SimpleOne."
            let exportedFile = try await simpleOneStore.exportTimeReportXLSXForCurrentUser()
            simpleOneProgressFraction = 0.78
            simpleOneProgressText = "Разбираю XLSX."
            await store.importSpreadsheet(data: exportedFile.data, fileName: exportedFile.fileName)
            if store.errorMessage == nil {
                simpleOneProgressFraction = 1
                simpleOneProgressText = "Готово."
            }
        } catch {
            store.notice = nil
            guard let message = appUserFacingErrorMessage(error) else { return }
            store.errorMessage = "\(originalErrorMessage) Резервный XLSX: \(message)"
        }
    }

    private func formatDuration(_ minutes: Int) -> String {
        ClosedRequestsAnalyticsContent.formatDurationWords(minutes)
    }

    private func percentage(for minutes: Int) -> Int {
        guard totalMinutes > 0 else { return 0 }
        return Int((Double(minutes) / Double(totalMinutes) * 100).rounded())
    }

    private func openTimeReportEntry(_ entry: TimeReportEntry) {
        guard let recordID = entry.simpleOneRecordID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !recordID.isEmpty else {
            store.errorMessage = "У этой архивной строки нет ID SimpleOne. Обновите трудозатраты из SimpleOne."
            AppHaptics.trigger(.error)
            return
        }
        let url = Self.timeReportURL(recordID: recordID)
        openSimpleOne(url: url, title: "Трудозатраты")
    }

    private func openSimpleOne(url: URL, title: String) {
        guard let authKey = simpleOneStore.browserAuthKey, !authKey.isEmpty else {
            simpleOneStore.errorMessage = "Сначала войдите в SimpleOne."
            AppHaptics.trigger(.error)
            return
        }
        browserDestination = SimpleOneBrowserDestination(
            url: url,
            authKey: authKey,
            title: title
        )
    }

    private var simpleOneProgressPercent: Int {
        min(100, max(0, Int((simpleOneProgressFraction * 100).rounded())))
    }

    private static let exportDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func shortMonthTitle(from monthID: String) -> String {
        guard let date = ClosedRequestsAnalyticsContent.timeReportMonthKeyFormatter.date(from: monthID) else {
            return monthID
        }
        let title = shortMonthFormatter.string(from: date).replacingOccurrences(of: ".", with: "")
        return title.prefix(1).uppercased() + title.dropFirst()
    }

    private static let shortMonthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "LLL"
        return formatter
    }()

    private static func timeReportURL(recordID: String? = nil) -> URL {
        var url = AppConfig.configuredURL(AppConfig().simpleOneWebOrigin)
            .appendingPathComponent("record/itsm_tchnsrv_time_report")
        if let recordID, !recordID.isEmpty {
            url.appendPathComponent(recordID)
        }
        url.append(queryItems: [URLQueryItem(name: "form_view", value: "Внешняя система")])
        return url
    }
}

private struct TimeReportDistributionBar: View {
    let workMinutes: Int
    let travelMinutes: Int

    private var workFraction: CGFloat {
        let total = workMinutes + travelMinutes
        guard total > 0 else { return 0 }
        return CGFloat(workMinutes) / CGFloat(total)
    }

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                Rectangle()
                    .fill(AppTheme.primaryTint)
                    .frame(width: proxy.size.width * workFraction)

                Rectangle()
                    .fill(AppTheme.secondaryTint)
            }
        }
        .frame(height: 12)
        .background(AppTheme.softFill)
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Работа и дорога")
        .accessibilityValue("Работа \(workMinutes) минут, дорога \(travelMinutes) минут")
    }
}

private struct TimeReportCategoryMetric: View {
    let title: String
    let value: String
    let percent: Int
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Circle()
                    .fill(tint)
                    .frame(width: 9, height: 9)

                Text(title)
                    .foregroundStyle(AppTheme.mutedTint)
            }
            .font(.subheadline)

            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(AppTheme.ink)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.68)

            Text("\(percent)%")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TimeReportCompactMetric: View {
    let value: String
    let title: String

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AppTheme.ink)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Text(title)
                .font(.caption2)
                .foregroundStyle(AppTheme.mutedTint)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}
