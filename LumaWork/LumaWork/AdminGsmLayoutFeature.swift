import Foundation
import Observation
import SwiftUI

struct AdminGsmLayoutBlock: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    var enabled: Bool
}

struct AdminGsmLayoutPage: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    var blocks: [AdminGsmLayoutBlock]

    var enabledBlockCount: Int {
        blocks.filter(\.enabled).count
    }

    var isEnabled: Bool {
        !blocks.isEmpty && enabledBlockCount == blocks.count
    }
}

struct AdminGsmLayoutConfiguration: Codable, Hashable {
    var pages: [AdminGsmLayoutPage]
    let updatedAt: String?

    var disabledBlockIDs: Set<String> {
        Set(pages.flatMap(\.blocks).filter { !$0.enabled }.map(\.id))
    }
}

@MainActor
struct AdminGsmLayoutAPI {
    private struct Response: Decodable {
        let layout: AdminGsmLayoutConfiguration
    }

    private let baseURL: URL
    private let http = HTTPClient()

    init(config: AppConfig) {
        baseURL = AppConfig.configuredURL(config.lumaWorkAPIOrigin)
    }

    func fetch(token: String) async throws -> AdminGsmLayoutConfiguration {
        let response = try await http.request(
            url("/api/v2/admin/gsm-layout"),
            authToken: token
        )
        return try decode(response.json).layout
    }

    func update(disabledBlockIDs: Set<String>, token: String) async throws -> AdminGsmLayoutConfiguration {
        let response = try await http.request(
            url("/api/v2/admin/gsm-layout"),
            method: "PUT",
            body: ["disabledBlockIds": disabledBlockIDs.sorted()],
            authToken: token
        )
        return try decode(response.json).layout
    }

