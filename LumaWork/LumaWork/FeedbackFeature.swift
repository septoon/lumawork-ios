import Darwin
import Foundation
import Observation
import PhotosUI
import SwiftUI
import UIKit

enum FeedbackKind: String, CaseIterable, Codable, Identifiable {
    case error = "ERROR"
    case improvement = "IMPROVEMENT"
    case freeze = "FREEZE"
    case slowdown = "SLOWDOWN"
    case longLoading = "LONG_LOADING"
    case inconvenientInterface = "UI_INCONVENIENT"
    case inappropriateInterface = "UI_INAPPROPRIATE"
    case other = "OTHER"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .error: "Ошибка"
        case .improvement: "Предложение по улучшению"
        case .freeze: "Зависание или фриз"
        case .slowdown: "Торможение"
        case .longLoading: "Долгая загрузка"
        case .inconvenientInterface: "Неудобный интерфейс"
        case .inappropriateInterface: "Неуместный элемент интерфейса"
        case .other: "Другое"
        }
    }

    var systemImage: String {
        switch self {
        case .error: "exclamationmark.triangle.fill"
        case .improvement: "lightbulb.fill"
        case .freeze: "snowflake"
        case .slowdown: "tortoise.fill"
        case .longLoading: "hourglass"
        case .inconvenientInterface: "hand.raised.fill"
        case .inappropriateInterface: "rectangle.badge.xmark"
        case .other: "ellipsis.circle.fill"
        }
    }

    var needsReproductionSteps: Bool {
        switch self {
        case .error, .freeze, .slowdown, .longLoading:
            true
        default:
            false
        }
    }
}

enum FeedbackImpact: String, CaseIterable, Codable, Identifiable {
    case minor = "MINOR"
    case interferes = "INTERFERES"
    case blocks = "BLOCKS"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .minor: "Незначительно"
        case .interferes: "Мешает работе"
        case .blocks: "Работа невозможна"
        }
    }
}

enum FeedbackFrequency: String, CaseIterable, Codable, Identifiable {
    case once = "ONCE"
    case sometimes = "SOMETIMES"
    case always = "ALWAYS"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .once: "Один раз"
        case .sometimes: "Иногда"
        case .always: "Всегда"
        }
    }
}

enum FeedbackStatus: String, Codable, CaseIterable, Identifiable {
    case draft = "DRAFT"
    case new = "NEW"
    case inProgress = "IN_PROGRESS"
    case resolved = "RESOLVED"
    case closed = "CLOSED"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .draft: "Черновик"
        case .new: "Новое"
        case .inProgress: "В работе"
        case .resolved: "Решено"
        case .closed: "Закрыто"
        }
    }

    var tint: Color {
        switch self {
        case .draft: AppTheme.mutedTint
        case .new: AppTheme.secondaryTint
        case .inProgress: .blue
        case .resolved: .green
        case .closed: AppTheme.mutedTint
        }
    }
}

enum FeedbackPriority: String, Codable, CaseIterable, Identifiable {
    case low = "LOW"
    case normal = "NORMAL"
    case high = "HIGH"
    case critical = "CRITICAL"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .low: "Низкий"
        case .normal: "Обычный"
        case .high: "Высокий"
        case .critical: "Критический"
        }
    }
}

enum FeedbackEmailStatus: String, Codable {
    case notQueued = "NOT_QUEUED"
    case pending = "PENDING"
    case sending = "SENDING"
    case sent = "SENT"
    case failed = "FAILED"

    var title: String {
        switch self {
        case .notQueued: "Не поставлено в очередь"
        case .pending: "Ожидает отправки"
        case .sending: "Отправляется"
        case .sent: "Письмо отправлено"
        case .failed: "Письмо не отправлено"
        }
    }
}

enum FeedbackArea: String, CaseIterable, Codable, Identifiable, Hashable {
    case home
    case backpack
    case employees
    case maintenance
    case fuel
    case wiki
    case ftp
    case salary
    case requests
    case coordination
    case timeReport
    case analytics
    case users
    case sidebar
    case settings
    case authorization
    case notifications
    case other

    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "Главная"
        case .backpack: "Мой рюкзак"
        case .employees: "Сотрудники"
        case .maintenance: "Авто"
        case .fuel: "Топливо"
        case .wiki: "Вики"
        case .ftp: "Файлы"
        case .salary: "Зарплата"
        case .requests: "Заявки"
        case .coordination: "Координация"
        case .timeReport: "Трудозатраты"
        case .analytics: "Аналитика"
        case .users: "Админка"
        case .sidebar: "Боковое меню"
        case .settings: "Настройки"
        case .authorization: "Авторизация"
        case .notifications: "Уведомления"
        case .other: "Другое"
        }
    }

    static func current(_ section: AppNavigationSection) -> FeedbackArea {
        FeedbackArea(rawValue: section.rawValue) ?? .other
    }
}

struct FeedbackDeviceInfo: Codable, Hashable {
    var deviceModel: String
    var osVersion: String
    var appVersion: String
    var language: String
    var timeZone: String
    var capturedAt: String

