import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

nonisolated struct AdminEngineerRemoteFile: Codable, Identifiable, Hashable, Sendable {
    let area: AdminSelectelManagedArea
    let name: String
    let sizeBytes: Int64
    let uploadedAt: String
    let kind: String?
    let isActive: Bool?

    var id: String { "\(area.rawValue)/\(name)" }
    var isSnapshot: Bool { kind == "snapshot" || area == .wikiSnapshots }
}

nonisolated private struct AdminEngineerFilesResponse: Decodable {
    let files: [AdminEngineerRemoteFile]
}

nonisolated private struct AdminEngineerSourceResponse: Decodable {
    let source: AdminEngineerSource
}

nonisolated private struct AdminEngineerFileResponse: Decodable {
    let file: AdminEngineerRemoteFile
}

nonisolated private struct AdminEngineerChunkResponse: Decodable {
    let complete: Bool
    let file: AdminEngineerRemoteFile?
}

nonisolated private struct AdminEngineerAPIError: Decodable {
    let message: String?
}

private struct AdminEngineerFilesAPI {
    private let baseURL: URL
    private let token: String
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(config: AppConfig, token: String) {
        baseURL = AppConfig.configuredURL(config.lumaWorkAPIOrigin)
        self.token = token
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        session = URLSession(configuration: configuration)
    }

    func list(area: AdminSelectelManagedArea) async throws -> [AdminEngineerRemoteFile] {
        var components = URLComponents(url: endpoint(["api", "v2", "admin", "engineer-files"]), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "area", value: area.rawValue)]
        let response: AdminEngineerFilesResponse = try await json(components.url!)
        return response.files
    }

    func upload(
        _ localURL: URL,
        area: AdminSelectelManagedArea,
        overwrite: Bool,
        progress: @MainActor (Double) -> Void
    ) async throws -> AdminEngineerRemoteFile {
        guard area.allows(fileName: localURL.lastPathComponent) else {
            throw AppServiceError.message("Имя файла не разрешено для выбранного раздела.")
        }
        let accessed = localURL.startAccessingSecurityScopedResource()
        defer { if accessed { localURL.stopAccessingSecurityScopedResource() } }
        let values = try localURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
            throw AppServiceError.message("Выбранный файл пуст или недоступен.")
        }
        let chunkSize = 512 * 1_024
        let totalChunks = Int(ceil(Double(size) / Double(chunkSize)))
        guard totalChunks <= 1_024 else {
            throw AppServiceError.message("Файл не должен превышать 512 МБ.")
        }
        let uploadID = UUID().uuidString.lowercased()
        let handle = try FileHandle(forReadingFrom: localURL)
        defer { try? handle.close() }
        var uploaded: AdminEngineerRemoteFile?

        for index in 0 ..< totalChunks {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                throw AppServiceError.message("Не удалось прочитать часть файла.")
            }
            let body = try JSONSerialization.data(withJSONObject: [
                "uploadId": uploadID,
                "fileName": localURL.lastPathComponent,
                "chunkIndex": index,
                "totalChunks": totalChunks,
                "chunkBase64": chunk.base64EncodedString(),
                "overwrite": overwrite
            ])
            let response: AdminEngineerChunkResponse = try await json(
                endpoint(["api", "v2", "admin", "engineer-files", area.rawValue, "upload-chunk"]),
                method: "POST",
                body: body
            )
            if response.complete { uploaded = response.file }
            progress(Double(index + 1) / Double(totalChunks))
        }
        guard let uploaded else { throw AppServiceError.message("Сервер не подтвердил загрузку файла.") }
        return uploaded
    }

    func download(_ file: AdminEngineerRemoteFile) async throws -> URL {
        let url = endpoint(["api", "v2", "admin", "engineer-files", file.area.rawValue, file.name, "content"])
        var request = request(url, method: "GET", body: nil)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let (temporaryURL, response) = try await session.download(for: request)
        try validate(response, data: nil)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumaWorkEngineerFiles", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(file.name)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    func rename(_ file: AdminEngineerRemoteFile, to newName: String) async throws -> AdminEngineerRemoteFile {
        let body = try JSONSerialization.data(withJSONObject: ["newName": newName])
        let response: AdminEngineerFileResponse = try await json(
            endpoint(["api", "v2", "admin", "engineer-files", file.area.rawValue, file.name]),
            method: "PATCH",
            body: body
        )
        return response.file
    }

    func delete(_ file: AdminEngineerRemoteFile) async throws {
        let url = endpoint(["api", "v2", "admin", "engineer-files", file.area.rawValue, file.name])
        let (_, response) = try await session.data(for: request(url, method: "DELETE", body: nil))
        try validate(response, data: nil)
    }

    func source() async throws -> AdminEngineerSource {
        let response: AdminEngineerSourceResponse = try await json(
            endpoint(["api", "v2", "admin", "engineer-files", "source"])
        )
        return response.source
    }

    func save(source: AdminEngineerSource) async throws -> AdminEngineerSource {
        let response: AdminEngineerSourceResponse = try await json(
            endpoint(["api", "v2", "admin", "engineer-files", "source"]),
            method: "PUT",
            body: try encoder.encode(source)
        )
        return response.source
    }

    private func json<Response: Decodable>(
        _ url: URL,
        method: String = "GET",
        body: Data? = nil
    ) async throws -> Response {
        let (data, response) = try await session.data(for: request(url, method: method, body: body))
        try validate(response, data: data)
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw AppServiceError.message("Сервер вернул некорректный ответ.")
        }
    }

    private func request(_ url: URL, method: String, body: Data?) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        AppBuildIdentity.apply(to: &request)
        return request
    }

    private func validate(_ response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AppServiceError.message("Сервер вернул неизвестный ответ.")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            if let data,
               let payload = try? decoder.decode(AdminEngineerAPIError.self, from: data),
               let message = payload.message,
               !message.isEmpty {
                throw AppServiceError.message(message)
            }
            throw AppServiceError.http(status: http.statusCode, fallback: "Ошибка файлового API")
        }
    }

    private func endpoint(_ segments: [String]) -> URL {
        segments.reduce(baseURL) { url, segment in
            url.appendingPathComponent(segment)
        }
    }
}

