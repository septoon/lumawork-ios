import Foundation

nonisolated enum EvotorDriver: String, CaseIterable, Identifiable {
    case aisino
    case pax
    var id: String { rawValue }
    var title: String { self == .aisino ? "Драйвер Aisino" : "Драйвер PAX" }
}

nonisolated struct EvotorDriverLinks: Codable, Equatable {
    var aisinoURL: String
    var paxURL: String

    static let defaults = EvotorDriverLinks(
        aisinoURL: "https://market.evotor.ru/store/apps/43419d26-13cb-4f63-8b52-7ede7dbbc439",
        paxURL: "https://market.evotor.ru/store/apps/834b8dbb-2680-40cd-b1ff-98351f5f32e5#discussion-anchor"
    )

    func url(for driver: EvotorDriver) -> URL? {
        Self.validURL(driver == .aisino ? aisinoURL : paxURL)
    }

    func validated() throws -> EvotorDriverLinks {
        let normalized = EvotorDriverLinks(
            aisinoURL: aisinoURL.trimmingCharacters(in: .whitespacesAndNewlines),
            paxURL: paxURL.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        for driver in EvotorDriver.allCases {
            let raw = driver == .aisino ? normalized.aisinoURL : normalized.paxURL
            guard raw.isEmpty || Self.validURL(raw) != nil else {
                throw ValidationError.invalidURL(driver.title)
            }
        }
        return normalized
    }

    private static func validURL(_ raw: String) -> URL? {
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.count <= 2048, !raw.contains(where: \.isWhitespace),
              let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              ["https", "http"].contains(scheme), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    enum ValidationError: LocalizedError {
        case invalidURL(String)
        var errorDescription: String? {
            switch self {
            case .invalidURL(let title): "\(title): укажите корректную HTTP(S)-ссылку."
            }
        }
    }
}

#if canImport(UIKit)
import Observation
import SafariServices
import SwiftUI

@MainActor
private struct EvotorDriverLinksAPI {
    let baseURL: URL
    let token: String?
    private let http = HTTPClient()

    func fetch() async throws -> EvotorDriverLinks {
        try await request(path: "/api/v2/evotor-drivers")
    }

    func save(_ links: EvotorDriverLinks) async throws -> EvotorDriverLinks {
        try await request(path: "/api/v2/admin/evotor-drivers", method: "PUT", body: [
            "aisinoURL": links.aisinoURL, "paxURL": links.paxURL
        ])
    }

    private func request(path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> EvotorDriverLinks {
        guard let token, !token.isEmpty else { throw AppServiceError.message("Нет активной сессии приложения.") }
        let response = try await http.request(
            baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
            method: method, body: body, authToken: token
        )
        guard let payload = dictionaryValue(response.json)?["drivers"] as? [String: Any],
              let aisinoURL = payload["aisinoURL"] as? String,
              let paxURL = payload["paxURL"] as? String else {
            throw AppServiceError.message("Сервер не вернул ссылки драйверов Эвотор.")
        }
        return try EvotorDriverLinks(aisinoURL: aisinoURL, paxURL: paxURL).validated()
    }
}

@MainActor
@Observable
final class EvotorDriverLinksStore {
    private let api: EvotorDriverLinksAPI
    private let cacheKey: String
    private(set) var links: EvotorDriverLinks
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var loadError: String?

    init(config: AppConfig, token: String?, cacheID: String?) {
        api = EvotorDriverLinksAPI(baseURL: AppConfig.configuredURL(config.lumaWorkAPIOrigin), token: token)
        cacheKey = AppOfflineSnapshotStore.scopedKey("evotor-drivers", userID: cacheID)
        links = AppOfflineSnapshotStore.load(EvotorDriverLinks.self, key: cacheKey)?.value ?? .defaults
    }

    func refresh() async {
        guard !isLoading, !isSaving else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let refreshed = try await api.fetch()
            try Task.checkCancellation()
            links = refreshed
            loadError = nil
            AppOfflineSnapshotStore.save(links, key: cacheKey)
        } catch is CancellationError {
            return
        } catch {
            loadError = appUserFacingErrorMessage(error, showsNetworkBanner: false)
        }
    }

    func save(_ value: EvotorDriverLinks) async -> Bool {
        guard !isSaving, !isLoading else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            let saved = try await api.save(value.validated())
            links = saved
            loadError = nil
            AppOfflineSnapshotStore.save(links, key: cacheKey)
            AppBannerCenter.shared.show("Ссылки драйверов сохранены", style: .success)
            return true
        } catch {
            AppBannerCenter.shared.show(
                appUserFacingErrorMessage(error, showsNetworkBanner: false) ?? error.localizedDescription,
                style: .error
            )
            return false
        }
    }
}

struct EvotorDriversCard: View {
    @Environment(EvotorDriverLinksStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var browserDestination: SimpleOneBrowserDestination?
    @State private var qrDestination: EvotorDriverQrDestination?

    var body: some View {
        AppCard {
            AppSectionHeader(title: "Драйвер Эвотор")
            GlassEffectContainer(spacing: 12) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 12) {
                        driverCard(.aisino)
                        driverCard(.pax)
                    }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            driverCard(.aisino).frame(minWidth: 140)
                            driverCard(.pax).frame(minWidth: 140)
                        }
                        VStack(spacing: 12) {
                            driverCard(.aisino)
                            driverCard(.pax)
                        }
                    }
                }
            }
            if EvotorDriver.allCases.allSatisfy({ store.links.url(for: $0) == nil }) {
                Text("Ссылки на драйверы пока не настроены.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedTint)
            }
        }
        .task { await store.refresh() }
        .background(EvotorDriverSafariPresenter(destination: $browserDestination).frame(width: 0, height: 0))
        .sheet(item: $qrDestination) { destination in
            EvotorDriverQrSheet(destination: destination)
        }
    }

    private func driverCard(_ driver: EvotorDriver) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(driver.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                driverAction("Открыть", icon: "arrow.up.right.square", driver: driver, tint: AppTheme.primaryTint) {
                    guard let url = store.links.url(for: driver) else { return }
                    browserDestination = SimpleOneBrowserDestination(url: url, authKey: nil, title: driver.title)
                }
                driverAction("QR-код", icon: "qrcode", driver: driver, tint: AppTheme.mutedTint) {
                    guard let url = store.links.url(for: driver) else { return }
                    qrDestination = EvotorDriverQrDestination(driver: driver, url: url)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardSurface, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(AppTheme.border, lineWidth: 1))
    }

    private func driverAction(_ title: String, icon: String, driver: EvotorDriver, tint: Color,
                              action: @escaping () -> Void) -> some View {
        Button {
            AppHaptics.trigger()
            action()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title2)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 4)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.roundedRectangle(radius: 14))
        .tint(tint)
        .disabled(store.links.url(for: driver) == nil)
        .accessibilityLabel("\(title): \(driver.title)")
    }
}