    static var current: FeedbackDeviceInfo {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return FeedbackDeviceInfo(
            deviceModel: machineIdentifier(),
            osVersion: "iOS \(UIDevice.current.systemVersion)",
            appVersion: "\(version) (\(build))",
            language: Locale.current.localizedString(forLanguageCode: Locale.current.language.languageCode?.identifier ?? "ru") ?? "Русский",
            timeZone: TimeZone.current.identifier,
            capturedAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    private static func machineIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}

struct FeedbackAttachment: Codable, Identifiable, Hashable {
    var id: String
    var fileName: String
    var mimeType: String
    var sizeBytes: Int
    var width: Int
    var height: Int
    var createdAt: Date
}

struct FeedbackAddition: Codable, Identifiable, Hashable {
    var id: String
    var text: String
    var createdAt: Date
}

struct FeedbackMessage: Codable, Identifiable, Hashable {
    var id: String
    var number: String
    var kind: FeedbackKind
    var title: String
    var message: String
    var reproductionSteps: String?
    var expectedResult: String?
    var areaCodes: [String]
    var otherArea: String?
    var impact: FeedbackImpact
    var frequency: FeedbackFrequency
    var status: FeedbackStatus
    var priority: FeedbackPriority
    var adminNote: String?
    var reporterEmail: String
    var reporterName: String?
    var deviceInfo: FeedbackDeviceInfo?
    var resubmittedFromId: String?
    var submittedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    var resolvedAt: Date?
    var emailStatus: FeedbackEmailStatus
    var emailError: String?
    var attachments: [FeedbackAttachment]
    var additions: [FeedbackAddition]

    var areaTitles: String {
        let titles = areaCodes.compactMap { FeedbackArea(rawValue: $0)?.title }
        return (titles + [otherArea].compactMap { $0 }).joined(separator: ", ")
    }

    var resendDraft: FeedbackDraft {
        FeedbackDraft(
            clientRequestID: UUID(),
            kind: kind,
            title: title,
            message: message,
            reproductionSteps: reproductionSteps ?? "",
            expectedResult: expectedResult ?? "",
            areas: Set(areaCodes.compactMap(FeedbackArea.init(rawValue:))),
            otherArea: otherArea ?? "",
            impact: impact,
            frequency: frequency,
            resubmittedFromID: id
        )
    }
}

struct FeedbackDraft: Codable, Equatable {
    var clientRequestID = UUID()
    var kind: FeedbackKind = .error
    var title = ""
    var message = ""
    var reproductionSteps = ""
    var expectedResult = ""
    var areas: Set<FeedbackArea> = []
    var otherArea = ""
    var impact: FeedbackImpact = .minor
    var frequency: FeedbackFrequency = .once
    var resubmittedFromID: String?

    var hasContent: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || resubmittedFromID != nil
    }

    var isValid: Bool {
        validationMessage == nil
    }

    var validationMessage: String? {
        if areas.isEmpty {
            return "Выберите хотя бы один раздел приложения."
        }
        if areas.contains(.other), otherArea.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Укажите название другого раздела."
        }
        if title.trimmingCharacters(in: .whitespacesAndNewlines).count < 5 {
            return "Заголовок должен содержать не меньше 5 символов."
        }
        if message.trimmingCharacters(in: .whitespacesAndNewlines).count < 20 {
            return "Опишите сообщение подробнее — не меньше 20 символов."
        }
        return nil
    }
}

struct FeedbackSelectedImage: Identifiable {
    var id = UUID().uuidString
    var data: Data
    var image: UIImage
    var fileName: String
}

private struct FeedbackMessagesEnvelope: Decodable {
    var messages: [FeedbackMessage]
}

private struct FeedbackMessageEnvelope: Decodable {
    var message: FeedbackMessage
}

@MainActor
struct FeedbackAPI {
    private let baseURL: URL
    private let http = HTTPClient()
    private let session: URLSession

