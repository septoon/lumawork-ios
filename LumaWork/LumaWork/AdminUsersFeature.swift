import Foundation
import Observation
import SwiftUI

struct AdminUserRecord: Codable, Identifiable, Hashable {
    var id: String
    var email: String
    var role: String
    var adminPermissions: [String]
    var isProtectedAdmin: Bool
    var profile: UserProfileData?
    var avatarUrl: String?
    var registeredAt: Date?
    var lastActiveAt: Date?
    var appVersion: String?
    var appBuild: String?
    var appVersionSeenAt: Date?
    var isBlocked: Bool
    var blockedUntil: Date?

    var displayName: String {
        profile?.fullName ?? email
    }

    var jobTitle: String {
        UserProfileData.clean(profile?.jobTitle) ?? (isAdmin ? "Администратор" : "Пользователь")
    }

    var isAdmin: Bool {
        ["admin", "administrator", "superadmin", "owner"].contains(role.lowercased())
    }

    var permissionSet: Set<AdminPermission> {
        Set(adminPermissions.compactMap(AdminPermission.init(rawValue:)))
    }

    var effectiveIsBlocked: Bool {
        guard isBlocked else { return false }
        if let blockedUntil {
            return blockedUntil > Date()
        }
        return true
    }

    var appVersionDisplay: String {
        let version = UserProfileData.clean(appVersion)
        let build = UserProfileData.clean(appBuild)
        if let version, let build { return "\(version) (\(build))" }
        if let version { return version }
        if let build { return "Сборка \(build)" }
        return "Не определена"
    }
}

struct AdminUpdateEmailResult: Hashable {
    let sent: Int
    let failed: Int
    let matched: Int
}

@MainActor
struct AdminUsersAPI {
    private let baseURL: URL
    private let http = HTTPClient()

    init(config: AppConfig) {
        baseURL = AppConfig.configuredURL(config.lumaWorkAPIOrigin)
    }

