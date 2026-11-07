import Foundation
import Observation
import SwiftUI

nonisolated struct AdminLeaderboardPolicy: Codable, Equatable, Sendable {
    var enabled = true
    var platforms = Platforms()
    var users: [String: Bool] = [:]
    struct Platforms: Codable, Equatable, Sendable {
        var ios: Bool?
        var android: Bool?
        // Keep nulls explicit: null means inheritance, not a missing contract field.
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            if let ios { try values.encode(ios, forKey: .ios) } else { try values.encodeNil(forKey: .ios) }
            if let android { try values.encode(android, forKey: .android) } else { try values.encodeNil(forKey: .android) }
        }
        enum CodingKeys: String, CodingKey { case ios, android }
    }
}
nonisolated struct AdminLeaderboardPolicyUser: Decodable, Identifiable, Sendable {
    var userId: String
    var displayName: String
    var id: String { userId }
}
private enum LeaderboardVisibilityRule: String, CaseIterable, Identifiable {
    case inherited, enabled, disabled
    var id: String { rawValue }
    var title: String {
        switch self { case .inherited: "По умолчанию"; case .enabled: "Включён"; case .disabled: "Выключен" }
    }
    var value: Bool? {
        switch self { case .inherited: nil; case .enabled: true; case .disabled: false }
    }
    init(_ value: Bool?) { self = value.map { $0 ? .enabled : .disabled } ?? .inherited }
}

@MainActor private struct AdminLeaderboardAccessAPI {
    let token: String?
    let baseURL = AppConfig.configuredURL(AppConfig().lumaWorkAPIOrigin)
    let http = HTTPClient()
    struct Settings: Decodable {
        var policy: AdminLeaderboardPolicy
        var updatedAt: String?
        var lockedByEnvironment: Bool
        var availableUsers: [AdminLeaderboardPolicyUser]
    }
    struct Receipt: Decodable { var policy: AdminLeaderboardPolicy; var updatedAt: String? }
    func fetch() async throws -> Settings { try await request() }
    func save(_ policy: AdminLeaderboardPolicy, updatedAt: String?) async throws -> Receipt {
        try await request(method: "PUT", body: [
            "policy": try JSONSerialization.jsonObject(with: JSONEncoder().encode(policy)),
            "expectedUpdatedAt": updatedAt as Any? ?? NSNull()
        ])
    }
    private func request<T: Decodable>(method: String = "GET", body: [String: Any]? = nil) async throws -> T {
        guard let token, !token.isEmpty else { throw AppServiceError.message("Требуется авторизация администратора.") }
        let response = try await http.request(baseURL.appendingPathComponent("api/v2/admin/leaderboard-access"), method: method, body: body, authToken: token)
        guard let json = response.json else { throw AppServiceError.message("Сервер вернул пустые настройки.") }
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: json))
    }
}

@MainActor @Observable private final class AdminLeaderboardAccessStore {
    var policy = AdminLeaderboardPolicy()
    private(set) var users: [AdminLeaderboardPolicyUser] = []
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var loaded = false
    private(set) var lockedByEnvironment = false
    var error: String?
    private var original = AdminLeaderboardPolicy()
    private var updatedAt: String?
    @ObservationIgnored private let api: AdminLeaderboardAccessAPI
    var hasChanges: Bool { loaded && policy != original }
    init(token: String?) { api = AdminLeaderboardAccessAPI(token: token) }
    func load() async {
        guard !isLoading, !isSaving else { return }
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            let result = try await api.fetch()
            try Task.checkCancellation()
            policy = result.policy; original = result.policy; updatedAt = result.updatedAt
            users = result.availableUsers; lockedByEnvironment = result.lockedByEnvironment; loaded = true
        } catch is CancellationError { return }
        catch { self.error = appUserFacingErrorMessage(error) ?? "Не удалось загрузить настройки рейтинга." }
    }
    func save() async {
        guard hasChanges, !isSaving, !isLoading else { return }
        isSaving = true; error = nil
        defer { isSaving = false }
        do {
            let result = try await api.save(policy, updatedAt: updatedAt)
            policy = result.policy; original = result.policy; updatedAt = result.updatedAt
            NotificationCenter.default.post(name: .leaderboardAccessChanged, object: nil)
            AppBannerCenter.shared.show("Настройки рейтинга сохранены.", style: .success)
        } catch AppServiceError.http(status: 409, fallback: _) {
            self.error = "Настройки изменил другой администратор. Обновите их и повторите изменения."
        } catch { self.error = appUserFacingErrorMessage(error) ?? "Не удалось сохранить настройки рейтинга." }
    }
}