    init(config: AppConfig) {
        baseURL = AppConfig.configuredURL(config.lumaWorkAPIOrigin)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    func fetchMessages(token: String, admin: Bool = false) async throws -> [FeedbackMessage] {
        let response = try await http.request(url(admin ? "/api/v2/admin/feedback" : "/api/v2/feedback"), authToken: token)
        return try decode(FeedbackMessagesEnvelope.self, response.json).messages
    }

    func createDraft(_ draft: FeedbackDraft, device: FeedbackDeviceInfo, token: String) async throws -> FeedbackMessage {
        let deviceObject = try jsonObject(device)
        let response = try await http.request(
            url("/api/v2/feedback"),
            method: "POST",
            body: [
                "clientRequestId": draft.clientRequestID.uuidString,
                "kind": draft.kind.rawValue,
                "title": draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                "message": draft.message.trimmingCharacters(in: .whitespacesAndNewlines),
                "reproductionSteps": optionalText(draft.reproductionSteps),
                "expectedResult": optionalText(draft.expectedResult),
                "areaCodes": draft.areas.map(\.rawValue).sorted(),
                "otherArea": draft.areas.contains(.other) ? optionalText(draft.otherArea) : NSNull(),
                "impact": draft.impact.rawValue,
                "frequency": draft.frequency.rawValue,
                "deviceInfo": deviceObject,
                "resubmittedFromId": draft.resubmittedFromID ?? NSNull()
            ],
            authToken: token
        )
        return try decode(FeedbackMessageEnvelope.self, response.json).message
    }

    func upload(
        _ image: FeedbackSelectedImage,
        reportID: String,
        token: String,
        progress: (Double) -> Void
    ) async throws {
        let chunkSize = 512 * 1024
        let chunks = stride(from: 0, to: image.data.count, by: chunkSize).map { offset in
            image.data.subdata(in: offset ..< min(offset + chunkSize, image.data.count))
        }
        let uploadID = UUID().uuidString
        for (index, chunk) in chunks.enumerated() {
            _ = try await http.request(
                url("/api/v2/feedback/\(reportID)/attachments/chunk"),
                method: "POST",
                body: [
                    "uploadId": uploadID,
                    "imageId": image.id,
                    "fileName": image.fileName,
                    "chunkIndex": index,
                    "totalChunks": chunks.count,
                    "chunkBase64": chunk.base64EncodedString()
                ],
                authToken: token
            )
            progress(Double(index + 1) / Double(max(chunks.count, 1)))
        }
    }

    func submit(id: String, token: String) async throws -> FeedbackMessage {
        let response = try await http.request(
            url("/api/v2/feedback/\(id)/submit"),
            method: "POST",
            body: [:],
            authToken: token
        )
        return try decode(FeedbackMessageEnvelope.self, response.json).message
    }

    func add(text: String, to id: String, token: String) async throws -> FeedbackMessage {
        let response = try await http.request(
            url("/api/v2/feedback/\(id)/additions"),
            method: "POST",
            body: ["text": text],
            authToken: token
        )
        return try decode(FeedbackMessageEnvelope.self, response.json).message
    }

    func updateAdmin(
        id: String,
        status: FeedbackStatus,
        priority: FeedbackPriority,
        note: String,
        token: String
    ) async throws -> FeedbackMessage {
        let normalizedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let noteValue: Any = normalizedNote.isEmpty ? NSNull() : normalizedNote
        let response = try await http.request(
            url("/api/v2/admin/feedback/\(id)"),
            method: "PATCH",
            body: [
                "status": status.rawValue,
                "priority": priority.rawValue,
                "note": noteValue
            ],
            authToken: token
        )
        return try decode(FeedbackMessageEnvelope.self, response.json).message
    }

    func retryAdminEmail(id: String, token: String) async throws {
        _ = try await http.request(
            url("/api/v2/admin/feedback/\(id)/retry-email"),
            method: "POST",
            body: [:],
            authToken: token
        )
    }

    func attachmentData(
        reportID: String,
        attachmentID: String,
        token: String,
        admin: Bool = false
    ) async throws -> Data {
        let prefix = admin ? "/api/v2/admin/feedback" : "/api/v2/feedback"
        var request = URLRequest(url: url("\(prefix)/\(reportID)/attachments/\(attachmentID)"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode) else {
            throw AppServiceError.message("Не удалось загрузить снимок экрана.")
        }
        return data
    }

    private func url(_ path: String) -> URL {
        baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    private func decode<Value: Decodable>(_ type: Value.Type, _ json: Any?) throws -> Value {
        guard let json else { throw AppServiceError.message("Сервер вернул пустой ответ.") }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try feedbackJSONDecoder().decode(type, from: data)
    }

    private func jsonObject<Value: Encodable>(_ value: Value) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    private func optionalText(_ value: String) -> Any {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? NSNull() : trimmed
    }
}

@MainActor
@Observable
final class FeedbackStore {
    private let api: FeedbackAPI
    private let token: String?
    private let cacheKey: String
    private let draftKey: String

    var messages: [FeedbackMessage] = []
    var savedDraft: FeedbackDraft?
    var isLoading = false
    var isSubmitting = false
    var uploadProgress: Double?
    var errorMessage: String?
    var notice: String?

    init(config: AppConfig, token: String?, userID: String?) {
        api = FeedbackAPI(config: config)
        self.token = token
        cacheKey = AppOfflineSnapshotStore.scopedKey("feedback-messages", userID: userID)
        draftKey = AppOfflineSnapshotStore.scopedKey("feedback-draft", userID: userID)
        messages = AppOfflineSnapshotStore.load([FeedbackMessage].self, key: cacheKey)?.value ?? []
        let restored = AppOfflineSnapshotStore.load(FeedbackDraft.self, key: draftKey)?.value
        savedDraft = restored?.hasContent == true ? restored : nil
    }

    func load(showsNetworkBanner: Bool = false) async {
        guard !isLoading, let token, !token.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            messages = try await api.fetchMessages(token: token)
            persist()
            errorMessage = nil
        } catch {
            errorMessage = appUserFacingErrorMessage(error, showsNetworkBanner: showsNetworkBanner)
        }
    }

    func submit(_ draft: FeedbackDraft, images: [FeedbackSelectedImage]) async -> FeedbackMessage? {
        guard let token, !token.isEmpty else {
            errorMessage = "Требуется авторизация."
            return nil
        }
        guard draft.isValid else {
            errorMessage = "Заполните обязательные поля и выберите раздел."
            return nil
        }
        isSubmitting = true
        uploadProgress = images.isEmpty ? nil : 0
        errorMessage = nil
        notice = nil
        defer {
            isSubmitting = false
            uploadProgress = nil
        }
        do {
            let serverDraft = try await api.createDraft(draft, device: .current, token: token)
            for (imageIndex, image) in images.enumerated() {
                try await api.upload(image, reportID: serverDraft.id, token: token) { imageProgress in
                    uploadProgress = (Double(imageIndex) + imageProgress) / Double(max(images.count, 1))
                }
            }
            let message = try await api.submit(id: serverDraft.id, token: token)
            replace(message)
            clearDraft()
            notice = "Сообщение \(message.number) отправлено."
            return message
        } catch {
            saveDraft(draft)
            errorMessage = appUserFacingErrorMessage(error)
            return nil
        }
    }

    func add(_ text: String, to message: FeedbackMessage) async -> Bool {
        guard let token, !token.isEmpty else { return false }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 3 else {
            errorMessage = "Введите дополнение."
            return false
        }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            replace(try await api.add(text: normalized, to: message.id, token: token))
            notice = "Дополнение отправлено."
            return true
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
            return false
        }
    }

    func imageData(reportID: String, attachmentID: String) async -> Data? {
        guard let token, !token.isEmpty else { return nil }
        return try? await api.attachmentData(
            reportID: reportID,
            attachmentID: attachmentID,
            token: token
        )
    }

    func saveDraft(_ draft: FeedbackDraft) {
        savedDraft = draft.hasContent ? draft : nil
        AppOfflineSnapshotStore.save(draft, key: draftKey)
    }

    func clearDraft() {
        let empty = FeedbackDraft()
        savedDraft = nil
        AppOfflineSnapshotStore.save(empty, key: draftKey)
    }

    private func replace(_ message: FeedbackMessage) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.insert(message, at: 0)
        }
        messages.sort { ($0.submittedAt ?? $0.createdAt) > ($1.submittedAt ?? $1.createdAt) }
        persist()
    }

    private func persist() {
        AppOfflineSnapshotStore.save(messages, key: cacheKey)
    }
}

