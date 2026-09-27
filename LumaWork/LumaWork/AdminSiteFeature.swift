import Foundation
import Observation
import PhotosUI
import SwiftUI

struct AdminSiteSettings: Codable, Hashable {
    var isEnabled = true
    var unavailableMessage = "Сайт временно недоступен. Попробуйте позже."
    var brandTitle = "LumaWork"
    var brandCaption = "Приложение «Инженер»"
    var statusText = "Источник обновлений доступен"
    var heroTitle = "Рабочие задачи"
    var heroAccent = "в одном приложении"
    var heroDescription = "LumaWork объединяет заявки, маршруты, пробег, топливо, аналитику и рабочую базу знаний."
    var minimumIOS = "26.2"
    var screenshotsTitle = "Приложение, созданное под ежедневную работу"
    var screenshotsCaption = "Светлый интерфейс, крупные элементы и быстрый доступ к основным разделам без лишних переходов."
}

struct AdminSiteScreenshot: Codable, Identifiable, Hashable {
    let id: String
    var title: String
    var caption: String
    var altText: String
    let imageURL: URL?
    let sizeBytes: Int
    let sortOrder: Int
    var isVisible: Bool
}

private struct AdminSiteImageSelection: Identifiable {
    let id = UUID()
    let data: Data
    let defaultTitle: String
}

@MainActor
struct AdminSiteAPI {
    private let baseURL: URL
    private let token: String?
    private let http = HTTPClient()

    init(config: AppConfig, token: String?) {
        baseURL = AppConfig.configuredURL(config.lumaWorkAPIOrigin)
        self.token = token
    }

    func fetch() async throws -> (AdminSiteSettings, [AdminSiteScreenshot]) {
        let response = try await request("/api/v2/admin/site")
        let root = dictionaryValue(response) ?? [:]
        return (settings(root["settings"]), screenshots(root["screenshots"]))
    }

    func save(_ value: AdminSiteSettings) async throws -> AdminSiteSettings {
        let response = try await request("/api/v2/admin/site", method: "PUT", body: [
            "isEnabled": value.isEnabled,
            "unavailableMessage": value.unavailableMessage,
            "brandTitle": value.brandTitle,
            "brandCaption": value.brandCaption,
            "statusText": value.statusText,
            "heroTitle": value.heroTitle,
            "heroAccent": value.heroAccent,
            "heroDescription": value.heroDescription,
            "minimumIOS": value.minimumIOS,
            "screenshotsTitle": value.screenshotsTitle,
            "screenshotsCaption": value.screenshotsCaption
        ])
        return settings(dictionaryValue(response)?["settings"])
    }

    func upload(
        data: Data,
        screenshotID: String,
        title: String,
        caption: String,
        altText: String,
        progress: @MainActor (Double) -> Void
    ) async throws -> AdminSiteScreenshot {
        guard !data.isEmpty, data.count <= 20 * 1024 * 1024 else {
            throw AppServiceError.message("Скриншот должен быть не больше 20 МБ.")
        }
        let chunkSize = 512 * 1024
        let chunks = stride(from: 0, to: data.count, by: chunkSize).map {
            data.subdata(in: $0 ..< min($0 + chunkSize, data.count))
        }
        let uploadID = UUID().uuidString
        var uploaded: AdminSiteScreenshot?
        for (index, chunk) in chunks.enumerated() {
            let response = try await request("/api/v2/admin/site/screenshots/chunk", method: "POST", body: [
                "uploadId": uploadID,
                "screenshotId": screenshotID,
                "title": title,
                "caption": caption,
                "altText": altText,
                "chunkIndex": index,
                "totalChunks": chunks.count,
                "chunkBase64": chunk.base64EncodedString()
            ])
            if let raw = dictionaryValue(response)?["screenshot"] {
                uploaded = screenshot(raw)
            }
            progress(Double(index + 1) / Double(chunks.count))
        }
        guard let uploaded else { throw AppServiceError.message("Сервер не подтвердил загрузку скриншота.") }
        return uploaded
    }

