import Foundation
import Observation
import PhotosUI
import SwiftUI

struct AdminSiteContent: Codable, Hashable {
    var pages: [AdminSitePage] = []
    var sections: [AdminSiteSection] = []
    var texts: [AdminSiteText] = []
}

struct AdminSitePage: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let path: String
    var seoTitle: String
    var seoDescription: String
    var isVisible: Bool
}

struct AdminSiteSection: Codable, Hashable, Identifiable {
    let id: String
    let pageId: String
    let title: String
    var isVisible: Bool
}

struct AdminSiteText: Codable, Hashable, Identifiable {
    let id: String
    let group: String
    let label: String
    var value: String
    var isVisible: Bool
}

enum AdminSitePlatform: String, Codable, CaseIterable, Identifiable {
    case ios, android
    var id: String { rawValue }
    var title: String { self == .ios ? "iOS" : "Android" }
}

struct AdminSiteSettings: Codable, Hashable {
    var content = AdminSiteContent()
    var isEnabled = true
    var unavailableMessage = "Сайт временно недоступен. Попробуйте позже."
    var brandTitle = "Инженер"
    var brandCaption = "Приложение «Инженер»"
    var statusText = "Источник обновлений доступен"
    var heroTitle = "Рабочие задачи"
    var heroAccent = "в одном приложении"
    var heroDescription = "Инженер объединяет заявки, маршруты, пробег, топливо, аналитику и рабочую базу знаний."
    var minimumIOS = "26.2"
    var screenshotsTitle = "Приложение, созданное под ежедневную работу"
    var screenshotsCaption = "Светлый интерфейс, крупные элементы и быстрый доступ к основным разделам без лишних переходов."
}