struct FeedbackScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: FeedbackStore
    let initialArea: FeedbackArea
    let includesAdminArea: Bool

    var body: some View {
        NavigationStack {
            AppScreen {
                if let error = store.errorMessage {
                    AppNoticeBanner(text: error, tint: AppTheme.dangerTint, isCritical: true)
                }

                NavigationLink {
                    FeedbackComposerScreen(
                        store: store,
                        initialDraft: preparedDraft,
                        includesAdminArea: includesAdminArea
                    )
                } label: {
                    AppCard {
                        HStack(spacing: 14) {
                            Image(systemName: "square.and.pencil")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(AppTheme.primaryTint)
                                .frame(width: 42, height: 42)
                                .background(AppTheme.primaryTint.opacity(0.12), in: Circle())
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Новое сообщение")
                                    .font(.headline)
                                    .foregroundStyle(AppTheme.ink)
                                Text("Ошибка, предложение или замечание по интерфейсу")
                                    .font(.subheadline)
                                    .foregroundStyle(AppTheme.mutedTint)
                            }
                            Spacer(minLength: 6)
                            Image(systemName: "chevron.forward")
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain)

                AppSectionHeader(
                    title: "Мои сообщения",
                    caption: store.messages.isEmpty ? nil : "Всего: \(store.messages.count)"
                )

                if store.isLoading && store.messages.isEmpty {
                    AppLoadingView(title: "Загружаю историю")
                } else if store.messages.isEmpty {
                    AppEmptyState(
                        title: "Сообщений пока нет",
                        message: "Здесь появятся ваши ошибки, предложения и дополнения.",
                        systemName: "text.bubble"
                    )
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(store.messages.enumerated()), id: \.element.id) { index, message in
                            NavigationLink {
                                FeedbackDetailScreen(
                                    messageID: message.id,
                                    store: store,
                                    includesAdminArea: includesAdminArea
                                )
                            } label: {
                                FeedbackMessageRow(message: message)
                            }
                            .buttonStyle(.plain)
                            if index < store.messages.count - 1 {
                                Divider().padding(.leading, 62)
                            }
                        }
                    }
                    .background(AppTheme.cardSurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
                }
            }
            .navigationTitle("Обратная связь")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ModalCloseButton(action: dismiss.callAsFunction)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await store.load(showsNetworkBanner: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(store.isLoading)
                    .accessibilityLabel("Обновить сообщения")
                }
            }
            .refreshable { await store.load(showsNetworkBanner: true) }
            .task { await store.load() }
        }
        .tint(AppTheme.primaryTint)
        .task(id: store.notice) {
            guard let notice = store.notice else { return }
            AppBannerCenter.shared.show(notice, style: .success)
            await appDismissTransientMessage(
                notice,
                delayNanoseconds: 2_500_000_000
            ) { value in
                if store.notice == value {
                    store.notice = nil
                }
            }
        }
        .onDisappear {
            store.notice = nil
        }
    }

    private var preparedDraft: FeedbackDraft {
        if var draft = store.savedDraft {
            if !includesAdminArea { draft.areas.remove(.users) }
            return draft
        }
        var draft = FeedbackDraft()
        draft.areas = [initialArea]
        if !includesAdminArea { draft.areas.remove(.users) }
        return draft
    }
}

