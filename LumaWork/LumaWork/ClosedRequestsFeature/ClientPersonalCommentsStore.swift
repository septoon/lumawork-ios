import Foundation
import SwiftUI

nonisolated struct ClientPersonalComment: Codable, Hashable, Identifiable, Sendable {
    var id: String {
        Self.storageKey(normalizedTIN: normalizedTIN, targets: targets)
    }

    var normalizedTIN: String
    var displayTIN: String
    var targets: [ClientPersonalCommentTarget]
    var contactPerson: String
    var phone: String
    var email: String
    var extraInfo: String?
    var authorShortName: String?
    var updatedAt: Date

    init(
        normalizedTIN: String,
        displayTIN: String,
        targets: [ClientPersonalCommentTarget],
        contactPerson: String,
        phone: String,
        email: String,
        extraInfo: String?,
        authorShortName: String?,
        updatedAt: Date
    ) {
        self.normalizedTIN = normalizedTIN
        self.displayTIN = displayTIN
        self.targets = targets
        self.contactPerson = contactPerson
        self.phone = phone
        self.email = email
        self.extraInfo = extraInfo
        self.authorShortName = authorShortName
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let displayTIN = try container.decodeIfPresent(String.self, forKey: .displayTIN) ?? ""
        let normalizedTIN = try container.decodeIfPresent(String.self, forKey: .normalizedTIN)
            ?? ClientPersonalCommentsStore.normalizedTIN(displayTIN)

        self.normalizedTIN = normalizedTIN
        self.displayTIN = displayTIN
        self.targets = try container.decodeIfPresent([ClientPersonalCommentTarget].self, forKey: .targets) ?? []
        self.contactPerson = try container.decodeIfPresent(String.self, forKey: .contactPerson) ?? ""
        self.phone = try container.decodeIfPresent(String.self, forKey: .phone) ?? ""
        self.email = try container.decodeIfPresent(String.self, forKey: .email) ?? ""
        self.extraInfo = try container.decodeIfPresent(String.self, forKey: .extraInfo)
        self.authorShortName = try container.decodeIfPresent(String.self, forKey: .authorShortName)
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }

    static func storageKey(normalizedTIN: String, targets: [ClientPersonalCommentTarget]) -> String {
        let targetKey = targets.isEmpty
            ? "all"
            : targets.map(\.normalizedKey).sorted().joined(separator: "||")
        return "\(normalizedTIN)#\(targetKey)"
    }
}

nonisolated struct ClientPersonalCommentTarget: Codable, Hashable, Identifiable, Sendable {
    var address: String

    var id: String { normalizedKey }

    var normalizedKey: String {
        ClientPersonalCommentsStore.normalizedScopeText(address)
    }

    var displayText: String {
        let addressText = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return addressText.isEmpty ? "Адрес не указан" : addressText
    }

    func matches(address rawAddress: String) -> Bool {
        let ownAddress = Self.normalized(address)
        let incomingAddress = Self.normalized(rawAddress)
        guard !ownAddress.isEmpty, !incomingAddress.isEmpty else {
            return ownAddress.isEmpty
        }
        return ownAddress == incomingAddress
            || ownAddress.contains(incomingAddress)
            || incomingAddress.contains(ownAddress)
    }

    private static func normalized(_ raw: String) -> String {
        ClientPersonalCommentsStore.normalizedScopeText(raw)
    }
}

