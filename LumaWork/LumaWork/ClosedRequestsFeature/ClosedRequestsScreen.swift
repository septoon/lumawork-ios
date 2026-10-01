import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ClosedRequestsScreen: View {
    let store: ClosedRequestsStore
    let sessionStore: AppSessionStore
    let simpleOneStore: SimpleOneRequestsStore
    let clientCommentsStore: ClientPersonalCommentsStore
    let requestedActiveRequestID: String?
    let onRequestedActiveRequestHandled: (String) -> Void

    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @AppStorage("ClosedRequestsScreen.activeStatusFilter")
    var activeStatusFilterRaw = ActiveRequestsStatusFilter.available.rawValue

    @State var closedSimpleOneStore = ClosedSimpleOneRequestsStore()
    @State var requestsMode: RequestsViewMode = .active
    @State var simpleOnePassword = ""
    @State var searchText = ""
    @State var committedClosedSearchText = ""
    @State var clientCommentDraft: ClientPersonalCommentDraft?
    @State var clientCommentTargetOptions: [ClientPersonalCommentTarget] = []
    @State var clientCommentTerminalOptions: [ClientPersonalCommentTerminalOption] = []
    @State var clientCommentCurrentTarget: ClientPersonalCommentTarget?
    @State var clientCommentCurrentTerminalID = ""
    @State var currentPage = 1
    @State var isSpreadsheetImporterPresented = false
    @State var isSpreadsheetExporterPresented = false
    @State var exportDocument = XLSXExportDocument()
    @State var exportFileName = "LumaWork.xlsx"
    @State var selectedRequestRoute: RequestDetailRoute?
    @State var searchEntries: [SearchEntry] = []
    @State var closedRequestsCache: [ClosedRequestRecord] = []
    @State var filteredRecordsCache: [ClosedRequestListItem] = []
    @State var activeRequestItemsCache: [ActiveRequestListItem] = []
    @State var filteredActiveRequestItemsCache: [ActiveRequestListItem] = []
    @State var warehouseTerminalSelection: WarehouseTerminalSelection?
    @State var warehouseSearchRecords: [SimpleOneRequestRecord] = []
    @State var isWarehouseSearchLoading = false
    @State var warehouseSearchError: String?
    @State var isActiveStatusPickerPresented = false
    @State var isRefreshingSimpleOneData = true
    @State var isRefreshingClosedRequestsArchive = false
    @State var closedRequestsNoChangeStreak = 0
    @State var closedArchiveProgressFraction = 0.0
    @State var closedArchiveProgressText = ""
    @State var cleanupRangeSelection: LocalArchiveCleanupRange?
    @State var isDeleteAllConfirmationPresented = false
    @State var closedDateRange: ClosedRange<Date>?
    @State var automaticClosedDateRange: ClosedRange<Date>?
    @State var closedDateRangeSelection: ClosedRequestsDateRangeSelection?
    @State var closedDayPositions: [String: CGFloat] = [:]

    let pageSize = 30

    init(
        store: ClosedRequestsStore,
        sessionStore: AppSessionStore,
        simpleOneStore: SimpleOneRequestsStore,
        clientCommentsStore: ClientPersonalCommentsStore,
        requestedActiveRequestID: String? = nil,
        onRequestedActiveRequestHandled: @escaping (String) -> Void = { _ in }
    ) {
        self.store = store
        self.sessionStore = sessionStore
        self.simpleOneStore = simpleOneStore
        self.clientCommentsStore = clientCommentsStore
        self.requestedActiveRequestID = requestedActiveRequestID
        self.onRequestedActiveRequestHandled = onRequestedActiveRequestHandled
    }

    var body: some View {
        AppScreen(fixedTopContent: {
            if simpleOneStore.isAuthorized {
                switch requestsMode {
                case .active:
                    activeRequestsHeader
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                case .closed:
                    if !store.isLoadingSnapshot, !closedRequests.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            closedRequestsHeader

                            if let currentDay = visibleClosedDay {
                                ClosedRequestDayHeader(
                                    title: currentDay.title,
                                    caption: currentDay.caption
                                )
                                .id(currentDay.id)
                                .transition(.opacity)
                            }
                        }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                    }
                case .warehouse, .closedSimpleOne:
                    EmptyView()
                }
            }
        }) {
            requestsScreenContent
        }
        .navigationTitle("Заявки")
        .navigationBarTitleDisplayMode(.inline)
        .appNativeSearch(
            text: $searchText,
            prompt: bottomSearchPrompt,
            isEnabled: simpleOneStore.isAuthorized
        )
        .scrollBounceBehavior(.always, axes: .vertical)
        .refreshable {
            if simpleOneStore.isAuthorized {
                await refreshSimpleOneRequests()
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Раздел заявок", selection: $requestsMode) {
                    ForEach(RequestsViewMode.visibleCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 196)
            }

            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task {
                            await refreshAllSimpleOneData()
                        }
                    } label: {
                        Label("Обновить SimpleOne", systemImage: "arrow.clockwise")
                    }
                    .disabled(simpleOneStore.isLoading || !simpleOneStore.isAuthorized || isRefreshingClosedRequestsArchive)

                    Button {
                        Task {
                            await refreshClosedRequestsArchiveFromSimpleOne()
                        }
                    } label: {
                        Label("Обновить закрытые из SimpleOne", systemImage: "tray.and.arrow.down")
                    }
                    .disabled(!simpleOneStore.isAuthorized || store.isImporting || store.isSynchronizingClosedRequests || isRefreshingClosedRequestsArchive)

                    Button {
                        AppHaptics.trigger()
                        let draft = ClientPersonalCommentDraftStore.load() ?? ClientPersonalCommentDraft()
                        var targetsByKey = Dictionary(
                            uniqueKeysWithValues: clientCommentTargets(forTIN: draft.tin, including: nil)
                                .map { ($0.normalizedKey, $0) }
                        )
                        for target in draft.targets {
                            targetsByKey[target.normalizedKey] = target
                        }
                        clientCommentTargetOptions = Array(targetsByKey.values).sorted {
                            $0.displayText.localizedCaseInsensitiveCompare($1.displayText) == .orderedAscending
                        }
                        clientCommentTerminalOptions = clientCommentTerminals(
                            forTIN: draft.tin,
                            including: "",
                            at: nil
                        )
                        clientCommentCurrentTarget = nil
                        clientCommentCurrentTerminalID = ""
                        clientCommentDraft = draft
                    } label: {
                        Label("Комментарий", systemImage: "text.bubble")
                    }

                    if simpleOneStore.isAuthorized {
                        Button(role: .destructive) {
                            simpleOneStore.signOut()
                            simpleOnePassword = ""
                        } label: {
                            Label("Выйти из SimpleOne", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }

                    Button {
                        AppHaptics.trigger()
                        isSpreadsheetImporterPresented = true
                    } label: {
                        Label(store.snapshot == nil ? "Загрузить заявки" : "Обновить заявки", systemImage: "checklist.checked")
                    }
                    .disabled(
                        store.isImporting
                            || store.isLoadingSnapshot
                            || store.isDeleting
                            || store.isSynchronizingClosedRequests
                            || isRefreshingClosedRequestsArchive
                    )

                    Button {
                        AppHaptics.trigger()
                        exportClosedRequests()
                    } label: {
                        Label("Экспорт заявок XLSX", systemImage: "square.and.arrow.up")
                    }
                    .disabled(store.records.isEmpty)

                    closedRequestsCleanupMenuItems
                } label: {
                    Label("Действия", systemImage: "ellipsis.circle")
                }
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
                _ = await synchronizeClosedRequestsAutomatically(scope: .narrow)
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
                store.notice = "Экспорт XLSX готов."
            case .failure(let error):
                store.errorMessage = appUserFacingErrorMessage(error)
            }
        }
        .onAppear {
            if requestsMode == .closedSimpleOne {
                requestsMode = .active
            }
            rebuildActiveRequestItems()
        }
        .onChange(of: searchText) { _, _ in
            currentPage = 1
            switch requestsMode {
            case .active:
                refreshFilteredActiveRequestItems()
            case .closed:
                break
            case .warehouse, .closedSimpleOne:
                break
            }
        }
        .onChange(of: activeStatusFilterRaw) { _, _ in
            refreshFilteredActiveRequestItems()
        }
        .onChange(of: requestsMode) { _, newMode in
            AppHaptics.trigger(.expandCollapse)
            if newMode == .closedSimpleOne {
                requestsMode = .active
            }
            currentPage = 1
        }
        .task(id: simpleOneStore.activeRequestsRevision) {
            rebuildActiveRequestItems()
            handleRequestedActiveRequestIfNeeded()
        }
        .task(id: requestedActiveRequestID) {
            handleRequestedActiveRequestIfNeeded()
        }
        .task(id: isRefreshingSimpleOneData) {
            handleRequestedActiveRequestIfNeeded()
        }
        .task(id: store.recordsRevision) {
            await rebuildSearchIndex()
        }
        .task(id: closedSearchTaskID) {
            await commitClosedSearchAfterDelay()
        }
        .task(id: warehouseSearchTaskID) {
            await searchWarehouseRequestsIfNeeded()
        }
        .task(id: simpleOneStore.isAuthorized) {
            guard simpleOneStore.isAuthorized else {
                clientCommentsStore.errorMessage = nil
                isRefreshingSimpleOneData = false
                return
            }
            guard !simpleOneStore.isSigningIn else {
                isRefreshingSimpleOneData = false
                return
            }
            await refreshSimpleOneRequests(showsSuccessNotice: false, forceCommentsRefresh: false)
        }
        .task(id: closedRequestsAutomaticSyncTaskID) {
            await runClosedRequestsAutomaticSyncLoop()
        }
        .sheet(item: $clientCommentDraft) { draft in
            ClientPersonalCommentEditor(
                initialDraft: draft,
                targetOptions: clientCommentTargetOptions,
                terminalOptions: clientCommentTerminalOptions,
                currentTarget: clientCommentCurrentTarget,
                currentTerminalID: clientCommentCurrentTerminalID,
                onSave: { updatedDraft in
                    ClientPersonalCommentDraftStore.save(updatedDraft)
                    Task {
                        do {
                            try await clientCommentsStore.save(updatedDraft)
                            ClientPersonalCommentDraftStore.clear()
                            store.notice = "Личный комментарий сохранен."
                        } catch {
                            store.errorMessage = appUserFacingErrorMessage(error)
                        }
                    }
                }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(.disabled)
        }
        .sheet(item: $warehouseTerminalSelection) { selection in
            WarehouseRequestsSheet(
                terminalID: selection.terminalID,
                simpleOneStore: simpleOneStore
            )
        }
        .sheet(item: $closedDateRangeSelection) { selection in
            ClosedRequestsPeriodFilterSheet(
                availableRange: selection.availableRange,
                selectedRange: selection.selectedRange
            ) { startDate, endDate in
                closedDateRange = ClosedRequestsFilterSupport.normalizedRange(
                    first: startDate,
                    second: endDate
                )
                currentPage = 1
                refreshFilteredRecords()
            } onReset: {
                closedDateRange = nil
                currentPage = 1
                refreshFilteredRecords()
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(AppTheme.modalSurface)
        }
        .modifier(ClosedRequestsCleanupPresentationModifier(
            store: store,
            cleanupRangeSelection: $cleanupRangeSelection,
            isDeleteAllConfirmationPresented: $isDeleteAllConfirmationPresented
        ))
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
        .navigationDestination(
            isPresented: requestDetailPresentationBinding
        ) {
            requestDetailDestinationView
        }
    }

    @ViewBuilder
    private var requestsScreenContent: some View {
        if !simpleOneStore.isAuthorized {
            simpleOneConnectionCard
        } else {
            VStack(alignment: .leading, spacing: 16) {
                if let notice = store.notice {
                    AppNoticeBanner(text: notice, tint: AppTheme.primaryTint)
                }

                if let errorMessage = store.errorMessage {
                    AppNoticeBanner(text: errorMessage, tint: AppTheme.dangerTint, isCritical: true)
                }

                if let errorMessage = simpleOneStore.errorMessage {
                    AppNoticeBanner(text: errorMessage, tint: AppTheme.dangerTint, isCritical: true)
                }

                if let errorMessage = clientCommentsStore.errorMessage {
                    AppNoticeBanner(text: errorMessage, tint: AppTheme.dangerTint, isCritical: true)
                }

                if isRefreshingClosedRequestsArchive {
                    closedArchiveProgressCard
                }

                requestsModePage(requestsMode)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension ClosedRequestsScreen {
    var activeStatusFilter: ActiveRequestsStatusFilter {
        ActiveRequestsStatusFilter(rawValue: activeStatusFilterRaw) ?? .available
    }

    func handleRequestedActiveRequestIfNeeded() {
        guard let requestID = requestedActiveRequestID else { return }
        requestsMode = .active

        if let record = simpleOneStore.activeRequests.first(where: { $0.id == requestID }) {
            onRequestedActiveRequestHandled(requestID)
            openSimpleOneRequest(record)
            return
        }

        guard !isRefreshingSimpleOneData, !simpleOneStore.isLoading else { return }

        if !simpleOneStore.isAuthorized {
            AppBannerCenter.shared.show(
                "Войдите в SimpleOne, чтобы открыть заявку.",
                style: .information
            )
            onRequestedActiveRequestHandled(requestID)
            return
        }

        guard simpleOneStore.lastUpdatedAt != nil || simpleOneStore.errorMessage != nil else { return }
        AppBannerCenter.shared.show(
            "Заявка \(requestID) не найдена среди активных.",
            style: .information
        )
        onRequestedActiveRequestHandled(requestID)
    }
}

private extension ClosedRequestsScreen {
    @ViewBuilder
    var closedRequestsCleanupMenuItems: some View {
        if requestsMode == .closed {
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
                    || isRefreshingClosedRequestsArchive
            )

            Button(role: .destructive) {
                AppHaptics.trigger()
                isDeleteAllConfirmationPresented = true
            } label: {
                Label("Удалить все закрытые заявки", systemImage: "trash")
            }
            .disabled(
                store.records.isEmpty
                    || store.isLoadingSnapshot
                    || store.isDeleting
                    || isRefreshingClosedRequestsArchive
            )
        }
    }

    var bottomSearchPrompt: String {
        "Поиск"
    }

    var activeRequestsHeader: some View {
        HStack(spacing: 8) {
            Button {
                AppHaptics.trigger(.expandCollapse)
                isActiveStatusPickerPresented = true
            } label: {
                HStack(spacing: 8) {
                    Text(activeStatusFilter.title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(AppTheme.ink)
                        .lineLimit(1)

                    Text(filteredActiveRequestItemsCache.count, format: .number)
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(AppTheme.primaryTint)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(AppTheme.primaryTint.opacity(0.14), in: Capsule())

                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(AppTheme.mutedTint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "Выбрать статус. \(activeStatusFilter.title), \(filteredActiveRequestItemsCache.count)"
            )
            .popover(
                isPresented: $isActiveStatusPickerPresented,
                attachmentAnchor: .rect(.bounds),
                arrowEdge: .top
            ) {
                ActiveRequestStatusPopover(
                    selected: activeStatusFilter,
                    counts: activeRequestStatusCounts
                ) { filter in
                    AppHaptics.trigger(.expandCollapse)
                    activeStatusFilterRaw = filter.rawValue
                    isActiveStatusPickerPresented = false
                }
                .presentationCompactAdaptation(.popover)
            }

            Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var activeRequestStatusCounts: [ActiveRequestsStatusFilter: Int] {
        var counts = Dictionary(
            uniqueKeysWithValues: ActiveRequestsStatusFilter.allCases.map { ($0, 0) }
        )
        let query = normalizedSearchQuery
        for item in activeRequestItemsCache
        where query.isEmpty || item.searchText.contains(query) {
            for filter in item.matchingStatusFilters {
                counts[filter, default: 0] += 1
            }
        }
        return counts
    }

    @ViewBuilder
    func requestsModePage(_ mode: RequestsViewMode) -> some View {
        switch mode {
        case .active:
            if (isRefreshingSimpleOneData || simpleOneStore.isLoading), simpleOneStore.lastUpdatedAt == nil {
                AppLoadingView(title: "Обновляю активные заявки")
                    .frame(maxWidth: .infinity, minHeight: 420, alignment: .center)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    simpleOneRequestsContent(
                        emptyTitle: "Активных заявок нет",
                        emptyMessage: simpleOneStore.isAuthorized
                            ? "По текущему фильтру SimpleOne ничего не найдено."
                            : "Войдите в SimpleOne, чтобы загрузить активные заявки.",
                        records: filteredActiveRequestItemsCache
                    )
                }
            }
        case .warehouse:
            warehouseRequestsContent
        case .closedSimpleOne:
            ClosedSimpleOneRequestsSection(
                store: closedSimpleOneStore,
                simpleOneStore: simpleOneStore,
                searchText: searchText
            ) { record in
                selectedRequestRoute = .closedSimpleOne(record)
            }
        case .closed:
            closedRequestsContent
        }
    }

    @ViewBuilder
    var closedRequestsContent: some View {
        if store.isLoadingSnapshot {
            AppLoadingView(title: "Открываю локальную базу заявок")
        } else if closedRequests.isEmpty {
            AppEmptyState(
                title: "Закрытых заявок пока нет",
                message: "Загрузите Excel-файл, чтобы наполнить локальный архив.",
                systemName: "checklist.checked"
            )
        } else {
            if filteredRecordsCache.isEmpty {
                AppEmptyState(
                    title: closedRequestsEmptyTitle,
                    message: closedRequestsEmptyMessage,
                    systemName: "magnifyingglass"
                )
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(paginatedDayGroups) { group in
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(group.records) { record in
                                requestCard(record)
                                    .depthStackPrimary(
                                        reduceMotion: reduceMotion,
                                        stage: closedRequestDepthStages[record.id, default: 0]
                                    )
                            }
                        }
                        .background(alignment: .top) {
                            ClosedRequestDayMarker(dayKey: group.id)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onPreferenceChange(ClosedRequestDayPositionKey.self) { positions in
                    let keys = paginatedDayGroups.map(\.id)
                    let previous = ClosedRequestDayTracking.visibleKey(
                        orderedKeys: keys, positions: closedDayPositions
                    )
                    let next = ClosedRequestDayTracking.visibleKey(
                        orderedKeys: keys, positions: positions
                    )
                    if previous == next {
                        closedDayPositions = positions
                    } else {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            closedDayPositions = positions
                        }
                    }
                }

                if pageCount > 1 {
                    paginationCard
                }
            }
        }
    }

    var closedRequestDepthStages: [String: Int] {
        Dictionary(
            uniqueKeysWithValues: paginatedRecords.enumerated().map { index, record in
                (record.id, index)
            }
        )
    }

    var visibleClosedDay: ClosedRequestDayGroup? {
        let groups = paginatedDayGroups
        guard let key = ClosedRequestDayTracking.visibleKey(
            orderedKeys: groups.map(\.id),
            positions: closedDayPositions
        ) else { return nil }
        return groups.first { $0.id == key }
    }

    var closedRequestsEmptyTitle: String {
        if !normalizedClosedSearchQuery.isEmpty { return "Ничего не найдено" }
        return "За выбранную дату заявок нет"
    }

    var closedRequestsEmptyMessage: String {
        if !normalizedClosedSearchQuery.isEmpty {
            return closedDateRange == nil
                ? "Поиск выполнен по всему архиву. Измените запрос."
                : "Измените запрос или выбранный период."
        }
        return "Выберите другой период или воспользуйтесь поиском по всему архиву."
    }

    var closedRequestsHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            AppSectionHeader(
                title: "Закрытые заявки",
                caption: "\(filteredRecordsCache.count) из \(closedRequests.count)"
            )

            Spacer(minLength: 8)

            Button {
                presentClosedRequestsDateRangePicker()
            } label: {
                Label(closedRequestsDateRangeTitle, systemImage: "calendar")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryTint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(AppTheme.primaryTint.opacity(0.10), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Период закрытых заявок: \(closedRequestsDateRangeTitle)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var closedRequestsDateRangeTitle: String {
        guard let range = effectiveClosedDateRange else { return "Выбрать дату" }
        if closedDateRange == nil,
           range.lowerBound == todayAndYesterdayClosedDateRange.lowerBound,
           range.upperBound == todayAndYesterdayClosedDateRange.upperBound {
            return "Сегодня и вчера"
        }
        let start = Self.filterDateFormatter.string(from: range.lowerBound)
        let end = Self.filterDateFormatter.string(from: range.upperBound)
        return start == end ? start : "\(start)–\(end)"
    }

    func presentClosedRequestsDateRangePicker() {
        let dates = searchEntries.compactMap(\.item.date)
        guard let firstDate = dates.min(), let lastDate = dates.max() else { return }
        let calendar = Calendar.autoupdatingCurrent
        let availableRange = calendar.startOfDay(for: firstDate)...calendar.startOfDay(for: lastDate)
        closedDateRangeSelection = ClosedRequestsDateRangeSelection(
            availableRange: availableRange,
            selectedRange: effectiveClosedDateRange ?? availableRange.upperBound...availableRange.upperBound
        )
    }
}

@MainActor
private struct ClosedRequestsPeriodFilterSheet: View {
    @Environment(\.dismiss) private var dismiss

    let availableRange: ClosedRange<Date>
    let onApply: (Date, Date) -> Void
    let onReset: () -> Void

    @State private var mode: SelectionMode = .choices
    @State private var visibleMonth: Date
    @State private var startDate: Date?
    @State private var endDate: Date?

    init(
        availableRange: ClosedRange<Date>,
        selectedRange: ClosedRange<Date>,
        onApply: @escaping (Date, Date) -> Void,
        onReset: @escaping () -> Void
    ) {
        self.availableRange = availableRange
        self.onApply = onApply
        self.onReset = onReset
        let initialStart = min(max(selectedRange.lowerBound, availableRange.lowerBound), availableRange.upperBound)
        let initialEnd = min(max(selectedRange.upperBound, availableRange.lowerBound), availableRange.upperBound)
        _visibleMonth = State(initialValue: initialStart)
        _startDate = State(initialValue: initialStart)
        _endDate = State(initialValue: initialEnd)
    }

    var body: some View {
        NavigationStack {
            AppScreen(bottomContentPadding: 20) {
                AppCard {
                    switch mode {
                    case .choices:
                        AppSectionHeader(
                            title: "Дата заявок",
                            caption: "Доступно: \(formatted(availableRange.lowerBound)) — \(formatted(availableRange.upperBound))"
                        )
                        filterChoice(
                            title: "Один день",
                            subtitle: "Выберите дату — список откроется сразу",
                            systemImage: "calendar"
                        ) {
                            mode = .day
                        }
                        Divider()
                        filterChoice(
                            title: "Период",
                            subtitle: "Укажите начало и конец в одном календаре",
                            systemImage: "calendar.badge.clock"
                        ) {
                            startDate = nil
                            endDate = nil
                            mode = .range
                        }
                    case .day, .range:
                        AppSectionHeader(
                            title: mode == .day ? "Один день" : "Период",
                            caption: mode == .day
                                ? "Нажмите на нужную дату"
                                : rangeSelectionCaption
                        )
                        ClosedRequestsMonthCalendar(
                            visibleMonth: $visibleMonth,
                            availableRange: availableRange,
                            selectedStart: startDate,
                            selectedEnd: mode == .range ? endDate : nil,
                            onSelect: selectDate
                        )

                        if mode == .range {
                            Button("Показать заявки") {
                                guard let startDate, let endDate else { return }
                                AppHaptics.trigger()
                                onApply(startDate, endDate)
                                dismiss()
                            }
                            .buttonStyle(AppActionButtonStyle())
                            .disabled(startDate == nil || endDate == nil)
                        }
                    }
                }
            }
            .navigationTitle("Фильтр по дате")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if mode == .choices {
                        ModalCloseButton(action: dismiss.callAsFunction)
                    } else {
                        Button {
                            mode = .choices
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Сбросить") {
                        onReset()
                        dismiss()
                    }
                }
            }
        }
    }

    private var rangeSelectionCaption: String {
        switch (startDate, endDate) {
        case (.none, _): return "Сначала выберите дату начала"
        case (.some, .none): return "Теперь выберите дату окончания"
        case let (.some(start), .some(end)): return "\(formatted(start)) — \(formatted(end))"
        }
    }

    private func filterChoice(
        title: String,
        subtitle: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            AppHaptics.trigger(.expandCollapse)
            action()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryTint)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(AppTheme.ink)
                    Text(subtitle).font(.caption).foregroundStyle(AppTheme.mutedTint)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppTheme.mutedTint)
            }
            .frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func selectDate(_ date: Date) {
        if mode == .day {
            AppHaptics.trigger()
            onApply(date, date)
            dismiss()
            return
        }
        if startDate == nil || endDate != nil {
            startDate = date
            endDate = nil
        } else if let startDate {
            let range = ClosedRequestsFilterSupport.normalizedRange(first: startDate, second: date)
            self.startDate = range.lowerBound
            endDate = range.upperBound
        }
    }

    private func formatted(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.wide).year().locale(AppLocale.russian))
    }

    private enum SelectionMode {
        case choices
        case day
        case range
    }
}

private struct ClosedRequestsMonthCalendar: View {
    @Binding var visibleMonth: Date
    let availableRange: ClosedRange<Date>
    let selectedStart: Date?
    let selectedEnd: Date?
    let onSelect: (Date) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = AppLocale.russian
        calendar.firstWeekday = 2
        return calendar
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                monthButton(systemImage: "chevron.left", offset: -1)
                Spacer()
                Text(monthTitle)
                    .font(.headline)
                Spacer()
                monthButton(systemImage: "chevron.right", offset: 1)
            }

            LazyVGrid(columns: columns, spacing: 7) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedTint)
                        .frame(maxWidth: .infinity)
                }
                ForEach(Array(monthDays.enumerated()), id: \.offset) { _, day in
                    if let day {
                        dayButton(day)
                    } else {
                        Color.clear.frame(height: 38)
                    }
                }
            }
        }
    }

    private var monthStart: Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: visibleMonth)) ?? visibleMonth
    }

    private var monthTitle: String {
        monthStart.formatted(.dateTime.month(.wide).year().locale(AppLocale.russian)).capitalized
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return Array(symbols[1...]) + [symbols[0]]
    }

    private var monthDays: [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: monthStart) else { return [] }
        let weekday = calendar.component(.weekday, from: monthStart)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: leading) + range.compactMap { day in
            calendar.date(bySetting: .day, value: day, of: monthStart)
        }.map(Optional.some)
    }

    private func monthButton(systemImage: String, offset: Int) -> some View {
        let candidate = calendar.date(byAdding: .month, value: offset, to: monthStart) ?? monthStart
        let isEnabled = offset < 0
            ? candidate >= calendar.date(from: calendar.dateComponents([.year, .month], from: availableRange.lowerBound))!
            : candidate <= calendar.date(from: calendar.dateComponents([.year, .month], from: availableRange.upperBound))!
        return Button {
            visibleMonth = candidate
        } label: {
            Image(systemName: systemImage).frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? AppTheme.primaryTint : AppTheme.mutedTint.opacity(0.35))
        .disabled(!isEnabled)
    }

    private func dayButton(_ date: Date) -> some View {
        let day = calendar.startOfDay(for: date)
        let lower = calendar.startOfDay(for: availableRange.lowerBound)
        let upper = calendar.startOfDay(for: availableRange.upperBound)
        let isEnabled = day >= lower && day <= upper
        let isEndpoint = [selectedStart, selectedEnd].compactMap { $0 }.contains { calendar.isDate($0, inSameDayAs: day) }
        let isInRange: Bool = {
            guard let selectedStart, let selectedEnd else { return false }
            let range = ClosedRequestsFilterSupport.normalizedRange(first: selectedStart, second: selectedEnd, calendar: calendar)
            return day >= range.lowerBound && day <= range.upperBound
        }()
        return Button {
            onSelect(day)
        } label: {
            Text(day, format: .dateTime.day())
                .font(.subheadline.weight(isEndpoint ? .bold : .medium))
                .foregroundStyle(isEndpoint ? Color.white : (isEnabled ? AppTheme.ink : AppTheme.mutedTint.opacity(0.35)))
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(
                    isEndpoint ? AppTheme.primaryTint : AppTheme.primaryTint.opacity(isInRange ? 0.12 : 0),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

private struct ClosedRequestsCleanupPresentationModifier: ViewModifier {
    let store: ClosedRequestsStore
    @Binding var cleanupRangeSelection: LocalArchiveCleanupRange?
    @Binding var isDeleteAllConfirmationPresented: Bool

    func body(content: Content) -> some View {
        content
            .sheet(item: $cleanupRangeSelection) { selection in
                LocalArchivePeriodCleanupSheet(
                    title: "Удалить закрытые заявки",
                    itemCountTitle: "Заявок к удалению",
                    availableRange: selection.bounds,
                    additionalMessage: "Заявки без распознаваемой даты останутся в архиве.",
                    itemCount: { startDate, endDate in
                        store.recordCount(from: startDate, through: endDate)
                    },
                    deleteAction: { startDate, endDate in
                        let deletedCount = await store.deleteRecords(from: startDate, through: endDate)
                        guard deletedCount > 0 else {
                            return .failure(
                                store.errorMessage
                                    ?? store.notice
                                    ?? "Не удалось удалить закрытые заявки. Повторите попытку."
                            )
                        }
                        return .success
                    }
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.modalSurface)
            }
            .confirmationDialog(
                "Удалить все закрытые заявки с устройства?",
                isPresented: $isDeleteAllConfirmationPresented
            ) {
                Button("Удалить все (\(store.records.count))", role: .destructive) {
                    Task {
                        await store.deleteAllRecords()
                    }
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Локальный архив будет удалён. Данные в SimpleOne не изменятся и могут загрузиться снова при следующем обновлении.")
            }
    }
}

private struct ActiveRequestStatusPopover: View {
    let selected: ActiveRequestsStatusFilter
    let counts: [ActiveRequestsStatusFilter: Int]
    let select: (ActiveRequestsStatusFilter) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Статус заявок")
                .font(.caption.weight(.bold))
                .tracking(1.1)
                .foregroundStyle(AppTheme.mutedTint)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 6)

            ForEach(Array(ActiveRequestsStatusFilter.allCases.enumerated()), id: \.element.id) { index, filter in
                Button {
                    select(filter)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: filter.systemImage)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(
                                filter == selected ? AppTheme.primaryTint : AppTheme.mutedTint
                            )
                            .frame(width: 24)

                        Text(filter.title)
                            .font(.body.weight(filter == selected ? .semibold : .regular))
                            .foregroundStyle(AppTheme.ink)

                        Spacer(minLength: 16)

                        Text(counts[filter, default: 0], format: .number)
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .foregroundStyle(AppTheme.mutedTint)
                            .frame(minWidth: 28, alignment: .trailing)

                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppTheme.primaryTint)
                            .opacity(filter == selected ? 1 : 0)
                            .frame(width: 16)
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if index < ActiveRequestsStatusFilter.allCases.count - 1 {
                    Divider()
                        .padding(.leading, 48)
                }
            }
        }
        .padding(.vertical, 6)
        .frame(width: 280)
        .accessibilityElement(children: .contain)
    }
}

private extension ClosedRequestsScreen {
    var requestDetailPresentationBinding: Binding<Bool> {
        Binding(
            get: { selectedRequestRoute != nil },
            set: { isPresented in
                if !isPresented {
                    selectedRequestRoute = nil
                }
            }
        )
    }

    var requestDetailDestinationView: AnyView {
        guard let selectedRequestRoute else {
            return AnyView(EmptyView())
        }
        return AnyView(requestDetailDestination(for: selectedRequestRoute))
    }
}