private struct FeedbackMessageRow: View {
    let message: FeedbackMessage

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: message.kind.systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(message.status.tint)
                .frame(width: 38, height: 38)
                .background(message.status.tint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(message.number)
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(AppTheme.mutedTint)
                    Text(message.status.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(message.status.tint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(message.status.tint.opacity(0.12), in: Capsule())
                }
                Text(message.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(2)
                Text("\(message.kind.title) • \(feedbackShortDate(message.submittedAt ?? message.createdAt))")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedTint)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.forward")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 10)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

private struct FeedbackComposerScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: FeedbackStore
    @State private var draft: FeedbackDraft
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var images: [FeedbackSelectedImage] = []
    @State private var imageError: String?
    @State private var didSubmit = false
    let includesAdminArea: Bool

    init(store: FeedbackStore, initialDraft: FeedbackDraft, includesAdminArea: Bool) {
        self.store = store
        self.includesAdminArea = includesAdminArea
        var preparedDraft = initialDraft
        if !includesAdminArea { preparedDraft.areas.remove(.users) }
        _draft = State(initialValue: preparedDraft)
    }

    var body: some View {
        Form {
            if let error = store.errorMessage ?? imageError {
                AppNoticeBanner(
                    text: error,
                    tint: AppTheme.dangerTint,
                    isCritical: true,
                    style: .error
                )
            }

            Section("Тема") {
                NavigationLink {
                    FeedbackSingleChoiceScreen(
                        navigationTitle: "Тема",
                        options: FeedbackKind.allCases,
                        selection: $draft.kind,
                        optionTitle: { $0.title },
                        optionSystemImage: { $0.systemImage }
                    )
                } label: {
                    FeedbackThemeSelectionLabel(kind: draft.kind)
                }
            }

            Section("Разделы приложения") {
                NavigationLink {
                    FeedbackAreasPicker(
                        selection: $draft.areas,
                        includesAdmin: includesAdminArea
                    )
                } label: {
                    LabeledContent("Выбрано", value: draft.areas.isEmpty ? "Не выбрано" : draft.areas.sorted(by: { $0.title < $1.title }).map(\.title).joined(separator: ", "))
                }
                if draft.areas.contains(.other) {
                    TextField("Укажите раздел", text: $draft.otherArea)
                }
            }

            Section("Сообщение") {
                TextField("Короткий заголовок", text: $draft.title)
                TextField("Опишите, что произошло или что можно улучшить", text: $draft.message, axis: .vertical)
                    .lineLimit(4 ... 10)
                if draft.kind.needsReproductionSteps {
                    TextField("Условие, при котором возникает проблема", text: $draft.reproductionSteps, axis: .vertical)
                        .lineLimit(3 ... 8)
                }
                TextField("Как должно работать", text: $draft.expectedResult, axis: .vertical)
                    .lineLimit(3 ... 8)
            }

            Section("Влияние") {
                NavigationLink {
                    FeedbackSingleChoiceScreen(
                        navigationTitle: "Насколько мешает",
                        options: FeedbackImpact.allCases,
                        selection: $draft.impact,
                        optionTitle: { $0.title }
                    )
                } label: {
                    LabeledContent("Насколько мешает", value: draft.impact.title)
                }
                NavigationLink {
                    FeedbackSingleChoiceScreen(
                        navigationTitle: "Как часто возникает",
                        options: FeedbackFrequency.allCases,
                        selection: $draft.frequency,
                        optionTitle: { $0.title }
                    )
                } label: {
                    LabeledContent("Как часто возникает", value: draft.frequency.title)
                }
            }

            Section("Снимки экрана") {
                if !images.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(images) { item in
                                ZStack(alignment: .topTrailing) {
                                    Image(uiImage: item.image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 108, height: 108)
                                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    Button {
                                        images.removeAll { $0.id == item.id }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, Color.black.opacity(0.65))
                                    }
                                    .padding(5)
                                    .accessibilityLabel("Удалить снимок")
                                }
                            }
                        }
                    }
                }
                PhotosPicker(selection: $selectedItems, maxSelectionCount: max(1, 4 - images.count), matching: .images) {
                    Label(images.isEmpty ? "Добавить снимки" : "Добавить ещё", systemImage: "photo.badge.plus")
                }
                .disabled(images.count >= 4)
                Text("До четырёх изображений. Перед отправкой проверьте, что на них нет лишних персональных данных.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Данные устройства") {
                LabeledContent("Устройство", value: FeedbackDeviceInfo.current.deviceModel)
                LabeledContent("ОС", value: FeedbackDeviceInfo.current.osVersion)
                LabeledContent("Приложение", value: FeedbackDeviceInfo.current.appVersion)
                LabeledContent("Часовой пояс", value: FeedbackDeviceInfo.current.timeZone)
            }

            Section {
                Button {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil,
                        from: nil,
                        for: nil
                    )
                    if let validationMessage = draft.validationMessage {
                        store.errorMessage = validationMessage
                        AppHaptics.trigger(.error)
                        return
                    }
                    Task {
                        if await store.submit(draft, images: images) != nil {
                            didSubmit = true
                            dismiss()
                        }
                    }
                } label: {
                    HStack {
                        Spacer()
                        if store.isSubmitting {
                            ProgressView()
                                .controlSize(.small)
                            Text(progressTitle)
                        } else {
                            Label("Отправить сообщение", systemImage: "paperplane.fill")
                        }
                        Spacer()
                    }
                }
                .disabled(store.isSubmitting)
            }
        }
        .navigationTitle(draft.resubmittedFromID == nil ? "Новое сообщение" : "Отправить заново")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: selectedItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await loadImages(items) }
        }
        .onDisappear {
            if !store.isSubmitting && !didSubmit { store.saveDraft(draft) }
        }
    }

    private var progressTitle: String {
        guard let progress = store.uploadProgress else { return "Отправляем" }
        return "Загружаем \(Int(progress * 100))%"
    }

    private func loadImages(_ items: [PhotosPickerItem]) async {
        defer { selectedItems = [] }
        imageError = nil
        for item in items.prefix(max(0, 4 - images.count)) {
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data),
                      let prepared = image.feedbackJPEGData(maxDimension: 2560, compressionQuality: 0.88),
                      let preview = UIImage(data: prepared) else {
                    imageError = "Не удалось подготовить выбранное изображение."
                    continue
                }
                images.append(FeedbackSelectedImage(
                    data: prepared,
                    image: preview,
                    fileName: "снимок-\(images.count + 1).jpg"
                ))
            } catch {
                imageError = "Не удалось прочитать выбранное изображение."
            }
        }
    }
}