    private func url(_ path: String) -> URL {
        baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    private func decode(_ json: Any?) throws -> Response {
        guard let json else {
            throw AppServiceError.message("Сервер вернул пустой ответ.")
        }
        return try JSONDecoder().decode(
            Response.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
    }
}

@MainActor
@Observable
final class AdminGsmLayoutStore {
    private let api: AdminGsmLayoutAPI
    private let token: String?
    private let cacheKey: String
    private var savedDisabledBlockIDs: Set<String> = []

    var configuration: AdminGsmLayoutConfiguration?
    var isLoading = false
    var isSaving = false
    var errorMessage: String?
    var notice: String?

    init(token: String?, cacheID: String?, api: AdminGsmLayoutAPI? = nil) {
        self.token = token
        self.api = api ?? AdminGsmLayoutAPI(config: AppConfig())
        cacheKey = AppOfflineSnapshotStore.scopedKey("admin-gsm-layout", userID: cacheID)
        if let snapshot = AppOfflineSnapshotStore.load(AdminGsmLayoutConfiguration.self, key: cacheKey) {
            configuration = snapshot.value
            savedDisabledBlockIDs = snapshot.value.disabledBlockIDs
        }
    }

    var isDirty: Bool {
        configuration?.disabledBlockIDs != savedDisabledBlockIDs
    }

    func loadIfNeeded() async {
        await refresh(reportErrors: configuration == nil)
    }

    func refresh(reportErrors: Bool = true) async {
        guard !isLoading, !isSaving else { return }
        guard let token, !token.isEmpty else {
            errorMessage = "Требуется авторизация администратора."
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            apply(try await api.fetch(token: token))
        } catch is CancellationError {
            return
        } catch {
            if reportErrors {
                errorMessage = appUserFacingErrorMessage(error)
            }
        }
    }

    func save() async {
        guard !isSaving, let configuration, isDirty else { return }
        guard let token, !token.isEmpty else {
            errorMessage = "Требуется авторизация администратора."
            return
        }
        isSaving = true
        errorMessage = nil
        notice = nil
        defer { isSaving = false }
        do {
            apply(try await api.update(
                disabledBlockIDs: configuration.disabledBlockIDs,
                token: token
            ))
            notice = "Настройки заполнения сохранены."
        } catch is CancellationError {
            return
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
        }
    }

    func isPageEnabled(_ pageID: String) -> Bool {
        configuration?.pages.first(where: { $0.id == pageID })?.isEnabled == true
    }

    func setPage(_ pageID: String, enabled: Bool) {
        guard var configuration,
              let pageIndex = configuration.pages.firstIndex(where: { $0.id == pageID }) else { return }
        for blockIndex in configuration.pages[pageIndex].blocks.indices {
            configuration.pages[pageIndex].blocks[blockIndex].enabled = enabled
        }
        self.configuration = configuration
        notice = nil
    }

    func setBlock(_ blockID: String, enabled: Bool) {
        guard var configuration,
              let pageIndex = configuration.pages.firstIndex(where: { page in
            page.blocks.contains(where: { $0.id == blockID })
        }), let blockIndex = configuration.pages[pageIndex].blocks.firstIndex(where: { $0.id == blockID }) else {
            return
        }
        configuration.pages[pageIndex].blocks[blockIndex].enabled = enabled
        self.configuration = configuration
        notice = nil
    }

    func enableAll() {
        guard let pages = configuration?.pages else { return }
        for page in pages {
            setPage(page.id, enabled: true)
        }
    }

    private func apply(_ value: AdminGsmLayoutConfiguration) {
        configuration = value
        savedDisabledBlockIDs = value.disabledBlockIDs
        AppOfflineSnapshotStore.save(value, key: cacheKey)
    }
}

struct AdminGsmLayoutCard: View {
    @State private var store: AdminGsmLayoutStore

    let canEdit: Bool

    init(token: String?, cacheID: String?, canEdit: Bool) {
        _store = State(initialValue: AdminGsmLayoutStore(token: token, cacheID: cacheID))
        self.canEdit = canEdit
    }

    var body: some View {
        Group {
            AppSectionHeader(
                title: "Заполнение отчёта",
                caption: "Листы и блоки для новых ГСМ-отчётов"
            )

            if let errorMessage = store.errorMessage {
                AppNoticeBanner(text: errorMessage, tint: AppTheme.dangerTint, isCritical: true)
            }
            if let notice = store.notice {
                AppNoticeBanner(text: notice, tint: AppTheme.primaryTint)
            }

            if let configuration = store.configuration {
                ForEach(configuration.pages) { page in
                    pageCard(page)
                }

                if canEdit {
                    HStack(spacing: 12) {
                        Button("Включить всё") {
                            AppHaptics.trigger()
                            store.enableAll()
                        }
                        .buttonStyle(.bordered)
                        .disabled(store.isSaving || configuration.disabledBlockIDs.isEmpty)

                        Button {
                            AppHaptics.trigger()
                            Task { await store.save() }
                        } label: {
                            if store.isSaving {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text("Сохранить")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.isSaving || !store.isDirty)
                    }
                } else {
                    AppNoticeBanner(
                        text: "Доступен только просмотр. Для изменения требуется право замены шаблона ГСМ.",
                        tint: AppTheme.mutedTint
                    )
                }
            } else if store.isLoading {
                AppLoadingView(title: "Загружаю настройки заполнения")
            } else {
                AppEmptyState(
                    title: "Настройки недоступны",
                    message: "Обновите экран, чтобы повторить запрос.",
                    systemName: "switch.2"
                )
                Button("Повторить") {
                    Task { await store.refresh() }
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
            }
        }
        .task { await store.loadIfNeeded() }
    }

    private func pageCard(_ page: AdminGsmLayoutPage) -> some View {
        AppCard {
            Toggle(
                isOn: Binding(
                    get: { store.isPageEnabled(page.id) },
                    set: { store.setPage(page.id, enabled: $0) }
                )
            ) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(page.title)
                        .font(.headline)
                        .foregroundStyle(AppTheme.ink)
                    Text("Включено \(page.enabledBlockCount) из \(page.blocks.count) · \(page.detail)")
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedTint)
                }
            }
            .tint(AppTheme.primaryTint)
            .disabled(!canEdit || store.isSaving)

            ForEach(page.blocks) { block in
                Divider()
                Toggle(
                    isOn: Binding(
                        get: {
                            store.configuration?.pages
                                .flatMap(\.blocks)
                                .first(where: { $0.id == block.id })?.enabled == true
                        },
                        set: { store.setBlock(block.id, enabled: $0) }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(block.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.ink)
                        Text(block.detail)
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedTint)
                    }
                }
                .tint(AppTheme.primaryTint)
                .disabled(!canEdit || store.isSaving)
                .accessibilityLabel("Заполнять блок «\(block.title)»")
            }
        }
    }
}