    func fetchUsers(token: String) async throws -> [AdminUserRecord] {
        let response = try await http.request(url(path: "/api/v2/admin/users"), authToken: token)
        return adminArray(from: response.json, keys: ["users", "data", "items"])
            .map(AdminUserRecord.init(raw:))
            .filter { !$0.id.isEmpty }
            .sorted { lhs, rhs in
                let lhsDate = lhs.lastActiveAt ?? lhs.registeredAt ?? .distantPast
                let rhsDate = rhs.lastActiveAt ?? rhs.registeredAt ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
    }

    func fetchUser(id: String, token: String) async throws -> AdminUserRecord {
        let response = try await http.request(url(path: "/api/v2/admin/users/\(id)"), authToken: token)
        let raw = adminDictionary(from: response.json, keys: ["user", "data"])
            ?? (response.json as? [String: Any])
            ?? [:]
        return AdminUserRecord(raw: raw)
    }

    func updateBlock(id: String, blockedUntil: Date?, token: String) async throws -> AdminUserRecord {
        var body: [String: Any] = ["isBlocked": blockedUntil != nil]
        body["blockedUntil"] = blockedUntil.map(AdminUsersDateFormatters.api.string(from:)) ?? NSNull()
        let response = try await http.request(
            url(path: "/api/v2/admin/users/\(id)/block"),
            method: "POST",
            body: body,
            authToken: token
        )
        let raw = adminDictionary(from: response.json, keys: ["user", "data"])
            ?? (response.json as? [String: Any])
            ?? [:]
        return AdminUserRecord(raw: raw)
    }

    func updateAccess(
        id: String,
        isAdmin: Bool,
        permissions: Set<AdminPermission>,
        token: String
    ) async throws -> AdminUserRecord {
        let response = try await http.request(
            url(path: "/api/v2/admin/users/\(id)/access"),
            method: "PATCH",
            body: [
                "role": isAdmin ? "admin" : "user",
                "permissions": AdminPermission.allCases
                    .filter(permissions.contains)
                    .map(\.rawValue)
            ],
            authToken: token
        )
        let raw = adminDictionary(from: response.json, keys: ["user", "data"])
            ?? (response.json as? [String: Any])
            ?? [:]
        return AdminUserRecord(raw: raw)
    }

    func deleteUser(id: String, confirmationEmail: String, token: String) async throws {
        _ = try await http.request(
            url(path: "/api/v2/admin/users/\(id)"),
            method: "DELETE",
            body: ["confirmationEmail": confirmationEmail],
            authToken: token
        )
    }

    func sendUpdateEmail(
        userID: String?,
        version: String,
        build: String?,
        subject: String,
        body: String,
        token: String
    ) async throws -> AdminUpdateEmailResult {
        let target: [String: Any] = userID.map { ["kind": "user", "userId": $0] } ?? ["kind": "outdated"]
        var payload: [String: Any] = [
            "target": target,
            "version": version,
            "subject": subject,
            "body": body
        ]
        payload["build"] = build.map { $0 as Any } ?? NSNull()
        let response = try await http.request(
            url(path: "/api/v2/admin/users/update-email"),
            method: "POST",
            body: payload,
            authToken: token
        )
        let raw = response.json as? [String: Any] ?? [:]
        return AdminUpdateEmailResult(
            sent: (raw["sent"] as? NSNumber)?.intValue ?? 0,
            failed: (raw["failed"] as? NSNumber)?.intValue ?? 0,
            matched: (raw["matched"] as? NSNumber)?.intValue ?? 0
        )
    }

    private func url(path: String) -> URL {
        baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
}

@MainActor
@Observable
final class AdminUsersStore {
    private let api: AdminUsersAPI
    private let token: String?
    private let cacheKey: String

    var users: [AdminUserRecord] = []
    var isLoading = false
    var isSendingUpdateEmail = false
    var errorMessage: String?
    var notice: String?

    init(token: String?, cacheID: String? = nil) {
        api = AdminUsersAPI(config: AppConfig())
        self.token = token
        cacheKey = AppOfflineSnapshotStore.scopedKey("admin-users", userID: cacheID)
        if let snapshot = AppOfflineSnapshotStore.load([AdminUserRecord].self, key: cacheKey) {
            users = snapshot.value
        }
    }

    init(api: AdminUsersAPI, token: String?, cacheID: String? = nil) {
        self.api = api
        self.token = token
        cacheKey = AppOfflineSnapshotStore.scopedKey("admin-users", userID: cacheID)
        if let snapshot = AppOfflineSnapshotStore.load([AdminUserRecord].self, key: cacheKey) {
            users = snapshot.value
        }
    }

    func load() async {
        guard !isLoading else { return }
        await refresh()
    }

    func refresh() async {
        guard let token, !token.isEmpty else {
            errorMessage = "Требуется авторизация администратора."
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            users = try await api.fetchUsers(token: token)
            persist()
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
        }
    }

    func refreshUser(_ user: AdminUserRecord) async -> AdminUserRecord {
        guard let token, !token.isEmpty else { return user }
        do {
            let updated = try await api.fetchUser(id: user.id, token: token)
            replace(updated)
            return updated
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
            return user
        }
    }

    func setBlocked(user: AdminUserRecord, until blockedUntil: Date?) async -> AdminUserRecord? {
        await mutate(notice: blockedUntil == nil ? "Пользователь разблокирован." : "Пользователь заблокирован.") { token in
            try await api.updateBlock(id: user.id, blockedUntil: blockedUntil, token: token)
        }
    }

    func setAccess(
        user: AdminUserRecord,
        isAdmin: Bool,
        permissions: Set<AdminPermission>
    ) async -> AdminUserRecord? {
        await mutate(notice: isAdmin ? "Права администратора обновлены." : "Администраторские права сняты.") { token in
            try await api.updateAccess(id: user.id, isAdmin: isAdmin, permissions: permissions, token: token)
        }
    }

    func delete(_ user: AdminUserRecord, confirmationEmail: String) async -> Bool {
        guard let token, !token.isEmpty else {
            errorMessage = "Требуется авторизация администратора."
            return false
        }
        isLoading = true
        errorMessage = nil
        notice = nil
        defer { isLoading = false }
        do {
            try await api.deleteUser(
                id: user.id,
                confirmationEmail: confirmationEmail,
                token: token
            )
            users.removeAll { $0.id == user.id }
            persist()
            notice = "Пользователь удалён."
            return true
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
            return false
        }
    }

    func sendUpdateEmail(
        userID: String?,
        version: String,
        build: String?,
        subject: String,
        body: String
    ) async -> Bool {
        guard let token, !token.isEmpty else {
            errorMessage = "Требуется авторизация администратора."
            return false
        }
        isSendingUpdateEmail = true
        errorMessage = nil
        notice = nil
        defer { isSendingUpdateEmail = false }
        do {
            let result = try await api.sendUpdateEmail(
                userID: userID,
                version: version,
                build: build,
                subject: subject,
                body: body,
                token: token
            )
            if result.matched == 0 {
                notice = "Пользователей с устаревшей версией не найдено."
            } else if result.failed == 0 {
                notice = "Письмо отправлено: \(result.sent)."
            } else {
                notice = "Отправлено: \(result.sent), ошибок: \(result.failed)."
            }
            return result.failed == 0
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
            return false
        }
    }

    private func mutate(
        notice successNotice: String,
        action: (String) async throws -> AdminUserRecord
    ) async -> AdminUserRecord? {
        guard let token, !token.isEmpty else {
            errorMessage = "Требуется авторизация администратора."
            return nil
        }
        isLoading = true
        errorMessage = nil
        notice = nil
        defer { isLoading = false }
        do {
            let updated = try await action(token)
            replace(updated)
            notice = successNotice
            return updated
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
            return nil
        }
    }

    private func replace(_ user: AdminUserRecord) {
        if let index = users.firstIndex(where: { $0.id == user.id }) {
            users[index] = user
        } else {
            users.append(user)
        }
        persist()
    }

    private func persist() {
        AppOfflineSnapshotStore.save(users, key: cacheKey)
    }
}

struct AdminUsersScreen: View {
    @State private var store: AdminUsersStore
    @State private var overviewStore: AdminOverviewStore
    @State private var searchText = ""
    @State private var selectedFilter: AdminUsersFilter = .all
    @State private var updateEmailTarget: AdminUpdateEmailInitialTarget?

    private let currentUser: AppUser?
    private let token: String?

    init(sessionStore: AppSessionStore, store: AdminUsersStore? = nil) {
        let user = sessionStore.session?.user
        let token = sessionStore.authToken
        _store = State(initialValue: store ?? AdminUsersStore(
            token: token,
            cacheID: user?.id
        ))
        _overviewStore = State(initialValue: AdminOverviewStore(token: token))
        currentUser = user
        self.token = token
    }

    private var permissions: Set<AdminPermission> {
        currentUser?.adminPermissionSet ?? []
    }

    private var hasAvailableDestination: Bool {
        can(.viewOverview)
            || can(.viewUsers)
            || can(.viewImages)
            || can(.viewFeedback)
            || can(.viewGsmTemplate)
            || can(.viewAssistant)
            || can(.viewSite)
            || can(.viewEngineerFiles)
    }

    private var filteredUsers: [AdminUserRecord] {
        let query = normalizedAdminUserSearchText(searchText)
        return store.users.filter { user in
            switch selectedFilter {
            case .all:
                break
            case .admins:
                guard user.isAdmin else { return false }
            case .active:
                guard user.isRecentlyActive, !user.effectiveIsBlocked else { return false }
            case .blocked:
                guard user.effectiveIsBlocked else { return false }
            }
            guard !query.isEmpty else { return true }
            return [user.displayName, user.email, user.role, user.jobTitle]
                .map(normalizedAdminUserSearchText)
                .contains { $0.contains(query) }
        }
    }

    var body: some View {
        Group {
            if currentUser?.canAccessAdminPanel == true, hasAvailableDestination {
                adminMenu
            } else {
                AppScreen {
                    AppCard {
                        ContentUnavailableView(
                            "Нет доступа",
                            systemImage: "lock.fill",
                            description: Text("Для админки не назначено ни одного разрешения.")
                        )
                    }
                }
            }
        }
        .navigationTitle("Админка")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var adminMenu: some View {
        Form {
            if can(.viewOverview) {
                Section("Система") {
                    NavigationLink {
                        AdminOverviewDetailScreen(
                            store: overviewStore,
                            permissions: permissions,
                            page: .system
                        )
                    } label: {
                        AdminNavigationRow(
                            title: "Состояние системы",
                            subtitle: "Статус API и ресурсы VPS",
                            systemImage: "gauge.with.dots.needle.50percent",
                            tint: .green
                        )
                    }

                    NavigationLink {
                        AdminOverviewDetailScreen(
                            store: overviewStore,
                            permissions: permissions,
                            page: .storage
                        )
                    } label: {
                        AdminNavigationRow(
                            title: "Хранилище данных",
                            subtitle: "База данных, файлы и место пользователей",
                            systemImage: "externaldrive.fill",
                            tint: AppTheme.primaryTint
                        )
                    }
                }
            }

            if can(.viewUsers) || can(.viewFeedback) || can(.viewImages) || can(.viewSite) {
                Section("Управление") {
                    if can(.viewSite) {
                        NavigationLink {
                            AdminSiteScreen(
                                token: token,
                                canManage: can(.manageSite)
                            )
                        } label: {
                            AdminNavigationRow(
                                title: "Сайт",
                                subtitle: "Доступность, информация и скриншоты",
                                systemImage: "globe",
                                tint: .blue
                            )
                        }
                    }

                    if can(.viewUsers) {
                        NavigationLink {
                            usersContent
                        } label: {
                            AdminNavigationRow(
                                title: "Пользователи",
                                subtitle: "Аккаунты, роли, права и блокировки",
                                systemImage: "person.2.fill",
                                tint: AppTheme.primaryTint
                            )
                        }
                    }

                    if can(.viewFeedback) {
                        NavigationLink {
                            AdminFeedbackPanel(
                                token: token,
                                cacheID: currentUser?.id,
                                permissions: permissions
                            )
                        } label: {
                            AdminNavigationRow(
                                title: "Обратная связь",
                                subtitle: "Обращения, ошибки и предложения",
                                systemImage: "text.bubble.fill",
                                tint: AppTheme.secondaryTint
                            )
                        }
                    }

                    if can(.viewImages) {
                        NavigationLink {
                            AdminImagesPanel(
                                token: token,
                                permissions: permissions
                            )
                        } label: {
                            AdminNavigationRow(
                                title: "Изображения",
                                subtitle: "Каталог автомобилей, терминалов и привязок",
                                systemImage: "photo.on.rectangle.angled",
                                tint: .orange
                            )
                        }
                    }
                }
            }

            if can(.viewAssistant) {
                Section("ИИ-помощник") {
                    NavigationLink {
                        AdminAssistantScreen(
                            token: token,
                            cacheID: currentUser?.id,
                            canManage: can(.manageAssistant)
                        )
                    } label: {
                        AdminNavigationRow(
                            title: "Модель и расходы",
                            subtitle: "Токены, деньги, пользователи, лимиты и системный промпт",
                            systemImage: "brain.head.profile.fill",
                            tint: .purple
                        )
                    }
                }
            }

            if can(.viewOverview) {
                Section("Статистика и контроль") {
                    NavigationLink {
                        AdminOverviewDetailScreen(
                            store: overviewStore,
                            permissions: permissions,
                            page: .metrics
                        )
                    } label: {
                        AdminNavigationRow(
                            title: "Показатели",
                            subtitle: "Сводка по пользователям и контенту",
                            systemImage: "chart.bar.xaxis",
                            tint: AppTheme.primaryTint
                        )
                    }

                    if can(.viewOverview), can(.viewAuditLog) {
                        NavigationLink {
                            AdminOverviewDetailScreen(
                                store: overviewStore,
                                permissions: permissions,
                                page: .audit
                            )
                        } label: {
                            AdminNavigationRow(
                                title: "Журнал действий",
                                subtitle: "История административных изменений",
                                systemImage: "checklist",
                                tint: AppTheme.secondaryTint
                            )
                        }
                    }
                }
            }

            if can(.viewGsmTemplate) || can(.viewEngineerFiles) {
                Section("Инструменты") {
                    if can(.viewEngineerFiles) {
                        NavigationLink {
                            AdminSelectelFilesScreen(
                                token: token,
                                canManage: can(.manageEngineerFiles)
                            )
                        } label: {
                            AdminNavigationRow(
                                title: "Файлы инженера",
                                subtitle: "Снимки Wiki, загрузки, релизы и SideStore",
                                systemImage: "externaldrive.badge.icloud",
                                tint: .blue
                            )
                        }
                    }

                    if can(.viewGsmTemplate) {
                        NavigationLink {
                            gsmTemplateContent
                        } label: {
                            AdminNavigationRow(
                                title: "ГСМ-отчёт",
                                subtitle: "Заполнение страниц и шаблон XLTX",
                                systemImage: "tablecells.fill",
                                tint: .green
                            )
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
    }

    private var usersContent: some View {
        AppScreen {
            AdminUsersOverview(users: store.users)

            if can(.notifyUsers) {
                AdminUpdateEmailCard(users: store.users) {
                    updateEmailTarget = .outdated
                }
            }

            if let errorMessage = store.errorMessage {
                AppNoticeBanner(text: errorMessage, tint: AppTheme.dangerTint, isCritical: true)
            }
            if let notice = store.notice {
                AppNoticeBanner(text: notice, tint: AppTheme.primaryTint)
            }

            AppSectionHeader(
                title: "Пользователи",
                caption: "Показано \(filteredUsers.count) из \(store.users.count)"
            )

            Picker("Фильтр пользователей", selection: $selectedFilter) {
                ForEach(AdminUsersFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)

            if store.isLoading && store.users.isEmpty {
                AppLoadingView(title: "Загружаю пользователей")
            } else if store.users.isEmpty && store.errorMessage == nil {
                AppEmptyState(
                    title: "Пользователей нет",
                    message: "Сервер не вернул пользователей.",
                    systemName: "person.3"
                )
            } else if filteredUsers.isEmpty {
                AppEmptyState(
                    title: "Ничего не найдено",
                    message: "Измените фильтр или поисковый запрос.",
                    systemName: "magnifyingglass"
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(filteredUsers.enumerated()), id: \.element.id) { index, user in
                        NavigationLink {
                            AdminUserDetailScreen(
                                user: user,
                                store: store,
                                currentUserID: currentUser?.id,
                                permissions: currentUser?.adminPermissionSet ?? []
                            )
                        } label: {
                            AdminUserRow(user: user)
                        }
                        .buttonStyle(.plain)

                        if index < filteredUsers.count - 1 {
                            Divider().padding(.leading, 70)
                        }
                    }
                }
                .background(AppTheme.cardSurface.opacity(0.82), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
            }
        }
        .navigationTitle("Пользователи")
        .navigationBarTitleDisplayMode(.inline)
        .appNativeSearch(text: $searchText, prompt: "Поиск пользователей")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    AppHaptics.trigger()
                    Task { await store.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(store.isLoading)
                .accessibilityLabel("Обновить пользователей")
            }
        }
        .refreshable { await store.refresh() }
        .task { await store.load() }
        .sheet(item: $updateEmailTarget) { target in
            AdminUpdateEmailSheet(initialTarget: target, store: store)
                .appEditorSheetStyle()
        }
    }

    private var gsmTemplateContent: some View {
        AppScreen {
            AdminGsmProjectsCard(
                token: token,
                canEdit: can(.replaceGsmTemplate)
            )

            AdminGsmLayoutCard(
                token: token,
                cacheID: currentUser?.id,
                canEdit: can(.replaceGsmTemplate)
            )

            AdminGsmTemplateCard(
                token: token,
                canReplace: can(.replaceGsmTemplate)
            )
        }
        .navigationTitle("ГСМ-отчёт")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func can(_ permission: AdminPermission) -> Bool {
        currentUser?.can(permission) == true
    }
}

private struct AdminNavigationRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedTint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
    }
}

private enum AdminUsersFilter: String, CaseIterable, Identifiable {
    case all
    case admins
    case active
    case blocked

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "Все"
        case .admins: "Админы"
        case .active: "Активные"
        case .blocked: "Блок"
        }
    }
}

private enum AdminUpdateEmailInitialTarget: Identifiable, Hashable {
    case outdated
    case user(String)

    var id: String {
        switch self {
        case .outdated: "outdated"
        case .user(let id): "user-\(id)"
        }
    }
}

private enum AdminUpdateEmailMode: String, CaseIterable, Identifiable {
    case outdated
    case user

    var id: String { rawValue }
    var title: String {
        switch self {
        case .outdated: "Устаревшие"
        case .user: "Один пользователь"
        }
    }
}

private struct AdminUpdateEmailCard: View {
    let users: [AdminUserRecord]
    let action: () -> Void

    private var outdatedCount: Int {
        users.filter {
            adminIsOlderAppVersion(
                $0.appVersion,
                build: $0.appBuild,
                than: AppBuildIdentity.version,
                build: AppBuildIdentity.build
            )
        }.count
    }

    var body: some View {
        AppCard {
            HStack(spacing: 14) {
                Image(systemName: "envelope.badge")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryTint)
                    .frame(width: 42, height: 42)
                    .background(AppTheme.primaryTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Сообщить об обновлении")
                        .font(.headline)
                        .foregroundStyle(AppTheme.ink)
                    Text("Версия \(AppBuildIdentity.display) • устаревших: \(outdatedCount)")
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedTint)
                }
                Spacer(minLength: 4)
                Button("Создать", action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }
}

private struct AdminUpdateEmailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: AdminUsersStore

    @State private var mode: AdminUpdateEmailMode
    @State private var selectedUserID: String
    @State private var version = AppBuildIdentity.version
    @State private var build = AppBuildIdentity.build
    @State private var subject = "Вышло обновление LumaWork \(AppBuildIdentity.version)"
    @State private var message = "Что изменилось:\n\n• "
    @State private var showsMassConfirmation = false

    init(initialTarget: AdminUpdateEmailInitialTarget, store: AdminUsersStore) {
        self.store = store
        switch initialTarget {
        case .outdated:
            _mode = State(initialValue: .outdated)
            _selectedUserID = State(initialValue: store.users.first?.id ?? "")
        case .user(let id):
            _mode = State(initialValue: .user)
            _selectedUserID = State(initialValue: id)
        }
    }

    private var outdatedCount: Int {
        store.users.filter {
            adminIsOlderAppVersion($0.appVersion, build: $0.appBuild, than: version, build: normalizedBuild)
        }.count
    }

    private var normalizedBuild: String? {
        let value = build.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private var canSend: Bool {
        let normalizedVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let validVersion = normalizedVersion.split(separator: ".").count >= 2
            && normalizedVersion.split(separator: ".").allSatisfy { Int($0) != nil }
        let validBuild = normalizedBuild.map { Int($0) != nil } ?? true
        return validVersion
            && validBuild
            && !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (mode == .outdated || !selectedUserID.isEmpty)
            && !store.isSendingUpdateEmail
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Получатели") {
                    Picker("Кому", selection: $mode) {
                        ForEach(AdminUpdateEmailMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if mode == .user {
                        Picker("Пользователь", selection: $selectedUserID) {
                            ForEach(store.users) { user in
                                Text("\(user.displayName) • \(user.email)").tag(user.id)
                            }
                        }
                    } else {
                        LabeledContent("Получателей", value: outdatedCount.formatted())
                        Text("Будут выбраны только пользователи с известной версией ниже указанной.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedTint)
                    }
                }

                Section("Версия обновления") {
                    TextField("Версия", text: $version)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("Build", text: $build)
                        .keyboardType(.numberPad)
                }

                Section {
                    TextField("Тема", text: $subject, axis: .vertical)
                    TextEditor(text: $message)
                        .frame(minHeight: 180)
                } header: {
                    Text("Письмо")
                } footer: {
                    Text("Заголовок с версией и ссылка на обновление будут добавлены автоматически. Текст письма можно оформить произвольно.")
                }
            }
            .navigationTitle("Письмо об обновлении")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Отправить") {
                        if mode == .outdated { showsMassConfirmation = true }
                        else { Task { await send() } }
                    }
                    .disabled(!canSend)
                }
            }
            .confirmationDialog(
                "Отправить письмо \(outdatedCount) пользователям?",
                isPresented: $showsMassConfirmation,
                titleVisibility: .visible
            ) {
                Button("Отправить всем устаревшим") { Task { await send() } }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Версия обновления: \(version)\(normalizedBuild.map { " (\($0))" } ?? "")")
            }
        }
    }

    private func send() async {
        let success = await store.sendUpdateEmail(
            userID: mode == .user ? selectedUserID : nil,
            version: version.trimmingCharacters(in: .whitespacesAndNewlines),
            build: normalizedBuild,
            subject: subject.trimmingCharacters(in: .whitespacesAndNewlines),
            body: message.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if success { dismiss() }
    }
}

private func adminIsOlderAppVersion(
    _ currentVersion: String?,
    build currentBuild: String?,
    than targetVersion: String,
    build targetBuild: String?
) -> Bool {
    guard let currentVersion = UserProfileData.clean(currentVersion) else { return false }
    let current = currentVersion.split(separator: ".").map { Int($0) ?? 0 }
    let target = targetVersion.split(separator: ".").map { Int($0) ?? 0 }
    for index in 0 ..< max(current.count, target.count) {
        let currentPart = index < current.count ? current[index] : 0
        let targetPart = index < target.count ? target[index] : 0
        if currentPart != targetPart { return currentPart < targetPart }
    }
    guard let targetBuild, let target = Int(targetBuild) else { return false }
    guard let currentBuild, let current = Int(currentBuild) else { return true }
    return current < target
}

private struct AdminUsersOverview: View {
    let users: [AdminUserRecord]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                metric("Всего", value: users.count, icon: "person.2.fill", tint: AppTheme.primaryTint)
                Divider().frame(height: 52)
                metric("Админы", value: users.filter(\.isAdmin).count, icon: "checkmark.shield.fill", tint: AppTheme.secondaryTint)
            }
            Divider()
            HStack(spacing: 0) {
                metric("Активны", value: users.filter { $0.isRecentlyActive && !$0.effectiveIsBlocked }.count, icon: "bolt.fill", tint: .green)
                Divider().frame(height: 52)
                metric("Блок", value: users.filter(\.effectiveIsBlocked).count, icon: "lock.fill", tint: AppTheme.dangerTint)
            }
        }
        .background(AppTheme.cardSurface.opacity(0.82), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
    }

    private func metric(_ title: String, value: Int, icon: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(value.formatted()).font(.title3.weight(.bold)).foregroundStyle(AppTheme.ink)
                Text(title).font(.caption2).foregroundStyle(AppTheme.mutedTint)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 70)
    }
}

private struct AdminUserRow: View {
    let user: AdminUserRecord

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                ProfileAvatar(size: 46, avatarUrl: user.avatarUrl)
                Circle()
                    .fill(statusTint)
                    .frame(width: 11, height: 11)
                    .overlay(Circle().stroke(AppTheme.cardSurface, lineWidth: 2))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(user.displayName)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)
                        .lineLimit(1)
                    if user.isAdmin {
                        AdminStatusPill(
                            text: user.isProtectedAdmin ? "owner" : "admin",
                            tint: AppTheme.primaryTint
                        )
                    }
                    if user.effectiveIsBlocked {
                        AdminStatusPill(text: "блок", tint: AppTheme.dangerTint)
                    }
                }

                Text(user.email)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.mutedTint)
                    .lineLimit(1)

                Text(user.isAdmin ? "Разрешений: \(user.permissionSet.count)" : user.jobTitle)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.mutedTint)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 7) {
                Text(adminFormattedDate(user.lastActiveAt) ?? "Нет активности")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.mutedTint)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedTint.opacity(0.75))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    private var statusTint: Color {
        if user.effectiveIsBlocked { return AppTheme.dangerTint }
        return user.isRecentlyActive ? .green : AppTheme.mutedTint.opacity(0.5)
    }
}