private struct FeedbackThemeSelectionLabel: View {
    let kind: FeedbackKind

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Что вы хотите сообщить")
                .foregroundStyle(.primary)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: kind.systemImage)
                    .foregroundStyle(AppTheme.primaryTint)
                    .frame(width: 24)
                Text(kind.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(AppTheme.primaryTint)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
    }
}

struct FeedbackSingleChoiceScreen<Value: Hashable>: View {
    @Environment(\.dismiss) private var dismiss
    let navigationTitle: String
    let options: [Value]
    @Binding var selection: Value
    let optionTitle: (Value) -> String
    let optionSystemImage: (Value) -> String?

    init(
        navigationTitle: String,
        options: [Value],
        selection: Binding<Value>,
        optionTitle: @escaping (Value) -> String,
        optionSystemImage: @escaping (Value) -> String? = { _ in nil }
    ) {
        self.navigationTitle = navigationTitle
        self.options = options
        _selection = selection
        self.optionTitle = optionTitle
        self.optionSystemImage = optionSystemImage
    }

    var body: some View {
        List {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        if let systemImage = optionSystemImage(option) {
                            Image(systemName: systemImage)
                                .foregroundStyle(AppTheme.primaryTint)
                                .frame(width: 24)
                        }
                        Text(optionTitle(option))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 12)
                        if selection == option {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(AppTheme.primaryTint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct FeedbackAreasPicker: View {
    @Binding var selection: Set<FeedbackArea>
    let includesAdmin: Bool

    var body: some View {
        List {
            ForEach(availableAreas) { area in
                Button {
                    if selection.contains(area) {
                        selection.remove(area)
                    } else {
                        selection.insert(area)
                    }
                } label: {
                    HStack {
                        Text(area.title)
                            .foregroundStyle(.primary)
                        Spacer()
                        if selection.contains(area) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(AppTheme.primaryTint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("Разделы")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var availableAreas: [FeedbackArea] {
        FeedbackArea.allCases.filter { includesAdmin || $0 != .users }
    }
}

private struct FeedbackDetailScreen: View {
    @Bindable var store: FeedbackStore
    let messageID: String
    let includesAdminArea: Bool
    @State private var supplementDestination: FeedbackSupplementDestination?

    init(messageID: String, store: FeedbackStore, includesAdminArea: Bool) {
        self.messageID = messageID
        self.store = store
        self.includesAdminArea = includesAdminArea
    }

    var body: some View {
        Group {
            if let message {
                AppScreen {
                    FeedbackReportHero(message: message)
                    FeedbackReportNarrative(message: message)

                    if !message.attachments.isEmpty {
                        FeedbackAttachmentGallery(
                            reportID: message.id,
                            attachments: message.attachments,
                            load: store.imageData
                        )
                    }

                    if !message.additions.isEmpty {
                        FeedbackAdditionsTimeline(
                            title: "Дополнения",
                            additions: message.additions
                        )
                    }

                    VStack(spacing: 10) {
                        Button {
                            supplementDestination = FeedbackSupplementDestination(message: message)
                        } label: {
                            Label("Дополнить сообщение", systemImage: "text.badge.plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(AppActionButtonStyle())
                        NavigationLink {
                            FeedbackComposerScreen(
                                store: store,
                                initialDraft: message.resendDraft,
                                includesAdminArea: includesAdminArea
                            )
                        } label: {
                            Label("Отправить заново", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(AppActionButtonStyle())
                    }
                }
                .navigationTitle(message.number)
                .navigationBarTitleDisplayMode(.inline)
            } else {
                ContentUnavailableView("Сообщение не найдено", systemImage: "text.bubble")
            }
        }
        .sheet(item: $supplementDestination) { destination in
            FeedbackSupplementSheet(store: store, message: destination.message)
                .appEditorSheetStyle()
        }
    }

    private var message: FeedbackMessage? {
        store.messages.first { $0.id == messageID }
    }
}

private struct FeedbackSupplementDestination: Identifiable {
    let message: FeedbackMessage
    var id: String { message.id }
}

private struct FeedbackSupplementSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: FeedbackStore
    let message: FeedbackMessage
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Дополнение") {
                    TextField("Что изменилось или что ещё важно знать", text: $text, axis: .vertical)
                        .lineLimit(5 ... 12)
                }
                Section {
                    Button {
                        Task {
                            if await store.add(text, to: message) { dismiss() }
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if store.isSubmitting { ProgressView().controlSize(.small) }
                            Text(store.isSubmitting ? "Отправляем" : "Отправить дополнение")
                            Spacer()
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).count < 3 || store.isSubmitting)
                }
            }
            .navigationTitle("Дополнить")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ModalCloseButton(action: dismiss.callAsFunction)
                }
            }
        }
    }
}

struct FeedbackReportHero: View {
    let message: FeedbackMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: message.kind.systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(message.status.tint)
                    .frame(width: 46, height: 46)
                    .background(message.status.tint.opacity(0.14), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(message.number)
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(AppTheme.mutedTint)
                    Text(message.kind.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(message.status.tint)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)
                FeedbackStatusPill(status: message.status)
            }

            Text(message.title)
                .font(.title2.weight(.bold))
                .foregroundStyle(AppTheme.ink)

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                spacing: 10
            ) {
                FeedbackMetadataTile(
                    title: "Разделы",
                    value: message.areaTitles,
                    systemImage: "square.grid.2x2",
                    tint: AppTheme.primaryTint
                )
                FeedbackMetadataTile(
                    title: "Отправлено",
                    value: feedbackFullDate(message.submittedAt ?? message.createdAt),
                    systemImage: "calendar",
                    tint: AppTheme.primaryTint
                )
                FeedbackMetadataTile(
                    title: "Влияние",
                    value: message.impact.title,
                    systemImage: "exclamationmark.circle",
                    tint: message.impact == .blocks ? AppTheme.dangerTint : AppTheme.secondaryTint
                )
                FeedbackMetadataTile(
                    title: "Частота",
                    value: message.frequency.title,
                    systemImage: "repeat",
                    tint: AppTheme.secondaryTint
                )
            }
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(AppTheme.performanceCardFill)
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [message.status.tint.opacity(0.16), .clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(message.status.tint.opacity(0.22), lineWidth: 1)
        )
    }
}

private struct FeedbackStatusPill: View {
    let status: FeedbackStatus

    var body: some View {
        Text(status.title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(status.tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(status.tint.opacity(0.13), in: Capsule())
    }
}

private struct FeedbackMetadataTile: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            Text(value.isEmpty ? "—" : value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.ink)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .padding(12)
        .background(AppTheme.subpanelSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct FeedbackReportNarrative: View {
    let message: FeedbackMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Подробности")
                .font(.title3.weight(.bold))
                .foregroundStyle(AppTheme.ink)

            FeedbackNarrativeRow(
                title: "Описание",
                text: message.message,
                systemImage: "text.bubble.fill",
                tint: AppTheme.primaryTint
            )
            if let steps = message.reproductionSteps, !steps.isEmpty {
                FeedbackNarrativeRow(
                    title: "Условие, при котором возникает проблема",
                    text: steps,
                    systemImage: "arrow.triangle.branch",
                    tint: AppTheme.secondaryTint
                )
            }
            if let expected = message.expectedResult, !expected.isEmpty {
                FeedbackNarrativeRow(
                    title: "Как должно работать",
                    text: expected,
                    systemImage: "checkmark.seal.fill",
                    tint: .green
                )
            }
        }
    }
}

private struct FeedbackNarrativeRow: View {
    let title: String
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.13), in: Circle())

            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                Text(text)
                    .font(.body)
                    .foregroundStyle(AppTheme.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(AppTheme.subpanelSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(tint.opacity(0.14), lineWidth: 1)
        )
    }
}

struct FeedbackAdditionsTimeline: View {
    let title: String
    let additions: [FeedbackAddition]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AppSectionHeader(title: title)
            ForEach(additions) { addition in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "plus.message.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.primaryTint)
                        .frame(width: 36, height: 36)
                        .background(AppTheme.primaryTint.opacity(0.13), in: Circle())
                    VStack(alignment: .leading, spacing: 6) {
                        Text(addition.text)
                            .foregroundStyle(AppTheme.ink)
                            .textSelection(.enabled)
                        Text(feedbackFullDate(addition.createdAt))
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedTint)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(AppTheme.subpanelSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
    }
}

struct FeedbackAttachmentGallery: View {
    let reportID: String
    let attachments: [FeedbackAttachment]
    let load: (String, String) async -> Data?
    @State private var viewerPayload: FeedbackImageViewerPayload?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AppSectionHeader(
                title: "Снимки экрана",
                caption: "\(attachments.count)"
            )
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(attachments) { attachment in
                        FeedbackRemoteImage(
                            reportID: reportID,
                            attachment: attachment,
                            load: load
                        ) { image, data in
                            viewerPayload = FeedbackImageViewerPayload(
                                attachment: attachment,
                                image: image,
                                data: data
                            )
                        }
                    }
                }
            }
            .contentMargins(.horizontal, 0, for: .scrollContent)
            .padding(.leading, -8)
            .padding(.trailing, -16)
        }
        .fullScreenCover(item: $viewerPayload) { payload in
            FeedbackImageViewer(payload: payload)
        }
    }
}

private struct FeedbackRemoteImage: View {
    let reportID: String
    let attachment: FeedbackAttachment
    let load: (String, String) async -> Data?
    let onOpen: (UIImage, Data) -> Void
    @State private var image: UIImage?
    @State private var imageData: Data?

