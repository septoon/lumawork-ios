import Foundation
import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

enum VehicleDocumentKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case osago = "OSAGO"
    case sts = "STS"
    case pts = "PTS"
    case diagnosticCard = "DIAGNOSTIC_CARD"
    case purchaseContract = "PURCHASE_CONTRACT"
    case service = "SERVICE"
    case other = "OTHER"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .osago: "ОСАГО"
        case .sts: "СТС"
        case .pts: "ПТС"
        case .diagnosticCard: "Диагностическая карта"
        case .purchaseContract: "Договор купли-продажи"
        case .service: "Сервисный документ"
        case .other: "Другой документ"
        }
    }

    var systemImage: String {
        switch self {
        case .osago: "shield"
        case .sts, .pts: "creditcard"
        case .diagnosticCard: "checkmark.seal"
        case .purchaseContract: "signature"
        case .service: "wrench.and.screwdriver"
        case .other: "doc"
        }
    }

    static func suggested(for fileName: String) -> VehicleDocumentKind {
        let normalized = fileName.lowercased()
        if normalized.contains("осаго") || normalized.contains("osago") || normalized.contains("полис") { return .osago }
        if normalized.contains("стс") || normalized.contains("sts") { return .sts }
        if normalized.contains("птс") || normalized.contains("pts") { return .pts }
        if normalized.contains("диагност") || normalized.contains("то-") { return .diagnosticCard }
        if normalized.contains("дкп") || normalized.contains("договор") { return .purchaseContract }
        if normalized.contains("сервис") || normalized.contains("заказ-наряд") { return .service }
        return .other
    }
}

struct VehicleDocument: Codable, Identifiable, Hashable {
    let id: String
    let kind: VehicleDocumentKind
    let fileName: String
    let mimeType: String
    let sizeBytes: Int
    let createdAt: String
}

struct VehicleDocumentSelection: Identifiable {
    let id: String
    let data: Data
    let fileName: String
    let mimeType: String
    let suggestedKind: VehicleDocumentKind

    init(data: Data, fileName: String, mimeType: String) throws {
        guard !data.isEmpty else {
            throw AppServiceError.message("Выбранный документ пуст.")
        }
        guard data.count <= 20 * 1024 * 1024 else {
            throw AppServiceError.message("Документ не должен превышать 20 МБ.")
        }
        guard Self.allowedMIMETypes.contains(mimeType) else {
            throw AppServiceError.message("Поддерживаются PDF, JPG, PNG, HEIC и WebP.")
        }
        id = UUID().uuidString
        self.data = data
        self.fileName = fileName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Документ"
        self.mimeType = mimeType
        suggestedKind = VehicleDocumentKind.suggested(for: fileName)
    }

    static let allowedMIMETypes = Set([
        "application/pdf", "image/jpeg", "image/png", "image/heic", "image/heif", "image/webp"
    ])
}

struct VehicleDocumentsSection: View {
    private enum PresentedSheet: Identifiable {
        case upload(VehicleDocumentSelection)
        case preview(VehicleDocumentPreviewItem)

        var id: String {
            switch self {
            case .upload(let selection): "upload-\(selection.id)"
            case .preview(let item): "preview-\(item.id)"
            }
        }
    }

    @Bindable var store: VehicleStore
    let vehicleID: String

    @State private var isSourceDialogPresented = false
    @State private var isPhotoPickerPresented = false
    @State private var isFileImporterPresented = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var presentedSheet: PresentedSheet?
    @State private var documentToDelete: VehicleDocument?
    @State private var isDeleteConfirmationPresented = false

