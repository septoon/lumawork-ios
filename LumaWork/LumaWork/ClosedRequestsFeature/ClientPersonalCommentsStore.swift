import Foundation
import SwiftUI

nonisolated struct ClientPersonalComment: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var normalizedTIN: String
    var displayTIN: String
    var targets: [ClientPersonalCommentTarget]
    var terminalIDs: [String]
    var contactPerson: String
    var phone: String
    var email: String
    var extraInfo: String?
    var authorShortName: String?
    var updatedAt: Date

    init(
        id: String,
        normalizedTIN: String,
        displayTIN: String,
        targets: [ClientPersonalCommentTarget],
        terminalIDs: [String],
        contactPerson: String,
        phone: String,
        email: String,
        extraInfo: String?,
        authorShortName: String?,
        updatedAt: Date
    ) {
        self.id = id
        self.normalizedTIN = normalizedTIN
        self.displayTIN = displayTIN
        self.targets = targets
        self.terminalIDs = terminalIDs
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

        let targets = try container.decodeIfPresent([ClientPersonalCommentTarget].self, forKey: .targets) ?? []
        self.id = try container.decodeIfPresent(String.self, forKey: .id)
            ?? Self.storageKey(normalizedTIN: normalizedTIN, targets: targets)
        self.normalizedTIN = normalizedTIN
        self.displayTIN = displayTIN
        self.targets = targets
        self.terminalIDs = try container.decodeIfPresent([String].self, forKey: .terminalIDs) ?? []
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
    }

    private static func normalized(_ raw: String) -> String {
        ClientPersonalCommentsStore.normalizedScopeText(raw)
    }
}

struct ClientPersonalCommentTerminalOption: Hashable, Identifiable {
    var terminalID: String
    var address: String

    var id: String { ClientPersonalCommentMatchingIndex.normalizedTerminalID(terminalID) }

    var displayText: String {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedAddress.isEmpty ? terminalID : "\(terminalID) · \(trimmedAddress)"
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
                id: draft.serverID,
                sourceCommentID: draft.sourceCommentID,
                displayTIN: draft.tin,
                targets: draft.targets,
                terminalIDs: draft.terminalIDs,
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
        request.setValue("2", forHTTPHeaderField: "X-LumaWork-Personal-Comments-Version")

        if let body {
            request.httpBody = try JSONEncoder().encode(AnyEncodable(body))
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, urlResponse) = try await session.data(for: request)
        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw AppServiceError.message("Сервер вернул неизвестный ответ.")
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 409,
               let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.message {
                throw AppServiceError.message(message)
            }
            throw AppServiceError.http(status: httpResponse.statusCode, fallback: "Не удалось сохранить комментарий")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = ClientPersonalCommentDateCoding.strategy
        return try decoder.decode(Response.self, from: data)
    }

    private struct CommentsResponse: Decodable {
        var comments: [ClientPersonalComment]
    }

    private struct SaveCommentResponse: Decodable {
        var comment: ClientPersonalComment
    }

    private struct ErrorResponse: Decodable {
        var message: String
    }

    private struct SaveCommentRequest: Encodable {
        var id: String?
        var sourceCommentID: String?
        var displayTIN: String
        var targets: [ClientPersonalCommentTarget]
        var terminalIDs: [String]
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
    private var matchingIndex = ClientPersonalCommentMatchingIndex(entries: [])
    private let refreshInterval: TimeInterval = 5 * 60
    @ObservationIgnored private var lastRefreshedAt: Date?
    @ObservationIgnored private var refreshTask: Task<[ClientPersonalComment], Error>?
    @ObservationIgnored private var saveRevision = 0
    @ObservationIgnored private var savedDuringRefresh: [String: ClientPersonalComment] = [:]
    @ObservationIgnored private var persistTask: Task<Void, Never>?

    init(api: ClientPersonalCommentsAPI) {
        self.api = api
        load()
    }

    func comment(forTIN rawTIN: String, address: String = "", terminalID: String = "") -> ClientPersonalComment? {
        guard let id = matchingIndex.selectedID(tin: rawTIN, address: address, terminalID: terminalID) else {
            return nil
        }
        return commentsByKey[id]
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
        let revisionAtStart = saveRevision
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
            var merged: [String: ClientPersonalComment] = [:]
            for comment in comments {
                merged[comment.id] = comment
            }
            if saveRevision != revisionAtStart {
                for (id, comment) in savedDuringRefresh {
                    merged[id] = comment
                }
            } else {
                savedDuringRefresh.removeAll()
            }
            commentsByKey = merged
            rebuildIndex()
            persist()
            lastRefreshedAt = Date()
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
        }
    }

