import Foundation
import Observation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum WorkDocumentCategory: String, Codable, CaseIterable, Identifiable, Hashable {
    case employmentContract = "EMPLOYMENT_CONTRACT"
    case certificate = "CERTIFICATE"
    case regulation = "REGULATION"
    case instruction = "INSTRUCTION"
    case application = "APPLICATION"
    case qualification = "QUALIFICATION"
    case other = "OTHER"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .employmentContract: "Трудовые договоры"
        case .certificate: "Справки"
        case .regulation: "Положения"
        case .instruction: "Инструкции"
        case .application: "Заявления"
        case .qualification: "Удостоверения и обучение"
        case .other: "Прочее"
        }
    }

    var systemImage: String {
        switch self {
        case .employmentContract: "signature"
        case .certificate: "checkmark.seal"
        case .regulation: "building.columns"
        case .instruction: "list.clipboard"
        case .application: "doc.text"
        case .qualification: "graduationcap"
        case .other: "folder"
        }
    }

    static func suggested(for name: String) -> WorkDocumentCategory {
        let value = name.lowercased()
        if value.contains("труд") || value.contains("договор") { return .employmentContract }
        if value.contains("справ") || value.contains("мед") { return .certificate }
        if value.contains("положен") || value.contains("регламент") { return .regulation }
        if value.contains("инструк") { return .instruction }
        if value.contains("заявлен") { return .application }
        if value.contains("удостовер") || value.contains("обуч") || value.contains("сертифик") { return .qualification }
        return .other
    }
}

struct WorkDocument: Codable, Identifiable, Hashable {
    let id: String
    var category: WorkDocumentCategory
    var title: String
    let fileName: String
    let mimeType: String
    let sizeBytes: Int
    let createdAt: String
    let updatedAt: String
}

struct WorkDocumentSelection: Identifiable {
    let id = UUID()
    let data: Data
    let fileName: String
    let mimeType: String
    let category: WorkDocumentCategory
    let title: String

    init(data: Data, fileName: String, mimeType: String) throws {
        guard !data.isEmpty else { throw AppServiceError.message("Выбранный документ пуст.") }
        guard data.count <= 20 * 1024 * 1024 else { throw AppServiceError.message("Документ не должен превышать 20 МБ.") }
        guard Self.allowedMIMETypes.contains(mimeType) else { throw AppServiceError.message("Формат документа не поддерживается.") }
        self.data = data
        self.fileName = fileName
        self.mimeType = mimeType
        category = WorkDocumentCategory.suggested(for: fileName)
        title = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
    }

    static let allowedMIMETypes = Set([
        "application/pdf", "image/jpeg", "image/png", "image/heic", "image/heif", "image/webp",
        "application/msword", "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/vnd.ms-excel", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "application/vnd.ms-powerpoint", "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "application/rtf", "text/rtf", "text/plain"
    ])
}

@MainActor
struct WorkDocumentsAPI {
    private let config: AppConfig
    private let token: String?
    private let http = HTTPClient()

    init(config: AppConfig, token: String?) {
        self.config = config
        self.token = token
    }

    func fetch() async throws -> [WorkDocument] {
        let response = try await request("/api/v2/work-documents")
        return (dictionaryValue(response)?["documents"] as? [Any] ?? []).compactMap(document)
    }

    func upload(
        _ selection: WorkDocumentSelection,
        documentID: String,
        category: WorkDocumentCategory,
        title: String,
        progress: @MainActor (Double) -> Void
    ) async throws -> WorkDocument {
        let chunkSize = 512 * 1024
        let chunks = stride(from: 0, to: selection.data.count, by: chunkSize).map {
            selection.data.subdata(in: $0 ..< min($0 + chunkSize, selection.data.count))
        }
        let uploadID = UUID().uuidString
        var uploaded: WorkDocument?
        for (index, chunk) in chunks.enumerated() {
            let response = try await request("/api/v2/work-documents/chunk", method: "POST", body: [
                "uploadId": uploadID,
                "documentId": documentID,
                "category": category.rawValue,
                "title": title,
                "fileName": selection.fileName,
                "mimeType": selection.mimeType,
                "chunkIndex": index,
                "totalChunks": chunks.count,
                "chunkBase64": chunk.base64EncodedString()
            ])
            if let raw = dictionaryValue(response)?["document"] { uploaded = document(raw) }
            progress(Double(index + 1) / Double(chunks.count))
        }
        guard let uploaded else { throw AppServiceError.message("Сервер не подтвердил загрузку документа.") }
        return uploaded
    }