@MainActor
@Observable
private final class AdminEngineerFilesStore {
    private let api: AdminEngineerFilesAPI?
    let canManage: Bool

    let selectedArea: AdminSelectelManagedArea
    var files: [AdminEngineerRemoteFile] = []
    var isLoading = false
    var isLoadingSource = false
    var busyFileID: String?
    var uploadProgress: Double?
    var loadError: String?
    var downloadedFile: URL?

    init(token: String?, canManage: Bool, area: AdminSelectelManagedArea) {
        self.canManage = canManage
        selectedArea = area
        if let token, !token.isEmpty {
            api = AdminEngineerFilesAPI(config: AppConfig(), token: token)
        } else {
            api = nil
        }
    }

    func load(showsBanner: Bool = false) async {
        guard !isLoading else { return }
        guard let api else {
            loadError = "Требуется авторизация администратора."
            return
        }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            files = try await api.list(area: selectedArea)
        } catch is CancellationError {
            return
        } catch {
            let message = appUserFacingErrorMessage(error, fallback: "Не удалось загрузить список файлов.") ?? "Не удалось загрузить список файлов."
            loadError = message
            if showsBanner { AppBannerCenter.shared.show(message, style: .error) }
        }
    }

    func upload(_ url: URL, overwrite: Bool) async {
        guard canManage, selectedArea != .wikiSnapshots, let api else { return }
        uploadProgress = 0
        defer { uploadProgress = nil }
        do {
            _ = try await api.upload(url, area: selectedArea, overwrite: overwrite) { [weak self] value in
                self?.uploadProgress = value
            }
            AppBannerCenter.shared.show(overwrite ? "Файл заменён." : "Файл загружен.", style: .success)
            await load()
        } catch {
            show(error, fallback: "Не удалось загрузить файл.")
        }
    }

    func download(_ file: AdminEngineerRemoteFile) async {
        guard let api else { return }
        busyFileID = file.id
        defer { busyFileID = nil }
        do {
            downloadedFile = try await api.download(file)
        } catch {
            show(error, fallback: "Не удалось скачать файл.")
        }
    }

    func rename(_ file: AdminEngineerRemoteFile, to newName: String) async -> Bool {
        guard canManage, !file.isSnapshot, let api else { return false }
        busyFileID = file.id
        defer { busyFileID = nil }
        do {
            _ = try await api.rename(file, to: newName)
            AppBannerCenter.shared.show("Файл переименован.", style: .success)
            await load()
            return true
        } catch {
            show(error, fallback: "Не удалось переименовать файл.")
            return false
        }
    }

    func delete(_ file: AdminEngineerRemoteFile) async {
        guard canManage, !file.isSnapshot, let api else { return }
        busyFileID = file.id
        defer { busyFileID = nil }
        do {
            try await api.delete(file)
            files.removeAll { $0.id == file.id }
            AppBannerCenter.shared.show("Файл удалён.", style: .success)
        } catch {
            show(error, fallback: "Не удалось удалить файл.")
        }
    }

    func loadSource() async -> AdminEngineerSource? {
        guard let api else { return nil }
        isLoadingSource = true
        defer { isLoadingSource = false }
        do {
            return try await api.source()
        } catch {
            show(error, fallback: "Не удалось открыть source.json.")
            return nil
        }
    }

    func saveSource(_ source: AdminEngineerSource) async -> Bool {
        guard canManage, let api else { return false }
        do {
            _ = try await api.save(source: source)
            AppBannerCenter.shared.show("source.json сохранён.", style: .success)
            if selectedArea == .publicationMetadata { await load() }
            return true
        } catch {
            show(error, fallback: "Не удалось сохранить source.json.")
            return false
        }
    }

    func consumeDownloadedFile() {
        downloadedFile = nil
    }

    private func show(_ error: Error, fallback: String) {
        let message = appUserFacingErrorMessage(error, fallback: fallback) ?? fallback
        AppBannerCenter.shared.show(message, style: .error)
    }
}

