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
    let closedRequestsStore: ClosedRequestsStore
    let simpleOneStore: SimpleOneRequestsStore
    let clientPersonalCommentsStore: ClientPersonalCommentsStore
    let timeReportStore: TimeReportStore
    let gsmReportStore: GsmReportStore
    let gsmProfileStore: GsmProfileSettingsStore
    let wikiStore: WikiStore
    let ftpStore: FTPStore
    let backpackStore: BackpackStore
    let officeEquipmentStore: OfficeEquipmentStore
    let assistantStore: AssistantStore
    let employeesStore: SimpleOneEmployeesStore
    let workScheduleStore: WorkScheduleStore
    let coordinationStore: CoordinationStore
    let groupClosedRequestsStore: CoordinationGroupClosedRequestsStore
    let adminUsersStore: AdminUsersStore
    let feedbackStore: FeedbackStore
    let workDocumentsStore: WorkDocumentsStore
    let navigationVisibilityStore: AppNavigationVisibilityStore

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
        closedRequestsStore = ClosedRequestsStore()
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
            service: WikiAPI(config: config),
            cacheID: userID
        )
        ftpStore = FTPStore(
            service: FTPAPI(config: config, authToken: authToken),
            downloadManager: .shared,
            cacheID: userID
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

            if closedRequestsStore.snapshot == nil || closedRequestsStore.needsMerchantTINRepair {
                let narrowHead = try? await simpleOneStore.fetchClosedSyncHead(scope: .narrow)
                let wideHead = try? await simpleOneStore.fetchClosedSyncHead(scope: .wide)
                let exportedFile = try await simpleOneStore.exportClosedRequestsXLSXForCurrentUser()
                await closedRequestsStore.importSpreadsheet(
                    data: exportedFile.data,
                    fileName: exportedFile.fileName
                )
                let baselineUserID = narrowHead?.userID ?? wideHead?.userID
                let baselineUsersMatch = narrowHead == nil
                    || wideHead == nil
                    || narrowHead?.userID == wideHead?.userID
                if let baselineUserID,
                   baselineUsersMatch,
                   closedRequestsStore.errorMessage == nil {
                    await closedRequestsStore.setClosedRequestsSyncBaseline(
                        userID: baselineUserID,
                        narrow: narrowHead?.cursor,
                        wide: wideHead?.cursor
                    )
                }
                if closedRequestsStore.errorMessage == nil {
                    closedRequestsStore.markMerchantTINRepairCompleted()
                }
                return
            }

            _ = try await closedRequestsStore.synchronizeFromSimpleOne(
                simpleOneStore,
                scope: .narrow,
                waitsForCurrentSync: true
            )
            if let userID = simpleOneStore.currentUser?.sysID,
               closedRequestsStore.shouldRunWideClosedRequestsSync(userID: userID) {
                _ = try await closedRequestsStore.synchronizeFromSimpleOne(
                    simpleOneStore,
                    scope: .wide,
                    waitsForCurrentSync: true
                )
            }
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