    func update(_ item: WorkDocument) async throws -> WorkDocument {
        let response = try await request("/api/v2/work-documents/\(item.id)", method: "PATCH", body: [
            "category": item.category.rawValue,
            "title": item.title
        ])
        guard let raw = dictionaryValue(response)?["document"], let item = document(raw) else {
            throw AppServiceError.message("Сервер не подтвердил изменение документа.")
        }
        return item
    }

    func data(id: String) async throws -> Data {
        guard let token, !token.isEmpty, let base = apiBaseURL else { throw AppServiceError.message("Требуется авторизация.") }
        var request = URLRequest(url: base.appendingPathComponent("api/v2/work-documents/\(id)"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200 ..< 300).contains(response.statusCode) else {
            throw AppServiceError.message("Не удалось загрузить документ.")
        }
        return data
    }

    func delete(id: String) async throws {
        _ = try await request("/api/v2/work-documents/\(id)", method: "DELETE")
    }

    private var apiBaseURL: URL? {
        AppConfig.configuredURL(config.lumaWorkAPIOrigin)
    }

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Any? {
        guard let token, !token.isEmpty, let base = apiBaseURL else { throw AppServiceError.message("Требуется авторизация.") }
        return try await http.request(
            base.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
            method: method,
            body: body,
            authToken: token
        ).json
    }

    private func document(_ raw: Any) -> WorkDocument? {
        guard let value = dictionaryValue(raw) else { return nil }
        let id = stringValue(value["id"])
        guard !id.isEmpty else { return nil }
        return WorkDocument(
            id: id,
            category: WorkDocumentCategory(rawValue: stringValue(value["category"])) ?? .other,
            title: stringValue(value["title"], default: "Документ"),
            fileName: stringValue(value["fileName"], default: "Документ"),
            mimeType: stringValue(value["mimeType"]),
            sizeBytes: intValue(value["sizeBytes"]) ?? 0,
            createdAt: stringValue(value["createdAt"]),
            updatedAt: stringValue(value["updatedAt"])
        )
    }
}

@MainActor
@Observable
final class WorkDocumentsStore {
    private let api: WorkDocumentsAPI
    private let cacheKey: String
    var documents: [WorkDocument] = []
    var isLoading = false
    var uploadProgress: Double?
    var busyDocumentID: String?

    init(config: AppConfig, token: String?, userID: String?) {
        api = WorkDocumentsAPI(config: config, token: token)
        cacheKey = AppOfflineSnapshotStore.scopedKey("work-documents", userID: userID)
        documents = AppOfflineSnapshotStore.load([WorkDocument].self, key: cacheKey)?.value ?? []
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            documents = try await api.fetch()
            persist()
        } catch is CancellationError {
            return
        } catch { show(error, fallback: "Не удалось загрузить рабочие документы.") }
    }

    func upload(_ selection: WorkDocumentSelection, replacing: WorkDocument? = nil, category: WorkDocumentCategory, title: String) async -> Bool {
        uploadProgress = 0
        defer { uploadProgress = nil }
        do {
            let item = try await api.upload(selection, documentID: replacing?.id ?? UUID().uuidString, category: category, title: title) { [weak self] in
                self?.uploadProgress = $0
            }
            documents.removeAll { $0.id == item.id }
            documents.append(item)
            sortAndPersist()
            AppBannerCenter.shared.show(replacing == nil ? "Документ прикреплён." : "Документ заменён.", style: .success)
            return true
        } catch { show(error, fallback: "Не удалось прикрепить документ."); return false }
    }