struct AdminSelectelFilesScreen: View {
    let token: String?
    let canManage: Bool

    var body: some View {
        List {
            Section("Хранилища") {
                ForEach(AdminSelectelManagedArea.allCases) { area in
                    NavigationLink {
                        AdminEngineerFilesAreaScreen(token: token, canManage: canManage, area: area)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: area.systemImage)
                                .font(.title3)
                                .foregroundStyle(AppTheme.primaryTint)
                                .frame(width: 42, height: 42)
                                .background(AppTheme.primaryTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

                            VStack(alignment: .leading, spacing: 3) {
                                Text(area.title)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(AppTheme.ink)
                                Text(area.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.mutedTint)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
        .navigationTitle("Файлы инженера")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AdminEngineerFilesAreaScreen: View {
    private enum PresentedSheet: Identifiable {
        case rename(AdminEngineerRemoteFile)
        case source(AdminEngineerSource)

        var id: String {
            switch self {
            case let .rename(file): "rename-\(file.id)"
            case .source: "source-editor"
            }
        }
    }

    private enum Confirmation: Identifiable {
        case replace(URL)
        case delete(AdminEngineerRemoteFile)

        var id: String {
            switch self {
            case let .replace(url): "replace-\(url.lastPathComponent)"
            case let .delete(file): "delete-\(file.id)"
            }
        }
    }

    @State private var store: AdminEngineerFilesStore
    @State private var isImporting = false
    @State private var isExporting = false
    @State private var presentedSheet: PresentedSheet?
    @State private var confirmation: Confirmation?
    @State private var searchText = ""

    init(token: String?, canManage: Bool, area: AdminSelectelManagedArea) {
        _store = State(initialValue: AdminEngineerFilesStore(token: token, canManage: canManage, area: area))
    }

    var body: some View {
        presentedContent
    }

    private var listContent: some View {
        List {
            uploadSection
            filesSection
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
        .navigationTitle(store.selectedArea.title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Поиск файлов")
        .toolbar {
            if store.selectedArea == .publicationMetadata {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Редактор", systemImage: "slider.horizontal.3") {
                        Task { await openSourceEditor() }
                    }
                    .disabled(store.isLoadingSource || store.files.isEmpty)
                }
            }
            if store.canManage, store.selectedArea != .wikiSnapshots {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Загрузить файл", systemImage: "plus") {
                        isImporting = true
                    }
                    .disabled(store.uploadProgress != nil)
                }
            }
        }
        .refreshable { await store.load(showsBanner: true) }
        .task { await store.load() }
    }

    private var transferContent: some View {
        listContent
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            if store.files.contains(where: { $0.name == url.lastPathComponent }) {
                confirmation = .replace(url)
            } else {
                Task { await store.upload(url, overwrite: false) }
            }
        }
        .fileMover(isPresented: $isExporting, file: store.downloadedFile) { _ in
            store.consumeDownloadedFile()
        }
        .onChange(of: store.downloadedFile) { _, value in
            isExporting = value != nil
        }
    }

    private var presentedContent: some View {
        transferContent
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case let .rename(file):
                AdminEngineerRenameFileSheet(file: file) { newName in
                    await store.rename(file, to: newName)
                }
            case let .source(source):
                AdminEngineerSourceEditor(source: source, canManage: store.canManage) { source in
                    await store.saveSource(source)
                }
            }
        }
        .alert(item: $confirmation) { confirmation in
            switch confirmation {
            case let .replace(url):
                Alert(
                    title: Text("Заменить файл?"),
                    message: Text(url.lastPathComponent),
                    primaryButton: .cancel(Text("Отмена")),
                    secondaryButton: .destructive(Text("Заменить")) {
                        Task { await store.upload(url, overwrite: true) }
                    }
                )
            case let .delete(file):
                Alert(
                    title: Text("Удалить файл?"),
                    message: Text(file.name),
                    primaryButton: .cancel(Text("Отмена")),
                    secondaryButton: .destructive(Text("Удалить")) {
                        Task { await store.delete(file) }
                    }
                )
            }
        }
    }

    @ViewBuilder
    private var uploadSection: some View {
        if let progress = store.uploadProgress {
            Section("Загрузка") {
                ProgressView(value: progress)
                Text(progress.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AppTheme.mutedTint)
            }
        }
    }

    private var filesSection: some View {
        Section {
            if store.isLoading, store.files.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if let error = store.loadError, store.files.isEmpty {
                ContentUnavailableView(
                    "Не удалось загрузить файлы",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else if store.files.isEmpty {
                ContentUnavailableView(
                    store.selectedArea == .wikiSnapshots ? "Снимков нет" : "Файлов нет",
                    systemImage: store.selectedArea.systemImage,
                    description: Text(emptyMessage)
                )
            } else if visibleFiles.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                ForEach(visibleFiles) { file in
                    if file.isSnapshot {
                        snapshotRow(file)
                    } else {
                        fileRow(file)
                    }
                }
            }
        } header: {
            Text(store.files.isEmpty ? "Содержимое" : "Содержимое · \(store.files.count)")
        } footer: {
            Text(store.selectedArea == .wikiSnapshots
                 ? "Снимки создаются и переключаются сервисом Wiki. Здесь доступен просмотр списка."
                 : store.selectedArea.subtitle)
        }
    }

    private var visibleFiles: [AdminEngineerRemoteFile] {
        guard !searchText.isEmpty else { return store.files }
        return store.files.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var emptyMessage: String {
        if store.selectedArea == .wikiSnapshots { return "Сервис Wiki пока не создал снимков." }
        return store.canManage ? "Загрузите первый файл в этот раздел." : "В этом разделе пока нет файлов."
    }

    private func snapshotRow(_ file: AdminEngineerRemoteFile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.title3)
                .foregroundStyle(AppTheme.primaryTint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(snapshotDate(for: file.name))
                    .font(.subheadline.weight(.semibold))
                Text(file.name)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AppTheme.mutedTint)
            }

            Spacer(minLength: 4)
            if file.isActive == true {
                Text("Активный")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.green.opacity(0.12), in: Capsule())
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func fileRow(_ file: AdminEngineerRemoteFile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: file.name == "source.json" ? "doc.badge.gearshape" : "doc.fill")
                .foregroundStyle(AppTheme.primaryTint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName(for: file))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(metadata(for: file))
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedTint)
            }
            Spacer(minLength: 4)
            if store.busyFileID == file.id {
                ProgressView()
            } else {
                Menu {
                    if file.name == "source.json" {
                        Button {
                            Task { await openSourceEditor() }
                        } label: {
                            Label("Редактировать поля", systemImage: "slider.horizontal.3")
                        }
                    }
                    Button {
                        Task { await store.download(file) }
                    } label: {
                        Label("Скачать", systemImage: "arrow.down.circle")
                    }
                    if store.canManage, file.area != .publicationMetadata {
                        Button {
                            presentedSheet = .rename(file)
                        } label: {
                            Label("Переименовать", systemImage: "pencil")
                        }
                    }
                    if store.canManage {
                        Button(role: .destructive) {
                            confirmation = .delete(file)
                        } label: {
                            Label("Удалить", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Действия с файлом \(file.name)")
            }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if store.canManage {
                Button("Удалить", role: .destructive) { confirmation = .delete(file) }
            }
        }
    }

    private func openSourceEditor() async {
        if let source = await store.loadSource() {
            presentedSheet = .source(source)
        }
    }

    private func metadata(for file: AdminEngineerRemoteFile) -> String {
        let size = ByteCountFormatter.string(fromByteCount: file.sizeBytes, countStyle: .file)
        let date = Self.dateFormatter.date(from: file.uploadedAt)?.formatted(date: .abbreviated, time: .shortened)
            ?? file.uploadedAt
        return "\(size) • \(date)"
    }

    private func displayName(for file: AdminEngineerRemoteFile) -> String {
        guard file.area == .engineerReleases,
              file.name.hasPrefix("LumaWork-"),
              file.name.lowercased().hasSuffix(".ipa") else { return file.name }
        let stem = file.name.dropFirst("LumaWork-".count).dropLast(".ipa".count)
        guard let divider = stem.lastIndex(of: "-") else { return file.name }
        let version = stem[..<divider]
        let build = stem[stem.index(after: divider)...]
        guard !version.isEmpty, !build.isEmpty else { return file.name }
        return "Версия \(version) · сборка \(build)"
    }

    private func snapshotDate(for name: String) -> String {
        Self.snapshotFormatter.date(from: name)?
            .formatted(date: .abbreviated, time: .shortened) ?? name
    }

    private static let snapshotFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private struct AdminEngineerRenameFileSheet: View {
    @Environment(\.dismiss) private var dismiss
    let file: AdminEngineerRemoteFile
    let onRename: (String) async -> Bool
    @State private var name: String
    @State private var isSaving = false

    init(file: AdminEngineerRemoteFile, onRename: @escaping (String) async -> Bool) {
        self.file = file
        self.onRename = onRename
        _name = State(initialValue: file.name)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Имя файла", text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !file.area.allows(fileName: name) {
                    Text("Имя не соответствует правилам выбранного раздела.")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.dangerTint)
                }
            }
            .navigationTitle("Переименовать")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Сохранение" : "Сохранить") {
                        Task {
                            isSaving = true
                            if await onRename(name) { dismiss() }
                            isSaving = false
                        }
                    }
                    .disabled(isSaving || name == file.name || !file.area.allows(fileName: name))
                }
            }
        }
    }
}

