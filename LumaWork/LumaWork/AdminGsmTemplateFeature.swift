import CryptoKit
import Foundation
import Observation
import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct AdminGsmTemplateMetadata: Codable, Equatable {
    let fileName: String
    let mimeType: String
    let sizeBytes: Int64
    let updatedAt: String
    let sha256: String

    var updatedDate: Date? {
        AdminGsmTemplateFormatters.iso8601.compactMap { $0.date(from: updatedAt) }.first
    }
}

private struct AdminGsmTemplateMetadataResponse: Decodable {
    let template: AdminGsmTemplateMetadata
}

struct AdminGsmTemplateChunkResponse: Decodable {
    let complete: Bool
    let received: Int?
    let totalChunks: Int?
    let template: AdminGsmTemplateMetadata?
    let previousSha256: String?
    let backupCreated: String?
    let validation: AdminGsmTemplateValidation?
}

struct AdminGsmTemplateValidation: Decodable {
    let generatorDryRun: Bool
}

struct AdminGsmTemplateDownloadedFile: Identifiable {
    let id = UUID()
    let url: URL
}

@MainActor
struct AdminGsmTemplateAPI {
    private let baseURL: URL
    private let http = HTTPClient()
    private let session: URLSession

    init(config: AppConfig, session: URLSession = .shared) {
        baseURL = AppConfig.configuredURL(config.lumaWorkAPIOrigin)
        self.session = session
    }

    func metadata(token: String) async throws -> AdminGsmTemplateMetadata {
        let response = try await http.request(
            url("/api/v2/admin/gsm-template"),
            authToken: token
        )
        return try decode(AdminGsmTemplateMetadataResponse.self, from: response.json).template
    }

    func download(metadata: AdminGsmTemplateMetadata, token: String) async throws -> URL {
        var request = URLRequest(url: url("/api/v2/admin/gsm-template/file"))
        request.timeoutInterval = 120
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)

        guard Self.sha256(data) == metadata.sha256.lowercased() else {
            throw AppServiceError.message("Шаблон изменился во время скачивания. Обновите карточку и повторите.")
        }

        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AdminGsmTemplates", isDirectory: true)
            .appendingPathComponent(String(metadata.sha256.prefix(16)), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(metadata.fileName)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    func uploadChunk(
        uploadID: String,
        chunkIndex: Int,
        totalChunks: Int,
        chunk: Data,
        fileName: String,
        expectedSha256: String,
        token: String
    ) async throws -> AdminGsmTemplateChunkResponse {
        let response = try await http.request(
            url("/api/v2/admin/gsm-template/chunk"),
            method: "POST",
            body: [
                "uploadId": uploadID,
                "chunkIndex": chunkIndex,
                "totalChunks": totalChunks,
                "chunkBase64": chunk.base64EncodedString(),
                "fileName": fileName,
                "expectedSha256": expectedSha256
            ],
            authToken: token
        )
        return try decode(AdminGsmTemplateChunkResponse.self, from: response.json)
    }

    func delete(metadata: AdminGsmTemplateMetadata, token: String) async throws {
        _ = try await http.request(
            url("/api/v2/admin/gsm-template"),
            method: "DELETE",
            body: ["expectedSha256": metadata.sha256],
            authToken: token
        )
    }

    nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func url(_ path: String) -> URL {
        baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from json: Any?) throws -> Value {
        guard let json else {
            throw AppServiceError.message("Сервер вернул пустой ответ.")
        }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(type, from: data)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let response = response as? HTTPURLResponse else {
            throw AppServiceError.message("Сервер вернул неизвестный ответ.")
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = payload?["message"] as? String
                ?? payload?["error"] as? String
                ?? "Не удалось скачать шаблон"
            throw AppServiceError.http(status: response.statusCode, fallback: message)
        }
    }
}

@MainActor
@Observable
final class AdminGsmTemplateStore {
    private static let chunkSize = 512 * 1024
    private static let maximumFileSize = 20 * 1024 * 1024

    private let api: AdminGsmTemplateAPI
    private let token: String?

    var metadata: AdminGsmTemplateMetadata?
    var isLoading = false
    var isDownloading = false
    var isUploading = false
    var isDeleting = false
    var uploadProgress: Double?
    var errorMessage: String?
    var notice: String?
    var previewFile: AdminGsmTemplateDownloadedFile?
    var downloadedFile: AdminGsmTemplateDownloadedFile?

    init(token: String?, api: AdminGsmTemplateAPI? = nil) {
        self.token = token
        self.api = api ?? AdminGsmTemplateAPI(config: AppConfig())
    }

    var isBusy: Bool {
        isLoading || isDownloading || isUploading || isDeleting
    }

    func loadIfNeeded() async {
        guard metadata == nil else { return }
        await refresh()
    }

