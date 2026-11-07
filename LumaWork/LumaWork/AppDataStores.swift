import Foundation
import Observation

@MainActor
@Observable
final class AppDataStores {
    let profileStore: ProfileStore
    let homeStore: HomeRouteStore
    let maintenanceStore: MaintenanceStore
    let vehicleStore: VehicleStore
    let salaryStore: SalaryStore
    let fuelStore: FuelStore
    let workStatistics: WorkStatisticsSyncCoordinator
    let leaderboardAccess: LeaderboardAccessStore
    let leaderboardStore: LeaderboardStore
    let closedRequestsStore: ClosedRequestsStore
    let simpleOneStore: SimpleOneRequestsStore
    let clientPersonalCommentsStore: ClientPersonalCommentsStore
    let timeReportStore: TimeReportStore
    let gsmReportStore: GsmReportStore
    let gsmProfileStore: GsmProfileSettingsStore
    let wikiStore: WikiStore
    let ftpStore: FTPStore
    let backpackLocations: BackpackItemLocationStore
    let backpackStore: BackpackStore
    let officeEquipmentStore: OfficeEquipmentStore
    let assistantStore: AssistantStore
    let employeesStore: SimpleOneEmployeesStore
    let workScheduleStore: WorkScheduleStore
    let coordinationStore: CoordinationStore
    let groupClosedRequestsStore: CoordinationGroupClosedRequestsStore
    let adminUsersStore: AdminUsersStore
    let evotorDriverLinksStore: EvotorDriverLinksStore
    let feedbackStore: FeedbackStore
    let workDocumentsStore: WorkDocumentsStore
    let navigationVisibilityStore: AppNavigationVisibilityStore

    private var protectedIdentity: SimpleOneAccessSnapshot?
    private(set) var isHomeInitialLoading: Bool

    convenience init(sessionStore: AppSessionStore) {
        self.init(config: AppConfig(), sessionStore: sessionStore)
    }

    init(config: AppConfig, sessionStore: AppSessionStore) {
        let authToken = sessionStore.authToken
        let userID = sessionStore.session?.user.id

        profileStore = ProfileStore()
        homeStore = HomeRouteStore(
            service: RouteDayService(config: config, authToken: authToken),
            cacheID: userID
        )
        maintenanceStore = MaintenanceStore(
            service: MaintenanceService(config: config, authToken: authToken),
            cacheID: userID
        )
        vehicleStore = VehicleStore(
            api: VehicleAPI(config: config, authToken: authToken),
            userID: userID,
            legacyProfile: sessionStore.userProfile
        )
        salaryStore = SalaryStore(
            service: SalaryService(config: config, authToken: authToken),
            cacheID: userID
        )
        fuelStore = FuelStore(
            service: FuelService(config: config, authToken: authToken),
            importAPI: FuelImportAPI(config: config, authToken: authToken),
            cacheID: userID
        )
        let workStatistics = WorkStatisticsSyncCoordinator(config: config, ownerID: userID)
        self.workStatistics = workStatistics
        let leaderboardStore = LeaderboardStore(config: config, ownerID: userID)
        self.leaderboardStore = leaderboardStore
        let leaderboardAccess = LeaderboardAccessStore(config: config, ownerID: userID)
        self.leaderboardAccess = leaderboardAccess
        leaderboardAccess.onDisabled = { [weak leaderboardStore] in leaderboardStore?.clearProtectedState() }
        leaderboardStore.onVisibilityDenied = { [weak leaderboardAccess] in leaderboardAccess?.markDisabled() }
        closedRequestsStore = ClosedRequestsStore()
        closedRequestsStore.workStatistics = workStatistics
        let simpleOneStore = SimpleOneRequestsStore(
            notificationCoordinator: SimpleOneRequestNotificationCoordinator(
                config: config,
                authToken: authToken
            ),
            automaticallyRefresh: false
        )
        self.simpleOneStore = simpleOneStore
        clientPersonalCommentsStore = ClientPersonalCommentsStore(
            api: ClientPersonalCommentsAPI(config: config, authToken: authToken)
        )
        timeReportStore = TimeReportStore()
        gsmReportStore = GsmReportStore(
            api: GsmReportAPI(config: config, authToken: authToken)
        )
        gsmProfileStore = GsmProfileSettingsStore(
            api: GsmProfileAPI(config: config, authToken: authToken),
            cacheID: userID
        )
        wikiStore = WikiStore(
            service: WikiAPI(config: config, authToken: authToken),
            cacheID: userID
        )
        let favoritesAPI = PersonalStateAPI(config: config, ownerID: userID ?? "", collection: "ftp-favorites")
        let oldFavorites = AppOfflineSnapshotStore.load([String].self,
            key: AppOfflineSnapshotStore.scopedKey("ftp-favorites", userID: userID))?.value ?? []
        let favoritesState = PersonalStateStore(ownerID: userID ?? "", collection: "ftp-favorites",
            seed: Dictionary(oldFavorites.filter { $0 != "/" && !$0.isEmpty }.map { ($0, "selected") }, uniquingKeysWith: { a, _ in a }),
            synchronize: { seed, changes in try await favoritesAPI.synchronize(seed: seed, changes: changes) })
        backpackLocations = BackpackItemLocationStore(config: config, ownerID: userID ?? "")
        ftpStore = FTPStore(
            service: FTPAPI(config: config, authToken: authToken),
            downloadManager: .shared,
            cacheID: userID,
            favoritesState: favoritesState
        )
        let backpackStore = BackpackStore(cacheID: userID)
        self.backpackStore = backpackStore
        officeEquipmentStore = OfficeEquipmentStore(cacheID: userID)
        assistantStore = AssistantStore(
            api: AssistantAPI(config: config, authToken: authToken),
            userID: userID,
            toolExecutor: AssistantLocalToolExecutor(
                simpleOneStore: simpleOneStore,
                backpackStore: backpackStore
            )
        )
        employeesStore = SimpleOneEmployeesStore(cacheID: userID)
        workScheduleStore = WorkScheduleStore(cacheID: userID)
        coordinationStore = CoordinationStore(cacheID: userID)
        groupClosedRequestsStore = CoordinationGroupClosedRequestsStore(cacheID: userID)
        adminUsersStore = AdminUsersStore(token: authToken, cacheID: userID)
        evotorDriverLinksStore = EvotorDriverLinksStore(config: config, token: authToken, cacheID: userID)
        feedbackStore = FeedbackStore(
            config: config,
            token: authToken,
            userID: userID
        )
        workDocumentsStore = WorkDocumentsStore(
            config: config,
            token: authToken,
            userID: userID
        )
        navigationVisibilityStore = AppNavigationVisibilityStore()
        isHomeInitialLoading = simpleOneStore.needsInitialSnapshot
        protectedIdentity = try? SimpleOneProtectedAccess.capture()
    }

