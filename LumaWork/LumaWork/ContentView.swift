import LocalAuthentication
import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedSection: AppNavigationSection = .home
    @State private var previousSection: AppNavigationSection = .home
    @State private var previousAdminSection: AppNavigationSection = .home
    @State private var isAdminUnlocked = false
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
            groupClosedRequestsStore: stores.groupClosedRequestsStore,
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
            if newValue == .users, oldValue != .users {
                previousAdminSection = oldValue
            } else if oldValue == .users {
                isAdminUnlocked = false
            }
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
            isAdminUnlocked = false
            normalizeSelectedSection()
        }
        .onChange(of: sessionStore.authToken) { _, _ in
            isAdminUnlocked = false
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
            EngineerVoiceRequestIndex.publish(
                store: stores.simpleOneStore,
                userID: sessionStore.session?.user.id
            )
            WidgetSnapshotPublisher.publish(
                stores: stores,
                isAuthenticated: sessionStore.isAuthenticated
            )
        }
        .task(id: "\(stores.simpleOneStore.isAuthorized)|\(makeCoordinationSessionID(for: stores.simpleOneStore))") {
            await stores.groupClosedRequestsStore.loadCacheIfNeeded(simpleOneStore: stores.simpleOneStore)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                stores.groupClosedRequestsStore.resumeIfNeeded(simpleOneStore: stores.simpleOneStore)
            }
            guard newPhase == .background else { return }
            isAdminUnlocked = false
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
                store: stores.coordinationStore,
                groupClosedRequestsStore: stores.groupClosedRequestsStore
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
            if isAdminUnlocked {
                AdminUsersScreen(
                    sessionStore: sessionStore,
                    store: stores.adminUsersStore
                )
            } else {
                AdminAccessLockView(
                    onUnlock: {
                        guard selectedSection == .users,
                              scenePhase == .active,
                              sessionStore.isAdmin else { return }
                        isAdminUnlocked = true
                    },
                    onCancel: {
                        selectedSection = previousAdminSection == .users ? .home : previousAdminSection
                    }
                )
            }
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

private struct AdminAccessLockView: View {
    let onUnlock: () -> Void
    let onCancel: () -> Void

    @State private var authenticationAttempt = 0
    @State private var isAuthenticating = true
    @State private var errorMessage: String?

    var body: some View {
        AppScreen {
            AppCard {
                VStack(spacing: 16) {
                    ContentUnavailableView(
                        "Админка заблокирована",
                        systemImage: "lock.shield",
                        description: Text("Подтвердите личность для входа в админку.")
                    )

                    if isAuthenticating {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        if let errorMessage {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(AppTheme.dangerTint)
                                .multilineTextAlignment(.center)
                        }

                        Button("Повторить проверку", systemImage: "faceid") {
                            authenticationAttempt += 1
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Назад") {
                            onCancel()
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Админка")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: authenticationAttempt) {
            await authenticate()
        }
    }

    private func authenticate() async {
        isAuthenticating = true
        errorMessage = nil
        defer { isAuthenticating = false }

        let context = LAContext()
        context.localizedCancelTitle = "Отмена"
        var availabilityError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &availabilityError) else {
            errorMessage = "Для входа настройте Face ID или код устройства."
            return
        }

        do {
            let authenticated = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Открыть админку"
            )
            guard authenticated, !Task.isCancelled else { return }
            AppHaptics.trigger(.success)
            onUnlock()
        } catch let error as LAError {
            guard !Task.isCancelled else { return }
            switch error.code {
            case .userCancel, .systemCancel, .appCancel:
                break
            default:
                errorMessage = "Не удалось подтвердить личность. Повторите попытку."
                AppHaptics.trigger(.error)
            }
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = "Не удалось подтвердить личность. Повторите попытку."
            AppHaptics.trigger(.error)
        }
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