nonisolated struct ClientPersonalCommentsAPI: Sendable {
    private let baseURL: URL
    private let authToken: String?
    private let session: URLSession

    init(config: AppConfig, authToken: String?, session: URLSession = .shared) {
        self.baseURL = AppConfig.configuredURL(config.lumaWorkAPIOrigin)
        self.authToken = authToken
        self.session = session
    }

    func fetchComments() async throws -> [ClientPersonalComment] {
        let response: CommentsResponse = try await request(path: "/api/v2/client-personal-comments")
        return response.comments
    }

    func saveComment(_ draft: ClientPersonalCommentDraft) async throws -> ClientPersonalComment {
        let response: SaveCommentResponse = try await request(
            path: "/api/v2/client-personal-comments",
            method: "POST",
            body: SaveCommentRequest(
                displayTIN: draft.tin,
                targets: draft.targets,
                contactPerson: draft.contactPerson,
                phone: draft.normalizedPhone,
                email: draft.email,
                extraInfo: draft.extraInfo
            )
        )
        return response.comment
    }

    private func request<Response: Decodable>(
        path: String,
        method: String = "GET",
        body: (any Encodable)? = nil
    ) async throws -> Response {
        guard let authToken, !authToken.isEmpty else {
            throw AppServiceError.message("Требуется авторизация.")
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")

        if let body {
            request.httpBody = try JSONEncoder().encode(AnyEncodable(body))
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, urlResponse) = try await session.data(for: request)
        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw AppServiceError.message("Сервер вернул неизвестный ответ.")
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw AppServiceError.http(status: httpResponse.statusCode, fallback: "Не удалось сохранить комментарий")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Response.self, from: data)
    }

    private struct CommentsResponse: Decodable {
        var comments: [ClientPersonalComment]
    }

    private struct SaveCommentResponse: Decodable {
        var comment: ClientPersonalComment
    }

    private struct SaveCommentRequest: Encodable {
        var displayTIN: String
        var targets: [ClientPersonalCommentTarget]
        var contactPerson: String
        var phone: String
        var email: String
        var extraInfo: String
    }

    private struct AnyEncodable: Encodable {
        let value: any Encodable

        init(_ value: any Encodable) {
            self.value = value
        }

        func encode(to encoder: Encoder) throws {
            try value.encode(to: encoder)
        }
    }
}

@MainActor
@Observable
final class ClientPersonalCommentsStore {
    private(set) var commentsByKey: [String: ClientPersonalComment] = [:]
    var isSyncing = false
    var errorMessage: String?

    private let api: ClientPersonalCommentsAPI
    private var commentsByTIN: [String: [ClientPersonalComment]] = [:]
    private let refreshInterval: TimeInterval = 5 * 60
    @ObservationIgnored private var lastRefreshedAt: Date?
    @ObservationIgnored private var refreshTask: Task<[ClientPersonalComment], Error>?

    init(api: ClientPersonalCommentsAPI) {
        self.api = api
        load()
    }

    func comment(forTIN rawTIN: String, address: String = "") -> ClientPersonalComment? {
        let normalizedTIN = Self.normalizedTIN(rawTIN)
        guard !normalizedTIN.isEmpty else { return nil }

        let comments = commentsByTIN[normalizedTIN] ?? []
        if let addressComment = comments.first(where: { comment in
            !comment.targets.isEmpty && comment.targets.contains { target in
                target.matches(address: address)
            }
        }) {
            return addressComment
        }

        return comments.first { $0.targets.isEmpty } ?? comments.first
    }

    func refresh(force: Bool = false) async {
        if !force,
           let lastRefreshedAt,
           Date().timeIntervalSince(lastRefreshedAt) < refreshInterval {
            return
        }
        if let refreshTask {
            _ = try? await refreshTask.value
            return
        }

        isSyncing = true
        errorMessage = nil
        let task = Task {
            try await api.fetchComments()
        }
        refreshTask = task
        defer {
            refreshTask = nil
            isSyncing = false
        }
        do {
            let comments = try await task.value
            var merged = commentsByKey
            for comment in comments {
                merged[comment.id] = comment
            }
            commentsByKey = merged
            rebuildTINIndex()
            persist()
            lastRefreshedAt = Date()
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
        }
    }

    func save(_ draft: ClientPersonalCommentDraft) async throws {
        let normalizedTIN = Self.normalizedTIN(draft.tin)
        guard !normalizedTIN.isEmpty else { return }

        let localComment = ClientPersonalComment(
            normalizedTIN: normalizedTIN,
            displayTIN: draft.tin.trimmingCharacters(in: .whitespacesAndNewlines),
            targets: draft.targets,
            contactPerson: draft.contactPerson.trimmingCharacters(in: .whitespacesAndNewlines),
            phone: draft.normalizedPhone,
            email: draft.email.trimmingCharacters(in: .whitespacesAndNewlines),
            extraInfo: draft.extraInfo.trimmingCharacters(in: .whitespacesAndNewlines),
            authorShortName: nil,
            updatedAt: Date()
        )
        commentsByKey[localComment.id] = localComment
        rebuildTINIndex()
        persist()

        var serverComment = try await api.saveComment(draft)
        if serverComment.targets.isEmpty, !draft.targets.isEmpty {
            serverComment.targets = draft.targets
        }
        commentsByKey[serverComment.id] = serverComment
        rebuildTINIndex()
        persist()
    }

    nonisolated static func normalizedTIN(_ raw: String) -> String {
        raw.filter(\.isNumber)
    }

