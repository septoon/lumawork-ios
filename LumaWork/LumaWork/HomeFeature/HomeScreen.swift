import Foundation
import SwiftUI
import UIKit
import WebKit

struct HomeScreen: View {
    let profileStore: ProfileStore
    let sessionStore: AppSessionStore
    let routeStore: HomeRouteStore
    let maintenanceStore: MaintenanceStore
    let vehicleStore: VehicleStore
    let fuelStore: FuelStore
    let closedRequestsStore: ClosedRequestsStore
    let workDocumentsStore: WorkDocumentsStore
    let simpleOneStore: SimpleOneRequestsStore
    let gsmReportStore: GsmReportStore
    let loadsRouteOnAppear: Bool
    let onRefresh: () async -> Void
    let onOpenActiveRequests: () -> Void

    @State private var isProfilePresented = false
    @State private var isCalendarPresented = false
    @State private var isRoutesArchivePresented = false
    @State private var isFuelEntryPresented = false
    @State private var sendConfirmationPresented = false
    @State private var stopPendingDeletion: RouteStop?
    @State private var stopEditorSelection: RouteStopEditorSelection?
    @State private var draggedStopID: String?
    @State private var yandexRoute: YandexRouteDestination?
    @State private var routesArchiveStore: RouteArchiveStore
    @State private var selectedActiveRequest: SimpleOneRequestRecord?
    @State private var unavailableSendFeedbackTrigger = 0
    @State private var sentReportCelebrationID: UUID?
    @GestureState private var isSendButtonPressed = false

    init(
        profileStore: ProfileStore,
        sessionStore: AppSessionStore,
        routeStore: HomeRouteStore,
        maintenanceStore: MaintenanceStore,
        vehicleStore: VehicleStore,
        fuelStore: FuelStore,
        closedRequestsStore: ClosedRequestsStore,
        workDocumentsStore: WorkDocumentsStore,
        simpleOneStore: SimpleOneRequestsStore,
        gsmReportStore: GsmReportStore,
        loadsRouteOnAppear: Bool = true,
        onRefresh: @escaping () async -> Void = {},
        onOpenActiveRequests: @escaping () -> Void
    ) {
        self.profileStore = profileStore
        self.sessionStore = sessionStore
        self.routeStore = routeStore
        self.maintenanceStore = maintenanceStore
        self.vehicleStore = vehicleStore
        self.fuelStore = fuelStore
        self.closedRequestsStore = closedRequestsStore
        self.workDocumentsStore = workDocumentsStore
        self.simpleOneStore = simpleOneStore
        self.gsmReportStore = gsmReportStore
        self.loadsRouteOnAppear = loadsRouteOnAppear
        self.onRefresh = onRefresh
        self.onOpenActiveRequests = onOpenActiveRequests
        _routesArchiveStore = State(initialValue: routeStore.makeRoutesArchiveStore())
    }