    func refresh() async {
        guard !isLoading else { return }
        guard let token, !token.isEmpty else {
            errorMessage = "Требуется авторизация администратора."
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            metadata = try await api.metadata(token: token)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
        }
    }

    func preview() async {
        guard let file = await download() else { return }
        previewFile = AdminGsmTemplateDownloadedFile(url: file)
    }

    func export() async {
        guard let file = await download() else { return }
        downloadedFile = AdminGsmTemplateDownloadedFile(url: file)
    }

    func replace(from sourceURL: URL) async {
        guard !isUploading else { return }
        guard let token, !token.isEmpty else {
            errorMessage = "Требуется авторизация администратора."
            return
        }
        guard let currentMetadata = metadata else {
            errorMessage = "Сначала обновите данные текущего шаблона."
            return
        }
        guard sourceURL.pathExtension.lowercased() == "xltx" else {
            errorMessage = "Выберите шаблон Excel в формате XLTX."
            return
        }

        let didStartAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        isUploading = true
        uploadProgress = 0
        errorMessage = nil
        notice = nil
        defer {
            isUploading = false
            uploadProgress = nil
        }

        do {
            let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
            guard !data.isEmpty, data.count <= Self.maximumFileSize else {
                throw AppServiceError.message("Размер XLTX-шаблона должен быть от 1 байта до 20 МБ.")
            }
            let localSha256 = AdminGsmTemplateAPI.sha256(data)
            let totalChunks = max(1, Int(ceil(Double(data.count) / Double(Self.chunkSize))))
            let uploadID = UUID().uuidString.lowercased()
            var finalResponse: AdminGsmTemplateChunkResponse?

            for index in 0 ..< totalChunks {
                try Task.checkCancellation()
                let lowerBound = index * Self.chunkSize
                let upperBound = min(lowerBound + Self.chunkSize, data.count)
                finalResponse = try await api.uploadChunk(
                    uploadID: uploadID,
                    chunkIndex: index,
                    totalChunks: totalChunks,
                    chunk: data.subdata(in: lowerBound ..< upperBound),
                    fileName: sourceURL.lastPathComponent,
                    expectedSha256: currentMetadata.sha256,
                    token: token
                )
                uploadProgress = Double(index + 1) / Double(totalChunks)
            }

            guard let response = finalResponse,
                  response.complete,
                  let newMetadata = response.template,
                  newMetadata.sha256.lowercased() == localSha256,
                  response.validation?.generatorDryRun == true else {
                throw AppServiceError.message("Сервер не подтвердил установку и проверку нового шаблона.")
            }

            metadata = newMetadata
            previewFile = nil
            downloadedFile = nil
            let backupText = response.backupCreated.map { " Резервная копия: \($0)." } ?? ""
            notice = "Шаблон заменён и проверен генератором. Новые отчёты будут собираться из него.\(backupText)"
        } catch is CancellationError {
            return
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
        }
    }

    func delete() async {
        guard !isDeleting else { return }
        guard let token, !token.isEmpty else {
            errorMessage = "Требуется авторизация администратора."
            return
        }
        guard let metadata else {
            errorMessage = "Данные шаблона ещё не загружены."
            return
        }

        isDeleting = true
        errorMessage = nil
        notice = nil
        defer { isDeleting = false }

        do {
            try await api.delete(metadata: metadata, token: token)
            self.metadata = nil
            previewFile = nil
            downloadedFile = nil
            notice = "Шаблон ГСМ-отчёта удалён."
        } catch is CancellationError {
            return
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
        }
    }

    func report(_ error: Error) {
        errorMessage = appUserFacingErrorMessage(error)
    }

    private func download() async -> URL? {
        guard !isDownloading else { return nil }
        guard let token, !token.isEmpty else {
            errorMessage = "Требуется авторизация администратора."
            return nil
        }
        guard let metadata else {
            errorMessage = "Данные шаблона ещё не загружены."
            return nil
        }

        isDownloading = true
        errorMessage = nil
        defer { isDownloading = false }
        do {
            return try await api.download(metadata: metadata, token: token)
        } catch is CancellationError {
            return nil
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
            return nil
        }
    }
}

struct AdminGsmTemplateCard: View {
    @State private var store: AdminGsmTemplateStore
    @State private var isImporterPresented = false
    @State private var isDeletionConfirmationPresented = false
    @State private var pendingReplacementURL: URL?

    let canReplace: Bool

    init(token: String?, canReplace: Bool) {
        _store = State(initialValue: AdminGsmTemplateStore(token: token))
        self.canReplace = canReplace
    }