    private var documents: [VehicleDocument] {
        store.vehicles.first(where: { $0.id == vehicleID })?.documents ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("ПРИКРЕПЛЁННЫЕ ДОКУМЕНТЫ", systemImage: "paperclip")
                    .font(.caption.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(AppTheme.mutedTint)
                Spacer()
                if !documents.isEmpty {
                    Text("\(documents.count)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppTheme.mutedTint)
                }
            }

            if documents.isEmpty {
                Text("Добавьте полис ОСАГО, сканы СТС и ПТС или другой документ автомобиля.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.mutedTint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(AppTheme.cardSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(AppTheme.border, lineWidth: 1)
                    )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(documents.enumerated()), id: \.element.id) { index, document in
                        documentRow(document)
                        if index < documents.count - 1 {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
                .background(AppTheme.cardSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(AppTheme.border, lineWidth: 1)
                )
            }

            Button {
                AppHaptics.trigger()
                isSourceDialogPresented = true
            } label: {
                Label("Добавить документ", systemImage: "paperclip")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
            }
            .buttonStyle(.bordered)
            .tint(AppTheme.primaryTint)
            .disabled(documents.count >= 20 || store.documentUploadProgress != nil)

            Text("PDF, JPG, PNG, HEIC или WebP · до 20 МБ")
                .font(.caption)
                .foregroundStyle(AppTheme.mutedTint)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .confirmationDialog("Добавить документ", isPresented: $isSourceDialogPresented) {
            Button("Выбрать фото", systemImage: "photo.on.rectangle") {
                isPhotoPickerPresented = true
            }
            Button("Выбрать файл", systemImage: "folder") {
                isFileImporterPresented = true
            }
            Button("Отмена", role: .cancel) {}
        }
        .photosPicker(
            isPresented: $isPhotoPickerPresented,
            selection: $selectedPhoto,
            matching: .images
        )
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task { await loadPhoto(item) }
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.pdf, .image],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await loadFile(url) }
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .upload(let selection):
                VehicleDocumentUploadSheet(store: store, vehicleID: vehicleID, selection: selection)
            case .preview(let item):
                VehicleDocumentPreviewSheet(item: item)
            }
        }
        .confirmationDialog(
            "Удалить документ?",
            isPresented: $isDeleteConfirmationPresented,
            presenting: documentToDelete
        ) { document in
            Button("Удалить", role: .destructive) {
                Task {
                    if await store.deleteDocument(vehicleID: vehicleID, documentID: document.id) {
                        AppBannerCenter.shared.show("Документ удалён.", style: .success)
                    }
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: { document in
            Text(document.fileName)
        }
    }

    private func documentRow(_ document: VehicleDocument) -> some View {
        HStack(spacing: 10) {
            Button {
                open(document)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: document.kind.systemImage)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(AppTheme.primaryTint)
                        .frame(width: 30)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(document.kind.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.ink)
                        Text(document.fileName)
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedTint)
                            .lineLimit(1)
                        Text(documentMetadata(document))
                            .font(.caption2)
                            .foregroundStyle(AppTheme.mutedTint.opacity(0.8))
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.loadingDocumentID != nil || store.deletingDocumentID != nil)

            if store.loadingDocumentID == document.id || store.deletingDocumentID == document.id {
                ProgressView().controlSize(.small)
            } else {
                Menu {
                    Button("Открыть", systemImage: "eye") { open(document) }
                    Button("Удалить", systemImage: "trash", role: .destructive) {
                        documentToDelete = document
                        isDeleteConfirmationPresented = true
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedTint)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Действия с документом \(document.fileName)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func open(_ document: VehicleDocument) {
        AppHaptics.trigger(.expandCollapse)
        Task {
            guard let data = await store.documentData(vehicleID: vehicleID, documentID: document.id) else { return }
            do {
                let item = try VehicleDocumentPreviewItem(document: document, data: data)
                presentedSheet = .preview(item)
            } catch {
                present(error, fallback: "Не удалось подготовить документ к просмотру.")
            }
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem) async {
        defer { selectedPhoto = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw AppServiceError.message("Не удалось прочитать выбранное фото.")
            }
            let contentType = item.supportedContentTypes.first ?? .jpeg
            let mimeType = normalizedMIMEType(contentType.preferredMIMEType, pathExtension: contentType.preferredFilenameExtension)
            let fileExtension = contentType.preferredFilenameExtension ?? extensionForMIMEType(mimeType)
            let timestamp = Self.photoNameFormatter.string(from: Date())
            let selection = try VehicleDocumentSelection(
                data: data,
                fileName: "Документ-\(timestamp).\(fileExtension)",
                mimeType: mimeType
            )
            presentedSheet = .upload(selection)
        } catch is CancellationError {
            return
        } catch {
            present(error, fallback: "Не удалось добавить фото.")
        }
    }

    private func loadFile(_ url: URL) async {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let values = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
            if let fileSize = values.fileSize, fileSize > 20 * 1024 * 1024 {
                throw AppServiceError.message("Документ не должен превышать 20 МБ.")
            }
            let type = values.contentType ?? UTType(filenameExtension: url.pathExtension)
            let mimeType = normalizedMIMEType(type?.preferredMIMEType, pathExtension: url.pathExtension)
            let selection = try VehicleDocumentSelection(
                data: try Data(contentsOf: url, options: .mappedIfSafe),
                fileName: url.lastPathComponent,
                mimeType: mimeType
            )
            presentedSheet = .upload(selection)
        } catch is CancellationError {
            return
        } catch {
            present(error, fallback: "Не удалось добавить файл.")
        }
    }

    private func present(_ error: Error, fallback: String) {
        if let message = appUserFacingErrorMessage(error, fallback: fallback) {
            AppBannerCenter.shared.show(message, style: .error)
        }
    }

    private func normalizedMIMEType(_ value: String?, pathExtension: String?) -> String {
        let mimeType = value?.lowercased() ?? ""
        if mimeType == "image/jpg" { return "image/jpeg" }
        if VehicleDocumentSelection.allowedMIMETypes.contains(mimeType) { return mimeType }
        switch pathExtension?.lowercased() {
        case "pdf": return "application/pdf"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "webp": return "image/webp"
        default: return mimeType
        }
    }

    private func extensionForMIMEType(_ mimeType: String) -> String {
        switch mimeType {
        case "application/pdf": "pdf"
        case "image/png": "png"
        case "image/heic": "heic"
        case "image/heif": "heif"
        case "image/webp": "webp"
        default: "jpg"
        }
    }

    private func documentMetadata(_ document: VehicleDocument) -> String {
        let size = Self.byteFormatter.string(fromByteCount: Int64(document.sizeBytes))
        guard let date = Self.documentDate(document.createdAt) else { return size }
        return "\(size) · \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    private static func documentDate(_ value: String) -> Date? {
        isoFormatters.lazy.compactMap { $0.date(from: value) }.first
    }

    private static let photoNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    fileprivate static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter
    }()

    private static let isoFormatters: [ISO8601DateFormatter] = {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return [fractional, standard]
    }()
}

private struct VehicleDocumentUploadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: VehicleStore
    let vehicleID: String
    let selection: VehicleDocumentSelection
    @State private var kind: VehicleDocumentKind

    init(store: VehicleStore, vehicleID: String, selection: VehicleDocumentSelection) {
        self.store = store
        self.vehicleID = vehicleID
        self.selection = selection
        _kind = State(initialValue: selection.suggestedKind)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Тип документа") {
                    Picker("Документ", selection: $kind) {
                        ForEach(VehicleDocumentKind.allCases) { kind in
                            Label(kind.title, systemImage: kind.systemImage).tag(kind)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }

                Section("Файл") {
                    LabeledContent("Название", value: selection.fileName)
                    LabeledContent(
                        "Размер",
                        value: VehicleDocumentsSection.byteFormatter.string(fromByteCount: Int64(selection.data.count))
                    )
                }

                if let progress = store.documentUploadProgress {
                    Section("Загрузка на сервер") {
                        ProgressView(value: progress)
                        Text("\(Int(progress * 100)) %")
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedTint)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.background)
            .navigationTitle("Новый документ")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(store.documentUploadProgress != nil)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    ModalCloseButton { dismiss() }
                        .disabled(store.documentUploadProgress != nil)
                }
                ToolbarItem(placement: .confirmationAction) {
                    ModalConfirmButton(
                        action: upload,
                        isLoading: store.documentUploadProgress != nil,
                        accessibilityLabel: "Прикрепить документ"
                    )
                }
            }
        }
        .appEditorSheetStyle()
    }

    private func upload() {
        Task {
            if await store.uploadDocument(vehicleID: vehicleID, selection: selection, kind: kind) {
                AppBannerCenter.shared.show("Документ прикреплён к автомобилю.", style: .success)
                dismiss()
            }
        }
    }
}

private struct VehicleDocumentPreviewItem: Identifiable {
    let id: String
    let document: VehicleDocument
    let url: URL

    init(document: VehicleDocument, data: Data) throws {
        id = document.id
        self.document = document
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumaWorkVehicleDocuments", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = document.fileName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
        url = directory.appendingPathComponent("\(document.id)-\(safeName)")
        try data.write(to: url, options: .atomic)
    }
}

private struct VehicleDocumentPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: VehicleDocumentPreviewItem

    var body: some View {
        NavigationStack {
            VehicleDocumentQuickLook(url: item.url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(item.document.kind.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        ModalCloseButton { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: item.url) {
                            Label("Поделиться", systemImage: "square.and.arrow.up")
                        }
                    }
                }
        }
        .onDisappear {
            try? FileManager.default.removeItem(at: item.url)
        }
    }
}

private struct VehicleDocumentQuickLook: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

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

        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