private enum AdminUserSheetDestination: String, Identifiable {
    case updateEmail
    case access
    case blockUntil
    case delete

    var id: String { rawValue }
}

private struct AdminUserDetailScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var user: AdminUserRecord
    @State private var customBlockUntil = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var sheet: AdminUserSheetDestination?

    let store: AdminUsersStore
    let currentUserID: String?
    let permissions: Set<AdminPermission>

    init(
        user: AdminUserRecord,
        store: AdminUsersStore,
        currentUserID: String?,
        permissions: Set<AdminPermission>
    ) {
        _user = State(initialValue: user)
        self.store = store
        self.currentUserID = currentUserID
        self.permissions = permissions
    }

    var body: some View {
        AppScreen {
            AppCard {
                HStack(spacing: 14) {
                    ProfileAvatar(size: 62, avatarUrl: user.avatarUrl)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(user.displayName)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(AppTheme.ink)
                        Text(user.email)
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.mutedTint)
                        HStack(spacing: 8) {
                            AdminStatusPill(text: user.isAdmin ? "admin" : "user", tint: AppTheme.primaryTint)
                            if user.isProtectedAdmin {
                                AdminStatusPill(text: "защищён", tint: AppTheme.secondaryTint)
                            }
                            if user.effectiveIsBlocked {
                                AdminStatusPill(text: "заблокирован", tint: AppTheme.dangerTint)
                            }
                        }
                    }
                }
            }

            AdminInfoCard(rows: userInfoRows)

            if !userProfileRows.isEmpty {
                AppSectionHeader(title: "Профиль", caption: "Данные, доступные для этого пользователя")
                AdminInfoCard(rows: userProfileRows)
            }

            if !userVehicleRows.isEmpty {
                AppSectionHeader(title: "Транспорт")
                AdminInfoCard(rows: userVehicleRows)
            }

            if user.isAdmin {
                AppSectionHeader(
                    title: "Права",
                    caption: user.isProtectedAdmin ? "Полный доступ владельца" : "Назначено: \(user.permissionSet.count)"
                )
                AdminPermissionsSummary(permissions: user.permissionSet)
            }

            if canNotify || canManageAccess || canBlock || canDelete {
                AppSectionHeader(title: "Управление")
                VStack(spacing: 0) {
                    if canNotify {
                        actionRow("Сообщить об обновлении", systemImage: "envelope.badge") {
                            sheet = .updateEmail
                        }
                    }

                    if canNotify && (canManageAccess || canBlock || canDelete) { Divider().padding(.leading, 54) }

                    if canManageAccess {
                        actionRow("Роль и разрешения", systemImage: "checkmark.shield") {
                            sheet = .access
                        }
                    }

                    if canManageAccess && (canBlock || canDelete) { Divider().padding(.leading, 54) }

                    if canBlock {
                        if user.effectiveIsBlocked {
                            actionRow("Разблокировать", systemImage: "lock.open.fill") {
                                Task { await updateBlock(until: nil) }
                            }
                        } else {
                            Menu {
                                Button("На 1 час") { Task { await updateBlock(until: Date().addingTimeInterval(3_600)) } }
                                Button("На 1 день") { Task { await updateBlock(until: Date().addingTimeInterval(86_400)) } }
                                Button("На 7 дней") { Task { await updateBlock(until: Date().addingTimeInterval(604_800)) } }
                                Button("На 30 дней") { Task { await updateBlock(until: Date().addingTimeInterval(2_592_000)) } }
                                Button("Выбрать дату") { sheet = .blockUntil }
                            } label: {
                                AdminActionRowLabel(title: "Заблокировать", systemImage: "lock.fill", tint: AppTheme.dangerTint)
                            }
                        }
                    }

                    if canDelete && (canManageAccess || canBlock) { Divider().padding(.leading, 54) }

                    if canDelete {
                        Button(role: .destructive) {
                            sheet = .delete
                        } label: {
                            AdminActionRowLabel(title: "Удалить пользователя", systemImage: "trash.fill", tint: AppTheme.dangerTint)
                        }
                    }
                }
                .background(AppTheme.cardSurface.opacity(0.82), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
            }

            if let error = store.errorMessage {
                AppNoticeBanner(text: error, tint: AppTheme.dangerTint, isCritical: true)
            }
        }
        .navigationTitle(user.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .appSidebarBackButton()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { user = await store.refreshUser(user) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(store.isLoading)
                .accessibilityLabel("Обновить пользователя")
            }
        }
        .sheet(item: $sheet) { destination in
            Group {
                switch destination {
                case .updateEmail:
                    AdminUpdateEmailSheet(initialTarget: .user(user.id), store: store)
                case .access:
                    AdminUserAccessSheet(user: user, store: store)
                case .blockUntil:
                    AdminUserBlockDateSheet(date: $customBlockUntil) { date in
                        Task { await updateBlock(until: date) }
                    }
                case .delete:
                    AdminUserDeleteSheet(user: user, store: store) {
                        dismiss()
                    }
                }
            }
            .appEditorSheetStyle()
        }
        .onChange(of: store.users) { _, users in
            if let updated = users.first(where: { $0.id == user.id }) { user = updated }
        }
        .task { user = await store.refreshUser(user) }
    }

    private var isMutableTarget: Bool {
        user.id != currentUserID && !user.isProtectedAdmin
    }
    private var canManageAccess: Bool { isMutableTarget && permissions.contains(.manageUserPermissions) }
    private var canNotify: Bool { permissions.contains(.notifyUsers) }
    private var canBlock: Bool { isMutableTarget && permissions.contains(.blockUsers) }
    private var canDelete: Bool { isMutableTarget && permissions.contains(.deleteUsers) }

    private func updateBlock(until blockedUntil: Date?) async {
        if let updated = await store.setBlocked(user: user, until: blockedUntil) { user = updated }
    }

    private func actionRow(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            AdminActionRowLabel(title: title, systemImage: systemImage, tint: AppTheme.primaryTint)
        }
    }

    private var userInfoRows: [AdminInfoRow] {
        [
            adminFormattedDate(user.registeredAt).map { AdminInfoRow(title: "Зарегистрирован", value: $0) },
            adminFormattedDate(user.lastActiveAt).map { AdminInfoRow(title: "Последняя активность", value: $0) },
            AdminInfoRow(title: "Версия приложения", value: user.appVersionDisplay),
            adminFormattedDate(user.appVersionSeenAt).map { AdminInfoRow(title: "Версия получена", value: $0) },
            AdminInfoRow(title: "Роль", value: user.isAdmin ? "Администратор" : "Пользователь"),
            AdminInfoRow(
                title: "Блокировка",
                value: user.effectiveIsBlocked ? (adminFormattedDate(user.blockedUntil) ?? "Без срока") : "Нет"
            )
        ]
        .compactMap { $0 }
    }

    private var userProfileRows: [AdminInfoRow] {
        guard let profile = user.profile else { return [] }

        return [
            profileRow("Имя", profile.fullName),
            profileRow("Должность", profile.jobTitle),
            profileRow("Подразделение", profile.departmentTitle),
            profileRow("Группа", profile.departmentGroup),
            profileRow("Табельный номер", profile.personnelNumber),
            profileRow("Город", profile.city),
            profileRow("Личный телефон", profile.personalPhone),
            profileRow("Рабочая почта", profile.workEmail),
        ].compactMap { $0 }
    }

    private var userVehicleRows: [AdminInfoRow] {
        guard let profile = user.profile else { return [] }

        return [
            profileRow("Автомобиль", profile.vehicleModel),
            profileRow("Госномер", profile.vehiclePlate),
            profileRow("VIN", profile.vehicleVin),
            profileRow("СТС", profile.vehicleSts),
            profileRow("ПТС", profile.vehiclePts),
            profileRow("Цвет", profile.vehicleColor),
            profileRow("Объём двигателя", profile.engineVolumeCm3),
            profileRow("Мощность двигателя", profile.enginePowerHp),
            profileRow("Начальный пробег", profile.initialMileageKm),
            profileRow("Склад", profile.routeWarehouseAddress),
            profileRow("Дом", profile.routeHomeAddress)
        ].compactMap { $0 }
    }

    private func profileRow(_ title: String, _ value: String?) -> AdminInfoRow? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return AdminInfoRow(title: title, value: value)
    }
}