    func update(_ item: AdminSiteScreenshot) async throws -> AdminSiteScreenshot {
        let response = try await request("/api/v2/admin/site/screenshots/\(item.id)", method: "PATCH", body: [
            "title": item.title,
            "caption": item.caption,
            "altText": item.altText,
            "isVisible": item.isVisible
        ])
        guard let raw = dictionaryValue(response)?["screenshot"], let updated = screenshot(raw) else {
            throw AppServiceError.message("Сервер не подтвердил изменение скриншота.")
        }
        return updated
    }

    func reorder(ids: [String]) async throws -> [AdminSiteScreenshot] {
        let response = try await request("/api/v2/admin/site/screenshots-order", method: "PUT", body: ["screenshotIds": ids])
        return screenshots(dictionaryValue(response)?["screenshots"])
    }

    func delete(id: String) async throws {
        _ = try await request("/api/v2/admin/site/screenshots/\(id)", method: "DELETE")
    }

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Any? {
        guard let token, !token.isEmpty else { throw AppServiceError.message("Требуется авторизация администратора.") }
        return try await http.request(
            baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
            method: method,
            body: body,
            authToken: token
        ).json
    }

    private func settings(_ raw: Any?) -> AdminSiteSettings {
        guard let value = dictionaryValue(raw) else { return AdminSiteSettings() }
        var result = AdminSiteSettings()
        result.isEnabled = value["isEnabled"] as? Bool ?? result.isEnabled
        result.unavailableMessage = stringValue(value["unavailableMessage"], default: result.unavailableMessage)
        result.brandTitle = stringValue(value["brandTitle"], default: result.brandTitle)
        result.brandCaption = stringValue(value["brandCaption"], default: result.brandCaption)
        result.statusText = stringValue(value["statusText"], default: result.statusText)
        result.heroTitle = stringValue(value["heroTitle"], default: result.heroTitle)
        result.heroAccent = stringValue(value["heroAccent"], default: result.heroAccent)
        result.heroDescription = stringValue(value["heroDescription"], default: result.heroDescription)
        result.minimumIOS = stringValue(value["minimumIOS"], default: result.minimumIOS)
        result.screenshotsTitle = stringValue(value["screenshotsTitle"], default: result.screenshotsTitle)
        result.screenshotsCaption = stringValue(value["screenshotsCaption"], default: result.screenshotsCaption)
        return result
    }

    private func screenshots(_ raw: Any?) -> [AdminSiteScreenshot] {
        (raw as? [Any] ?? []).compactMap(screenshot)
    }

    private func screenshot(_ raw: Any) -> AdminSiteScreenshot? {
        guard let value = dictionaryValue(raw) else { return nil }
        let id = stringValue(value["id"])
        guard !id.isEmpty else { return nil }
        let imagePath = stringValue(value["imageUrl"])
        let imageURL = URL(string: imagePath, relativeTo: baseURL)?.absoluteURL
        return AdminSiteScreenshot(
            id: id,
            title: stringValue(value["title"]),
            caption: stringValue(value["caption"]),
            altText: stringValue(value["altText"]),
            imageURL: imageURL,
            sizeBytes: intValue(value["sizeBytes"]) ?? 0,
            sortOrder: intValue(value["sortOrder"]) ?? 0,
            isVisible: value["isVisible"] as? Bool ?? true
        )
    }
}

@MainActor
@Observable
final class AdminSiteStore {
    private let api: AdminSiteAPI
    var settings = AdminSiteSettings()
    var screenshots: [AdminSiteScreenshot] = []
    var isLoading = false
    var isSaving = false
    var uploadProgress: Double?