    var body: some View {
        AppScreen(bottomContentPadding: HomeLayout.bottomContentPadding) {
            if let notice = routeStore.notice {
                AppNoticeBanner(text: notice, tint: AppTheme.secondaryTint)
            }

            if let errorMessage = routeStore.errorMessage {
                AppNoticeBanner(text: errorMessage, tint: AppTheme.dangerTint, isCritical: true)
            }

            if routeStore.workType == .pos {
                activeRequestsCard
            }
            dayControlsCard

            RouteTimelineCard(
                stops: routeStore.record.stops,
                startEndpointKind: routeStore.selectedEndpointKind(for: .start),
                finishEndpointKind: routeStore.selectedEndpointKind(for: .finish),
                isHomeEndpointAvailable: routeStore.routeSettings.address(for: .home).isEmpty == false,
                draggedStopID: $draggedStopID,
                onEditStop: { stop, pointNumber in
                    stopEditorSelection = RouteStopEditorSelection(
                        stop: stop,
                        pointNumber: pointNumber,
                        suggestions: routeStore.workType == .pos ? routeStore.suggestions(for: stop) : [],
                        requiresOfficeSelection: routeStore.requiresOfficeAddressSelection
                    )
                },
                onDropStop: { draggedID, targetID in
                    let didMove = routeStore.reorderStop(draggedID, targetID: targetID)
                    if didMove {
                        AppHaptics.trigger(.expandCollapse)
                    }
                    return didMove
                },
                onAddStop: { routeStore.addMiddleStop() },
                canRemoveStop: canRemoveStop(at:),
                onRemoveStop: { stopPendingDeletion = $0 },
                onEndpointSelect: { role, kind in
                    routeStore.updateEndpoint(role, kind: kind)
                },
                onCopyEndpoint: { kind in
                    AppClipboard.copy(routeStore.routeSettings.address(for: kind), message: "Адрес скопирован")
                }
            )

        }
        .appLoadingOverlay(
            isPresented: routeStore.isLoadingRemote && !routeStore.hasCurrentRouteData,
            title: "Загружаем маршрут за \(routeStore.selectedDateTitle.lowercased())"
        )
        .navigationTitle("Главная")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await onRefresh()
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Тип работы", selection: Binding(
                    get: { routeStore.workType },
                    set: { newValue in
                        AppHaptics.trigger(.expandCollapse)
                        routeStore.setWorkType(newValue)
                    }
                )) {
                    ForEach(RouteWorkType.allCases) { workType in
                        Text(workType.title).tag(workType)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 176)
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    AppHaptics.trigger()
                    isProfilePresented = true
                } label: {
                    ProfileAvatar(size: 44, avatarUrl: sessionStore.avatarUrl)
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
                .accessibilityLabel("Открыть профиль")
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .safeAreaBar(edge: .bottom) {
            fixedSendButton
        }
        .overlay {
            if sentReportCelebrationID != nil {
                ReportSentCelebration(
                    reportTitle: routeStore.workType.title,
                    dateTitle: routeStore.selectedDateTitle
                )
                .transition(.opacity.combined(with: .scale(scale: 0.94)))
                .zIndex(20)
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .sheet(isPresented: $isProfilePresented) { profileSheet }
        .sheet(isPresented: $isCalendarPresented) {
            NavigationStack {
                HomeCalendarScreen(selectedDate: Binding(
                    get: { routeStore.selectedDate },
                    set: { routeStore.setSelectedDate($0) }
                ))
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isRoutesArchivePresented) {
            NavigationStack {
                RouteArchiveScreen(
                    store: routesArchiveStore,
                    gsmReportStore: gsmReportStore,
                    routeStore: routeStore
                )
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $isFuelEntryPresented) {
            NavigationStack {
                HomeFuelEntryScreen(store: fuelStore)
            }
            .presentationDetents([.large])
        }
        .sheet(item: $stopEditorSelection) { selection in
            RouteStopEditorSheet(
                selection: selection,
                officeAddresses: routeStore.officeAddresses,
                isLoadingOfficeAddresses: routeStore.isLoadingOfficeAddresses,
                onRefreshOfficeAddresses: {
                    await routeStore.refreshOfficeAddressesIfNeeded(force: true)
                }
            ) { address, requestNumber in
                routeStore.updateStop(
                    selection.stop.id,
                    address: address,
                    requestNumber: requestNumber
                )
            }
            .appEditorSheetStyle(
                initialHeight: selection.requiresOfficeSelection
                    ? 330
                    : selection.suggestions.isEmpty ? 340 : 390
            )
        }
        .sheet(item: $yandexRoute) { destination in
            YandexRouteBrowser(url: destination.url)
                .ignoresSafeArea()
        }
        .alert("Отправить отчёт?", isPresented: $sendConfirmationPresented) {
            Button("Отправить") {
                dismissKeyboard()
                Task {
                    guard await routeStore.sendCurrentDay() else { return }
                    AppHaptics.trigger(.success)
                    withAnimation(.spring(response: 0.48, dampingFraction: 0.78)) {
                        sentReportCelebrationID = UUID()
                    }
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Отчёт \(routeStore.workType.title) будет отправлен на сервер за \(routeStore.selectedDateTitle.lowercased()).")
        }
        .alert("Удалить точку?", isPresented: Binding(
            get: { stopPendingDeletion != nil },
            set: { if !$0 { stopPendingDeletion = nil } }
        )) {
            Button("Удалить", role: .destructive) {
                if let stopPendingDeletion {
                    routeStore.removeStop(stopPendingDeletion.id)
                }
                stopPendingDeletion = nil
            }
            Button("Отмена", role: .cancel) {
                stopPendingDeletion = nil
            }
        } message: {
            Text("Точка будет удалена из маршрута.")
        }
        .navigationDestination(isPresented: activeRequestDetailPresentationBinding) {
            activeRequestDetailDestination
        }
        .task(id: routeStore.notice) {
            await appDismissTransientMessage(routeStore.notice) { value in
                if routeStore.notice == value {
                    routeStore.notice = nil
                }
            }
        }
        .task(id: routeStore.errorMessage) {
            await appDismissTransientMessage(routeStore.errorMessage) { value in
                if routeStore.errorMessage == value {
                    routeStore.errorMessage = nil
                }
            }
        }
        .task(id: autoClosedRequestsImportTaskID) {
            await autoImportClosedRequestsIfNeeded()
        }
        .task(id: autoOdometerSuggestionTaskID) {
            await autoFillPeriodStartOdometerIfNeeded()
        }
        .task(id: routeStore.workType) {
            await routeStore.refreshOfficeAddressesIfNeeded()
        }
        .task(id: sentReportCelebrationID) {
            guard let celebrationID = sentReportCelebrationID else { return }
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled, sentReportCelebrationID == celebrationID else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                sentReportCelebrationID = nil
            }
        }
        .task {
            guard loadsRouteOnAppear else { return }
            await routeStore.loadIfNeeded()
        }
    }

    private var profileSheet: some View {
        NavigationStack {
            ProfileScreen(
                profile: sessionStore.userProfile,
                avatarUrl: sessionStore.avatarUrl,
                vehicleStore: vehicleStore,
                workDocumentsStore: workDocumentsStore,
                closedRequestsStore: closedRequestsStore
            )
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var dayControlsCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: HomeLayout.dayContentSpacing) {
                HStack(alignment: .center, spacing: HomeLayout.dayHeaderSpacing) {
                    Button {
                        AppHaptics.trigger()
                        isCalendarPresented = true
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Рабочий день")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.mutedTint)

                            HStack(spacing: 6) {
                                Text(routeStore.selectedDateTitle.capitalized)
                                    .font(.title2.weight(.bold))
                                    .foregroundStyle(AppTheme.ink)

                                Image(systemName: "chevron.down")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(AppTheme.primaryTint)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Дата маршрута")
                    .accessibilityValue(routeStore.selectedDateTitle)
                    .accessibilityHint("Открывает календарь")

                    addFuelButton
                }

                Divider()
                    .overlay(AppTheme.border)

                mileageRow

                Divider()
                    .overlay(AppTheme.border)

                routesArchiveRow
            }
        }
    }

    private var addFuelButton: some View {
        Button {
            AppHaptics.trigger()
            isFuelEntryPresented = true
        } label: {
            Label("Добавить заправку", systemImage: "fuelpump.fill")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.regular)
        .tint(AppTheme.secondaryTint)
        .accessibilityHint("Открывает добавление заправки")
    }

    private var mileageRow: some View {
        HStack(spacing: HomeLayout.mileageSpacing) {
            Label("Пробег дня", systemImage: "road.lanes")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.ink)

            Spacer(minLength: 4)

            TextField("0", text: Binding(
                get: { routeStore.record.distanceKm.map(String.init) ?? "" },
                set: routeStore.updateDistanceKm
            ))
            .keyboardType(.numberPad)
            .font(.body.weight(.semibold).monospacedDigit())
            .multilineTextAlignment(.trailing)
            .padding(.horizontal, 10)
            .frame(
                width: HomeLayout.mileageFieldWidth,
                height: HomeLayout.mileageFieldHeight
            )
            .background(
                AppTheme.subpanelSurface,
                in: RoundedRectangle(
                    cornerRadius: HomeLayout.mileageFieldCornerRadius,
                    style: .continuous
                )
            )
            .overlay(
                RoundedRectangle(
                    cornerRadius: HomeLayout.mileageFieldCornerRadius,
                    style: .continuous
                )
                    .stroke(AppTheme.secondaryTint.opacity(0.28), lineWidth: 1)
            )
            .accessibilityLabel("Пробег за день")

            Text("км")
                .font(.subheadline)
                .foregroundStyle(AppTheme.mutedTint)

            Button("Составить маршрут", systemImage: "map.fill") {
                openYandexRoute()
            }
            .labelStyle(.iconOnly)
            .appNativeIconControl(.inline)
            .accessibilityHint("Открывает маршрут в Яндекс.Картах")
        }
    }

    private var routesArchiveRow: some View {
        Button {
            AppHaptics.trigger()
            isRoutesArchivePresented = true
        } label: {
            HStack(spacing: HomeLayout.odometerSpacing) {
                Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryTint)
                    .frame(width: 34, height: 34)
                    .background(AppTheme.primaryTint.opacity(0.12), in: Circle())

                Text("Архив маршрутов")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppTheme.mutedTint)
            }
            .frame(minHeight: HomeLayout.odometerMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Открывает архив маршрутов и одометр месяца")
    }

    private var overdueActiveRequestsCount: Int {
        simpleOneStore.activeRequests.count(where: \.isOverdue)
    }

    private var dueTodayActiveRequestsCount: Int {
        simpleOneStore.activeRequests.count { record in
            guard let deadline = record.deadlineDate else { return false }
            return Calendar.current.isDateInToday(deadline)
        }
    }

    private var nearestActiveRequest: SimpleOneRequestRecord? {
        simpleOneStore.activeRequests
            .filter { $0.deadlineDate != nil }
            .min { ($0.deadlineDate ?? .distantFuture) < ($1.deadlineDate ?? .distantFuture) }
    }

    private var activeRequestsCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: HomeLayout.activeRequestsContentSpacing) {
                AppSectionHeader(
                    title: "Активные заявки",
                    caption: simpleOneStore.lastUpdatedAt.map {
                        "Обновлено \($0.formatted(date: .omitted, time: .shortened))"
                    }
                )

                HStack(spacing: HomeLayout.metricSpacing) {
                    Button {
                        AppHaptics.trigger()
                        onOpenActiveRequests()
                    } label: {
                        homeRequestMetric(
                            title: "Всего",
                            value: "\(simpleOneStore.activeRequests.count)",
                            systemImage: "tray.full.fill",
                            tint: AppTheme.primaryTint
                        )
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .accessibilityHint("Открывает активные заявки")

                    homeRequestMetric(
                        title: "Просрочено",
                        value: "\(overdueActiveRequestsCount)",
                        systemImage: "exclamationmark.triangle.fill",
                        tint: overdueActiveRequestsCount > 0 ? AppTheme.dangerTint : AppTheme.secondaryTint
                    )
                    homeRequestMetric(
                        title: "Сегодня",
                        value: "\(dueTodayActiveRequestsCount)",
                        systemImage: "calendar",
                        tint: dueTodayActiveRequestsCount > 0 ? AppTheme.secondaryTint : AppTheme.mutedTint
                    )
                }

                if let nearestActiveRequest {
                    Button {
                        openActiveRequest(nearestActiveRequest)
                    } label: {
                        nearestRequestSummary(nearestActiveRequest)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Открывает заявку")
                } else {
                    Label("Заявок со сроком SLA нет", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AppTheme.mutedTint)
                        .padding(.vertical, 4)
                }
            }
        }
    }

    private var activeRequestDetailPresentationBinding: Binding<Bool> {
        Binding(
            get: { selectedActiveRequest != nil },
            set: { isPresented in
                if !isPresented {
                    selectedActiveRequest = nil
                }
            }
        )
    }

    @ViewBuilder
    private var activeRequestDetailDestination: some View {
        if let selectedActiveRequest {
            ActiveSimpleOneRequestDetailScreen(
                record: selectedActiveRequest,
                simpleOneAuthKey: simpleOneStore.browserAuthKey,
                lumaWorkAuthToken: sessionStore.authToken
            )
        }
    }

    private func openActiveRequest(_ request: SimpleOneRequestRecord) {
        AppHaptics.trigger()
        selectedActiveRequest = request

        Task {
            do {
                let detailedRequest = try await simpleOneStore.fetchDetailedRequest(request)
                if selectedActiveRequest?.id == detailedRequest.id {
                    selectedActiveRequest = detailedRequest
                }
            } catch is CancellationError {
                return
            } catch {
                simpleOneStore.errorMessage = appUserFacingErrorMessage(error)
            }
        }
    }

    private func homeRequestMetric(
        title: String,
        value: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        HomeMetricContainer(tint: tint) {
            VStack(alignment: .leading, spacing: HomeLayout.metricContentSpacing) {
                HStack(spacing: 4) {
                    Image(systemName: systemImage)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(tint)

                    Text(title)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppTheme.mutedTint)

                Text(value)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }

    private func nearestRequestSummary(_ request: SimpleOneRequestRecord) -> some View {
        let accent = request.isOverdue ? AppTheme.dangerTint : AppTheme.primaryTint
        let requestNumber = request.incomingNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? request.number
            : request.incomingNumber
        let description = request.shortDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let assignee = request.assignedUser.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = request.address.trimmingCharacters(in: .whitespacesAndNewlines)

        return HomeRequestSummaryContainer(tint: accent) {
            VStack(alignment: .leading, spacing: HomeLayout.requestSummarySpacing) {
                HStack(alignment: .center, spacing: 8) {
                    Text(requestNumber)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AppTheme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    Spacer(minLength: 8)

                    Text(request.isOverdue ? "Просрочено" : "В срок")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(accent.opacity(0.11), in: Capsule())
                }

                if !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(AppTheme.ink.opacity(0.84))
                        .lineLimit(2)
                }

                activeRequestMetadata(
                    systemImage: "clock.fill",
                    text: deadlineSummary(request),
                    tint: accent
                )

                HStack(spacing: 12) {
                    if !assignee.isEmpty {
                        activeRequestMetadata(systemImage: "person.fill", text: assignee)
                    }

                    if !address.isEmpty {
                        activeRequestMetadata(systemImage: "location.fill", text: address)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func activeRequestMetadata(
        systemImage: String,
        text: String,
        tint: Color = AppTheme.mutedTint
    ) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func deadlineSummary(_ request: SimpleOneRequestRecord) -> String {
        let deadline = request.deadlineDate?.formatted(date: .abbreviated, time: .shortened)
            ?? request.deadline
        return [deadline, request.slaStatusText]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " • ")
    }

    private var autoClosedRequestsImportTaskID: String {
        [
            routeStore.selectedDateKey,
            routeStore.workType.rawValue,
            routeStore.isLoadingRemote ? "remote-loading" : "remote-ready",
            closedRequestsStore.isLoadingSnapshot ? "requests-loading" : "requests-ready",
            "\(closedRequestsStore.snapshot?.importedAt.timeIntervalSinceReferenceDate ?? 0)"
        ].joined(separator: "|")
    }

    private func autoImportClosedRequestsIfNeeded() async {
        guard routeStore.workType == .pos,
              !routeStore.isLoadingRemote,
              !closedRequestsStore.isLoadingSnapshot,
              !routeStore.hasCurrentRouteData else {
            return
        }

        let records = await closedRequestsStore.routeTemplateRecords(
            for: routeStore.selectedDateKey,
            warehouseAddress: routeStore.routeSettings.address(for: .warehouse)
        )
        guard !Task.isCancelled else { return }
        _ = routeStore.autoImportClosedRequestsIfEmpty(records)
    }

    private var autoOdometerSuggestionTaskID: String {
        [
            routeStore.selectedMonthKey,
            routeStore.isLoadingRemote ? "remote-loading" : "remote-ready",
            routeStore.record.periodStartOdometer.map(String.init) ?? "missing"
        ].joined(separator: "|")
    }

    private func autoFillPeriodStartOdometerIfNeeded() async {
        let month = routeStore.selectedMonthKey
        guard !routeStore.isLoadingRemote,
              routeStore.record.periodStartOdometer == nil,
              let suggestion = await gsmReportStore.suggestedStartOdometer(for: month),
              !Task.isCancelled else {
            return
        }
        _ = routeStore.applySuggestedPeriodStartOdometer(suggestion, for: month)
    }

    private func openYandexRoute() {
        AppHaptics.trigger()
        guard let url = routeStore.makeYandexMapsRouteURL() else { return }
        yandexRoute = YandexRouteDestination(url: url)
    }

    private var fixedSendButton: some View {
        Button {
            handleSendButtonTap()
        } label: {
            HStack(spacing: 10) {
                if routeStore.isSending {
                    ProgressView()
                } else {
                    Image(systemName: "paperplane.fill")
                        .font(.subheadline.weight(.bold))
                }

                Text(routeStore.isSending ? "Отправляю…" : "Отправить")
            }
            .font(.headline.weight(.bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(minHeight: HomeLayout.sendButtonMinHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.regular)
        .tint(sendButtonTint)
        .scaleEffect(isSendButtonPressed ? 0.965 : 1)
        .shadow(
            color: AppTheme.primaryTint.opacity(routeStore.canSendCurrentRecord ? 0.26 : 0.12),
            radius: routeStore.canSendCurrentRecord ? 12 : 6,
            y: 4
        )
        .animation(.snappy(duration: 0.22, extraBounce: 0.08), value: isSendButtonPressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .updating($isSendButtonPressed) { _, isPressed, _ in
                    isPressed = true
                }
        )
        .sensoryFeedback(.error, trigger: unavailableSendFeedbackTrigger)
        .padding(.horizontal, HomeLayout.bottomBarHorizontalPadding)
        .padding(.vertical, HomeLayout.bottomBarVerticalPadding)
        .accessibilityValue(sendButtonAccessibilityValue)
        .accessibilityHint(sendButtonAccessibilityHint)
    }

    private var sendButtonTint: Color {
        routeStore.canSendCurrentRecord
            ? AppTheme.primaryTint
            : AppTheme.primaryTint.opacity(0.62)
    }

    private var sendButtonAccessibilityValue: String {
        if routeStore.isSending {
            return "Отправляется"
        }
        return routeStore.canSendCurrentRecord ? "Готово к отправке" : "Недоступно"
    }

    private func handleSendButtonTap() {
        guard !routeStore.isSending else { return }
        guard routeStore.canSendCurrentRecord else {
            unavailableSendFeedbackTrigger += 1
            return
        }
        dismissKeyboard()
        AppHaptics.trigger()
        sendConfirmationPresented = true
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private var sendButtonAccessibilityHint: String {
        routeStore.canSendCurrentRecord
            ? "Показывает подтверждение отправки отчёта"
            : "Доступно после заполнения маршрута, пробега дня и одометра"
    }

    private func canRemoveStop(at index: Int) -> Bool {
        guard index != 0, index != routeStore.record.stops.count - 1 else { return false }
        return routeStore.record.stops.count > 3
    }

}

private struct ReportSentCelebration: View {
    let reportTitle: String
    let dateTitle: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAnimated = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    AppTheme.primaryTint.opacity(0.97),
                    AppTheme.secondaryTint.opacity(0.94),
                    Color.black.opacity(0.9)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ForEach(0 ..< 12, id: \.self) { index in
                Circle()
                    .fill(index.isMultiple(of: 2) ? Color.white.opacity(0.9) : AppTheme.secondaryTint)
                    .frame(width: index.isMultiple(of: 3) ? 9 : 5)
                    .offset(
                        x: isAnimated ? CGFloat((index % 4) - 2) * 72 : 0,
                        y: isAnimated ? CGFloat((index / 4) - 1) * 112 : 0
                    )
                    .opacity(isAnimated ? 0.15 : 0.9)
                    .scaleEffect(isAnimated ? 0.45 : 1)
            }

            VStack(spacing: 22) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.22), lineWidth: 2)
                        .frame(width: 154, height: 154)
                        .scaleEffect(isAnimated ? 1.18 : 0.72)
                        .opacity(isAnimated ? 0 : 1)

                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 126, height: 126)
                        .overlay {
                            Circle()
                                .stroke(Color.white.opacity(0.55), lineWidth: 1)
                        }

                    Image(systemName: "checkmark")
                        .font(.system(size: 54, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .symbolEffect(.bounce, value: isAnimated)
                }

                VStack(spacing: 8) {
                    Text("Отчёт отправлен")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text("\(reportTitle) • \(dateTitle.lowercased())")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.78))
                }
                .multilineTextAlignment(.center)
            }
            .padding(32)
            .scaleEffect(isAnimated ? 1 : 0.9)
            .opacity(isAnimated ? 1 : 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Отчёт отправлен. \(reportTitle), \(dateTitle)")
        .onAppear {
            if reduceMotion {
                isAnimated = true
            } else {
                withAnimation(.spring(response: 0.62, dampingFraction: 0.72)) {
                    isAnimated = true
                }
            }
        }
    }
}

private struct YandexRouteDestination: Identifiable {
    let id = UUID()
    let url: URL
}

private struct YandexRouteBrowser: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            YandexRouteWebView(url: url)
                .ignoresSafeArea(.container, edges: .bottom)
                .navigationTitle("Яндекс.Карты")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        ModalCloseButton(action: dismiss.callAsFunction)
                    }
                }
        }
    }
}

private struct YandexRouteWebView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: Self.configuration())
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard webView.url != url else { return }
        webView.load(URLRequest(url: url))
    }

    private static func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.addUserScript(WKUserScript(
            source: injectedScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        return configuration
    }

    private static let injectedScript = """
    (() => {
      try {
        Object.defineProperty(navigator, 'geolocation', {
          configurable: true,
          value: {
            getCurrentPosition: function(_success, error) {
              if (typeof error === 'function') {
                error({ code: 1, message: 'Geolocation is disabled in LumaWork.' });
              }
            },
            watchPosition: function(_success, error) {
              if (typeof error === 'function') {
                error({ code: 1, message: 'Geolocation is disabled in LumaWork.' });
              }
              return 0;
            },
            clearWatch: function() {}
          }
        });
      } catch (_) {}

      try {
        localStorage.setItem('lumaWorkEmbeddedMaps', '1');
      } catch (_) {}

      const style = document.createElement('style');
      style.textContent = [
        'meta[name="apple-itunes-app"]{display:none!important}',
        'a[href^="yandexmaps:"]{display:none!important}',
        'a[href^="yandexnavi:"]{display:none!important}',
        '[class*="smartbanner" i]{display:none!important}',
        '[class*="app-banner" i]{display:none!important}',
        '[class*="install-app" i]{display:none!important}'
      ].join('\\n');
      document.documentElement.appendChild(style);
    })();
    """

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
                decisionHandler(.cancel)
                return
            }

            let scheme = url.scheme?.lowercased()
            if let scheme, !["http", "https", "about"].contains(scheme) {
                decisionHandler(.cancel)
                return
            }

            let host = url.host()?.lowercased() ?? ""
            if host == "apps.apple.com" || host == "itunes.apple.com" {
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            completionHandler()
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            completionHandler(false)
        }
    }
}