    func synchronizeProtectedAccess() {
        simpleOneStore.reconcileStoredAuthorization()
        let identity = try? SimpleOneProtectedAccess.capture()
        guard identity != protectedIdentity else { return }
        protectedIdentity = identity
        closedRequestsStore.cancelClosedRequestsSync()
        workStatistics.clearProtectedState(); leaderboardStore.clearProtectedState(); leaderboardAccess.clearProtectedState()
        Task { await leaderboardAccess.refresh() }
        wikiStore.clearProtectedState(); ftpStore.clearProtectedState(); assistantStore.clearProtectedState()
        FTPBackgroundDownloadManager.shared.revokeUnauthorized()
        if identity != nil {
            wikiStore.restoreProtectedCache(); ftpStore.restoreProtectedCache(); assistantStore.restoreProtectedCache()
        }
    }

    func resolveHomeInitialLoading(isOnline: Bool) async {
        guard isOnline else {
            isHomeInitialLoading = false
            return
        }

        await simpleOneStore.refresh(showsNetworkBanner: false)
        isHomeInitialLoading = false
    }

    func refreshHomeData(refreshClosedArchive: Bool = false) async {
        await simpleOneStore.refresh(showsNetworkBanner: false)
        guard refreshClosedArchive,
              simpleOneStore.isAuthorized,
              simpleOneStore.errorMessage == nil,
              !closedRequestsStore.isDeleting,
              !closedRequestsStore.isImporting else {
            return
        }

        await refreshClosedRequestsFromSimpleOne()
    }

    private func refreshClosedRequestsFromSimpleOne() async {
        do {
            try await closedRequestsStore.waitForClosedRequestsSyncAvailability()

            try await closedRequestsStore.refreshVerifiedClosedArchive(simpleOneStore)
        } catch is CancellationError {
            return
        } catch {
            let message = appUserFacingErrorMessage(
                error,
                fallback: "Активные заявки обновлены, закрытый архив обновить не удалось.",
                showsNetworkBanner: false
            ) ?? "Активные заявки обновлены, закрытый архив обновить не удалось."
            closedRequestsStore.errorMessage = message
            AppBannerCenter.shared.show(message, style: .error)
        }
    }

}