private struct AdminEngineerSourceEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var source: AdminEngineerSource
    @State private var isSaving = false
    let canManage: Bool
    let onSave: (AdminEngineerSource) async -> Bool

    init(
        source: AdminEngineerSource,
        canManage: Bool,
        onSave: @escaping (AdminEngineerSource) async -> Bool
    ) {
        _source = State(initialValue: source)
        self.canManage = canManage
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Источник") {
                    TextField("Название", text: $source.name)
                        .disabled(!canManage)
                    TextField("Подзаголовок", text: $source.subtitle, axis: .vertical)
                        .disabled(!canManage)
                    TextField("Описание", text: $source.description, axis: .vertical)
                        .lineLimit(3 ... 8)
                        .disabled(!canManage)
                    TextField("URL иконки", text: $source.iconURL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(!canManage)
                    TextField("Сайт", text: $source.website)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(!canManage)
                }

                Section("Приложения") {
                    ForEach($source.apps) { $app in
                        NavigationLink {
                            AdminEngineerSourceAppEditor(app: $app, canManage: canManage)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name.isEmpty ? "Без названия" : app.name)
                                Text("\(app.bundleIdentifier) • версий: \(app.versions.count)")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.mutedTint)
                            }
                        }
                    }
                    .onDelete { if canManage { source.apps.remove(atOffsets: $0) } }
                    .onMove { if canManage { source.apps.move(fromOffsets: $0, toOffset: $1) } }

                    if canManage {
                        Button {
                            source.apps.append(.empty)
                        } label: {
                            Label("Добавить приложение", systemImage: "plus")
                        }
                    }
                }

                Section("Новости") {
                    ForEach($source.news) { $item in
                        NavigationLink {
                            AdminEngineerSourceNewsEditor(item: $item, canManage: canManage)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title.isEmpty ? "Без заголовка" : item.title)
                                Text(item.identifier)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(AppTheme.mutedTint)
                            }
                        }
                    }
                    .onDelete { if canManage { source.news.remove(atOffsets: $0) } }
                    .onMove { if canManage { source.news.move(fromOffsets: $0, toOffset: $1) } }

                    if canManage {
                        Button {
                            source.news.append(.empty)
                        } label: {
                            Label("Добавить новость", systemImage: "plus")
                        }
                    }
                }

                if let validationMessage = source.validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(AppTheme.dangerTint)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.background)
            .navigationTitle("source.json")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
                if canManage {
                    ToolbarItemGroup(placement: .confirmationAction) {
                        EditButton()
                        Button(isSaving ? "Сохранение" : "Сохранить") {
                            Task {
                                isSaving = true
                                if await onSave(source) { dismiss() }
                                isSaving = false
                            }
                        }
                        .disabled(isSaving || source.validationMessage != nil)
                    }
                }
            }
        }
    }
}