private struct AdminActionRowLabel: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.12), in: Circle())
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.ink)
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(AppTheme.mutedTint)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 54)
        .contentShape(Rectangle())
    }
}

private struct AdminPermissionsSummary: View {
    let permissions: Set<AdminPermission>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(AdminPermissionGroup.allCases) { group in
                let groupPermissions = AdminPermission.allCases.filter { $0.group == group && permissions.contains($0) }
                if !groupPermissions.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(group.title).font(.caption.weight(.bold)).foregroundStyle(AppTheme.mutedTint)
                        Text(groupPermissions.map(\.title).joined(separator: " • "))
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.ink)
                    }
                }
            }
            if permissions.isEmpty {
                Text("Разрешения не назначены")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.mutedTint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AppTheme.cardSurface.opacity(0.82), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
    }
}

private struct AdminUserAccessSheet: View {
    @Environment(\.dismiss) private var dismiss
    let user: AdminUserRecord
    let store: AdminUsersStore

    @State private var isAdmin: Bool
    @State private var selectedPermissions: Set<AdminPermission>
    @State private var isSaving = false

    init(user: AdminUserRecord, store: AdminUsersStore) {
        self.user = user
        self.store = store
        _isAdmin = State(initialValue: user.isAdmin)
        _selectedPermissions = State(initialValue: user.permissionSet)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Администратор", isOn: $isAdmin)
                        .onChange(of: isAdmin) { _, enabled in
                            selectedPermissions = enabled ? Set(AdminPermission.allCases) : []
                        }
                } footer: {
                    Text("Без роли администратора пользователь не увидит раздел «Админка».")
                }