    func save(_ draft: ClientPersonalCommentDraft) async throws {
        guard !Self.normalizedTIN(draft.tin).isEmpty else {
            throw AppServiceError.message("Укажите ИНН из 10 или 12 цифр.")
        }
        let serverComment = try await api.saveComment(draft)
        saveRevision &+= 1
        savedDuringRefresh[serverComment.id] = serverComment
        if let sourceID = draft.sourceCommentID,
           var source = commentsByKey[sourceID] {
            let transferred = Set(serverComment.terminalIDs.map(ClientPersonalCommentMatchingIndex.normalizedTerminalID))
            source.terminalIDs.removeAll {
                transferred.contains(ClientPersonalCommentMatchingIndex.normalizedTerminalID($0))
            }
            commentsByKey[sourceID] = source
            savedDuringRefresh[sourceID] = source
        }
        commentsByKey[serverComment.id] = serverComment
        rebuildIndex()
        persist()
    }

    nonisolated static func normalizedTIN(_ raw: String) -> String {
        ClientPersonalCommentMatchingIndex.normalizedTIN(raw)
    }

    nonisolated static func normalizedScopeText(_ raw: String) -> String {
        ClientPersonalCommentMatchingIndex.normalizedAddress(raw)
    }

    private func load() {
        guard let data = (try? Data(contentsOf: Self.storeURL))
            ?? (try? Data(contentsOf: Self.legacyStoreURL)),
              let snapshot = try? JSONDecoder().decode([ClientPersonalComment].self, from: data) else {
            return
        }

        var loaded: [String: ClientPersonalComment] = [:]
        for comment in snapshot {
            loaded[comment.id] = comment
        }
        commentsByKey = loaded
        rebuildIndex()
    }

    private func rebuildIndex() {
        let entries = commentsByKey.values
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { comment in
                ClientPersonalCommentMatchingIndex.Entry(
                    id: comment.id,
                    tin: comment.normalizedTIN,
                    addresses: comment.targets.map(\.address),
                    terminalIDs: comment.terminalIDs
                )
            }
        matchingIndex = ClientPersonalCommentMatchingIndex(entries: entries)
    }

    private func persist() {
        let comments = Array(commentsByKey.values)
        let previous = persistTask
        persistTask = Task.detached(priority: .utility) {
            await previous?.value
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
            .appendingPathComponent("client-personal-comments-v2.json")
    }

    nonisolated private static var legacyStoreURL: URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("LumaWork", isDirectory: true)
            .appendingPathComponent("client-personal-comments-v1.json")
    }
}