private struct AdminEngineerSourceAppEditor: View {
    @Binding var app: AdminEngineerSourceApp
    let canManage: Bool

    var body: some View {
        Form {
            Section("Приложение") {
                TextField("Название", text: $app.name).disabled(!canManage)
                TextField("Bundle ID", text: $app.bundleIdentifier)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(!canManage)
                TextField("Разработчик", text: $app.developerName).disabled(!canManage)
                TextField("Подзаголовок", text: $app.subtitle, axis: .vertical).disabled(!canManage)
                TextField("Описание", text: $app.localizedDescription, axis: .vertical)
                    .lineLimit(3 ... 10)
                    .disabled(!canManage)
                TextField("URL иконки", text: $app.iconURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(!canManage)
                TextField("Цвет", text: $app.tintColor)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(!canManage)
                TextField("Категория", text: $app.category)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(!canManage)
            }

            Section("Версии") {
                ForEach($app.versions) { $version in
                    NavigationLink {
                        AdminEngineerSourceVersionEditor(version: $version, canManage: canManage)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(version.version.isEmpty ? "Новая версия" : version.version)
                            Text("Сборка \(version.buildVersion.isEmpty ? "—" : version.buildVersion) • \(version.formattedSize)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(AppTheme.mutedTint)
                        }
                    }
                }
                .onDelete { if canManage { app.versions.remove(atOffsets: $0) } }
                .onMove { if canManage { app.versions.move(fromOffsets: $0, toOffset: $1) } }

                if canManage {
                    Button {
                        app.versions.insert(.empty, at: 0)
                    } label: {
                        Label("Добавить версию", systemImage: "plus")
                    }
                }
            }

            Section("Разрешения") {
                NavigationLink {
                    AdminEngineerEntitlementsEditor(entitlements: $app.appPermissions.entitlements, canManage: canManage)
                } label: {
                    LabeledContent("Entitlements", value: "\(app.appPermissions.entitlements.count)")
                }
                NavigationLink {
                    AdminEngineerPrivacyEditor(privacy: $app.appPermissions.privacy, canManage: canManage)
                } label: {
                    LabeledContent("Privacy", value: "\(app.appPermissions.privacy.count)")
                }
            }
        }
        .navigationTitle(app.name.isEmpty ? "Приложение" : app.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if canManage { EditButton() } }
    }
}

private struct AdminEngineerSourceVersionEditor: View {
    @Binding var version: AdminEngineerSourceVersion
    let canManage: Bool

