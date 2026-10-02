import Foundation
import Network
import Observation
import SwiftUI

#if DEBUG
private struct OfficeEquipmentPhotoDebugView: View {
    @State private var photos = BackpackPhotoStore()
    @State private var result = "Загрузка фото"

    private let item = OfficeEquipmentItem(
        id: "photo-cache-regression-huawei", name: "Ноутбук HUAWEI MateBook B3-520",
        serialNumber: "", vendor: "Huawei", type: "", model: "BDZ-WDH9A",
        number: "", location: "", owner: "", receivedAt: "", receivedAtDate: nil,
        alternativeName: "", additionalInformation: "", description: "", detailSections: []
    )

    var body: some View {
        NavigationStack {
            AppScreen {
                BackpackTerminalImage(image: photos.image(for: item), placeholderSystemImage: "desktopcomputer")
                    .frame(height: 260)
                Text(item.displayName).font(.headline)
                Text(result).accessibilityIdentifier("equipment-photo-load-result")
            }
            .navigationTitle("Проверка фото оборудования")
        }
        .task {
            if ProcessInfo.processInfo.arguments.contains("-equipment-photo-cache-404") {
                do {
                    let origin = AppConfig.configuredURL(AppConfig().lumaWorkAPIOrigin)
                    let (data, _) = try await URLSession.shared.data(from: origin.appendingPathComponent("api/v2/media/equipment"))
                    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    let entries = json?["items"] as? [[String: Any]] ?? []
                    let entry = entries.first { ($0["id"] as? String) == "huawei-matebook-b3-520" }
                    if let rawURL = entry?["url"] as? String, let url = URL(string: rawURL),
                       let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html"]) {
                        URLCache.shared.storeCachedResponse(
                            CachedURLResponse(response: response, data: Data("Not Found".utf8)),
                            for: URLRequest(url: url)
                        )
                    }
                } catch {
                    result = "Не удалось подготовить проверку: \(error.localizedDescription)"
                    return
                }
            }
            await photos.load(for: [item])
            result = photos.image(for: item) == nil ? "Фото не загрузилось" : "Фото загружено"
            print("EQUIPMENT_PHOTO_CHECK: \(result)")
        }
    }
}
#endif

struct AppRootView: View {
    @State private var sessionStore: AppSessionStore
    @State private var dataStores: AppDataStores?
    @State private var networkMonitor = AppNetworkMonitor()
    @State private var bannerCenter = AppBannerCenter.shared
    @State private var navigationRouter = AppNavigationRouter.shared
    @State private var isBootstrapping = false

    init() {
        let sessionStore = AppSessionStore()
        _sessionStore = State(initialValue: sessionStore)
        _dataStores = State(
            initialValue: sessionStore.isAuthenticated
                ? AppDataStores(sessionStore: sessionStore)
                : nil
        )
    }

    var body: some View {
        Group {
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-equipment-photo-ui-preview") {
                OfficeEquipmentPhotoDebugView()
            } else if ProcessInfo.processInfo.arguments.contains("-admin-images-ui-preview") {
                NavigationStack {
                    List {
                        NavigationLink("Изображения") {
                            AdminImagesPanel(token: nil, permissions: Set(AdminPermission.allCases))
                        }
                    }
                    .navigationTitle("Администрирование")
                }
            } else if ProcessInfo.processInfo.arguments.contains("-salary-passcode-ui-preview") {
                SalaryPasscodeDebugRootView()
            } else if ProcessInfo.processInfo.arguments.contains("-home-route-ui-preview") {
                HomeRouteDebugRootView()
            } else if ProcessInfo.processInfo.arguments.contains("-assistant-ui-preview") {
                AssistantDebugRootView()
            } else if sessionStore.isAuthenticated, let dataStores {
                ContentView(
                    sessionStore: sessionStore,
                    stores: dataStores,
                    navigationRouter: navigationRouter
                )
            } else {
                AppAuthScreen(store: sessionStore)
            }
#else
            if sessionStore.isAuthenticated, let dataStores {
                ContentView(
                    sessionStore: sessionStore,
                    stores: dataStores,
                    navigationRouter: navigationRouter
                )
            } else {
                AppAuthScreen(store: sessionStore)
            }
#endif
        }
        .environment(\.locale, AppLocale.russian)
        .overlay(alignment: .bottom) {
            AppGlobalBannerHost(center: bannerCenter)
        }
        .task {
            await bootstrap()
        }
        .onChange(of: sessionStore.isAuthenticated) { oldValue, newValue in
            guard oldValue != newValue else { return }
            if newValue {
                dataStores = AppDataStores(sessionStore: sessionStore)
                Task {
                    await bootstrap()
                }
            } else {
                WidgetSnapshotPublisher.publishSignedOut()
                EngineerVoiceRequestIndex.invalidateSuggestions()
                dataStores = nil
            }
        }
        .onChange(of: networkMonitor.status) { _, status in
            handleNetworkStatusChange(status)
        }
        .onOpenURL { url in
            guard let route = AppRoute(url: url) else { return }
            navigationRouter.open(route)
        }
    }

    private func bootstrap() async {
        guard !isBootstrapping else { return }
        guard sessionStore.isAuthenticated else {
            WidgetSnapshotPublisher.publishSignedOut()
            return
        }
        guard
              let dataStores else {
            return
        }

        isBootstrapping = true
        defer { isBootstrapping = false }

        let networkStatus = await networkMonitor.resolveInitialStatus()
        guard !Task.isCancelled, networkStatus != .checking else { return }
        let isOnline = networkStatus == .online
        sessionStore.isOfflineMode = !isOnline

        guard isOnline else {
            bannerCenter.show(.networkUnavailable)
            await dataStores.resolveHomeInitialLoading(isOnline: false)
            return
        }

        async let sessionRestore: Void = sessionStore.restoreSession()
        await dataStores.resolveHomeInitialLoading(isOnline: true)
        await sessionRestore
    }

    private func handleNetworkStatusChange(_ status: AppNetworkMonitor.Status) {
        switch status {
        case .checking:
            return
        case .offline:
            bannerCenter.show(.networkUnavailable)
            sessionStore.isOfflineMode = true
        case .online:
            guard sessionStore.isAuthenticated else { return }
            guard sessionStore.isOfflineMode else { return }
            sessionStore.isOfflineMode = false
            Task {
                await sessionStore.restoreSession()
                if networkMonitor.status == .online,
                   sessionStore.isAuthenticated {
                    sessionStore.isOfflineMode = false
                    await dataStores?.refreshHomeData()
                }
            }
        }
    }
}