    func update(_ item: WorkDocument) async {
        busyDocumentID = item.id
        defer { busyDocumentID = nil }
        do {
            let updated = try await api.update(item)
            if let index = documents.firstIndex(where: { $0.id == item.id }) { documents[index] = updated }
            sortAndPersist()
        } catch { show(error, fallback: "Не удалось изменить документ.") }
    }

    func preparePreview(_ item: WorkDocument) async -> WorkDocumentPreviewItem? {
        busyDocumentID = item.id
        defer { busyDocumentID = nil }
        do { return try WorkDocumentPreviewItem(document: item, data: try await api.data(id: item.id)) }
        catch { show(error, fallback: "Не удалось открыть документ."); return nil }
    }

    func delete(_ item: WorkDocument) async {
        busyDocumentID = item.id
        defer { busyDocumentID = nil }
        do {
            try await api.delete(id: item.id)
            documents.removeAll { $0.id == item.id }
            persist()
            AppBannerCenter.shared.show("Документ удалён.", style: .success)
        } catch { show(error, fallback: "Не удалось удалить документ.") }
    }

    private func sortAndPersist() {
        documents.sort { ($0.category.title, $0.title) < ($1.category.title, $1.title) }
        persist()
    }

    private func persist() { AppOfflineSnapshotStore.save(documents, key: cacheKey) }

    private func show(_ error: Error, fallback: String) {
        if let message = appUserFacingErrorMessage(error, fallback: fallback) { AppBannerCenter.shared.show(message, style: .error) }
    }
}

struct WorkDocumentsScreen: View {
    private enum PresentedSheet: Identifiable {
        case upload(WorkDocumentSelection)
        case edit(WorkDocument)
        case preview(WorkDocumentPreviewItem)
        var id: String {
            switch self {
            case .upload(let item): "upload-\(item.id)"
            case .edit(let item): "edit-\(item.id)"
            case .preview(let item): "preview-\(item.id)"
            }
        }
    }

    @Bindable var store: WorkDocumentsStore
    let canManage: Bool
    @State private var presentedSheet: PresentedSheet?
    @State private var isSourceDialogPresented = false
    @State private var isPhotoPickerPresented = false
    @State private var isFileImporterPresented = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var replacement: WorkDocument?
    @State private var documentToDelete: WorkDocument?