    var body: some View {
        Form {
            Section("Сборка") {
                TextField("Версия", text: $version.version)
                    .textInputAutocapitalization(.never)
                    .disabled(!canManage)
                TextField("Номер сборки", text: $version.buildVersion)
                    .keyboardType(.numberPad)
                    .disabled(!canManage)
                TextField("Дата ISO 8601", text: $version.date)
                    .textInputAutocapitalization(.never)
                    .disabled(!canManage)
                TextField("Минимальная iOS", text: $version.minOSVersion)
                    .textInputAutocapitalization(.never)
                    .disabled(!canManage)
                TextField("Размер, байт", value: $version.size, format: .number)
                    .keyboardType(.numberPad)
                    .disabled(!canManage)
            }
            Section("Публикация") {
                TextField("URL IPA", text: $version.downloadURL, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(!canManage)
                TextField("Описание изменений", text: $version.localizedDescription, axis: .vertical)
                    .lineLimit(3 ... 12)
                    .disabled(!canManage)
            }
        }
        .navigationTitle(version.version.isEmpty ? "Новая версия" : version.version)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AdminEngineerEntitlementsEditor: View {
    @Binding var entitlements: [String]
    let canManage: Bool

    var body: some View {
        Form {
            Section {
                ForEach(entitlements.indices, id: \.self) { index in
                    TextField("Entitlement", text: $entitlements[index])
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(!canManage)
                }
                .onDelete { if canManage { entitlements.remove(atOffsets: $0) } }
                .onMove { if canManage { entitlements.move(fromOffsets: $0, toOffset: $1) } }
                if canManage {
                    Button {
                        entitlements.append("")
                    } label: {
                        Label("Добавить entitlement", systemImage: "plus")
                    }
                }
            }
        }
        .navigationTitle("Entitlements")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if canManage { EditButton() } }
    }
}

private struct AdminEngineerPrivacyEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding private var privacy: [String: String]
    @State private var entries: [AdminEngineerSourcePrivacyEntry]
    let canManage: Bool

    init(privacy: Binding<[String: String]>, canManage: Bool) {
        _privacy = privacy
        _entries = State(initialValue: privacy.wrappedValue
            .map { AdminEngineerSourcePrivacyEntry(key: $0.key, value: $0.value) }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending })
        self.canManage = canManage
    }

