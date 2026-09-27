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

    func downloadURL(for selection: FTPDownloadSelection) throws -> URL {
        let request = selection.isFolderArchive
            ? try folderDownloadRequest(for: selection.item)
            : try downloadRequest(for: selection.item)
        guard let url = request.url else {
            throw AppServiceError.message("Не удалось собрать ссылку на FTP-файл.")
        }
        return url
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
    private let ownerID: String

    private(set) var itemsByPath: [String: [FTPItem]] = [:]
    private(set) var loadingPaths: Set<String> = []
    private(set) var errorsByPath: [String: String] = [:]
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
        if let snapshot = AppOfflineSnapshotStore.load(
            [String: [FTPItem]].self,
            key: cacheKey
        ) {
            itemsByPath = snapshot.value
        }
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

    func consumePendingShare() -> FTPDownloadedFile? {
        downloadManager.consumePendingShare(ownerID: ownerID)
    }

    func downloadedFile(recordID: UUID) -> FTPDownloadedFile? {
        downloadManager.downloadedFile(recordID: recordID)
    }

    func downloadLink(for selection: FTPDownloadSelection) -> URL? {
        downloadError = nil
        do {
            return try service.downloadURL(for: selection)
        } catch {
            downloadError = appUserFacingErrorMessage(error)
            return nil
        }
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

    var body: some View {
        FTPFolderScreen(store: store, path: "/", title: "FTP")
    }
}

private enum FTPSheet: Identifiable, Hashable {
    case fileActions(FTPDownloadSelection)
    case directoryPicker(FTPDownloadSelection)
    case shareLink(URL)
    case shareFile(FTPDownloadedFile)
    case downloads
    case preview(FTPDownloadedFile)

    var id: String {
        switch self {
        case .fileActions(let selection): "actions-\(selection.id.uuidString)"
        case .directoryPicker(let selection): "directory-\(selection.id.uuidString)"
        case .shareLink(let url): "link-\(url.absoluteString)"
        case .shareFile(let file): "share-\(file.id.uuidString)"
        case .downloads: "downloads"
        case .preview(let file): "preview-\(file.id.uuidString)"
        }
    }
}

private struct FTPFolderScreen: View {
    let store: FTPStore
    let path: String
    let title: String

    @Environment(\.appIsOfflineMode) private var isOfflineMode
    @Environment(\.scenePhase) private var scenePhase
    @State private var searchText = ""
    @State private var presentedSheet: FTPSheet?
    @State private var isVisible = false

    private var items: [FTPItem] {
        let source = store.items(at: path)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return source }
        return source.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        AppScreen {
            AppSectionHeader(title: title)

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
        }
        .navigationTitle(title == "FTP" ? "Файлы" : title)
        .navigationBarTitleDisplayMode(.inline)
        .appLoadingOverlay(
            isPresented: store.loadingPaths.contains(path) && store.items(at: path).isEmpty,
            title: "Загружаем файлы"
        )
        .modifier(FTPFolderSidebarButtonModifier(isNestedFolder: path != "/"))
        .appNativeSearch(text: $searchText, prompt: "Поиск в каталоге")
        .refreshable {
            await store.load(path: path, force: true)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    presentedSheet = .downloads
                } label: {
                    FTPDownloadsToolbarIcon(records: store.downloadRecords)
                }
                .accessibilityLabel(downloadsAccessibilityLabel)
            }
        }
        .task(id: path) {
            await store.load(path: path)
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .fileActions(let selection):
                FTPFileActionSheet(
                    selection: selection,
                    onShareLink: {
                        guard let url = store.downloadLink(for: selection) else {
                            presentedSheet = nil
                            return
                        }
                        replacePresentedSheet(with: .shareLink(url))
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
            case .shareLink(let url):
                FTPShareSheet(items: [url])
                    .presentationDetents([.medium, .large])
            case .shareFile(let file):
                FTPShareSheet(items: [file.url])
                    .presentationDetents([.medium, .large])
            case .downloads:
                FTPDownloadsSheet(store: store)
            case .preview(let file):
                FTPFilePreviewSheet(file: file)
            }
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

    private func presentPendingShareIfPossible() {
        guard isVisible, scenePhase == .active, presentedSheet == nil,
              let file = store.consumePendingShare() else {
            return
        }
        presentedSheet = .shareFile(file)
    }

    private var downloadsAccessibilityLabel: String {
        let active = store.downloadRecords.filter(\.state.isActive)
        guard let first = active.first else { return "Загрузки" }
        if let percent = first.progressPercent {
            return "Загрузки, \(percent) процентов"
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

private struct FTPFolderSidebarButtonModifier: ViewModifier {
    let isNestedFolder: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isNestedFolder {
            content.appSidebarBackButton()
        } else {
            content
        }
    }
}

private struct FTPItemRow: View {
    let store: FTPStore
    let item: FTPItem
    let onDownloadRequest: (FTPItem, Bool) -> Void
    let onOpenDownload: (FTPDownloadedFile) -> Void
    let onShowDownloads: () -> Void

    var body: some View {
        if item.isDirectory {
            NavigationLink {
                FTPFolderScreen(store: store, path: item.path, title: item.name)
            } label: {
                rowContent(trailingImage: "chevron.right")
            }
            .buttonStyle(.plain)
            .highPriorityGesture(
                LongPressGesture(minimumDuration: 0.6)
                    .onEnded { _ in
                        AppHaptics.trigger(.download)
                        onDownloadRequest(item, true)
                    }
            )
            .accessibilityHint("Зажмите, чтобы скачать папку целиком")
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
        }
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
    let onShareLink: () -> Void
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
                    actionButton("Поделиться ссылкой", systemImage: "link", action: onShareLink)
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

    var body: some View {
        NavigationStack {
            Group {
                if store.downloadRecords.isEmpty {
                    ContentUnavailableView(
                        "Нет загрузок",
                        systemImage: "arrow.down.circle",
                        description: Text("Скачанные и активные файлы появятся здесь.")
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
                            onRemove: { store.removeDownload(recordID: record.id) }
                        )
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Загрузки")
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
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Скрыть загрузку")
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
                    if record.bytesWritten > 0 || record.state.isActive {
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