                if isAdmin {
                    ForEach(AdminPermissionGroup.allCases) { group in
                        Section(group.title) {
                            ForEach(AdminPermission.allCases.filter { $0.group == group }) { permission in
                                Toggle(isOn: permissionBinding(permission)) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(permission.title)
                                        Text(permission.detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Роль и права")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        Task { await save() }
                    }
                    .disabled(isSaving)
                }
            }
        }
    }

    private func permissionBinding(_ permission: AdminPermission) -> Binding<Bool> {
        Binding(
            get: { selectedPermissions.contains(permission) },
            set: { enabled in
                if enabled {
                    selectedPermissions.insert(permission)
                    if permission == .viewAuditLog { selectedPermissions.insert(.viewOverview) }
                    if permission == .replaceGsmTemplate { selectedPermissions.insert(.viewGsmTemplate) }
                    if permission.group == .users, permission != .viewUsers { selectedPermissions.insert(.viewUsers) }
                    if permission.group == .images, permission != .viewImages { selectedPermissions.insert(.viewImages) }
                    if permission == .manageAssistant { selectedPermissions.insert(.viewAssistant) }
                    if permission == .manageEngineerFiles { selectedPermissions.insert(.viewEngineerFiles) }
                } else {
                    selectedPermissions.remove(permission)
                    if permission == .viewOverview { selectedPermissions.remove(.viewAuditLog) }
                    if permission == .viewGsmTemplate { selectedPermissions.remove(.replaceGsmTemplate) }
                    if permission == .viewUsers {
                        selectedPermissions.subtract([.blockUsers, .manageUserPermissions, .deleteUsers])
                    }
                    if permission == .viewImages {
                        selectedPermissions.subtract([.createImages, .editImages, .deleteImages])
                    }
                    if permission == .viewAssistant { selectedPermissions.remove(.manageAssistant) }
                    if permission == .viewEngineerFiles { selectedPermissions.remove(.manageEngineerFiles) }
                }
            }
        )
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        if await store.setAccess(
            user: user,
            isAdmin: isAdmin,
            permissions: isAdmin ? selectedPermissions : []
        ) != nil {
            dismiss()
        }
    }
}