    private var validationMessage: String? {
        if entries.contains(where: { $0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "Укажите ключ Privacy."
        }
        if entries.contains(where: { $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "Укажите описание использования."
        }
        let keys = entries.map { $0.key.trimmingCharacters(in: .whitespacesAndNewlines) }
        if Set(keys).count != keys.count { return "Ключи Privacy не должны повторяться." }
        return nil
    }

    var body: some View {
        Form {
            ForEach($entries) { $entry in
                Section {
                    TextField("Ключ", text: $entry.key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(!canManage)
                    TextField("Описание", text: $entry.value, axis: .vertical)
                        .lineLimit(2 ... 8)
                        .disabled(!canManage)
                }
            }
            .onDelete { if canManage { entries.remove(atOffsets: $0) } }

            if canManage {
                Section {
                    Button {
                        entries.append(AdminEngineerSourcePrivacyEntry(key: "", value: ""))
                    } label: {
                        Label("Добавить Privacy-ключ", systemImage: "plus")
                    }
                }
            }

            if let validationMessage {
                Section {
                    Text(validationMessage)
                        .font(.footnote)
                        .foregroundStyle(AppTheme.dangerTint)
                }
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canManage {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        privacy = Dictionary(uniqueKeysWithValues: entries.map {
                            ($0.key.trimmingCharacters(in: .whitespacesAndNewlines), $0.value.trimmingCharacters(in: .whitespacesAndNewlines))
                        })
                        dismiss()
                    }
                    .disabled(validationMessage != nil)
                }
            }
        }
    }
}

private struct AdminEngineerSourceNewsEditor: View {
    @Binding var item: AdminEngineerSourceNews
    let canManage: Bool

    var body: some View {
        Form {
            Section("Новость") {
                TextField("Заголовок", text: $item.title).disabled(!canManage)
                TextField("Идентификатор", text: $item.identifier)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(!canManage)
                TextField("Подпись", text: $item.caption, axis: .vertical)
                    .lineLimit(2 ... 8)
                    .disabled(!canManage)
                TextField("Дата ISO 8601", text: $item.date)
                    .textInputAutocapitalization(.never)
                    .disabled(!canManage)
                TextField("Цвет", text: $item.tintColor)
                    .textInputAutocapitalization(.never)
                    .disabled(!canManage)
                Toggle("Отправить уведомление", isOn: $item.notify)
                    .disabled(!canManage)
            }
            Section("Ссылки") {
                TextField("URL изображения", text: $item.imageURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(!canManage)
                TextField("Bundle ID приложения", text: $item.appID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(!canManage)
                TextField("URL новости", text: $item.url)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(!canManage)
            }
        }
        .navigationTitle(item.title.isEmpty ? "Новость" : item.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private extension AdminEngineerSourceVersion {
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}
