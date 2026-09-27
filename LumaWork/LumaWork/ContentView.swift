import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedSection: AppNavigationSection = .home
    @State private var previousSection: AppNavigationSection = .home
    @State private var isMenuPresented = false
    @State private var requestedActiveRequestID: String?
    @State private var stores: AppDataStores
    private let sessionStore: AppSessionStore
    private let navigationRouter: AppNavigationRouter

    init(
        config: AppConfig = AppConfig(),
        sessionStore: AppSessionStore,
        stores: AppDataStores? = nil,
        initialSection: AppNavigationSection = .home,
        navigationRouter: AppNavigationRouter? = nil
    ) {
        self.sessionStore = sessionStore
        self.navigationRouter = navigationRouter ?? .shared
        _selectedSection = State(initialValue: initialSection)
        _previousSection = State(initialValue: initialSection)
        _stores = State(
            initialValue: stores ?? AppDataStores(config: config, sessionStore: sessionStore)
        )
    }

    var body: some View {
        AppSidebarShell(
            selectedSection: $selectedSection,
            isMenuPresented: $isMenuPresented,
            sessionStore: sessionStore,
            routeStore: stores.homeStore,
            vehicleStore: stores.vehicleStore,
            feedbackStore: stores.feedbackStore,
            workDocumentsStore: stores.workDocumentsStore,
            navigationVisibilityStore: stores.navigationVisibilityStore,
            refreshHomeData: {
                await addClosedRequestsToRoute()
            }
        ) {
            selectedScreen
        }
        .environment(\.appIsOfflineMode, sessionStore.isOfflineMode)
        .tint(AppTheme.primaryTint)
        .background(KeyboardDismissOnTapInstaller())
        .onChange(of: selectedSection) { oldValue, newValue in
            if newValue != .salary {
                previousSection = newValue
            } else if oldValue != .salary {
                previousSection = oldValue
            }
        }
        .onChange(of: stores.navigationVisibilityStore.changeToken) { _, _ in
            normalizeSelectedSection()
        }
        .onChange(of: sessionStore.isAdmin) { _, _ in
            normalizeSelectedSection()
        }
        .task {
            normalizeSelectedSection()
        }
        .task(id: navigationRouter.pendingRoute) {
            consumePendingRoute()
        }
        .task {
            await stores.homeStore.loadIfNeeded()
        }
        .task(id: stores.homeStore.selectedMonthMileage) {
            guard let monthlyMileage = stores.homeStore.selectedMonthMileage else { return }
            do {
                try await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled else { return }
                await stores.fuelStore.syncMonthlyMileage(monthlyMileage)
            } catch {
                return
            }
        }
        .task(id: widgetPublicationTrigger) {
            WidgetSnapshotPublisher.publish(
                stores: stores,
                isAuthenticated: sessionStore.isAuthenticated
            )
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .background else { return }
            WidgetSnapshotPublisher.publish(
                stores: stores,
                isAuthenticated: sessionStore.isAuthenticated
            )
        }
    }

    @ViewBuilder
    private var selectedScreen: some View {
        switch selectedSection {
        case .home:
            if stores.isHomeInitialLoading {
                AppScreen {
                    AppLoadingView(title: "Загружаем рабочий день")
                }
            } else {
                HomeScreen(
                    profileStore: stores.profileStore,
                    sessionStore: sessionStore,
                    routeStore: stores.homeStore,
                    maintenanceStore: stores.maintenanceStore,
                    vehicleStore: stores.vehicleStore,
                    fuelStore: stores.fuelStore,
                    closedRequestsStore: stores.closedRequestsStore,
                    workDocumentsStore: stores.workDocumentsStore,
                    simpleOneStore: stores.simpleOneStore,
                    gsmReportStore: stores.gsmReportStore,
                    onRefresh: {
                        await addClosedRequestsToRoute()
                    },
                    onOpenActiveRequests: {
                        selectedSection = .requests
                    }
                )
            }
        case .backpack:
            BackpackScreen(
                store: stores.backpackStore,
                simpleOneStore: stores.simpleOneStore,
                coordinationStore: stores.coordinationStore,
                equipmentStore: stores.officeEquipmentStore
            )
        case .employees:
            EmployeesScreen(
                simpleOneStore: stores.simpleOneStore,
                store: stores.employeesStore,
                workScheduleStore: stores.workScheduleStore,
                profileCity: sessionStore.userProfile.city
            )
        case .maintenance:
            MaintenanceScreen(
                store: stores.maintenanceStore,
                vehicleStore: stores.vehicleStore
            )
        case .fuel:
            FuelScreen(
                store: stores.fuelStore,
                userEmail: sessionStore.currentEmail
            )
        case .wiki:
            AssistantWorkspaceScreen(
                wikiStore: stores.wikiStore,
                assistantStore: stores.assistantStore
            )
        case .ftp:
            if stores.simpleOneStore.isAuthorized {
                FTPScreen(store: stores.ftpStore)
            } else {
                SimpleOneAuthorizationRequiredScreen(title: "FTP")
            }
        case .salary:
            SalaryScreen(
                store: stores.salaryStore,
                userEmail: sessionStore.currentEmail
            ) {
                selectedSection = previousSection == .salary ? .home : previousSection
            }
        case .requests:
            ClosedRequestsScreen(
                store: stores.closedRequestsStore,
                sessionStore: sessionStore,
                simpleOneStore: stores.simpleOneStore,
                clientCommentsStore: stores.clientPersonalCommentsStore,
                requestedActiveRequestID: requestedActiveRequestID,
                onRequestedActiveRequestHandled: { requestID in
                    if requestedActiveRequestID == requestID {
                        requestedActiveRequestID = nil
                    }
                }
            )
        case .coordination:
            CoordinationScreen(
                simpleOneStore: stores.simpleOneStore,
                lumaWorkAuthToken: sessionStore.authToken,
                store: stores.coordinationStore
            )
        case .timeReport:
            TimeReportScreen(
                store: stores.timeReportStore,
                simpleOneStore: stores.simpleOneStore
            )
        case .analytics:
            ClosedRequestsAnalyticsScreen(
                snapshot: stores.closedRequestsStore.snapshot,
                records: stores.closedRequestsStore.records,
                showsCloseButton: false
            )
        case .users:
            AdminUsersScreen(
                sessionStore: sessionStore,
                store: stores.adminUsersStore
            )
        }
    }

    private func normalizeSelectedSection() {
        let visibleSections = stores.navigationVisibilityStore.visibleCases(
            isAdmin: sessionStore.isAdmin
        )
        if !visibleSections.contains(selectedSection) {
            selectedSection = visibleSections.first ?? .home
        }

        if !visibleSections.contains(previousSection) {
            previousSection = visibleSections.first ?? .home
        }
    }

    private func consumePendingRoute() {
        guard let route = navigationRouter.consume() else { return }

        switch route {
        case .home:
            requestedActiveRequestID = nil
            stores.homeStore.setSelectedDate(Date())
            selectedSection = .home
        case .requests:
            requestedActiveRequestID = nil
            selectedSection = .requests
        case .request(let requestID):
            requestedActiveRequestID = requestID
            selectedSection = .requests
        case .assistant:
            requestedActiveRequestID = nil
            selectedSection = .wiki
        case .timeReport:
            requestedActiveRequestID = nil
            selectedSection = .timeReport
        }
    }

    private func addClosedRequestsToRoute() async {
        let closedRequests = await stores.closedRequestsStore.routeTemplateRecords(
            for: stores.homeStore.selectedDateKey,
            warehouseAddress: stores.homeStore.routeSettings.address(for: .warehouse)
        )
        guard !Task.isCancelled else { return }
        stores.homeStore.appendClosedRequests(closedRequests)
    }

    private var widgetPublicationTrigger: WidgetPublicationTrigger {
        WidgetPublicationTrigger(
            activeRequestsRevision: stores.simpleOneStore.activeRequestsRevision,
            routeRecord: stores.homeStore.record,
            routeIsToday: stores.homeStore.isToday,
            isAuthenticated: sessionStore.isAuthenticated
        )
    }
}

private struct WidgetPublicationTrigger: Hashable {
    let activeRequestsRevision: UInt64
    let routeRecord: RouteDayRecord
    let routeIsToday: Bool
    let isAuthenticated: Bool
}

private struct SimpleOneAuthorizationRequiredScreen: View {
    let title: String

    private let message = "Необходимо авторизоваться в SimpleOne на экране «Заявки»."

    var body: some View {
        AppScreen {
            AppEmptyState(
                title: "SimpleOne не подключён",
                message: message,
                systemName: "person.crop.circle.badge.exclamationmark"
            )
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            AppBannerCenter.shared.show(message, style: .information)
        }
    }
}

#Preview {
    ContentView(sessionStore: AppSessionStore())
}