private struct EvotorDriverQrDestination: Identifiable {
    let driver: EvotorDriver
    let url: URL
    var id: String { driver.id }
}

private struct EvotorDriverQrSheet: View {
    @Environment(\.dismiss) private var dismiss
    let destination: EvotorDriverQrDestination
    private let qrImage: UIImage?

    init(destination: EvotorDriverQrDestination) {
        self.destination = destination
        qrImage = QRCodeBuilder.image(for: destination.url.absoluteString)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Text("Отсканируйте QR-код, чтобы открыть ссылку на драйвер")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.mutedTint)
                    if let qrImage {
                        Image(uiImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .padding(24)
                            .background(.white, in: RoundedRectangle(cornerRadius: 16))
                            .frame(maxWidth: 320)
                            .accessibilityLabel("QR-код: \(destination.driver.title)")
                    } else {
                        ContentUnavailableView("Не удалось создать QR-код", systemImage: "qrcode")
                    }
                    Text(destination.url.absoluteString)
                        .font(.footnote)
                        .foregroundStyle(AppTheme.ink)
                        .textSelection(.enabled)
                }
                .multilineTextAlignment(.center)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .background(AppTheme.background)
            .navigationTitle(destination.driver.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    ModalCloseButton { dismiss() }
                }
            }
        }
        .presentationDetents([.height(560), .large])
        .presentationDragIndicator(.visible)
    }
}

private struct EvotorDriverSafariPresenter: UIViewControllerRepresentable {
    @Binding var destination: SimpleOneBrowserDestination?

    func makeCoordinator() -> Coordinator {
        Coordinator(destination: $destination)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        context.coordinator.destination = $destination
        guard let destination, controller.viewIfLoaded?.window != nil,
              controller.presentedViewController == nil else { return }
        let configuration = SFSafariViewController.Configuration()
        configuration.barCollapsingEnabled = true
        let safari = SFSafariViewController(url: destination.url, configuration: configuration)
        safari.dismissButtonStyle = .close
        safari.modalPresentationStyle = .fullScreen
        safari.delegate = context.coordinator
        controller.present(safari, animated: true)
    }

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        var destination: Binding<SimpleOneBrowserDestination?>

        init(destination: Binding<SimpleOneBrowserDestination?>) {
            self.destination = destination
        }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            destination.wrappedValue = nil
            controller.dismiss(animated: true)
        }
    }
}

struct AdminEvotorDriversScreen: View {
    @Environment(EvotorDriverLinksStore.self) private var store
    let canManage: Bool
    @State private var draft = EvotorDriverLinks.defaults

    private var validationMessage: String? {
        do { _ = try draft.validated(); return nil }
        catch { return error.localizedDescription }
    }

    var body: some View {
        Form {
            Section("Ссылки драйверов") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Драйвер Aisino")
                    TextField("https://", text: $draft.aisinoURL)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Драйвер PAX")
                    TextField("https://", text: $draft.paxURL)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .disabled(!canManage || store.isLoading || store.isSaving)

            if let validationMessage {
                Section { Text(validationMessage).foregroundStyle(AppTheme.dangerTint) }
            }

            if canManage {
                Section {
                    Button(store.isSaving ? "Сохранение…" : "Сохранить") {
                        Task {
                            if await store.save(draft) { draft = store.links }
                        }
                    }
                    .disabled(store.isLoading || store.isSaving || validationMessage != nil || draft == store.links)
                } footer: {
                    Text("Общие ссылки используются во всех заявках с типом терминала intel_pin.")
                }
            }
        }
        .navigationTitle("Драйвер Эвотор")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: store.links) { previous, current in
            if draft == previous { draft = current }
        }
        .task {
            await store.refresh()
            draft = store.links
            if let error = store.loadError { AppBannerCenter.shared.show(error, style: .error) }
        }
    }
}
#endif