private struct AdminUserDeleteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isEmailFocused: Bool

    let user: AdminUserRecord
    let store: AdminUsersStore
    let onDeleted: () -> Void

    @State private var confirmationEmail = ""
    @State private var isDeleting = false

    private var normalizedConfirmationEmail: String {
        confirmationEmail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isConfirmed: Bool {
        normalizedConfirmationEmail.caseInsensitiveCompare(user.email) == .orderedSame
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(user.displayName)
                                .font(.headline)
                            Text(user.email)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        ProfileAvatar(size: 42, avatarUrl: user.avatarUrl)
                    }
                }

                Section {
                    TextField("Email пользователя", text: $confirmationEmail)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($isEmailFocused)
                } header: {
                    Text("Подтверждение")
                } footer: {
                    Text("Введите \(user.email), чтобы подтвердить необратимое удаление.")
                }

                Section {
                    Button(role: .destructive) {
                        Task { await deleteUser() }
                    } label: {
                        HStack {
                            if isDeleting {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Label("Удалить пользователя и данные", systemImage: "trash.fill")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(!isConfirmed || isDeleting)
                } footer: {
                    Text("Будут удалены профиль, сессии, маршруты, топливо, зарплата, автомобили и другие связанные записи.")
                        .foregroundStyle(AppTheme.dangerTint)
                }

                if let errorMessage = store.errorMessage {
                    AppNoticeBanner(
                        text: errorMessage,
                        tint: AppTheme.dangerTint,
                        isCritical: true,
                        style: .error
                    )
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.background)
            .navigationTitle("Удаление пользователя")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                        .disabled(isDeleting)
                }
            }
            .interactiveDismissDisabled(isDeleting)
            .task {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                isEmailFocused = true
            }
        }
    }

    private func deleteUser() async {
        guard isConfirmed else { return }
        isDeleting = true
        defer { isDeleting = false }

        if await store.delete(user, confirmationEmail: normalizedConfirmationEmail) {
            dismiss()
            onDeleted()
        }
    }
}