struct ClientPersonalCommentDraft: Codable, Identifiable, Hashable {
    var id = UUID()
    var serverID: String?
    var sourceCommentID: String?
    var tin = ""
    var targets: [ClientPersonalCommentTarget] = []
    var terminalIDs: [String] = []
    var contactPerson = ""
    var phone = "+7 "
    var email = ""
    var extraInfo = ""

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        serverID = try container.decodeIfPresent(String.self, forKey: .serverID)
        sourceCommentID = try container.decodeIfPresent(String.self, forKey: .sourceCommentID)
        tin = try container.decodeIfPresent(String.self, forKey: .tin) ?? ""
        targets = try container.decodeIfPresent([ClientPersonalCommentTarget].self, forKey: .targets) ?? []
        terminalIDs = try container.decodeIfPresent([String].self, forKey: .terminalIDs) ?? []
        contactPerson = try container.decodeIfPresent(String.self, forKey: .contactPerson) ?? ""
        phone = try container.decodeIfPresent(String.self, forKey: .phone) ?? "+7 "
        email = try container.decodeIfPresent(String.self, forKey: .email) ?? ""
        extraInfo = try container.decodeIfPresent(String.self, forKey: .extraInfo) ?? ""
    }

    init(comment: ClientPersonalComment, fallbackTIN: String = "") {
        id = UUID()
        serverID = comment.id
        sourceCommentID = nil
        tin = comment.displayTIN.isEmpty ? fallbackTIN : comment.displayTIN
        targets = comment.targets
        terminalIDs = comment.terminalIDs
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
    let terminalOptions: [ClientPersonalCommentTerminalOption]
    let currentTarget: ClientPersonalCommentTarget?
    let currentTerminalID: String
    let onSave: (ClientPersonalCommentDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ClientPersonalCommentDraft
    @State private var newTerminalID = ""

    init(
        initialDraft: ClientPersonalCommentDraft,
        targetOptions: [ClientPersonalCommentTarget],
        terminalOptions: [ClientPersonalCommentTerminalOption],
        currentTarget: ClientPersonalCommentTarget?,
        currentTerminalID: String,
        onSave: @escaping (ClientPersonalCommentDraft) -> Void
    ) {
        self.initialDraft = initialDraft
        self.targetOptions = targetOptions
        self.terminalOptions = terminalOptions
        self.currentTarget = currentTarget
        self.currentTerminalID = currentTerminalID
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
                        .disabled(draft.serverID != nil)
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

                if !targetOptions.isEmpty {
                    Section("Привязка к адресу") {
                        Toggle("Все адреса", isOn: allTargetsBinding)
                        ForEach(targetOptions) { target in
                            Toggle(target.displayText, isOn: binding(for: target))
                        }
                        if initialDraft.serverID != nil,
                           initialDraft.targets.isEmpty,
                           draft.serverID != nil,
                           let currentTarget {
                            Button("Отдельный комментарий для этого адреса") {
                                draft.sourceCommentID = draft.serverID
                                draft.serverID = nil
                                draft.targets = [currentTarget]
                                draft.terminalIDs = terminalOptions
                                    .filter {
                                        ClientPersonalCommentMatchingIndex.normalizedAddress($0.address)
                                            == currentTarget.normalizedKey
                                    }
                                    .map(\.terminalID)
                                appendTerminalID(currentTerminalID)
                            }
                        }
                    }
                }

                Section("ID терминалов") {
                    ForEach(draft.terminalIDs, id: \.self) { terminalID in
                        HStack {
                            Text(terminalID)
                                .font(.subheadline)
                            Spacer()
                            Button("Убрать ID терминала", systemImage: "minus.circle") {
                                draft.terminalIDs.removeAll { $0 == terminalID }
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                        }
                    }

                    HStack {
                        TextField("ID терминала", text: $newTerminalID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Добавить ID терминала", systemImage: "plus.circle") {
                            appendTerminalID(newTerminalID)
                            newTerminalID = ""
                        }
                        .labelStyle(.iconOnly)
                        .disabled(newTerminalID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    let suggestions = terminalOptions.filter { option in
                        let matchesAddress = draft.targets.isEmpty
                            || draft.selectedTargetKeys.contains(
                                ClientPersonalCommentMatchingIndex.normalizedAddress(option.address)
                            )
                        return !draft.terminalIDs.contains { selected in
                            ClientPersonalCommentMatchingIndex.normalizedTerminalID(selected)
                                == option.id
                        } && matchesAddress
                    }
                    if !suggestions.isEmpty {
                        Menu("ID из заявок", systemImage: "list.bullet") {
                            ForEach(suggestions) { option in
                                Button(option.displayText) { appendTerminalID(option.terminalID) }
                            }
                        }
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
                    draft.sourceCommentID = nil
                } else if draft.targets.isEmpty,
                          let target = currentTarget ?? targetOptions.first {
                    draft.targets = [target]
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

    private func appendTerminalID(_ raw: String) {
        let terminalID = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = ClientPersonalCommentMatchingIndex.normalizedTerminalID(terminalID)
        guard !normalized.isEmpty,
              !draft.terminalIDs.contains(where: {
                  ClientPersonalCommentMatchingIndex.normalizedTerminalID($0) == normalized
              }) else { return }
        draft.terminalIDs.append(terminalID)
    }
}

struct ClientPersonalCommentBlock: View {
    let comment: ClientPersonalComment
    var onEdit: (() -> Void)?

    private var rows: [(String, String)] {
        [
            ("ИНН", comment.displayTIN),
            ("Адреса", comment.targets.isEmpty ? "Все адреса" : comment.targets.map(\.displayText).joined(separator: "\n")),
            ("ID терминалов", comment.terminalIDs.joined(separator: ", ")),
            ("Контактное лицо", comment.contactPerson),
            ("Телефон", comment.phone.isEmpty ? "" : ClientPersonalCommentPhoneFormatter.display(comment.phone)),
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
                            textStyle: .subheadline,
                            weight: .medium,
                            color: title == "Почта" ? .blue : AppTheme.ink,
                            onTap: title == "Почта"
                                ? { AppClipboard.copy(value, message: "Почта скопирована") }
                                : nil,
                            onLongPress: title == "Телефон"
                                ? { AppClipboard.copy(ClientPersonalCommentPhoneFormatter.canonical(comment.phone), message: "Телефон скопирован") }
                                : nil
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            Text(metadataText)
                .font(.caption2)
                .foregroundStyle(AppTheme.mutedTint)
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