    var body: some View {
        List {
            if store.documents.isEmpty && !store.isLoading {
                ContentUnavailableView(
                    "Документов пока нет",
                    systemImage: "doc.badge.plus",
                    description: Text(canManage ? "Добавьте договоры, справки, положения и другие рабочие файлы." : "Документы можно добавить в настройках профиля.")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(WorkDocumentCategory.allCases) { category in
                    let items = store.documents.filter { $0.category == category }
                    if !items.isEmpty {
                        Section(category.title) {
                            ForEach(items) { item in documentRow(item) }
                        }
                    }
                }
            }

            if canManage {
                Section {
                    Button {
                        replacement = nil
                        isSourceDialogPresented = true
                    } label: {
                        Label("Добавить документ", systemImage: "paperclip")
                    }
                    .disabled(store.documents.count >= 100 || store.uploadProgress != nil)
                    if let progress = store.uploadProgress { ProgressView(value: progress) }
                } footer: {
                    Text("PDF, изображения, Word, Excel, PowerPoint, RTF и TXT · до 20 МБ")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
        .navigationTitle("Документы для работы")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if store.isLoading && store.documents.isEmpty { AppLoadingView(title: "Загружаю документы") } }
        .task { await store.load() }
        .refreshable { await store.load() }
        .confirmationDialog("Добавить документ", isPresented: $isSourceDialogPresented) {
            Button("Выбрать фото", systemImage: "photo.on.rectangle") { isPhotoPickerPresented = true }
            Button("Выбрать файл", systemImage: "folder") { isFileImporterPresented = true }
            Button("Отмена", role: .cancel) { replacement = nil }
        }
        .photosPicker(isPresented: $isPhotoPickerPresented, selection: $selectedPhoto, matching: .images)
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task { await loadPhoto(item) }
        }
        .fileImporter(isPresented: $isFileImporterPresented, allowedContentTypes: Self.allowedContentTypes, allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { replacement = nil; return }
            Task { await loadFile(url) }
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .upload(let selection): WorkDocumentUploadSheet(store: store, selection: selection)
            case .edit(let item): WorkDocumentEditSheet(store: store, item: item)
            case .preview(let item): WorkDocumentPreviewSheet(item: item)
            }
        }
        .confirmationDialog("Удалить документ?", isPresented: Binding(
            get: { documentToDelete != nil },
            set: { if !$0 { documentToDelete = nil } }
        )) {
            Button("Удалить", role: .destructive) {
                guard let item = documentToDelete else { return }
                documentToDelete = nil
                Task { await store.delete(item) }
            }
            Button("Отмена", role: .cancel) {}
        }
    }

    private func documentRow(_ item: WorkDocument) -> some View {
        Button { open(item) } label: {
            HStack(spacing: 12) {
                Image(systemName: item.category.systemImage).foregroundStyle(AppTheme.primaryTint).frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).foregroundStyle(.primary)
                    Text("\(item.fileName) · \(Self.byteFormatter.string(fromByteCount: Int64(item.sizeBytes)))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if store.busyDocumentID == item.id { ProgressView().controlSize(.small) }
                else if canManage {
                    Menu {
                        Button("Открыть", systemImage: "eye") { open(item) }
                        Button("Изменить", systemImage: "pencil") { presentedSheet = .edit(item) }
                        Button("Заменить файл", systemImage: "arrow.triangle.2.circlepath") {
                            replacement = item
                            isSourceDialogPresented = true
                        }
                        Button("Удалить", systemImage: "trash", role: .destructive) { documentToDelete = item }
                    } label: { Image(systemName: "ellipsis") }
                } else {
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(store.busyDocumentID != nil)
    }

    private func open(_ item: WorkDocument) {
        Task { if let preview = await store.preparePreview(item) { presentedSheet = .preview(preview) } }
    }

    private func loadPhoto(_ item: PhotosPickerItem) async {
        defer { selectedPhoto = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw AppServiceError.message("Не удалось прочитать фото.") }
            let type = item.supportedContentTypes.first ?? .jpeg
            let mime = normalizedMIME(type.preferredMIMEType, extension: type.preferredFilenameExtension)
            let ext = type.preferredFilenameExtension ?? "jpg"
            try await accept(WorkDocumentSelection(data: data, fileName: "Документ-\(Int(Date().timeIntervalSince1970)).\(ext)", mimeType: mime))
        } catch { present(error) }
    }

    private func loadFile(_ url: URL) async {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
            if let size = values.fileSize, size > 20 * 1024 * 1024 { throw AppServiceError.message("Документ не должен превышать 20 МБ.") }
            let type = values.contentType ?? UTType(filenameExtension: url.pathExtension)
            let selection = try WorkDocumentSelection(
                data: try Data(contentsOf: url, options: .mappedIfSafe),
                fileName: url.lastPathComponent,
                mimeType: normalizedMIME(type?.preferredMIMEType, extension: url.pathExtension)
            )
            try await accept(selection)
        } catch { present(error) }
    }

    private func accept(_ selection: WorkDocumentSelection) async throws {
        if let replacement {
            self.replacement = nil
            _ = await store.upload(selection, replacing: replacement, category: replacement.category, title: replacement.title)
        } else {
            presentedSheet = .upload(selection)
        }
    }

    private func normalizedMIME(_ value: String?, extension ext: String?) -> String {
        let mime = value?.lowercased() ?? ""
        if mime == "image/jpg" { return "image/jpeg" }
        if WorkDocumentSelection.allowedMIMETypes.contains(mime) { return mime }
        switch ext?.lowercased() {
        case "pdf": return "application/pdf"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "webp": return "image/webp"
        case "doc": return "application/msword"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls": return "application/vnd.ms-excel"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "ppt": return "application/vnd.ms-powerpoint"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "rtf": return "application/rtf"
        case "txt": return "text/plain"
        default: return mime
        }
    }

    private func present(_ error: Error) {
        replacement = nil
        AppBannerCenter.shared.show(appUserFacingErrorMessage(error, fallback: "Не удалось добавить документ.") ?? "Не удалось добавить документ.", style: .error)
    }

    private static let allowedContentTypes: [UTType] = {
        let extensions = ["pdf", "jpg", "jpeg", "png", "heic", "heif", "webp", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "rtf", "txt"]
        return extensions.compactMap { UTType(filenameExtension: $0) }
    }()

    fileprivate static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter(); formatter.allowedUnits = [.useKB, .useMB]; formatter.countStyle = .file; return formatter
    }()
}

private struct WorkDocumentUploadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: WorkDocumentsStore
    let selection: WorkDocumentSelection
    @State private var category: WorkDocumentCategory
    @State private var title: String