    private var previewSize: CGSize {
        let sourceSize = image?.size ?? CGSize(
            width: CGFloat(max(attachment.width, 1)),
            height: CGFloat(max(attachment.height, 1))
        )
        let aspectRatio = sourceSize.width / sourceSize.height
        let maximumLength: CGFloat = 300

        if aspectRatio <= 1 {
            return CGSize(
                width: max(maximumLength * aspectRatio, 100),
                height: maximumLength
            )
        }
        return CGSize(
            width: maximumLength,
            height: max(maximumLength / aspectRatio, 100)
        )
    }

    var body: some View {
        Button {
            guard let image, let imageData else { return }
            onOpen(image, imageData)
        } label: {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(AppTheme.softFill.opacity(0.55))
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: previewSize.width, height: previewSize.height)
                        .clipped()
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(9)
                        .background(.black.opacity(0.58), in: Circle())
                        .padding(10)
                } else {
                    ProgressView()
                }
            }
            .frame(width: previewSize.width, height: previewSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(image == nil || imageData == nil)
        .accessibilityLabel("Открыть снимок \(attachment.fileName)")
        .task(id: attachment.id) {
            if let data = await load(reportID, attachment.id),
               let loadedImage = UIImage(data: data) {
                imageData = data
                image = loadedImage
            }
        }
    }
}