#if DEBUG
private struct SalaryPasscodeDebugRootView: View {
    var body: some View {
        SalaryPasscodeLockView(
            passcode: "2580",
            recoveryEmail: "",
            onCreate: { _ in },
            onUnlock: {},
            onCancel: {}
        )
    }
}

private struct HomeRouteDebugRootView: View {
    @State private var sessionStore: AppSessionStore
    @State private var dataStores: AppDataStores

    init() {
        let sessionStore = AppSessionStore()
        let dataStores = AppDataStores(sessionStore: sessionStore)
        let warehouseAddress = "Алушта, ул. В. Хромых, 11"

        dataStores.homeStore.routeSettings = RouteSettings(
            warehouseAddress: warehouseAddress,
            homeAddress: "Алушта, ул. Ленина, 18"
        )
        dataStores.homeStore.record = RouteDayRecord(
            date: RouteDateFormatter.dayKey(from: Date()),
            stops: [
                Self.stop(id: "preview-start", address: warehouseAddress),
                Self.stop(
                    id: "preview-1",
                    address: "Алушта, ул. Набережная, 24",
                    requestNumber: "SUTSPROD-16383372"
                ),
                Self.stop(
                    id: "preview-2",
                    address: "Республика Крым, Партенит, ул. Солнечная, 3",
                    requestNumber: "SUTSPROD-16384979"
                ),
                Self.stop(id: "preview-finish", address: warehouseAddress)
            ],
            distanceKm: 64,
            periodStartOdometer: 128_420,
            sent: false
        )

        _sessionStore = State(initialValue: sessionStore)
        _dataStores = State(initialValue: dataStores)
    }

    var body: some View {
        NavigationStack {
            HomeScreen(
                profileStore: dataStores.profileStore,
                sessionStore: sessionStore,
                routeStore: dataStores.homeStore,
                maintenanceStore: dataStores.maintenanceStore,
                vehicleStore: dataStores.vehicleStore,
                fuelStore: dataStores.fuelStore,
                closedRequestsStore: dataStores.closedRequestsStore,
                workDocumentsStore: dataStores.workDocumentsStore,
                simpleOneStore: dataStores.simpleOneStore,
                gsmReportStore: dataStores.gsmReportStore,
                loadsRouteOnAppear: false,
                onOpenActiveRequests: {}
            )
        }
        .tint(AppTheme.primaryTint)
    }

    private static func stop(
        id: String,
        address: String,
        requestNumber: String = ""
    ) -> RouteStop {
        RouteStop(
            id: id,
            address: address,
            org: "",
            tid: "",
            reason: "",
            status: .pending,
            declineReason: "",
            requestNumber: requestNumber
        )
    }
}

private struct AssistantDebugRootView: View {
    @State private var sessionStore: AppSessionStore
    @State private var dataStores: AppDataStores

    init() {
        let sessionStore = AppSessionStore()
        _sessionStore = State(initialValue: sessionStore)
        _dataStores = State(initialValue: AppDataStores(sessionStore: sessionStore))
    }

    var body: some View {
        ContentView(
            sessionStore: sessionStore,
            stores: dataStores,
            initialSection: .wiki
        )
    }
}
#endif

@MainActor
@Observable
private final class AppNetworkMonitor {
    enum Status: Equatable {
        case checking
        case online
        case offline
    }

    private(set) var status: Status = .checking

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "LumaWork.NetworkMonitor")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let status: Status = path.status == .satisfied ? .online : .offline
            Task { @MainActor [weak self] in
                self?.status = status
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    func resolveInitialStatus(
        maxDuration: Duration = .milliseconds(180)
    ) async -> Status {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: maxDuration)

        while status == .checking, clock.now < deadline {
            do {
                try await Task.sleep(for: .milliseconds(12))
            } catch {
                return .checking
            }
            guard !Task.isCancelled else { return .checking }
        }

        return status
    }
}
