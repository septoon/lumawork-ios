import Foundation
import Observation
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct FTPDirectoryResponse: Codable {
    let path: String
    let items: [FTPItem]
}

struct FTPItem: Codable, Hashable, Identifiable {
    enum ItemType: String, Codable {
        case directory
        case file
    }

    let name: String
    let path: String
    let type: ItemType
    let size: Int64?
    let sizeText: String?
    let modifiedAt: String?

    var id: String { path }
    var isDirectory: Bool { type == .directory }
}

struct FTPAPI {
    private let origin: URL
    private let authToken: String?
    private let session: URLSession

    init(config: AppConfig, authToken: String?, session: URLSession = .shared) {
        self.origin = AppConfig.configuredURL(config.lumaWorkAPIOrigin)
        self.authToken = authToken
        self.session = session
    }

    func files(path: String) async throws -> FTPDirectoryResponse {
        let request = try authorizedRequest(path: "/api/v2/ftp/files", query: [
            URLQueryItem(name: "path", value: path)
        ])
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(FTPDirectoryResponse.self, from: data)
    }

    func downloadRequest(for item: FTPItem) throws -> URLRequest {
        try authorizedRequest(
            path: "/api/v2/ftp/download",
            query: [URLQueryItem(name: "path", value: item.path)],
            timeout: 7 * 24 * 60 * 60
        )
    }

    func folderDownloadRequest(for item: FTPItem) throws -> URLRequest {
        try authorizedRequest(
            path: "/api/v2/ftp/download-folder",
            query: [URLQueryItem(name: "path", value: item.path)],
            timeout: 7 * 24 * 60 * 60
        )
    }