    var body: some View {
        AppSectionHeader(
            title: "Шаблон ГСМ-отчёта",
            caption: "Источник для формирования новых отчётов"
        )

        if let errorMessage = store.errorMessage {
            AppNoticeBanner(text: errorMessage, tint: AppTheme.dangerTint, isCritical: true)
        }
        if let notice = store.notice {
            AppNoticeBanner(text: notice, tint: AppTheme.primaryTint)
        }

        AppCard {
            if let metadata = store.metadata {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "tablecells.fill")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.green)
                        .frame(width: 46, height: 46)
                        .background(Color.green.opacity(0.12), in: Circle())

                    VStack(alignment: .leading, spacing: 4) {
                        Text(metadata.fileName)
                            .font(.headline)
                            .foregroundStyle(AppTheme.ink)
                            .lineLimit(2)
                        Text("XLTX · \(AdminGsmTemplateFormatters.bytes.string(fromByteCount: metadata.sizeBytes))")
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedTint)
                    }

                    Spacer(minLength: 8)

                    templateMenu
                }

                Divider()
                AppStatRow(
                    title: "Обновлён",
                    value: metadata.updatedDate.map(AdminGsmTemplateFormatters.date.string(from:)) ?? "—"
                )
                Divider()
                AppStatRow(title: "SHA-256", value: String(metadata.sha256.prefix(12)) + "…")

                if store.isUploading, let progress = store.uploadProgress {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Проверяю и устанавливаю")
                            Spacer()
                            Text(progress, format: .percent.precision(.fractionLength(0)))
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedTint)
                        ProgressView(value: progress)
                            .tint(AppTheme.primaryTint)
                    }
                }

            } else if store.isLoading {
                AppLoadingView(title: "Загружаю данные шаблона")
            } else {
                ContentUnavailableView(
                    "Шаблон недоступен",
                    systemImage: "doc.badge.exclamationmark",
                    description: Text("Обновите карточку, чтобы повторить запрос.")
                )
                Button("Повторить") {
                    Task { await store.refresh() }
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
            }
        }
        .task { await store.loadIfNeeded() }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.xltxTemplate],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                pendingReplacementURL = urls.first
            case .failure(let error):
                store.report(error)
            }
        }
        .confirmationDialog(
            "Заменить шаблон ГСМ?",
            isPresented: Binding(
                get: { pendingReplacementURL != nil },
                set: { if !$0 { pendingReplacementURL = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Заменить шаблон", role: .destructive) {
                guard let url = pendingReplacementURL else { return }
                pendingReplacementURL = nil
                Task { await store.replace(from: url) }
            }
            Button("Отмена", role: .cancel) {
                pendingReplacementURL = nil
            }
        } message: {
            Text("Файл будет проверен на совместимость. Текущий шаблон сохранится на сервере как резервная копия.")
        }
        .confirmationDialog(
            "Удалить шаблон ГСМ?",
            isPresented: $isDeletionConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Удалить шаблон", role: .destructive) {
                AppHaptics.trigger()
                Task { await store.delete() }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Новые ГСМ-отчёты нельзя будет создать, пока администратор не загрузит новый XLTX-шаблон.")
        }
        .sheet(item: Bindable(store).previewFile) { file in
            AdminGsmTemplatePreviewSheet(url: file.url)
        }
        .sheet(item: Bindable(store).downloadedFile) { file in
            AdminGsmTemplateShareSheet(items: [file.url])
                .presentationDetents([.medium, .large])
        }
    }

    private var templateMenu: some View {
        Menu {
            Button {
                AppHaptics.trigger()
                Task { await store.preview() }
            } label: {
                Label("Открыть", systemImage: "eye")
            }
            .disabled(store.isBusy)

            Button {
                AppHaptics.trigger(.download)
                Task { await store.export() }
            } label: {
                Label("Загрузить", systemImage: "arrow.down.circle")
            }
            .disabled(store.isBusy)

            Button {
                AppHaptics.trigger()
                isImporterPresented = true
            } label: {
                Label("Заменить", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(store.isBusy || !canReplace)

            Divider()

            Button(role: .destructive) {
                isDeletionConfirmationPresented = true
            } label: {
                Label("Удалить", systemImage: "trash")
            }
            .disabled(store.isBusy || !canReplace)
        } label: {
            Image(systemName: "ellipsis")
        }
        .appNativeIconControl(.compactFloating)
        .accessibilityLabel("Действия с шаблоном")
    }
}

private struct AdminGsmTemplatePreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL

    var body: some View {
        NavigationStack {
            AdminGsmTemplateQuickLook(url: url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Шаблон ГСМ")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        ModalCloseButton { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: url) {
                            Label("Скачать", systemImage: "square.and.arrow.down")
                        }
                    }
                }
        }
    }
}

private struct AdminGsmTemplateQuickLook: UIViewControllerRepresentable {
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

private struct AdminGsmTemplateShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private extension UTType {
    static var xltxTemplate: UTType {
        UTType(filenameExtension: "xltx") ?? .data
    }
}

private enum AdminGsmTemplateFormatters {
    static let iso8601: [ISO8601DateFormatter] = {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return [fractional, standard]
    }()

    static let bytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB]
        return formatter
    }()

    static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = AppLocale.russian
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter
    }()
}