struct AdminLeaderboardAccessScreen: View {
    @State private var store: AdminLeaderboardAccessStore
    private let canManage: Bool
    init(token: String?, canManage: Bool) {
        _store = State(initialValue: AdminLeaderboardAccessStore(token: token)); self.canManage = canManage
    }
    var body: some View {
        Form {
            AdminLeaderboardPolicyError(store: store)
            if store.isLoading { ProgressView("Загрузка настроек") }
            if store.loaded {
                Section {
                    Toggle("Рейтинг по умолчанию", isOn: $store.policy.enabled)
                        .tint(AppTheme.primaryTint).disabled(!canManage)
                } header: { Text("Для всех") } footer: {
                    Text("Общее правило для пользователей без исключений. При выключенном рейтинге остаётся прежняя «Аналитика».")
                }
                Section {
                    rulePicker("iOS", value: $store.policy.platforms.ios)
                    rulePicker("Android", value: $store.policy.platforms.android)
                } header: { Text("Платформы") } footer: {
                    Text("Настройка платформы важнее общего правила.")
                }
                Section {
                    NavigationLink {
                        AdminLeaderboardUserRules(store: store, canManage: canManage)
                    } label: {
                        LabeledContent("Пользователи", value: "Исключений: \(store.policy.users.count)")
                    }
                } header: { Text("Персональные настройки") } footer: {
                    Text("Персональное правило важнее платформы. Выберите «По умолчанию», чтобы убрать исключение. Скрытие экрана не останавливает отправку агрегатов и не убирает инженера из рейтингов других пользователей.")
                }
                if store.lockedByEnvironment {
                    Section { Text("Рейтинг временно отключён на сервере. Настройки сохраняются, но показ возобновится после включения сервиса.").foregroundStyle(.secondary) }
                }
                Section { Text("Изменения применяются после сохранения. Приложение проверяет доступ при открытии аналитики, возврате из фона и каждые 30 секунд на экране. Нужна версия с поддержкой этой настройки.").font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .scrollContentBackground(.hidden).background(AppTheme.background)
        .navigationTitle("Рейтинг пользователей").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canManage {
                ToolbarItem(placement: .topBarTrailing) {
                    ModalConfirmButton(action: { Task { await store.save() } }, isLoading: store.isSaving, accessibilityLabel: "Сохранить настройки рейтинга")
                        .disabled(!store.hasChanges || store.isLoading || store.isSaving)
                }
            }
        }
        .disabled(store.isLoading || store.isSaving)
        .task { if !store.loaded { await store.load() } }
        .refreshable { await store.load() }
    }
    private func rulePicker(_ title: String, value: Binding<Bool?>) -> some View {
        Picker(title, selection: Binding(get: { LeaderboardVisibilityRule(value.wrappedValue) }, set: { value.wrappedValue = $0.value })) {
            ForEach(LeaderboardVisibilityRule.allCases) { Text($0.title).tag($0) }
        }.disabled(!canManage)
    }
}

private struct AdminLeaderboardPolicyError: View {
    @Bindable var store: AdminLeaderboardAccessStore
    var body: some View {
        if let error = store.error {
            Section {
                Text(error).foregroundStyle(AppTheme.dangerTint)
                Button("Обновить настройки") { Task { await store.load() } }
            }
        }
    }
}

private struct AdminLeaderboardUserRules: View {
    @Bindable var store: AdminLeaderboardAccessStore
    let canManage: Bool
    @State private var search = ""
    private var users: [AdminLeaderboardPolicyUser] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.users.filter { query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        Form {
            AdminLeaderboardPolicyError(store: store)
            if store.isLoading { ProgressView("Загрузка настроек") }
            ForEach(users) { user in
                Picker(user.displayName, selection: Binding(get: { LeaderboardVisibilityRule(store.policy.users[user.id]) }, set: { store.policy.users[user.id] = $0.value })) {
                    ForEach(LeaderboardVisibilityRule.allCases) { Text($0.title).tag($0) }
                }.disabled(!canManage || store.isSaving)
            }
        }
        .disabled(store.isLoading || store.isSaving)
        .searchable(text: $search, prompt: "Имя инженера")
        .navigationTitle("Пользователи").navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden).background(AppTheme.background)
        .toolbar {
            if canManage {
                ToolbarItem(placement: .topBarTrailing) {
                    ModalConfirmButton(action: { Task { await store.save() } }, isLoading: store.isSaving, accessibilityLabel: "Сохранить персональные настройки")
                        .disabled(!store.hasChanges || store.isLoading || store.isSaving)
                }
            }
        }
    }
}

#if DEBUG
extension AdminLeaderboardAccessScreen {
    static func userRulesVisualPreview() -> some View {
        let store = AdminLeaderboardAccessStore(token: nil)
        store.prepareVisualPreview()
        store.error = "Настройки изменил другой администратор. Обновите их и повторите изменения."
        return AdminLeaderboardUserRules(store: store, canManage: true)
    }
    static func visualPreview() -> Self {
        let store = AdminLeaderboardAccessStore(token: nil)
        store.policy = AdminLeaderboardPolicy(enabled: true, platforms: .init(ios: nil, android: false), users: ["preview-a": true, "preview-b": false])
        store.prepareVisualPreview()
        var view = Self(token: nil, canManage: true)
        view._store = State(initialValue: store)
        return view
    }
}
private extension AdminLeaderboardAccessStore {
    func prepareVisualPreview() {
        users = [.init(userId: "preview-a", displayName: "Александр Константинопольский"), .init(userId: "preview-b", displayName: "Мария Петрова"), .init(userId: "preview-c", displayName: "Иван Соколов")]
        original = policy; loaded = true
    }
}
struct LeaderboardAccessVisualPreview: View {
    private let disabled = ProcessInfo.processInfo.arguments.contains("-leaderboard-disabled-ui-preview")
    @State private var access = LeaderboardAccessStore(config: AppConfig(), ownerID: nil)
    @State private var leaderboard = LeaderboardStore(config: AppConfig())
    var body: some View {
        NavigationStack {
            if disabled {
                ClosedRequestsAnalyticsScreen(snapshot: nil, records: [], leaderboardStore: leaderboard, leaderboardAccess: access, sourceUserID: "", showsCloseButton: false)
                    .toolbar { ToolbarItem(placement: .topBarLeading) { AppSidebarMenuButton {} } }
            } else if ProcessInfo.processInfo.arguments.contains("-leaderboard-user-rules-ui-preview") {
                AdminLeaderboardAccessScreen.userRulesVisualPreview()
            } else { AdminLeaderboardAccessScreen.visualPreview() }
        }.environment(\.locale, AppLocale.russian)
    }
}
#endif