private struct AdminUserBlockDateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var date: Date
    let apply: (Date) -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                DatePicker(
                    "Заблокировать до",
                    selection: $date,
                    in: Date()...,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.graphical)
            }
            .padding(20)
            .navigationTitle("Срок блокировки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Применить") {
                        let selectedDate = date
                        dismiss()
                        apply(selectedDate)
                    }
                }
            }
        }
    }
}

private struct AdminInfoRow: Identifiable {
    var id: String { title }
    let title: String
    let value: String
}

private struct AdminInfoCard: View {
    let rows: [AdminInfoRow]

    var body: some View {
        AppCard {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider() }
                AppStatRow(title: row.title, value: row.value)
            }
        }
    }
}

private struct AdminStatusPill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

extension AppSessionStore {
    var isAdmin: Bool {
        session?.user.canAccessAdminPanel == true
    }

    func can(_ permission: AdminPermission) -> Bool {
        session?.user.can(permission) == true
    }
}

private extension AdminUserRecord {
    var isRecentlyActive: Bool {
        guard let lastActiveAt else { return false }
        return lastActiveAt >= Date().addingTimeInterval(-7 * 24 * 60 * 60)
    }

    init(raw: [String: Any]) {
        let id = adminString(raw, keys: ["id", "userId", "user_id", "_id"])
        let email = adminString(raw, keys: ["email", "mail", "login"])
        self.id = adminFirstNonEmpty(id, email)
        self.email = adminFirstNonEmpty(email, id)
        role = adminFirstNonEmpty(adminString(raw, keys: ["role"]), fallback: "user")
        adminPermissions = adminStringArray(raw["adminPermissions"] ?? raw["admin_permissions"])
        isProtectedAdmin = adminBool(raw, keys: ["isProtectedAdmin", "is_protected_admin"])
        let profileRaw = adminDictionary(from: raw, keys: ["profile", "userProfile", "user_profile"])
        profile = profileRaw.flatMap(adminUserProfile)
        avatarUrl = adminString(raw, keys: ["avatarUrl", "avatar_url", "avatar"])
        registeredAt = adminDate(raw, keys: ["registeredAt", "registered_at", "createdAt", "created_at"])
        lastActiveAt = adminDate(raw, keys: ["lastActiveAt", "last_active_at", "lastSeenAt", "last_seen_at"])
        appVersion = adminString(raw, keys: ["appVersion", "app_version", "lastAppVersion"])
        appBuild = adminString(raw, keys: ["appBuild", "app_build", "lastAppBuild"])
        appVersionSeenAt = adminDate(raw, keys: ["appVersionSeenAt", "app_version_seen_at", "lastAppSeenAt"])
        isBlocked = adminBool(raw, keys: ["isBlocked", "is_blocked", "blocked", "disabled"])
        blockedUntil = adminDate(raw, keys: ["blockedUntil", "blocked_until", "blockedTo", "blocked_to"])
    }
}