private struct FeedbackImageViewerPayload: Identifiable {
    let id: String
    let fileName: String
    let image: UIImage
    let data: Data

    init(attachment: FeedbackAttachment, image: UIImage, data: Data) {
        id = attachment.id
        fileName = attachment.fileName
        self.image = image
        self.data = data
    }
}

private struct FeedbackImageViewer: View {
    @Environment(\.dismiss) private var dismiss
    let payload: FeedbackImageViewerPayload
    @State private var shareItem: FeedbackImageShareItem?

    var body: some View {
        NavigationStack {
            FeedbackZoomableImage(image: payload.image)
                .background(Color.black.ignoresSafeArea())
                .navigationTitle(payload.fileName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        ModalCloseButton(action: dismiss.callAsFunction)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Сохранить", systemImage: "square.and.arrow.down") {
                            shareItem = FeedbackImageShareItem(payload: payload)
                        }
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("Сохранить снимок")
                    }
                }
        }
        .sheet(item: $shareItem) { item in
            FeedbackImageActivityView(
                items: item.items,
                cleanupDirectory: item.cleanupDirectory
            )
        }
    }
}

private struct FeedbackImageShareItem: Identifiable {
    let id = UUID()
    let items: [Any]
    let cleanupDirectory: URL?

    init(payload: FeedbackImageViewerPayload) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("feedback-\(UUID().uuidString)", isDirectory: true)
        let sourceName = (payload.fileName as NSString).deletingPathExtension
        let safeName = sourceName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent(safeName.isEmpty ? "снимок.jpg" : "\(safeName).jpg")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try payload.data.write(to: url, options: .atomic)
            items = [url]
            cleanupDirectory = directory
        } catch {
            items = [payload.image]
            cleanupDirectory = nil
        }
    }
}

private struct FeedbackImageActivityView: UIViewControllerRepresentable {
    let items: [Any]
    let cleanupDirectory: URL?

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            if let cleanupDirectory {
                try? FileManager.default.removeItem(at: cleanupDirectory)
            }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct FeedbackZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .black

        let zoomView = UIView()
        zoomView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(zoomView)

        let imageView = UIImageView(image: image)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        zoomView.addSubview(imageView)

        NSLayoutConstraint.activate([
            zoomView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            zoomView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            zoomView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            zoomView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            zoomView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            zoomView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
            imageView.leadingAnchor.constraint(equalTo: zoomView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: zoomView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: zoomView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: zoomView.bottomAnchor)
        ])

        context.coordinator.zoomView = zoomView
        context.coordinator.imageView = imageView
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var zoomView: UIView?
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            zoomView
        }
    }
}

private func feedbackJSONDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = fractional.date(from: value) ?? plain.date(from: value) { return date }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Некорректная дата: \(value)")
    }
    return decoder
}

private func feedbackShortDate(_ date: Date) -> String {
    date.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(AppLocale.russian))
}

func feedbackFullDate(_ date: Date) -> String {
    date.formatted(.dateTime.day().month(.wide).year().hour().minute().locale(AppLocale.russian))
}

private extension UIImage {
    func feedbackJPEGData(maxDimension: CGFloat, compressionQuality: CGFloat) -> Data? {
        let longestSide = max(size.width, size.height)
        let scale = longestSide > maxDimension ? maxDimension / longestSide : 1
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let rendered = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: targetSize))
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return rendered.jpegData(compressionQuality: compressionQuality)
    }
}