    private func authorizedRequest(
        path: String,
        query: [URLQueryItem],
        timeout: TimeInterval = 60
    ) throws -> URLRequest {
        guard let authToken, !authToken.isEmpty else {
            throw AppServiceError.message("Сессия LumaWork недоступна. Войдите заново.")
        }
        var components = URLComponents(
            url: origin.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = query
        guard let url = components?.url else {
            throw AppServiceError.message("Не удалось собрать адрес FTP.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("application/octet-stream, application/zip, */*", forHTTPHeaderField: "Accept")
        if let cookies = HTTPCookieStorage.shared.cookies(for: url), !cookies.isEmpty {
            for (field, value) in HTTPCookie.requestHeaderFields(with: cookies) {
                request.setValue(value, forHTTPHeaderField: field)
            }
        }
        return request
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppServiceError.message("FTP вернул неизвестный ответ.")
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["message"] as? String) ?? ($0["error"] as? String) }
                ?? "FTP недоступен"
            throw AppServiceError.message("\(message). HTTP \(httpResponse.statusCode)")
        }
    }
}

@MainActor
@Observable
final class FTPStore {
    private let service: FTPAPI
    private let downloadManager: FTPBackgroundDownloadManager
    private let cacheKey: String
    private let favoritesKey: String
    private let ownerID: String

    private(set) var itemsByPath: [String: [FTPItem]] = [:]
    private(set) var loadingPaths: Set<String> = []
    private(set) var errorsByPath: [String: String] = [:]
    private(set) var favoritePaths: [String] = []
    var downloadError: String?

    init(
        service: FTPAPI,
        downloadManager: FTPBackgroundDownloadManager,
        cacheID: String? = nil
    ) {
        self.service = service
        self.downloadManager = downloadManager
        ownerID = cacheID ?? "anonymous"
        cacheKey = AppOfflineSnapshotStore.scopedKey("ftp-directories", userID: cacheID)
        favoritesKey = AppOfflineSnapshotStore.scopedKey("ftp-favorites", userID: cacheID)
        if let snapshot = AppOfflineSnapshotStore.load(
            [String: [FTPItem]].self,
            key: cacheKey
        ) {
            itemsByPath = snapshot.value
        }
        favoritePaths = AppOfflineSnapshotStore.load([String].self, key: favoritesKey)?.value ?? []
    }

    func isFavorite(_ path: String) -> Bool {
        favoritePaths.contains(path)
    }

    func toggleFavorite(_ path: String) {
        guard path != "/" else { return }
        if let index = favoritePaths.firstIndex(of: path) {
            favoritePaths.remove(at: index)
        } else {
            favoritePaths.append(path)
            favoritePaths.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        AppOfflineSnapshotStore.save(favoritePaths, key: favoritesKey)
    }

    func items(at path: String) -> [FTPItem] {
        itemsByPath[path] ?? []
    }

    func load(path: String, force: Bool = false) async {
        guard force || itemsByPath[path] == nil else { return }
        guard !loadingPaths.contains(path) else { return }
        loadingPaths.insert(path)
        errorsByPath[path] = nil
        defer { loadingPaths.remove(path) }

        do {
            let response = try await service.files(path: path)
            guard !Task.isCancelled else { return }
            itemsByPath[path] = response.items
            AppOfflineSnapshotStore.save(itemsByPath, key: cacheKey)
        } catch is CancellationError {
            return
        } catch {
            errorsByPath[path] = appUserFacingErrorMessage(error)
        }
    }

    var downloadRecords: [FTPDownloadRecord] {
        downloadManager.records(ownerID: ownerID)
    }

    var savedDownloads: [FTPDownloadRecord] {
        downloadRecords.filter {
            $0.action == .download && $0.state == .completed &&
                downloadManager.downloadedFile(recordID: $0.id) != nil
        }
    }

    func activeDownload(for item: FTPItem) -> FTPDownloadRecord? {
        downloadManager.record(remotePath: item.path, ownerID: ownerID)
    }

    func downloadedFile(for item: FTPItem) -> FTPDownloadedFile? {
        downloadManager.downloadedFile(remotePath: item.path, ownerID: ownerID)
    }

    func startDownload(
        _ selection: FTPDownloadSelection,
        action: FTPDownloadAction,
        destinationDirectory: URL? = nil
    ) {
        downloadError = nil
        do {
            let request = selection.isFolderArchive
                ? try service.folderDownloadRequest(for: selection.item)
                : try service.downloadRequest(for: selection.item)
            try downloadManager.start(
                request: request,
                fileName: selection.fileName,
                remotePath: selection.item.path,
                action: action,
                destinationDirectory: destinationDirectory,
                ownerID: ownerID
            )
        } catch {
            downloadError = appUserFacingErrorMessage(error)
        }
    }

    func cancelDownload(recordID: UUID) {
        downloadManager.cancel(recordID: recordID)
    }

    func removeDownload(recordID: UUID) {
        downloadManager.remove(recordID: recordID)
    }

    func deleteSavedDownload(recordID: UUID) {
        do {
            try downloadManager.deleteSavedDownload(recordID: recordID, ownerID: ownerID)
            AppBannerCenter.shared.show("Файл удалён с устройства.", style: .success)
        } catch {
            AppBannerCenter.shared.show(
                appUserFacingErrorMessage(error, fallback: "Не удалось удалить файл.") ?? "Не удалось удалить файл.",
                style: .error
            )
        }
    }

    func consumePendingShare() -> FTPDownloadedFile? {
        downloadManager.consumePendingShare(ownerID: ownerID)
    }

    func downloadedFile(recordID: UUID) -> FTPDownloadedFile? {
        downloadManager.downloadedFile(recordID: recordID)
    }

    func filesDirectoryURL(recordID: UUID? = nil) -> URL? {
        downloadManager.filesDirectoryURL(recordID: recordID)
    }
}

struct FTPDownloadSelection: Identifiable, Hashable {
    let id = UUID()
    let item: FTPItem
    let isFolderArchive: Bool

    var fileName: String {
        isFolderArchive ? "\(item.name).zip" : item.name
    }
}

struct FTPDownloadedFile: Identifiable, Hashable {
    let recordID: UUID
    let url: URL

    var id: UUID { recordID }
}

struct FTPScreen: View {
    let store: FTPStore
    @State private var path = "/"

    var body: some View {
        FTPFolderScreen(store: store, path: $path)
    }
}

private enum FTPScreenSection: String, Hashable {
    case ftp
    case downloads
}

private enum FTPSheet: Identifiable, Hashable {
    case fileActions(FTPDownloadSelection)
    case directoryPicker(FTPDownloadSelection)
    case shareFile(FTPDownloadedFile)
    case downloads
    case files(URL)
    case preview(FTPDownloadedFile)

    var id: String {
        switch self {
        case .fileActions(let selection): "actions-\(selection.id.uuidString)"
        case .directoryPicker(let selection): "directory-\(selection.id.uuidString)"
        case .shareFile(let file): "share-\(file.id.uuidString)"
        case .downloads: "downloads"
        case .files(let url): "files-\(url.path)"
        case .preview(let file): "preview-\(file.id.uuidString)"
        }
    }
}

private struct FTPFolderScreen: View {
    let store: FTPStore
    @Binding var path: String

    @Environment(\.appIsOfflineMode) private var isOfflineMode
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedSection: FTPScreenSection = .ftp
    @State private var searchText = ""
    @State private var downloadedSearchText = ""
    @State private var presentedSheet: FTPSheet?
    @State private var savedDownloadToDelete: FTPDownloadRecord?
    @State private var isVisible = false

    private var items: [FTPItem] {
        let source = store.items(at: path)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return source }
        return source.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var title: String {
        path == "/" ? "FTP" : (path.split(separator: "/").last.map(String.init) ?? "FTP")
    }

    private var visibleSavedDownloads: [FTPDownloadRecord] {
        let query = downloadedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let downloads = store.savedDownloads
        guard !query.isEmpty else { return downloads }
        return downloads.filter { $0.fileName.localizedCaseInsensitiveContains(query) }
    }

    private var breadcrumbs: [(name: String, path: String)] {
        var result: [(name: String, path: String)] = [("FTP", "/")]
        var current = ""
        for segment in path.split(separator: "/") {
            current += "/" + String(segment)
            result.append((String(segment), current))
        }
        return result
    }

    var body: some View {
        AppScreen(fixedTopContent: {
            if selectedSection == .ftp {
                pathBar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
            }
        }) {
            if selectedSection == .ftp {
                if path == "/" {
                    if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        favoritesSection
                    }
                    AppSectionHeader(title: "Каталог")
                } else {
                    AppSectionHeader(title: title)
                }

            if let downloadError = visibleDownloadError {
                AppNoticeBanner(
                    text: downloadError,
                    tint: AppTheme.dangerTint,
                    isCritical: true,
                    style: .error
                )
            }

            if let error = store.errorsByPath[path],
                      store.items(at: path).isEmpty,
                      AppOfflineWarningPolicy.shouldDisplay(error, isOfflineMode: isOfflineMode) {
                AppNoticeBanner(
                    text: error,
                    tint: AppTheme.dangerTint,
                    isCritical: true,
                    style: .error
                )

                FTPStatusCard(icon: "folder.badge.questionmark", text: "Каталог не загружен.") {
                    Button("Повторить") {
                        Task { await store.load(path: path, force: true) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if items.isEmpty {
                FTPStatusCard(
                    icon: searchText.isEmpty ? "folder" : "magnifyingglass",
                    text: searchText.isEmpty ? "Каталог пуст." : "Ничего не найдено."
                ) { EmptyView() }
            } else {
                AppCard {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            FTPItemRow(
                                store: store,
                                item: item,
                                onOpenDirectory: { open($0) },
                                onDownloadRequest: { item, isFolderArchive in
                                    guard store.activeDownload(for: item) == nil else { return }
                                    presentedSheet = .fileActions(FTPDownloadSelection(
                                        item: item,
                                        isFolderArchive: isFolderArchive
                                    ))
                                },
                                onOpenDownload: { file in
                                    presentedSheet = .preview(file)
                                },
                                onShowDownloads: {
                                    presentedSheet = .downloads
                                }
                            )
                            if index < items.count - 1 {
                                Divider().padding(.leading, 52)
                            }
                        }
                    }
                }
            }
            } else {
                downloadedContent
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .appLoadingOverlay(
            isPresented: selectedSection == .ftp && store.loadingPaths.contains(path) && store.items(at: path).isEmpty,
            title: "Загружаем файлы"
        )
        .appNativeSearch(
            text: selectedSection == .ftp ? $searchText : $downloadedSearchText,
            prompt: selectedSection == .ftp ? "Поиск в каталоге" : "Поиск в загрузках"
        )
        .refreshable {
            if selectedSection == .ftp {
                await store.load(path: path, force: true)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Раздел FTP", selection: $selectedSection) {
                    Text("FTP").tag(FTPScreenSection.ftp)
                    Text("Загрузки").tag(FTPScreenSection.downloads)
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
                .onChange(of: selectedSection) { _, _ in
                    AppHaptics.trigger(.expandCollapse)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    presentedSheet = .downloads
                } label: {
                    FTPDownloadsToolbarIcon(records: store.downloadRecords)
                }
                .accessibilityLabel(downloadsAccessibilityLabel)
            }
        }
        .task(id: "\(selectedSection.rawValue):\(path)") {
            if selectedSection == .ftp {
                await store.load(path: path, force: true)
            }
        }
        .onChange(of: path) { _, _ in
            searchText = ""
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .fileActions(let selection):
                FTPFileActionSheet(
                    selection: selection,
                    onCopyPath: {
                        UIPasteboard.general.string = selection.item.path
                        presentedSheet = nil
                        AppBannerCenter.shared.show("Путь FTP скопирован.", style: .success)
                    },
                    onShareFile: {
                        presentedSheet = nil
                        store.startDownload(selection, action: .share)
                    },
                    onDownload: {
                        presentedSheet = nil
                        store.startDownload(selection, action: .download)
                    },
                    onChooseDirectory: {
                        replacePresentedSheet(with: .directoryPicker(selection))
                    }
                )
                .presentationDetents([.medium])
            case .directoryPicker(let selection):
                FTPDirectoryPicker(
                    onSelect: { directory in
                        presentedSheet = nil
                        store.startDownload(
                            selection,
                            action: .saveToFiles,
                            destinationDirectory: directory
                        )
                        presentPendingShareIfPossible()
                    },
                    onCancel: {
                        presentedSheet = nil
                        presentPendingShareIfPossible()
                    }
                )
                .ignoresSafeArea()
            case .shareFile(let file):
                FTPShareSheet(items: [file.url])
                    .presentationDetents([.medium, .large])
            case .downloads:
                FTPDownloadsSheet(store: store)
            case .files(let directory):
                FTPFilesLocationPicker(directoryURL: directory) {
                    presentedSheet = nil
                }
                .ignoresSafeArea()
            case .preview(let file):
                FTPFilePreviewSheet(file: file)
            }
        }
        .confirmationDialog(
            "Удалить файл с устройства?",
            isPresented: Binding(
                get: { savedDownloadToDelete != nil },
                set: { if !$0 { savedDownloadToDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: savedDownloadToDelete
        ) { record in
            Button("Удалить файл", role: .destructive) {
                store.deleteSavedDownload(recordID: record.id)
                savedDownloadToDelete = nil
            }
            Button("Отмена", role: .cancel) {}
        } message: { record in
            Text(record.fileName)
        }
        .onAppear {
            isVisible = true
            presentPendingShareIfPossible()
        }
        .onDisappear {
            isVisible = false
        }
        .onChange(of: store.downloadRecords) { _, _ in
            presentPendingShareIfPossible()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                presentPendingShareIfPossible()
            }
        }
        .onChange(of: presentedSheet) { _, sheet in
            if sheet == nil {
                presentPendingShareIfPossible()
            }
        }
        .onChange(of: store.downloadError) { _, error in
            guard let error,
                  !AppOfflineWarningPolicy.shouldDisplay(error, isOfflineMode: isOfflineMode) else {
                return
            }
            store.downloadError = nil
        }
    }

    private var visibleDownloadError: String? {
        guard let error = store.downloadError,
              AppOfflineWarningPolicy.shouldDisplay(error, isOfflineMode: isOfflineMode) else {
            return nil
        }
        return error
    }

    @ViewBuilder
    private var downloadedContent: some View {
        HStack(alignment: .top, spacing: 12) {
            AppSectionHeader(
                title: "На устройстве",
                caption: store.savedDownloads.isEmpty
                    ? "Сохранённые файлы появятся здесь"
                    : "\(store.savedDownloads.count) файлов · \(savedDownloadsSize)"
            )
            Spacer(minLength: 0)
            if let directory = store.filesDirectoryURL() {
                Button {
                    presentedSheet = .files(directory)
                } label: {
                    Image(systemName: "folder.fill")
                        .font(.subheadline)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.primaryTint)
                .accessibilityLabel("Открыть папку загрузок в Файлах")
            }
        }

        if store.savedDownloads.isEmpty {
            FTPStatusCard(
                icon: "tray.and.arrow.down.fill",
                text: "Скачанные файлы появятся здесь. Они доступны без подключения к FTP."
            ) {
                Button("Открыть FTP") {
                    selectedSection = .ftp
                }
                .buttonStyle(.borderedProminent)
            }
        } else if visibleSavedDownloads.isEmpty {
            FTPStatusCard(icon: "magnifyingglass", text: "В загрузках ничего не найдено.") {
                EmptyView()
            }
        } else {
            AppCard {
                LazyVStack(spacing: 0) {
                    ForEach(Array(visibleSavedDownloads.enumerated()), id: \.element.id) { index, record in
                        savedDownloadRow(record)
                        if index < visibleSavedDownloads.count - 1 {
                            Divider().padding(.leading, 44)
                        }
                    }
                }
            }
        }
    }

    private var savedDownloadsSize: String {
        let bytes = store.savedDownloads.reduce(Int64(0)) { $0 + max(0, $1.bytesWritten) }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func savedDownloadRow(_ record: FTPDownloadRecord) -> some View {
        HStack(spacing: 8) {
            Button {
                guard let file = store.downloadedFile(recordID: record.id) else { return }
                presentedSheet = .preview(file)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: savedDownloadIcon(for: record.fileName))
                        .font(.title3)
                        .foregroundStyle(AppTheme.primaryTint)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.fileName)
                            .font(.body.weight(.medium))
                            .foregroundStyle(AppTheme.ink)
                            .lineLimit(2)
                        Text("\(ByteCountFormatter.string(fromByteCount: max(0, record.bytesWritten), countStyle: .file)) · \(record.createdAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Открыть \(record.fileName)")

            Button(role: .destructive) {
                savedDownloadToDelete = record
            } label: {
                Image(systemName: "trash")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Удалить \(record.fileName) с устройства")
        }
        .padding(.vertical, 10)
    }

    private func savedDownloadIcon(for name: String) -> String {
        switch URL(fileURLWithPath: name).pathExtension.lowercased() {
        case "zip", "rar", "7z": "archivebox.fill"
        case "pdf": "doc.richtext.fill"
        case "jpg", "jpeg", "png", "heic": "photo.fill"
        case "xls", "xlsx", "csv": "tablecells.fill"
        default: "doc.fill"
        }
    }

    private var pathBar: some View {
        HStack(spacing: 8) {
            Button {
                open("/")
            } label: {
                Image(systemName: "house.fill")
                    .font(.subheadline)
                    .foregroundStyle(path == "/" ? AppTheme.ink : AppTheme.primaryTint)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .disabled(path == "/")
            .accessibilityLabel("В начало FTP")

            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    if path == "/" {
                        Text("Корень FTP")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.ink)
                    }
                    ForEach(breadcrumbs.indices.dropFirst(), id: \.self) { index in
                        if index > 1 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            open(breadcrumbs[index].path)
                        } label: {
                            Text(breadcrumbs[index].name)
                                .font(.caption.weight(index == breadcrumbs.count - 1 ? .semibold : .regular))
                                .foregroundStyle(index == breadcrumbs.count - 1 ? AppTheme.ink : AppTheme.primaryTint)
                        }
                        .buttonStyle(.plain)
                        .disabled(index == breadcrumbs.count - 1)
                        .accessibilityLabel("Перейти в \(breadcrumbs[index].name)")
                    }
                }
                .padding(.vertical, 5)
            }
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(.trailing)
        }
    }

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "star.fill")
                    .foregroundStyle(AppTheme.secondaryTint)
                Text("Избранное")
                    .foregroundStyle(AppTheme.ink)
                if !store.favoritePaths.isEmpty {
                    Text("\(store.favoritePaths.count)")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline.weight(.semibold))
            if store.favoritePaths.isEmpty {
                AppCard {
                    HStack(spacing: 12) {
                        Image(systemName: "folder.badge.plus")
                            .font(.title3)
                            .foregroundStyle(AppTheme.secondaryTint)
                            .frame(width: 28)
                        Text("Отмечайте папки звёздочкой для быстрого доступа.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 10) {
                        ForEach(store.favoritePaths, id: \.self) { favorite in
                            AppCard {
                                HStack {
                                    Image(systemName: "folder.fill")
                                        .foregroundStyle(AppTheme.secondaryTint)
                                    Spacer(minLength: 0)
                                    Button {
                                        store.toggleFavorite(favorite)
                                    } label: {
                                        Image(systemName: "star.fill")
                                            .foregroundStyle(AppTheme.primaryTint)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Убрать \(favorite) из избранного")
                                }
                                Button {
                                    open(favorite)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(favorite.split(separator: "/").last.map(String.init) ?? favorite)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(AppTheme.ink)
                                            .lineLimit(1)
                                        Text(favorite)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Открыть \(favorite)")
                            }
                            .frame(width: 190)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 2)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func open(_ destination: String) {
        guard destination != path else { return }
        path = destination
    }

    private func presentPendingShareIfPossible() {
        guard isVisible, scenePhase == .active, presentedSheet == nil,
              let file = store.consumePendingShare() else {
            return
        }
        presentedSheet = .shareFile(file)
    }

    private var downloadsAccessibilityLabel: String {
        let active = store.downloadRecords.filter(\.state.isActive)
        guard let first = active.first else { return "Очередь загрузок" }
        if let percent = first.progressPercent {
            return "Очередь загрузок, \(percent) процентов"
        }
        return "Идёт загрузка"
    }

    private func replacePresentedSheet(with sheet: FTPSheet) {
        presentedSheet = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard isVisible else { return }
            presentedSheet = sheet
        }
    }

}

private struct FTPItemRow: View {
    let store: FTPStore
    let item: FTPItem
    let onOpenDirectory: (String) -> Void
    let onDownloadRequest: (FTPItem, Bool) -> Void
    let onOpenDownload: (FTPDownloadedFile) -> Void
    let onShowDownloads: () -> Void

    var body: some View {
        if item.isDirectory {
            HStack(spacing: 0) {
                Button {
                    onOpenDirectory(item.path)
                } label: {
                    rowContent(trailingImage: "chevron.right")
                }
                .buttonStyle(.plain)
                Button {
                    store.toggleFavorite(item.path)
                } label: {
                    Image(systemName: store.isFavorite(item.path) ? "star.fill" : "star")
                        .font(.subheadline)
                        .foregroundStyle(store.isFavorite(item.path) ? AppTheme.primaryTint : Color.secondary)
                        .frame(width: 36, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(store.isFavorite(item.path) ? "Убрать папку из избранного" : "Добавить папку в избранное")
            }
            .contextMenu {
                Button("Скачать папку ZIP", systemImage: "archivebox") {
                    onDownloadRequest(item, true)
                }
                Button(store.isFavorite(item.path) ? "Убрать из избранного" : "Добавить в избранное",
                       systemImage: store.isFavorite(item.path) ? "star.slash" : "star") {
                    store.toggleFavorite(item.path)
                }
                Button("Скопировать путь FTP", systemImage: "doc.on.doc") {
                    copyPath()
                }
            }
            .accessibilityHint("Меню папки позволяет скачать её как ZIP")
        } else {
            Button {
                if let file = store.downloadedFile(for: item) {
                    onOpenDownload(file)
                } else if store.activeDownload(for: item) != nil {
                    onShowDownloads()
                } else {
                    onDownloadRequest(item, false)
                }
            } label: {
                rowContent(trailingImage: "arrow.down.circle")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(fileAccessibilityLabel)
            .accessibilityHint(fileAccessibilityHint)
            .contextMenu {
                Button("Действия с файлом", systemImage: "arrow.down.circle") {
                    onDownloadRequest(item, false)
                }
                Button("Скопировать путь FTP", systemImage: "doc.on.doc") {
                    copyPath()
                }
            }
        }
    }

    private func copyPath() {
        UIPasteboard.general.string = item.path
        AppBannerCenter.shared.show("Путь FTP скопирован.", style: .success)
    }

    private func rowContent(trailingImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.isDirectory ? "folder.fill" : fileIcon)
                .font(.title3)
                .foregroundStyle(item.isDirectory ? AppTheme.secondaryTint : AppTheme.primaryTint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(2)

                let details = [item.sizeText, item.modifiedAt]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if !details.isEmpty {
                    Text(details.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if let download = store.activeDownload(for: item) {
                FTPActiveDownloadIcon(record: download)
            } else if !item.isDirectory, store.downloadedFile(for: item) != nil {
                Image(systemName: "checkmark.circle.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppTheme.secondaryTint)
            } else {
                Image(systemName: trailingImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 12)
    }

    private var fileIcon: String {
        switch URL(fileURLWithPath: item.name).pathExtension.lowercased() {
        case "pdf": "doc.richtext.fill"
        case "jpg", "jpeg", "png", "gif", "heic": "photo.fill"
        case "zip", "rar", "7z": "archivebox.fill"
        case "xls", "xlsx", "csv": "tablecells.fill"
        case "doc", "docx", "rtf", "txt": "doc.text.fill"
        default: "doc.fill"
        }
    }

    private var fileAccessibilityLabel: String {
        if store.downloadedFile(for: item) != nil {
            return "Открыть \(item.name)"
        }
        if store.activeDownload(for: item) != nil {
            return "Показать загрузку \(item.name)"
        }
        return "Действия с файлом \(item.name)"
    }

    private var fileAccessibilityHint: String {
        if store.downloadedFile(for: item) != nil {
            return "Открывает предпросмотр скачанного файла"
        }
        if store.activeDownload(for: item) != nil {
            return "Открывает список загрузок"
        }
        return "Открывает скачивание и отправку файла"
    }
}

private struct FTPActiveDownloadIcon: View {
    let record: FTPDownloadRecord

    var body: some View {
        Group {
            if record.totalBytesExpected != nil {
                ProgressView(value: record.progress)
                    .progressViewStyle(.circular)
            } else {
                ProgressView()
            }
        }
        .controlSize(.small)
        .tint(AppTheme.primaryTint)
        .frame(width: 22, height: 22)
    }
}

private struct FTPDownloadsToolbarIcon: View {
    let records: [FTPDownloadRecord]

    private var activeRecord: FTPDownloadRecord? {
        records.first(where: \.state.isActive)
    }

    var body: some View {
        if let activeRecord {
            FTPActiveDownloadIcon(record: activeRecord)
        } else {
            Image(systemName: "arrow.down.circle.fill")
        }
    }
}

private struct FTPFileActionSheet: View {
    @Environment(\.dismiss) private var dismiss

    let selection: FTPDownloadSelection
    let onCopyPath: () -> Void
    let onShareFile: () -> Void
    let onDownload: () -> Void
    let onChooseDirectory: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(selection.fileName)
                        .font(.headline)
                        .foregroundStyle(AppTheme.ink)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Section {
                    actionButton("Скопировать путь FTP", systemImage: "doc.on.doc", action: onCopyPath)
                    actionButton("Поделиться файлом", systemImage: "doc.badge.arrow.up", action: onShareFile)
                }

                Section {
                    actionButton("Скачать", systemImage: "arrow.down.circle.fill", action: onDownload)
                    actionButton(
                        "Сохранить в выбранную папку",
                        systemImage: "folder.badge.plus",
                        action: onChooseDirectory
                    )
                } footer: {
                    Text("«Скачать» сохраняет файл в папку «Загрузки FTP» приложения «Инженер».")
                }
            }
            .contentMargins(.top, 4, for: .scrollContent)
            .navigationTitle("Детали")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    ModalCloseButton { dismiss() }
                }
            }
        }
    }

    private func actionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .foregroundStyle(AppTheme.ink)
    }
}

private enum FTPDownloadsSheetPresentation: Identifiable {
    case preview(FTPDownloadedFile)
    case share(FTPDownloadedFile)
    case files(URL)

    var id: String {
        switch self {
        case .preview(let file): "preview-\(file.id.uuidString)"
        case .share(let file): "share-\(file.id.uuidString)"
        case .files(let url): "files-\(url.path)"
        }
    }
}

private struct FTPDownloadsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: FTPStore

    @State private var presentation: FTPDownloadsSheetPresentation?
    @State private var savedDownloadToDelete: FTPDownloadRecord?

    var body: some View {
        NavigationStack {
            Group {
                if store.downloadRecords.isEmpty {
                    ContentUnavailableView(
                        "Нет передач",
                        systemImage: "arrow.down.circle",
                        description: Text("Активные и завершённые передачи появятся здесь.")
                    )
                } else {
                    List(store.downloadRecords) { record in
                        FTPDownloadStatusRow(
                            record: record,
                            onOpen: downloadedFile(for: record).map { file in
                                { presentation = .preview(file) }
                            },
                            onShare: downloadedFile(for: record).map { file in
                                { presentation = .share(file) }
                            },
                            onShowInFiles: filesDirectory(for: record).map { directory in
                                { presentation = .files(directory) }
                            },
                            onCancel: { store.cancelDownload(recordID: record.id) },
                            onRemove: {
                                if record.action == .download && record.state == .completed &&
                                    store.downloadedFile(recordID: record.id) != nil {
                                    savedDownloadToDelete = record
                                } else {
                                    store.removeDownload(recordID: record.id)
                                }
                            },
                            removeDeletesFile: record.action == .download &&
                                record.state == .completed &&
                                store.downloadedFile(recordID: record.id) != nil
                        )
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Передачи")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    ModalCloseButton { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if let directory = store.filesDirectoryURL() {
                        Button {
                            presentation = .files(directory)
                        } label: {
                            Image(systemName: "folder.fill")
                        }
                        .accessibilityLabel("Показать загрузки в Файлах")
                    }
                }
            }
        }
        .sheet(item: $presentation) { presentation in
            switch presentation {
            case .preview(let file):
                FTPFilePreviewSheet(file: file)
            case .share(let file):
                FTPShareSheet(items: [file.url])
                    .presentationDetents([.medium, .large])
            case .files(let directory):
                FTPFilesLocationPicker(directoryURL: directory) {
                    self.presentation = nil
                }
                .ignoresSafeArea()
            }
        }
        .confirmationDialog(
            "Удалить файл с устройства?",
            isPresented: Binding(
                get: { savedDownloadToDelete != nil },
                set: { if !$0 { savedDownloadToDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: savedDownloadToDelete
        ) { record in
            Button("Удалить файл", role: .destructive) {
                store.deleteSavedDownload(recordID: record.id)
                savedDownloadToDelete = nil
            }
            Button("Отмена", role: .cancel) {}
        } message: { record in
            Text(record.fileName)
        }
    }

    private func downloadedFile(for record: FTPDownloadRecord) -> FTPDownloadedFile? {
        store.downloadedFile(recordID: record.id)
    }

    private func filesDirectory(for record: FTPDownloadRecord) -> URL? {
        guard record.state == .completed, record.action != .share else { return nil }
        return store.filesDirectoryURL(recordID: record.id)
    }
}

private struct FTPDownloadStatusRow: View {
    let record: FTPDownloadRecord
    let onOpen: (() -> Void)?
    let onShare: (() -> Void)?
    let onShowInFiles: (() -> Void)?
    let onCancel: () -> Void
    let onRemove: () -> Void
    let removeDeletesFile: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let onOpen {
                Button(action: onOpen) {
                    statusContent
                }
                .buttonStyle(.plain)
            } else {
                statusContent
            }

            Spacer(minLength: 4)

            if record.canCancel {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Отменить загрузку")
            } else if !record.state.isActive {
                Button(action: onRemove) {
                    Image(systemName: removeDeletesFile ? "trash" : "xmark")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(removeDeletesFile ? "Удалить файл с устройства" : "Скрыть загрузку")
            }
        }
        .contextMenu {
            if let onOpen {
                Button("Открыть", systemImage: "doc.text.magnifyingglass", action: onOpen)
            }
            if let onShare {
                Button("Поделиться файлом", systemImage: "square.and.arrow.up", action: onShare)
            }
            if let onShowInFiles {
                Button("Показать в Файлах", systemImage: "folder", action: onShowInFiles)
            }
        }
    }

    private var statusContent: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: statusIcon)
                .font(.body.weight(.semibold))
                .foregroundStyle(statusTint)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 6) {
                Text(record.fileName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(record.state.title)
                    if let percent = record.progressPercent, record.state.isActive {
                        Text("\(percent)%").monospacedDigit()
                    }
                    if record.state.isActive || (record.state == .completed && record.bytesWritten > 0) {
                        Text("·")
                        Text(record.transferredSizeText)
                    }
                }
                .font(.caption)
                .foregroundStyle(record.state == .failed ? AppTheme.dangerTint : Color.secondary)

                if record.state.isActive {
                    if record.totalBytesExpected != nil {
                        ProgressView(value: record.progress)
                            .tint(AppTheme.primaryTint)
                    } else {
                        ProgressView()
                            .tint(AppTheme.primaryTint)
                    }
                }

                if let errorMessage = record.errorMessage, record.state == .failed {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(AppTheme.dangerTint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var statusIcon: String {
        switch record.state {
        case .preparing: "clock.fill"
        case .downloading: "arrow.down.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle.fill"
        }
    }

    private var statusTint: Color {
        switch record.state {
        case .preparing, .downloading: AppTheme.primaryTint
        case .completed: AppTheme.secondaryTint
        case .failed: AppTheme.dangerTint
        case .cancelled: .secondary
        }
    }
}

private struct FTPStatusCard<Accessory: View>: View {
    let icon: String
    let text: String
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        AppCard {
            VStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.largeTitle)
                    .foregroundStyle(AppTheme.primaryTint)
                Text(text)
                    .font(.body)
                    .foregroundStyle(AppTheme.ink)
                    .multilineTextAlignment(.center)
                accessory()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
        }
    }
}

private struct FTPFilePreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let file: FTPDownloadedFile

    var body: some View {
        NavigationStack {
            FTPFileQuickLook(url: file.url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(file.url.lastPathComponent)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        ModalCloseButton { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: file.url) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Поделиться файлом")
                    }
                }
        }
    }
}

private struct FTPFileQuickLook: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

private struct FTPShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct FTPFilesLocationPicker: UIViewControllerRepresentable {
    let directoryURL: URL
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)
        controller.directoryURL = directoryURL
        controller.delegate = context.coordinator
        controller.allowsMultipleSelection = false
        return controller
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {
        if controller.directoryURL != directoryURL {
            controller.directoryURL = directoryURL
        }
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onDismiss: () -> Void

        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onDismiss()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onDismiss()
        }
    }
}

private struct FTPDirectoryPicker: UIViewControllerRepresentable {
    let onSelect: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        controller.delegate = context.coordinator
        controller.allowsMultipleSelection = false
        controller.shouldShowFileExtensions = true
        return controller
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onSelect: (URL) -> Void
        private let onCancel: () -> Void

        init(onSelect: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onSelect = onSelect
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let directory = urls.first else {
                onCancel()
                return
            }
            onSelect(directory)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}