    init(token: String?) {
        api = AdminSiteAPI(config: AppConfig(), token: token)
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            (settings, screenshots) = try await api.fetch()
        } catch is CancellationError {
            return
        } catch {
            show(error)
        }
    }

    func saveSettings() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            settings = try await api.save(settings)
            AppBannerCenter.shared.show("Настройки сайта сохранены.", style: .success)
        } catch { show(error) }
    }

    func upload(data: Data, id: String = UUID().uuidString, title: String, caption: String, altText: String) async -> Bool {
        uploadProgress = 0
        defer { uploadProgress = nil }
        do {
            let item = try await api.upload(data: data, screenshotID: id, title: title, caption: caption, altText: altText) { [weak self] in
                self?.uploadProgress = $0
            }
            if let index = screenshots.firstIndex(where: { $0.id == id }) { screenshots[index] = item } else { screenshots.append(item) }
            screenshots.sort { $0.sortOrder < $1.sortOrder }
            AppBannerCenter.shared.show("Скриншот сохранён.", style: .success)
            return true
        } catch { show(error); return false }
    }

    func update(_ item: AdminSiteScreenshot) async {
        do {
            let updated = try await api.update(item)
            if let index = screenshots.firstIndex(where: { $0.id == item.id }) { screenshots[index] = updated }
        } catch { show(error) }
    }

    func move(_ item: AdminSiteScreenshot, offset: Int) async {
        guard let index = screenshots.firstIndex(where: { $0.id == item.id }) else { return }
        let target = index + offset
        guard screenshots.indices.contains(target) else { return }
        screenshots.swapAt(index, target)
        do { screenshots = try await api.reorder(ids: screenshots.map(\.id)) } catch { show(error); await load() }
    }

    func delete(_ item: AdminSiteScreenshot) async {
        do {
            try await api.delete(id: item.id)
            screenshots.removeAll { $0.id == item.id }
            AppBannerCenter.shared.show("Скриншот удалён.", style: .success)
        } catch { show(error) }
    }

    private func show(_ error: Error) {
        if let message = appUserFacingErrorMessage(error, fallback: "Не удалось обновить сайт.") {
            AppBannerCenter.shared.show(message, style: .error)
        }
    }
}

struct AdminSiteScreen: View {
    @State private var store: AdminSiteStore
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isReplacementPickerPresented = false
    @State private var selectedImage: AdminSiteImageSelection?
    @State private var replacement: AdminSiteScreenshot?
    @State private var editedScreenshot: AdminSiteScreenshot?
    @State private var screenshotToDelete: AdminSiteScreenshot?
    private let canManage: Bool

    init(token: String?, canManage: Bool) {
        _store = State(initialValue: AdminSiteStore(token: token))
        self.canManage = canManage
    }