    nonisolated static func normalizedScopeText(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "ё", with: "е")
            .replacingOccurrences(of: "Ё", with: "Е")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let snapshot = try? JSONDecoder().decode([ClientPersonalComment].self, from: data) else {
            return
        }

        var loaded: [String: ClientPersonalComment] = [:]
        for comment in snapshot {
            loaded[comment.id] = comment
        }
        commentsByKey = loaded
        rebuildTINIndex()
    }

    private func rebuildTINIndex() {
        commentsByTIN = Dictionary(grouping: commentsByKey.values, by: \.normalizedTIN)
            .mapValues { comments in
                comments.sorted { lhs, rhs in
                    if lhs.targets.isEmpty != rhs.targets.isEmpty {
                        return !lhs.targets.isEmpty
                    }
                    return lhs.updatedAt > rhs.updatedAt
                }
            }
    }

    private func persist() {
        let comments = Array(commentsByKey.values)
        Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(
                    at: Self.storeURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let data = try JSONEncoder().encode(comments)
                try data.write(to: Self.storeURL, options: [.atomic])
            } catch {
                assertionFailure("Client comments save failed: \(error.localizedDescription)")
            }
        }
    }

    nonisolated private static var storeURL: URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("LumaWork", isDirectory: true)
            .appendingPathComponent("client-personal-comments-v1.json")
    }
}

struct ClientPersonalCommentDraft: Codable, Identifiable, Hashable {
    var id = UUID()
    var tin = ""
    var targets: [ClientPersonalCommentTarget] = []
    var contactPerson = ""
    var phone = "+7 "
    var email = ""
    var extraInfo = ""

    init() {}

    init(comment: ClientPersonalComment, fallbackTIN: String = "") {
        id = UUID()
        tin = comment.displayTIN.isEmpty ? fallbackTIN : comment.displayTIN
        targets = comment.targets
        contactPerson = comment.contactPerson
        phone = comment.phone.isEmpty ? "+7" : ClientPersonalCommentPhoneFormatter.canonical(comment.phone)
        email = comment.email
        extraInfo = comment.extraInfo ?? ""
    }

    var normalizedTIN: String {
        ClientPersonalCommentsStore.normalizedTIN(tin)
    }

    var selectedTargetKeys: Set<String> {
        Set(targets.map(\.normalizedKey))
    }