    init(store: WorkDocumentsStore, selection: WorkDocumentSelection) {
        self.store = store; self.selection = selection
        _category = State(initialValue: selection.category); _title = State(initialValue: selection.title)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Документ") {
                    TextField("Название", text: $title)
                    Picker("Категория", selection: $category) {
                        ForEach(WorkDocumentCategory.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                    }
                    .pickerStyle(.navigationLink)
                }
                Section("Файл") {
                    LabeledContent("Название", value: selection.fileName)
                    LabeledContent("Размер", value: WorkDocumentsScreen.byteFormatter.string(fromByteCount: Int64(selection.data.count)))
                }
                if let progress = store.uploadProgress { Section("Загрузка на сервер") { ProgressView(value: progress) } }
            }
            .navigationTitle("Новый документ")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(store.uploadProgress != nil)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { ModalCloseButton { dismiss() }.disabled(store.uploadProgress != nil) }
                ToolbarItem(placement: .confirmationAction) {
                    ModalConfirmButton(action: {
                        Task { if await store.upload(selection, category: category, title: title) { dismiss() } }
                    }, isDisabled: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, isLoading: store.uploadProgress != nil, accessibilityLabel: "Прикрепить документ")
                }
            }
        }
    }
}

private struct WorkDocumentEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: WorkDocumentsStore
    @State var item: WorkDocument

    var body: some View {
        NavigationStack {
            Form {
                TextField("Название", text: $item.title)
                Picker("Категория", selection: $item.category) {
                    ForEach(WorkDocumentCategory.allCases) { Text($0.title).tag($0) }
                }
            }
            .navigationTitle("Документ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { ModalCloseButton { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { let value = item; dismiss(); Task { await store.update(value) } }
                        .disabled(item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct WorkDocumentPreviewItem: Identifiable {
    let id: String
    let document: WorkDocument
    let url: URL

    init(document: WorkDocument, data: Data) throws {
        id = document.id; self.document = document
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LumaWorkDocuments", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = document.fileName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\\", with: "-")
        url = directory.appendingPathComponent("\(document.id)-\(safeName)")
        try data.write(to: url, options: .atomic)
    }
}

private struct WorkDocumentPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: WorkDocumentPreviewItem

    var body: some View {
        NavigationStack {
            SalaryDocumentPreview(url: item.url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(item.document.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { ModalCloseButton { dismiss() } }
                    ToolbarItem(placement: .primaryAction) { ShareLink(item: item.url) { Label("Сохранить или поделиться", systemImage: "square.and.arrow.up") } }
                }
        }
    }
}