    var body: some View {
        Form {
            Section("Доступность") {
                Toggle("Сайт доступен", isOn: $store.settings.isEnabled)
                    .tint(AppTheme.primaryTint)
                    .disabled(!canManage)
                if !store.settings.isEnabled {
                    TextField("Сообщение при отключении", text: $store.settings.unavailableMessage, axis: .vertical)
                        .disabled(!canManage)
                }
            }

            Section("Главный экран") {
                siteField("Название", text: $store.settings.brandTitle)
                siteField("Подпись", text: $store.settings.brandCaption)
                siteField("Статус", text: $store.settings.statusText)
                siteField("Заголовок", text: $store.settings.heroTitle)
                siteField("Акцент заголовка", text: $store.settings.heroAccent)
                siteField("Описание", text: $store.settings.heroDescription, axis: .vertical)
                siteField("Минимальная iOS", text: $store.settings.minimumIOS)
            }

            Section("Раздел скриншотов") {
                siteField("Заголовок", text: $store.settings.screenshotsTitle)
                siteField("Описание", text: $store.settings.screenshotsCaption, axis: .vertical)
            }

            Section {
                if store.screenshots.isEmpty {
                    Text("После загрузки первого скриншота сайт переключится со встроенной галереи на управляемую.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.screenshots) { item in screenshotRow(item) }
                }
                if canManage {
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label("Добавить скриншот", systemImage: "plus")
                    }
                }
                if let progress = store.uploadProgress {
                    ProgressView(value: progress)
                }
            } header: {
                Text("Скриншоты")
            } footer: {
                Text("Изображения сжимаются в WebP и хранятся на сервере.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
        .navigationTitle("Сайт")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canManage {
                ToolbarItem(placement: .topBarTrailing) {
                    ModalConfirmButton(
                        action: { Task { await store.saveSettings() } },
                        isLoading: store.isSaving,
                        accessibilityLabel: "Сохранить настройки сайта"
                    )
                }
            }
        }
        .disabled(store.isLoading)
        .task { await store.load() }
        .refreshable { await store.load() }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task { await prepare(item) }
        }
        .photosPicker(isPresented: $isReplacementPickerPresented, selection: $selectedPhoto, matching: .images)
        .sheet(item: $selectedImage) { selection in
            AdminSiteNewScreenshotSheet(selection: selection, store: store)
        }
        .sheet(item: $editedScreenshot) { item in
            AdminSiteScreenshotEditor(item: item) { updated in Task { await store.update(updated) } }
        }
        .confirmationDialog("Удалить скриншот?", isPresented: Binding(
            get: { screenshotToDelete != nil },
            set: { if !$0 { screenshotToDelete = nil } }
        )) {
            Button("Удалить", role: .destructive) {
                guard let item = screenshotToDelete else { return }
                screenshotToDelete = nil
                Task { await store.delete(item) }
            }
            Button("Отмена", role: .cancel) {}
        }
    }

    private func siteField(_ title: String, text: Binding<String>, axis: Axis = .horizontal) -> some View {
        TextField(title, text: text, axis: axis).disabled(!canManage)
    }

    private func screenshotRow(_ item: AdminSiteScreenshot) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: item.imageURL) { phase in
                if let image = phase.image { image.resizable().scaledToFill() } else { Color.secondary.opacity(0.12) }
            }
            .frame(width: 52, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.subheadline.weight(.semibold))
                Text(item.caption).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if !item.isVisible { Text("Скрыт").font(.caption2.weight(.semibold)).foregroundStyle(.orange) }
            }
            Spacer()
            if canManage {
                Menu {
                    Button("Изменить", systemImage: "pencil") { editedScreenshot = item }
                    Button("Заменить файл", systemImage: "arrow.triangle.2.circlepath") {
                        replacement = item
                        selectedPhoto = nil
                        isReplacementPickerPresented = true
                    }
                    Button("Выше", systemImage: "arrow.up") { Task { await store.move(item, offset: -1) } }
                    Button("Ниже", systemImage: "arrow.down") { Task { await store.move(item, offset: 1) } }
                    Button("Удалить", systemImage: "trash", role: .destructive) { screenshotToDelete = item }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
    }

    private func prepare(_ item: PhotosPickerItem) async {
        defer { selectedPhoto = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw AppServiceError.message("Не удалось прочитать изображение.")
            }
            if let replacement {
                self.replacement = nil
                _ = await store.upload(data: data, id: replacement.id, title: replacement.title, caption: replacement.caption, altText: replacement.altText)
            } else {
                selectedImage = AdminSiteImageSelection(data: data, defaultTitle: "Скриншот")
            }
        } catch {
            AppBannerCenter.shared.show(appUserFacingErrorMessage(error, fallback: "Не удалось добавить скриншот.") ?? "Не удалось добавить скриншот.", style: .error)
        }
    }
}

private struct AdminSiteNewScreenshotSheet: View {
    @Environment(\.dismiss) private var dismiss
    let selection: AdminSiteImageSelection
    @Bindable var store: AdminSiteStore
    @State private var title: String
    @State private var caption = ""
    @State private var altText: String

    init(selection: AdminSiteImageSelection, store: AdminSiteStore) {
        self.selection = selection
        self.store = store
        _title = State(initialValue: selection.defaultTitle)
        _altText = State(initialValue: selection.defaultTitle)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Название", text: $title)
                TextField("Описание", text: $caption, axis: .vertical)
                TextField("Описание для VoiceOver", text: $altText, axis: .vertical)
                if let progress = store.uploadProgress { ProgressView(value: progress) }
            }
            .navigationTitle("Новый скриншот")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { ModalCloseButton { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    ModalConfirmButton(action: {
                        Task {
                            if await store.upload(data: selection.data, title: title, caption: caption, altText: altText) { dismiss() }
                        }
                    }, isDisabled: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || altText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, isLoading: store.uploadProgress != nil, accessibilityLabel: "Загрузить скриншот")
                }
            }
        }
    }
}

private struct AdminSiteScreenshotEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var item: AdminSiteScreenshot
    let save: (AdminSiteScreenshot) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("Название", text: $item.title)
                TextField("Описание", text: $item.caption, axis: .vertical)
                TextField("Описание для VoiceOver", text: $item.altText, axis: .vertical)
                Toggle("Показывать на сайте", isOn: $item.isVisible)
            }
            .navigationTitle("Скриншот")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { ModalCloseButton { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { save(item); dismiss() }
                        .disabled(item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || item.altText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