private func adminUserProfile(from raw: [String: Any]) -> UserProfileData {
    UserProfileData(
        firstName: adminString(raw, keys: ["firstName", "first_name"]),
        lastName: adminString(raw, keys: ["lastName", "last_name"]),
        middleName: adminString(raw, keys: ["middleName", "middle_name"]),
        jobTitle: adminString(raw, keys: ["jobTitle", "job_title", "title"]),
        departmentTitle: adminString(raw, keys: ["departmentTitle", "department_title"]),
        departmentGroup: adminString(raw, keys: ["departmentGroup", "department_group"]),
        personnelNumber: adminString(raw, keys: ["personnelNumber", "personnel_number"]),
        city: adminString(raw, keys: ["city", "workCity", "work_city"]),
        personalPhone: adminString(raw, keys: ["personalPhone", "personal_phone", "phone"]),
        workEmail: adminString(raw, keys: ["workEmail", "work_email"]),
        vehicleModel: adminString(raw, keys: ["vehicleModel", "vehicle_model"]),
        vehiclePlate: adminString(raw, keys: ["vehiclePlate", "vehicle_plate", "licensePlate", "license_plate"]),
        vehicleVin: adminString(raw, keys: ["vehicleVin", "vehicle_vin", "vin"]),
        vehicleSts: adminString(raw, keys: ["vehicleSts", "vehicle_sts", "sts"]),
        vehiclePts: adminString(raw, keys: ["vehiclePts", "vehicle_pts", "pts"]),
        vehicleColor: adminString(raw, keys: ["vehicleColor", "vehicle_color", "color"]),
        engineVolumeCm3: adminString(raw, keys: ["engineVolumeCm3", "engine_volume_cm3"]),
        enginePowerHp: adminString(raw, keys: ["enginePowerHp", "engine_power_hp"]),
        initialMileageKm: adminString(raw, keys: ["initialMileageKm", "initial_mileage_km"]),
        routeWarehouseAddress: adminString(raw, keys: ["routeWarehouseAddress", "route_warehouse_address"]),
        routeHomeAddress: adminString(raw, keys: ["routeHomeAddress", "route_home_address"])
    )
}

private func adminDictionary(from raw: Any?, keys: [String]) -> [String: Any]? {
    if let dictionary = raw as? [String: Any] {
        for key in keys {
            if let nested = dictionary[key] as? [String: Any] { return nested }
        }
        return dictionary
    }
    return nil
}

private func adminArray(from raw: Any?, keys: [String]) -> [[String: Any]] {
    if let array = raw as? [[String: Any]] { return array }
    guard let dictionary = raw as? [String: Any] else { return [] }
    for key in keys {
        if let array = dictionary[key] as? [[String: Any]] { return array }
        if let array = dictionary[key] as? [Any] { return array.compactMap { $0 as? [String: Any] } }
    }
    return []
}

private func adminString(_ raw: [String: Any], keys: [String]) -> String {
    for key in keys {
        if let value = raw[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        if let value = raw[key] as? NSNumber { return value.stringValue }
    }
    return ""
}

private func adminStringArray(_ raw: Any?) -> [String] {
    if let values = raw as? [String] { return values }
    if let values = raw as? [Any] { return values.compactMap { $0 as? String } }
    return []
}

private func adminBool(_ raw: [String: Any], keys: [String]) -> Bool {
    for key in keys {
        if let value = raw[key] as? Bool { return value }
        if let value = raw[key] as? NSNumber { return value.boolValue }
        if let value = raw[key] as? String {
            switch value.lowercased() {
            case "true", "1", "yes", "blocked": return true
            case "false", "0", "no", "active": return false
            default: break
            }
        }
    }
    return false
}

private func adminDate(_ raw: [String: Any], keys: [String]) -> Date? {
    for key in keys {
        guard let value = raw[key] else { continue }
        if let date = adminDate(from: value) { return date }
    }
    return nil
}

private func adminDate(from raw: Any) -> Date? {
    if let date = raw as? Date { return date }
    if let number = raw as? NSNumber {
        let value = number.doubleValue
        return Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1_000 : value)
    }
    guard let string = raw as? String else { return nil }
    for formatter in AdminUsersDateFormatters.iso {
        if let date = formatter.date(from: string) { return date }
    }
    for formatter in AdminUsersDateFormatters.input {
        if let date = formatter.date(from: string) { return date }
    }
    if let value = Double(string) {
        return Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1_000 : value)
    }
    return nil
}

private func adminFormattedDate(_ date: Date?) -> String? {
    guard let date else { return nil }
    return AdminUsersDateFormatters.output.string(from: date)
}

private func adminFirstNonEmpty(_ values: String..., fallback: String = "") -> String {
    values.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? fallback
}

private func normalizedAdminUserSearchText(_ raw: String) -> String {
    raw.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: AppLocale.russian)
        .lowercased()
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private enum AdminUsersDateFormatters {
    static let api: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let iso: [ISO8601DateFormatter] = {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return [fractional, standard]
    }()

    static let input: [DateFormatter] = [
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm:ss",
        "dd.MM.yyyy HH:mm:ss"
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    static let output: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = AppLocale.russian
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter
    }()
}