struct AdminSiteScreenshot: Codable, Identifiable, Hashable {
    let id: String
    var platform: AdminSitePlatform
    var title: String
    var caption: String
    var altText: String
    let imageURL: URL?
    let sizeBytes: Int
    let sortOrder: Int
    var isVisible: Bool
    var isTitleVisible: Bool
    var isCaptionVisible: Bool
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
            "screenshotsCaption": value.screenshotsCaption,
            "content": try JSONSerialization.jsonObject(with: JSONEncoder().encode(value.content))
        ])
        return settings(dictionaryValue(response)?["settings"])
    }

    func upload(
        data: Data,
        screenshotID: String,
        title: String,
        caption: String,
        altText: String,
        platform: AdminSitePlatform,
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
                "platform": platform.rawValue,
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
            "platform": item.platform.rawValue,
            "isTitleVisible": item.isTitleVisible,
            "isCaptionVisible": item.isCaptionVisible,
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

    func image(id: String) async -> Data? {
        guard let token, !token.isEmpty else { return nil }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v2/admin/site/screenshots/\(id)/image"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
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
        if let rawContent = value["content"],
           let data = try? JSONSerialization.data(withJSONObject: rawContent),
           let content = try? JSONDecoder().decode(AdminSiteContent.self, from: data) {
            result.content = content
        }
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
            platform: AdminSitePlatform(rawValue: stringValue(value["platform"])) ?? .ios,
            title: stringValue(value["title"]),
            caption: stringValue(value["caption"]),
            altText: stringValue(value["altText"]),
            imageURL: imageURL,
            sizeBytes: intValue(value["sizeBytes"]) ?? 0,
            sortOrder: intValue(value["sortOrder"]) ?? 0,
            isVisible: value["isVisible"] as? Bool ?? true,
            isTitleVisible: value["isTitleVisible"] as? Bool ?? true,
            isCaptionVisible: value["isCaptionVisible"] as? Bool ?? true
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
    private var hasLoaded = false

    init(token: String?) {
        api = AdminSiteAPI(config: AppConfig(), token: token)
    }

    func load(force: Bool = false) async {
        guard !isLoading, force || !hasLoaded else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            (settings, screenshots) = try await api.fetch()
            hasLoaded = true
        } catch is CancellationError {
            return
        } catch {
            show(error)
        }
    }

    func saveSettings() async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            settings = try await api.save(settings)
            AppBannerCenter.shared.show("Настройки сайта сохранены.", style: .success)
            return true
        } catch { show(error); return false }
    }

    func upload(data: Data, id: String = UUID().uuidString, title: String, caption: String, altText: String, platform: AdminSitePlatform) async -> Bool {
        guard uploadProgress == nil else { return false }
        uploadProgress = 0
        defer { uploadProgress = nil }
        do {
            let item = try await api.upload(data: data, screenshotID: id, title: title, caption: caption, altText: altText, platform: platform) { [weak self] in
                self?.uploadProgress = $0
            }
            if let index = screenshots.firstIndex(where: { $0.id == id }) { screenshots[index] = item } else { screenshots.append(item) }
            screenshots.sort { $0.sortOrder < $1.sortOrder }
            AppBannerCenter.shared.show("Скриншот сохранён.", style: .success)
            return true
        } catch { show(error); return false }
    }

    func update(_ item: AdminSiteScreenshot) async -> Bool {
        do {
            let updated = try await api.update(item)
            if let index = screenshots.firstIndex(where: { $0.id == item.id }) { screenshots[index] = updated }
            return true
        } catch { show(error); return false }
    }

    func move(_ item: AdminSiteScreenshot, offset: Int) async {
        guard let index = screenshots.firstIndex(where: { $0.id == item.id }) else { return }
        let platformIndices = screenshots.indices.filter { screenshots[$0].platform == item.platform }
        guard let platformIndex = platformIndices.firstIndex(of: index),
              platformIndices.indices.contains(platformIndex + offset) else { return }
        let target = platformIndices[platformIndex + offset]
        screenshots.swapAt(index, target)
        do { screenshots = try await api.reorder(ids: screenshots.map(\.id)) } catch {
            show(error)
            if let (_, items) = try? await api.fetch() { screenshots = items }
        }
    }

    func delete(_ item: AdminSiteScreenshot) async {
        do {
            try await api.delete(id: item.id)
            screenshots.removeAll { $0.id == item.id }
            AppBannerCenter.shared.show("Скриншот удалён.", style: .success)
        } catch { show(error) }
    }

    func image(id: String) async -> Data? { await api.image(id: id) }

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
    @State private var platform: AdminSitePlatform = .ios
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

            Section {
                ForEach(Array(store.settings.content.pages.enumerated()), id: \.element.id) { index, page in
                    NavigationLink {
                        AdminSitePageEditor(store: store, index: index, canManage: canManage)
                    } label: {
                        HStack {
                            Text(page.title)
                            Spacer()
                            Text(page.isVisible ? "Видна" : "Скрыта").foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach($store.settings.content.sections) { $section in
                    if section.pageId == "shared" {
                        Toggle(section.title, isOn: $section.isVisible).disabled(!canManage)
                    }
                }
            } header: { Text("Страницы и разделы") } footer: {
                Text("Скрытые страницы недоступны по прямой ссылке и убраны из навигации. Изменения применяются после сохранения настроек.")
            }

            Section("Тексты сайта") {
                NavigationLink {
                    AdminSiteTextList(store: store, canManage: canManage)
                } label: {
                    LabeledContent("Редактировать тексты", value: "\(store.settings.content.texts.count)")
                }
                if store.settings.content.pages.isEmpty && !store.isLoading {
                    Text("Для управления страницами и текстами требуется обновление сервера.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("Платформа", selection: $platform) {
                    ForEach(AdminSitePlatform.allCases) { item in Text(item.title).tag(item) }
                }
                .pickerStyle(.segmented)
                if !store.screenshots.contains(where: { $0.platform == platform }) {
                    Text("Скриншоты для \(platform.title) пока не добавлены.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.screenshots.filter { $0.platform == platform }) { item in screenshotRow(item) }
                }
                if canManage {
                    Button("Добавить скриншот", systemImage: "plus") {
                        replacement = nil
                        selectedPhoto = nil
                        isReplacementPickerPresented = true
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
        .disabled(store.isLoading || store.isSaving || store.uploadProgress != nil)
        .task { await store.load() }
        .refreshable { await store.load(force: true) }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task { await prepare(item) }
        }
        .photosPicker(isPresented: $isReplacementPickerPresented, selection: $selectedPhoto, matching: .images)
        .sheet(item: $selectedImage) { selection in
            AdminSiteNewScreenshotSheet(selection: selection, store: store, platform: platform)
        }
        .sheet(item: $editedScreenshot) { item in
            AdminSiteScreenshotEditor(item: item) { updated in await store.update(updated) }
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

    private func screenshotRow(_ item: AdminSiteScreenshot) -> some View {
        HStack(spacing: 12) {
            AdminSiteThumbnail(store: store, item: item)
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
                _ = await store.upload(data: data, id: replacement.id, title: replacement.title, caption: replacement.caption, altText: replacement.altText, platform: replacement.platform)
            } else {
                selectedImage = AdminSiteImageSelection(data: data, defaultTitle: "Скриншот")
            }
        } catch {
            AppBannerCenter.shared.show(appUserFacingErrorMessage(error, fallback: "Не удалось добавить скриншот.") ?? "Не удалось добавить скриншот.", style: .error)
        }
    }
}

private struct AdminSiteThumbnail: View {
    let store: AdminSiteStore
    let item: AdminSiteScreenshot
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Color.secondary.opacity(0.12) }
        }
        .task(id: item.imageURL) {
            image = nil
            if let data = await store.image(id: item.id), !Task.isCancelled { image = UIImage(data: data) }
        }
    }
}

private struct AdminSitePageEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: AdminSiteStore
    let index: Int
    let canManage: Bool

    var body: some View {
        Form {
            Section("Страница") {
                Toggle("Показывать страницу", isOn: $store.settings.content.pages[index].isVisible)
                LabeledContent("Адрес", value: store.settings.content.pages[index].path)
            }
            Section("Разделы") {
                ForEach($store.settings.content.sections) { $section in
                    if section.pageId == store.settings.content.pages[index].id {
                        Toggle(section.title, isOn: $section.isVisible)
                    }
                }
            }
            Section("Вкладка браузера") {
                TextField("Заголовок вкладки", text: $store.settings.content.pages[index].seoTitle, axis: .vertical)
            }
        }
        .disabled(!canManage || store.isSaving)
        .navigationTitle(store.settings.content.pages[index].title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canManage {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { Task { if await store.saveSettings() { dismiss() } } }
                        .disabled(store.isSaving)
                }
            }
        }
    }
}

private struct AdminSiteTextList: View {
    @Bindable var store: AdminSiteStore
    let canManage: Bool
    @State private var search = ""

    private var groups: [String] {
        Array(Set(store.settings.content.texts.map(\.group))).sorted()
    }

    var body: some View {
        List {
            ForEach(groups, id: \.self) { group in
                let indices = store.settings.content.texts.indices.filter { index in
                    let item = store.settings.content.texts[index]
                    return item.group == group && (search.isEmpty || item.value.localizedCaseInsensitiveContains(search) || item.label.localizedCaseInsensitiveContains(search))
                }
                if !indices.isEmpty {
                    Section(group) {
                        ForEach(indices, id: \.self) { index in
                            let item = store.settings.content.texts[index]
                            NavigationLink {
                                AdminSiteTextEditor(store: store, index: index, canManage: canManage)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.value.isEmpty ? item.label : item.value).lineLimit(3)
                                    if !item.isVisible { Text("Скрыт").font(.caption).foregroundStyle(.orange) }
                                }
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Найти текст на сайте")
        .navigationTitle("Тексты сайта")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AdminSiteTextEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: AdminSiteStore
    let index: Int
    let canManage: Bool

    var body: some View {
        Form {
            Section {
                Toggle("Показывать текст", isOn: $store.settings.content.texts[index].isVisible)
                TextField("Текст", text: $store.settings.content.texts[index].value, axis: .vertical)
                    .lineLimit(3...20)
            } header: { Text(store.settings.content.texts[index].group) } footer: {
                Text("Текст публикуется без HTML. Скрытие сохраняет его для повторного включения.")
            }
        }
        .disabled(!canManage || store.isSaving)
        .navigationTitle("Редактирование текста")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canManage {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { Task { if await store.saveSettings() { dismiss() } } }
                        .disabled(store.isSaving)
                }
            }
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
    @State private var platform: AdminSitePlatform

    init(selection: AdminSiteImageSelection, store: AdminSiteStore, platform: AdminSitePlatform) {
        self.selection = selection
        self.store = store
        _platform = State(initialValue: platform)
        _title = State(initialValue: selection.defaultTitle)
        _altText = State(initialValue: selection.defaultTitle)
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Платформа", selection: $platform) {
                    ForEach(AdminSitePlatform.allCases) { item in Text(item.title).tag(item) }
                }
                TextField("Название", text: $title)
                TextField("Описание", text: $caption, axis: .vertical)
                TextField("Описание для VoiceOver", text: $altText, axis: .vertical)
                if let progress = store.uploadProgress { ProgressView(value: progress) }
            }
            .interactiveDismissDisabled(store.uploadProgress != nil)
            .navigationTitle("Новый скриншот")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { ModalCloseButton { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    ModalConfirmButton(action: {
                        Task {
                            if await store.upload(data: selection.data, title: title, caption: caption, altText: altText, platform: platform) { dismiss() }
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
    @State private var isSaving = false
    let save: (AdminSiteScreenshot) async -> Bool

    var body: some View {
        NavigationStack {
            Form {
                Picker("Платформа", selection: $item.platform) {
                    ForEach(AdminSitePlatform.allCases) { platform in Text(platform.title).tag(platform) }
                }
                TextField("Название", text: $item.title)
                TextField("Описание", text: $item.caption, axis: .vertical)
                TextField("Описание для VoiceOver", text: $item.altText, axis: .vertical)
                Toggle("Показывать на сайте", isOn: $item.isVisible)
                Toggle("Показывать название", isOn: $item.isTitleVisible)
                Toggle("Показывать описание", isOn: $item.isCaptionVisible)
            }
            .disabled(isSaving)
            .interactiveDismissDisabled(isSaving)
            .navigationTitle("Скриншот")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { ModalCloseButton { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        Task {
                            isSaving = true
                            defer { isSaving = false }
                            if await save(item) { dismiss() }
                        }
                    }
                        .disabled(isSaving || item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || item.altText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