    var canSave: Bool {
        !normalizedTIN.isEmpty
            && (!contactPerson.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !normalizedPhoneDigits.isEmpty
                || !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !extraInfo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var normalizedPhone: String {
        ClientPersonalCommentPhoneFormatter.canonical(phone)
    }

    private var normalizedPhoneDigits: String {
        String(normalizedPhone.dropFirst(2))
    }
}

enum ClientPersonalCommentPhoneFormatter {
    static func canonical(_ raw: String) -> String {
        var digits = raw.filter(\.isNumber)
        if digits.count > 10 {
            digits = String(digits.suffix(10))
        } else if raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("+7")
            || digits.hasPrefix("7")
            || digits.hasPrefix("8") {
            digits.removeFirst()
        }
        return "+7\(digits)"
    }
}

enum ClientPersonalCommentDraftStore {
    static func load() -> ClientPersonalCommentDraft? {
        guard let data = try? Data(contentsOf: storeURL) else { return nil }
        return try? JSONDecoder().decode(ClientPersonalCommentDraft.self, from: data)
    }

    static func save(_ draft: ClientPersonalCommentDraft) {
        do {
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(draft)
            try data.write(to: storeURL, options: [.atomic])
        } catch {
            assertionFailure("Client comment draft save failed: \(error.localizedDescription)")
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: storeURL)
    }

    private static var storeURL: URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("LumaWork", isDirectory: true)
            .appendingPathComponent("client-personal-comment-draft-v1.json")
    }
}

struct ClientPersonalCommentEditor: View {
    let initialDraft: ClientPersonalCommentDraft
    let targetOptions: [ClientPersonalCommentTarget]
    let onSave: (ClientPersonalCommentDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ClientPersonalCommentDraft

    init(
        initialDraft: ClientPersonalCommentDraft,
        targetOptions: [ClientPersonalCommentTarget],
        onSave: @escaping (ClientPersonalCommentDraft) -> Void
    ) {
        self.initialDraft = initialDraft
        self.targetOptions = targetOptions
        self.onSave = onSave
        _draft = State(initialValue: initialDraft)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("ИНН", text: $draft.tin)
                        .keyboardType(.numberPad)
                        .textContentType(.none)
                        .onChange(of: draft.tin) { _, newValue in
                            draft.tin = newValue.filter(\.isNumber)
                        }

                    TextField("Контактное лицо", text: $draft.contactPerson)
                        .textContentType(.name)

                    TextField("Телефон", text: $draft.phone)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        .onChange(of: draft.phone) { _, newValue in
                            draft.phone = ClientPersonalCommentPhoneFormatter.canonical(newValue)
                        }

                    TextField("Почта", text: $draft.email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Дополнительно (Wi-Fi, ориентир...)", text: $draft.extraInfo, axis: .vertical)
                        .textInputAutocapitalization(.sentences)
                        .lineLimit(2...4)
                }

                if targetOptions.count > 1 {
                    Section("Привязка к адресу") {
                        Toggle("Все адреса", isOn: allTargetsBinding)
                        ForEach(targetOptions) { target in
                            Toggle(target.displayText, isOn: binding(for: target))
                        }
                    }
                } else if let target = targetOptions.first {
                    Section("Привязка к адресу") {
                        Text(target.displayText)
                            .font(.subheadline)
                    }
                }
            }
            .navigationTitle("Личный комментарий")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ModalCloseButton(action: dismiss.callAsFunction)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    ModalConfirmButton(
                        action: {
                            AppHaptics.trigger()
                            onSave(draft)
                            dismiss()
                        },
                        isDisabled: !draft.canSave,
                        accessibilityLabel: "Сохранить комментарий"
                    )
                }
            }
            .onChange(of: draft) { _, newValue in
                ClientPersonalCommentDraftStore.save(newValue)
            }
        }
    }

    private var allTargetsBinding: Binding<Bool> {
        Binding(
            get: { draft.targets.isEmpty },
            set: { isSelected in
                if isSelected {
                    draft.targets = []
                } else if draft.targets.isEmpty, let firstTarget = targetOptions.first {
                    draft.targets = [firstTarget]
                }
            }
        )
    }

    private func binding(for target: ClientPersonalCommentTarget) -> Binding<Bool> {
        Binding(
            get: { draft.selectedTargetKeys.contains(target.normalizedKey) },
            set: { isSelected in
                var selected = draft.targets.filter { option in
                    targetOptions.contains { $0.normalizedKey == option.normalizedKey }
                }
                let containsTarget = selected.contains { $0.normalizedKey == target.normalizedKey }

                if isSelected, !containsTarget {
                    selected.append(target)
                } else if !isSelected, containsTarget, selected.count > 1 {
                    selected.removeAll { $0.normalizedKey == target.normalizedKey }
                }
                draft.targets = selected
            }
        )
    }
}

struct ClientPersonalCommentBlock: View {
    let comment: ClientPersonalComment
    var onEdit: (() -> Void)?

    private var rows: [(String, String)] {
        [
            ("ИНН", comment.displayTIN),
            ("Адреса", comment.targets.isEmpty ? "Все адреса" : comment.targets.map(\.displayText).joined(separator: "\n")),
            ("Контактное лицо", comment.contactPerson),
            ("Телефон", ClientPersonalCommentPhoneFormatter.canonical(comment.phone)),
            ("Почта", comment.email),
            ("Дополнительно", comment.extraInfo ?? "")
        ]
        .filter { !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var metadataText: String {
        let author = comment.authorShortName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let date = Self.updatedAtFormatter.string(from: comment.updatedAt)
        if let author, !author.isEmpty {
            return "\(author) • \(date)"
        }
        return date
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Личный комментарий")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)
                    Text(metadataText)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(AppTheme.mutedTint)
                }

                Spacer(minLength: 8)

                if let onEdit {
                    Button("Редактировать комментарий", systemImage: "pencil") {
                        AppHaptics.trigger()
                        onEdit()
                    }
                    .labelStyle(.iconOnly)
                    .appNativeIconControl(.inline)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows, id: \.0) { title, value in
                    HStack(alignment: .top, spacing: 10) {
                        Text(title)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AppTheme.mutedTint)
                            .frame(width: 98, alignment: .leading)

                        AppSelectableText(
                            text: value,
                            textStyle: .caption1,
                            weight: .semibold
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.primaryTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.primaryTint.opacity(0.22), lineWidth: 1)
            )
    }

    private static let updatedAtFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter
    }()
}
