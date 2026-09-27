import Charts
import Foundation
import Observation
import SwiftUI

private enum AdminAssistantPeriod: String, CaseIterable, Codable, Identifiable {
    case today
    case sevenDays = "7d"
    case month
    case thirtyDays = "30d"
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Сегодня"
        case .sevenDays: "7 дней"
        case .month: "Месяц"
        case .thirtyDays: "30 дней"
        case .all: "Всё время"
        }
    }
}

private struct AdminAssistantSnapshot: Codable {
    var period: AdminAssistantPeriodInfo
    var service: AdminAssistantService
    var settings: AdminAssistantSettings
    var summary: AdminAssistantSummary
    var stages: [AdminAssistantStage]
    var models: [AdminAssistantModel]
    var breakdowns: AdminAssistantBreakdowns
    var daily: [AdminAssistantDay]
    var users: [AdminAssistantUser]
}

private struct AdminAssistantPeriodInfo: Codable {
    var key: String
    var label: String
    var from: String?
    var to: String
}

private struct AdminAssistantService: Codable {
    var enabled: Bool
    var provider: String
    var endpointHost: String
    var routerModel: String
    var textModel: String
    var visionModel: String
    var reasoningEffort: String
    var routerMaxInputTokens: Int
    var routerMaxOutputTokens: Int
    var visionMaxTextInputTokens: Int
    var visionMaxOutputTokens: Int
    var textMaxInputTokens: Int
    var textMaxOutputTokens: Int
    var answerMaxCharacters: Int
    var contextMaxTokens: Int
    var documentMaxTokens: Int
    var contextMaxSources: Int
    var conversationTokenLimit: Int
    var conversationCompressionThreshold: Int
    var usageRetentionDays: Int
    var balance: Double?
    var budgetRemaining: Double?
    var balanceUpdatedAt: String?
}

private struct AdminAssistantSettings: Codable {
    var defaultSystemPrompt: String
    var classifierEnabled: Bool?
    var systemPrompt: String
    var usesDefaultSystemPrompt: Bool
    var additionalInstructions: String
    var synonyms: [AdminAssistantSynonym]
    var defaultLimits: AdminAssistantLimits
    var globalLimits: AdminAssistantLimits
    var updatedAt: String?
    var updatedByUserId: String?
}

private struct AdminAssistantSummary: Codable {
    var requests: Int
    var uniqueRequests: Int
    var pipelineEvents: Int?
    var uniqueUsers: Int
    var conversations: Int
    var storedConversations: Int
    var storedMessages: Int
    var blockedBeforeMainModel: Int
    var blockedSharePercent: Double
    var mainModelCalls: Int
    var visionCalls: Int
    var documentRequests: Int
    var streamedResponses: Int
    var contextCompressions: Int
    var errors: Int
    var replayedRequests: Int
    var deterministicAnswers: Int
    var toolRequests: Int
    var truncatedResponses: Int
    var inputTokens: Int
    var outputTokens: Int
    var cachedInputTokens: Int
    var reasoningTokens: Int
    var totalTokens: Int
    var actualCost: Double
    var estimatedCost: Double
    var totalCost: Double
    var currency: String
    var imageBytes: Int
    var documentBytes: Int
    var documentCharacters: Int
    var responseCharacters: Int
    var averageResponseCharacters: Double
    var averageLatencyMs: Double
    var maximumLatencyMs: Int
    var maximumRequestTokens: Int
    var maximumRequestCost: Double
}

private struct AdminAssistantStage: Codable, Identifiable {
    var key: String
    var label: String
    var calls: Int
    var inputTokens: Int
    var outputTokens: Int
    var cachedInputTokens: Int
    var reasoningTokens: Int
    var actualCost: Double
    var estimatedCost: Double
    var totalCost: Double

    var id: String { key }
}

private struct AdminAssistantModel: Codable, Identifiable {
    var stage: String
    var stageLabel: String
    var model: String
    var calls: Int
    var inputTokens: Int
    var outputTokens: Int
    var cachedInputTokens: Int
    var reasoningTokens: Int
    var actualCost: Double
    var estimatedCost: Double
    var totalCost: Double

    var id: String { "\(stage)-\(model)" }
}

private struct AdminAssistantBreakdowns: Codable {
    var outcomes: [AdminAssistantBreakdown]
    var routeReasons: [AdminAssistantBreakdown]
    var contexts: [AdminAssistantBreakdown]
    var finishReasons: [AdminAssistantBreakdown]
    var errors: [AdminAssistantBreakdown]
}

private struct AdminAssistantBreakdown: Codable, Identifiable {
    var key: String
    var label: String
    var count: Int
    var estimatedTokens: Int?

    var id: String { key }
}

private struct AdminAssistantDay: Codable, Identifiable {
    var date: String
    var requests: Int
    var tokens: Int
    var cost: Double
    var blocked: Int
    var vision: Int
    var documents: Int
    var streamed: Int
    var compression: Int
    var errors: Int

    var id: String { date }
}

private struct AdminAssistantUser: Codable, Identifiable {
    var userId: String
    var email: String
    var displayName: String
    var requests: Int
    var totalTokens: Int
    var inputTokens: Int
    var outputTokens: Int
    var cachedInputTokens: Int
    var actualCost: Double
    var estimatedCost: Double
    var totalCost: Double
    var mainModelCalls: Int
    var visionCalls: Int
    var documentRequests: Int
    var streamedResponses: Int
    var contextCompressions: Int
    var blockedRequests: Int
    var errors: Int
    var averageLatencyMs: Double
    var enabled: Bool
    var hasCustomLimits: Bool
    var limits: AdminAssistantLimits
    var effectiveLimits: AdminAssistantLimits

    var id: String { userId }
}

private struct AdminAssistantSynonym: Codable, Hashable, Identifiable {
    var id: String
    var canonical: String
    var aliases: [String]
    var note: String?
}

private struct AdminAssistantLimits: Codable, Hashable {
    var requestsPerMinute: Double?
    var dailyRequests: Double?
    var monthlyRequests: Double?
    var dailyTokens: Double?
    var monthlyTokens: Double?
    var dailyCost: Double?
    var monthlyCost: Double?
    var dailyVisionRequests: Double?
    var monthlyVisionRequests: Double?

    init(
        requestsPerMinute: Double? = nil,
        dailyRequests: Double? = nil,
        monthlyRequests: Double? = nil,
        dailyTokens: Double? = nil,
        monthlyTokens: Double? = nil,
        dailyCost: Double? = nil,
        monthlyCost: Double? = nil,
        dailyVisionRequests: Double? = nil,
        monthlyVisionRequests: Double? = nil
    ) {
        self.requestsPerMinute = requestsPerMinute
        self.dailyRequests = dailyRequests
        self.monthlyRequests = monthlyRequests
        self.dailyTokens = dailyTokens
        self.monthlyTokens = monthlyTokens
        self.dailyCost = dailyCost
        self.monthlyCost = monthlyCost
        self.dailyVisionRequests = dailyVisionRequests
        self.monthlyVisionRequests = monthlyVisionRequests
    }

    func dictionary(includeNulls: Bool) -> [String: Any] {
        var result: [String: Any] = [:]
        for spec in AdminAssistantLimitSpec.allCases {
            if let value = value(for: spec) {
                result[spec.rawValue] = value
            } else if includeNulls {
                result[spec.rawValue] = NSNull()
            }
        }
        return result
    }

    func value(for spec: AdminAssistantLimitSpec) -> Double? {
        switch spec {
        case .requestsPerMinute: requestsPerMinute
        case .dailyRequests: dailyRequests
        case .monthlyRequests: monthlyRequests
        case .dailyTokens: dailyTokens
        case .monthlyTokens: monthlyTokens
        case .dailyCost: dailyCost
        case .monthlyCost: monthlyCost
        case .dailyVisionRequests: dailyVisionRequests
        case .monthlyVisionRequests: monthlyVisionRequests
        }
    }

    mutating func set(_ value: Double?, for spec: AdminAssistantLimitSpec) {
        switch spec {
        case .requestsPerMinute: requestsPerMinute = value
        case .dailyRequests: dailyRequests = value
        case .monthlyRequests: monthlyRequests = value
        case .dailyTokens: dailyTokens = value
        case .monthlyTokens: monthlyTokens = value
        case .dailyCost: dailyCost = value
        case .monthlyCost: monthlyCost = value
        case .dailyVisionRequests: dailyVisionRequests = value
        case .monthlyVisionRequests: monthlyVisionRequests = value
        }
    }
}

private enum AdminAssistantLimitSpec: String, CaseIterable, Identifiable {
    case requestsPerMinute
    case dailyRequests
    case monthlyRequests
    case dailyTokens
    case monthlyTokens
    case dailyCost
    case monthlyCost
    case dailyVisionRequests
    case monthlyVisionRequests

    var id: String { rawValue }

    var title: String {
        switch self {
        case .requestsPerMinute: "Запросов в минуту"
        case .dailyRequests: "Запросов в день"
        case .monthlyRequests: "Запросов в месяц"
        case .dailyTokens: "Токенов в день"
        case .monthlyTokens: "Токенов в месяц"
        case .dailyCost: "Расход в день, ₽"
        case .monthlyCost: "Расход в месяц, ₽"
        case .dailyVisionRequests: "Изображений в день"
        case .monthlyVisionRequests: "Изображений в месяц"
        }
    }

    var isMoney: Bool {
        self == .dailyCost || self == .monthlyCost
    }
}

@MainActor
private struct AdminAssistantAPI {
    private let baseURL: URL
    private let http = HTTPClient()

    init(config: AppConfig) {
        baseURL = AppConfig.configuredURL(config.lumaWorkAPIOrigin)
    }

    func fetch(period: AdminAssistantPeriod, token: String) async throws -> AdminAssistantSnapshot {
        var components = URLComponents(
            url: url(path: "/api/v2/admin/assistant"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "period", value: period.rawValue)]
        let response = try await http.request(components.url!, authToken: token)
        return try decode(AdminAssistantSnapshot.self, from: response.json)
    }

    func updateSettings(body: [String: Any], token: String) async throws -> AdminAssistantSettings {
        let response = try await http.request(
            url(path: "/api/v2/admin/assistant/settings"),
            method: "PATCH",
            body: body,
            authToken: token
        )
        let envelope = try decode(AdminAssistantSettingsEnvelope.self, from: response.json)
        return envelope.settings
    }

    func updateUserLimit(
        userID: String,
        enabled: Bool,
        limits: AdminAssistantLimits,
        token: String
    ) async throws {
        _ = try await http.request(
            url(path: "/api/v2/admin/assistant/users/\(userID)/limit"),
            method: "PUT",
            body: ["enabled": enabled, "limits": limits.dictionary(includeNulls: false)],
            authToken: token
        )
    }

    func resetUserLimit(userID: String, token: String) async throws {
        _ = try await http.request(
            url(path: "/api/v2/admin/assistant/users/\(userID)/limit"),
            method: "DELETE",
            authToken: token
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, from json: Any?) throws -> T {
        guard let json else { throw AppServiceError.message("Сервер вернул пустой ответ.") }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(type, from: data)
    }

    private func url(path: String) -> URL {
        baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
}

private struct AdminAssistantSettingsEnvelope: Codable {
    var settings: AdminAssistantSettings
}

@MainActor
@Observable
private final class AdminAssistantStore {
    private let token: String?
    private let api: AdminAssistantAPI
    private let cacheID: String?
    private var latestSettings: AdminAssistantSettings? = nil

    var period: AdminAssistantPeriod = .month
    var snapshot: AdminAssistantSnapshot?
    var isLoading = false
    var isSaving = false
    var errorMessage: String?
    var notice: String?
    var lastUpdatedAt: Date?

    init(token: String?, cacheID: String? = nil) {
        self.token = token
        self.cacheID = cacheID
        api = AdminAssistantAPI(config: AppConfig())
        latestSettings = AppOfflineSnapshotStore.load(
            AdminAssistantSettings.self,
            key: settingsCacheKey
        )?.value
        restoreCachedSnapshot(for: period)
    }

    init(token: String?, cacheID: String? = nil, api: AdminAssistantAPI) {
        self.token = token
        self.cacheID = cacheID
        self.api = api
        latestSettings = AppOfflineSnapshotStore.load(
            AdminAssistantSettings.self,
            key: settingsCacheKey
        )?.value
        restoreCachedSnapshot(for: period)
    }

    func loadIfNeeded() async {
        await refresh(reportErrors: snapshot == nil)
    }

    func refresh(reportErrors: Bool = true) async {
        guard !isLoading, !isSaving else { return }
        guard let token, !token.isEmpty else {
            if reportErrors {
                errorMessage = "Требуется авторизация администратора."
            }
            return
        }
        let requestedPeriod = period
        isLoading = true
        if reportErrors {
            errorMessage = nil
        }
        defer { isLoading = false }
        do {
            let value = try await api.fetch(period: requestedPeriod, token: token)
            try apply(value, for: requestedPeriod)
        } catch is CancellationError {
            return
        } catch {
            guard period == requestedPeriod, reportErrors else { return }
            errorMessage = appUserFacingErrorMessage(error)
                ?? (snapshot == nil
                    ? "Не удалось загрузить статистику. Повторите запрос."
                    : "Не удалось обновить статистику. Показаны сохранённые данные.")
        }
    }

    func changePeriod(_ period: AdminAssistantPeriod) async {
        guard self.period != period, !isLoading, !isSaving else { return }
        self.period = period
        errorMessage = nil
        notice = nil
        restoreCachedSnapshot(for: period)
        await refresh()
    }

    func savePrompt(systemPrompt: String?, additionalInstructions: String?) async -> Bool {
        await saveSettings(
            body: [
                "systemPrompt": systemPrompt ?? NSNull(),
                "additionalInstructions": additionalInstructions ?? NSNull()
            ],
            successMessage: "Системный промпт и указания обновлены."
        )
    }

    func setClassifierEnabled(_ enabled: Bool) {
        guard !isSaving, snapshot != nil else { return }
        let previous = snapshot?.settings.classifierEnabled ?? true
        snapshot?.settings.classifierEnabled = enabled
        isSaving = true
        errorMessage = nil
        notice = nil

        Task { [weak self] in
            guard let self else { return }
            defer { isSaving = false }
            guard let token, !token.isEmpty else {
                snapshot?.settings.classifierEnabled = previous
                errorMessage = "Требуется авторизация администратора."
                return
            }

            do {
                let settings = try await api.updateSettings(
                    body: ["classifierEnabled": enabled],
                    token: token
                )
                guard settings.classifierEnabled == enabled else {
                    throw AppServiceError.message("Сервер не подтвердил изменение настройки.")
                }
                apply(settings: settings)
                let message = enabled
                    ? "Классификатор включён."
                    : "Классификатор отключён для тестирования."
                notice = message
                AppBannerCenter.shared.show(message, style: .success)
            } catch is CancellationError {
                snapshot?.settings.classifierEnabled = previous
            } catch {
                snapshot?.settings.classifierEnabled = previous
                errorMessage = appUserFacingErrorMessage(error)
                    ?? "Не удалось сохранить состояние классификатора."
                if let errorMessage {
                    AppBannerCenter.shared.show(errorMessage, style: .error)
                }
            }
        }
    }

    func saveSynonyms(_ synonyms: [AdminAssistantSynonym]) async -> Bool {
        let values = synonyms.map { term in
            [
                "id": term.id,
                "canonical": term.canonical,
                "aliases": term.aliases,
                "note": term.note ?? ""
            ] as [String: Any]
        }
        return await saveSettings(
            body: ["synonyms": values],
            successMessage: "Словарь терминов обновлён."
        )
    }

    func saveLimits(defaultLimits: AdminAssistantLimits, globalLimits: AdminAssistantLimits) async -> Bool {
        await saveSettings(
            body: [
                "defaultLimits": defaultLimits.dictionary(includeNulls: true),
                "globalLimits": globalLimits.dictionary(includeNulls: true)
            ],
            successMessage: "Общие лимиты ИИ обновлены."
        )
    }

    func saveUserLimit(user: AdminAssistantUser, enabled: Bool, limits: AdminAssistantLimits) async -> Bool {
        guard let token, !token.isEmpty else {
            errorMessage = "Требуется авторизация администратора."
            return false
        }
        return await saving(successMessage: "Лимиты пользователя обновлены.") {
            try await api.updateUserLimit(userID: user.userId, enabled: enabled, limits: limits, token: token)
            let requestedPeriod = period
            try apply(try await api.fetch(period: requestedPeriod, token: token), for: requestedPeriod)
        }
    }

    func resetUserLimit(user: AdminAssistantUser) async -> Bool {
        guard let token, !token.isEmpty else {
            errorMessage = "Требуется авторизация администратора."
            return false
        }
        return await saving(successMessage: "Для пользователя восстановлены общие лимиты.") {
            try await api.resetUserLimit(userID: user.userId, token: token)
            let requestedPeriod = period
            try apply(try await api.fetch(period: requestedPeriod, token: token), for: requestedPeriod)
        }
    }

    private func saveSettings(
        body: [String: Any],
        successMessage: String
    ) async -> Bool {
        guard let token, !token.isEmpty else {
            errorMessage = "Требуется авторизация администратора."
            return false
        }
        return await saving(successMessage: successMessage) {
            let settings = try await api.updateSettings(body: body, token: token)
            apply(settings: settings)
        }
    }

    private func saving(successMessage: String, operation: () async throws -> Void) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        errorMessage = nil
        notice = nil
        defer { isSaving = false }
        do {
            try await operation()
            notice = successMessage
            AppBannerCenter.shared.show(successMessage, style: .success)
            return true
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
            if let errorMessage {
                AppBannerCenter.shared.show(errorMessage, style: .error)
            }
            return false
        }
    }

    private func restoreCachedSnapshot(for period: AdminAssistantPeriod) {
        guard let cached = AppOfflineSnapshotStore.load(
            AdminAssistantSnapshot.self,
            key: cacheKey(for: period)
        ), cached.value.period.key == period.rawValue else {
            snapshot = nil
            lastUpdatedAt = nil
            return
        }
        var value = cached.value
        if let latestSettings {
            value.settings = latestSettings
        }
        snapshot = value
        lastUpdatedAt = cached.updatedAt
    }

    private func apply(_ value: AdminAssistantSnapshot, for requestedPeriod: AdminAssistantPeriod) throws {
        guard value.period.key == requestedPeriod.rawValue else {
            throw AppServiceError.message("Сервер вернул статистику за другой период.")
        }
        let updatedAt = Date()
        AppOfflineSnapshotStore.save(value, key: cacheKey(for: requestedPeriod))
        latestSettings = value.settings
        AppOfflineSnapshotStore.save(value.settings, key: settingsCacheKey)
        guard period == requestedPeriod else { return }
        snapshot = value
        lastUpdatedAt = updatedAt
        errorMessage = nil
    }

    private func apply(settings: AdminAssistantSettings) {
        latestSettings = settings
        snapshot?.settings = settings
        AppOfflineSnapshotStore.save(settings, key: settingsCacheKey)
    }

    private func cacheKey(for period: AdminAssistantPeriod) -> String {
        AppOfflineSnapshotStore.scopedKey(
            "admin-assistant-\(period.rawValue)",
            userID: cacheID
        )
    }

    private var settingsCacheKey: String {
        AppOfflineSnapshotStore.scopedKey("admin-assistant-settings", userID: cacheID)
    }
}

struct AdminAssistantScreen: View {
    @State private var store: AdminAssistantStore
    private let canManage: Bool

    init(token: String?, cacheID: String?, canManage: Bool) {
        _store = State(initialValue: AdminAssistantStore(token: token, cacheID: cacheID))
        self.canManage = canManage
    }

    var body: some View {
        AppScreen {
            AdminAssistantPeriodFilter(store: store)

            if let errorMessage = store.errorMessage {
                AppNoticeBanner(text: errorMessage, tint: AppTheme.dangerTint, isCritical: true)
            }
            if let notice = store.notice {
                AppNoticeBanner(text: notice, tint: .green)
            }

            if let snapshot = store.snapshot {
                AdminAssistantBalanceCard(
                    service: snapshot.service,
                    summary: snapshot.summary,
                    period: snapshot.period,
                    days: snapshot.daily
                )
                AdminAssistantOverviewCards(snapshot: snapshot)
                AdminAssistantTrendPreview(days: snapshot.daily)

                AppSectionHeader(title: "Аналитика", caption: "Подробности разнесены по отдельным экранам")
                AppCard {
                    NavigationLink {
                        AdminAssistantAnalyticsScreen(snapshot: snapshot)
                    } label: {
                        AdminAssistantNavigationRow(
                            title: "Расход и токены",
                            subtitle: "Интерактивные диаграммы по этапам и результатам",
                            icon: "chart.pie.fill",
                            tint: .purple
                        )
                    }
                    Divider()
                    NavigationLink {
                        AdminAssistantDailyAnalyticsScreen(days: snapshot.daily)
                    } label: {
                        AdminAssistantNavigationRow(
                            title: "Динамика по дням",
                            subtitle: "Расход, токены и запросы",
                            icon: "chart.xyaxis.line",
                            tint: AppTheme.primaryTint
                        )
                    }
                    Divider()
                    NavigationLink {
                        AdminAssistantModelsScreen(snapshot: snapshot)
                    } label: {
                        AdminAssistantNavigationRow(
                            title: "Модели и этапы",
                            subtitle: "Вызовы, стоимость и лимиты обработки",
                            icon: "cpu.fill",
                            tint: .orange
                        )
                    }
                    Divider()
                    NavigationLink {
                        AdminAssistantRoutingScreen(breakdowns: snapshot.breakdowns)
                    } label: {
                        AdminAssistantNavigationRow(
                            title: "Маршрутизация и источники",
                            subtitle: "Решения, контекст и ошибки",
                            icon: "arrow.triangle.branch",
                            tint: .teal
                        )
                    }
                    Divider()
                    NavigationLink {
                        AdminAssistantDetailedMetricsScreen(summary: snapshot.summary)
                    } label: {
                        AdminAssistantNavigationRow(
                            title: "Все показатели",
                            subtitle: "Полная техническая статистика периода",
                            icon: "list.bullet.rectangle.portrait.fill",
                            tint: AppTheme.mutedTint
                        )
                    }
                }

                AppSectionHeader(
                    title: "Управление",
                    caption: canManage ? "Настройки применяются без нового деплоя" : "Доступен только просмотр"
                )
                AppCard {
                    Toggle(isOn: Binding(
                        get: { store.snapshot?.settings.classifierEnabled ?? true },
                        set: { store.setClassifierEnabled($0) }
                    )) {
                        AdminAssistantNavigationRow(
                            title: "Классификатор",
                            subtitle: (snapshot.settings.classifierEnabled ?? true)
                                ? "Проверяет тематику и выбирает источники"
                                : "Тестовый режим: Wiki и источники выбираются без LLM-классификатора",
                            icon: "point.3.connected.trianglepath.dotted",
                            tint: (snapshot.settings.classifierEnabled ?? true) ? .green : .orange,
                            showsChevron: false
                        )
                    }
                    .disabled(!canManage || store.isSaving)
                    Divider()
                    NavigationLink {
                        AdminAssistantPromptEditor(settings: snapshot.settings, store: store, canManage: canManage)
                    } label: {
                        AdminAssistantNavigationRow(
                            title: "Системный промпт",
                            subtitle: snapshot.settings.usesDefaultSystemPrompt ? "Используется стандартный" : "Задан администратором",
                            icon: "text.quote",
                            tint: .purple
                        )
                    }
                    Divider()
                    NavigationLink {
                        AdminAssistantSynonymScreen(settings: snapshot.settings, store: store, canManage: canManage)
                    } label: {
                        AdminAssistantNavigationRow(
                            title: "Словарь терминов",
                            subtitle: "\(snapshot.settings.synonyms.count) соответствий",
                            icon: "character.book.closed.fill",
                            tint: .purple
                        )
                    }
                    Divider()
                    NavigationLink {
                        AdminAssistantLimitsScreen(settings: snapshot.settings, store: store, canManage: canManage)
                    } label: {
                        AdminAssistantNavigationRow(
                            title: "Общие лимиты",
                            subtitle: "Пользовательские и глобальные ограничения",
                            icon: "gauge.with.dots.needle.33percent",
                            tint: .purple
                        )
                    }
                }

                AppSectionHeader(title: "Доступ и система")
                AppCard {
                    NavigationLink {
                        AdminAssistantUsersScreen(users: snapshot.users, store: store, canManage: canManage)
                    } label: {
                        AdminAssistantNavigationRow(
                            title: "Пользователи",
                            subtitle: "\(snapshot.users.count) аккаунтов и персональные лимиты",
                            icon: "person.2.fill",
                            tint: .orange
                        )
                    }
                    Divider()
                    NavigationLink {
                        AdminAssistantServiceScreen(service: snapshot.service)
                    } label: {
                        AdminAssistantNavigationRow(
                            title: "Конфигурация моделей",
                            subtitle: "Провайдер, модели и технические лимиты",
                            icon: "server.rack",
                            tint: snapshot.service.enabled ? .green : AppTheme.dangerTint
                        )
                    }
                }
            } else if store.isLoading {
                AppLoadingView(title: "Загружаю статистику ИИ")
            } else {
                AdminAssistantUnavailableState(
                    message: store.errorMessage ?? "Сервер не вернул статистику ИИ."
                ) {
                    AppHaptics.trigger()
                    Task { await store.refresh() }
                }
            }
        }
        .navigationTitle("Модель и расходы")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    AppHaptics.trigger()
                    Task { await store.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(store.isLoading || store.isSaving)
                .accessibilityLabel("Обновить статистику ИИ")
            }
        }
        .refreshable { await store.refresh() }
        .task { await store.loadIfNeeded() }
    }
}

private struct AdminAssistantPeriodFilter: View {
    let store: AdminAssistantStore

    private var subtitle: String {
        guard let updatedAt = store.lastUpdatedAt else {
            return "Фильтр применяется ко всей аналитике"
        }
        return "Обновлено \(updatedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    var body: some View {
        AppCard {
            HStack(spacing: 12) {
                Image(systemName: "calendar.badge.clock")
                    .font(.headline)
                    .foregroundStyle(AppTheme.primaryTint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Период")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedTint)
                }
                Spacer()
                if store.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Обновление статистики")
                }
                Picker("Период статистики", selection: Binding(
                    get: { store.period },
                    set: { value in Task { await store.changePeriod(value) } }
                )) {
                    ForEach(AdminAssistantPeriod.allCases) { period in
                        Text(period.title).tag(period)
                    }
                }
                .pickerStyle(.menu)
                .disabled(store.isLoading || store.isSaving)
            }
        }
    }
}

private struct AdminAssistantUnavailableState: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        AppCard {
            VStack(spacing: 12) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(AppTheme.secondaryTint)
                Text("Статистика недоступна")
                    .font(.headline)
                    .foregroundStyle(AppTheme.ink)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.mutedTint)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Повторить", systemImage: "arrow.clockwise", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }
}

private struct AdminAssistantBalanceCard: View {
    let service: AdminAssistantService
    let summary: AdminAssistantSummary
    let period: AdminAssistantPeriodInfo
    let days: [AdminAssistantDay]

    private var averageDailyCost: Double {
        guard !days.isEmpty else { return 0 }
        return days.reduce(0) { $0 + $1.cost } / Double(days.count)
    }

    private var forecastDays: Int? {
        guard let balance = service.balance, balance > 0, averageDailyCost > 0 else { return nil }
        return max(Int(balance / averageDailyCost), 0)
    }

    var body: some View {
        AppCard {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "rublesign.circle.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(service.balance == nil ? AppTheme.mutedTint : Color.green)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Баланс AITunnel")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedTint)
                    Text(service.balance.map(adminAssistantMoney) ?? "Недоступен")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(AppTheme.ink)
                        .contentTransition(.numericText())
                }
                Spacer()
                Text(service.enabled ? "Подключён" : "Отключён")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(service.enabled ? Color.green : AppTheme.dangerTint)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background((service.enabled ? Color.green : AppTheme.dangerTint).opacity(0.10), in: Capsule())
            }
            Divider()
            AppStatRow(title: "Расход — \(period.label.lowercased())", value: adminAssistantMoney(summary.totalCost), accent: .green)
            if averageDailyCost > 0 {
                AppStatRow(title: "Средний расход в день", value: adminAssistantMoney(averageDailyCost))
            }
            if let forecastDays {
                AppStatRow(title: "Прогноз запаса", value: "≈ \(forecastDays.formatted()) дн.")
            }
            if let budget = service.budgetRemaining {
                AppStatRow(title: "Лимит API-ключа", value: adminAssistantMoney(budget))
            }
            if let updatedAt = service.balanceUpdatedAt {
                Text("Баланс обновлён \(adminAssistantDateTime(updatedAt))")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.mutedTint)
            } else {
                Text("Баланс появится после ответа провайдера; API-ключ в приложение не передаётся.")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.mutedTint)
            }
        }
    }
}

private struct AdminAssistantOverviewCards: View {
    let snapshot: AdminAssistantSnapshot

    private var averageDailyCost: Double {
        guard !snapshot.daily.isEmpty else { return 0 }
        return snapshot.summary.totalCost / Double(snapshot.daily.count)
    }

    private var averageRequestCost: Double {
        guard snapshot.summary.requests > 0 else { return 0 }
        return snapshot.summary.totalCost / Double(snapshot.summary.requests)
    }

    private var topCostModel: AdminAssistantModel? {
        snapshot.models.max { $0.totalCost < $1.totalCost }
    }

    private var topTokenModel: AdminAssistantModel? {
        snapshot.models.max { modelTokens($0) < modelTokens($1) }
    }

    var body: some View {
        AppSectionHeader(title: "Сводка", caption: "Главное за выбранный период")
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            metric("Расход", adminAssistantMoney(snapshot.summary.totalCost), snapshot.period.label, "rublesign.circle.fill", .green)
            metric("Среднее в день", adminAssistantMoney(averageDailyCost), "по дням с данными", "calendar", AppTheme.primaryTint)
            metric("Среднее за запрос", adminAssistantMoney(averageRequestCost), "\(adminAssistantNumber(snapshot.summary.requests)) запросов", "divide.circle.fill", .purple)
            metric("Токены", adminAssistantNumber(snapshot.summary.totalTokens), "всего обработано", "number.circle.fill", .orange)
            metric(
                "Топ по расходу",
                topCostModel.map { adminAssistantMoney($0.totalCost) } ?? "—",
                topCostModel?.model ?? "Нет вызовов",
                "flame.fill",
                .pink
            )
            metric(
                "Топ по токенам",
                topTokenModel.map { adminAssistantNumber(modelTokens($0)) } ?? "—",
                topTokenModel?.model ?? "Нет вызовов",
                "cpu.fill",
                .teal
            )
        }
    }

    private func metric(_ title: String, _ value: String, _ detail: String, _ icon: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: icon).foregroundStyle(tint)
                Spacer()
                Text(title.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppTheme.mutedTint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            Text(value)
                .font(.headline.weight(.bold))
                .foregroundStyle(AppTheme.ink)
                .contentTransition(.numericText())
            Text(detail)
                .font(.caption2)
                .foregroundStyle(AppTheme.mutedTint)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 102, alignment: .leading)
        .background(AppTheme.cardSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
    }

    private func modelTokens(_ model: AdminAssistantModel) -> Int {
        model.inputTokens + model.outputTokens + model.reasoningTokens
    }
}

private struct AdminAssistantTrendPreview: View {
    let days: [AdminAssistantDay]
    @State private var isVisible = false

    private var visibleDays: [AdminAssistantDay] {
        Array(days.suffix(14))
    }

    var body: some View {
        if !visibleDays.isEmpty {
            AppSectionHeader(title: "Динамика расхода", caption: "Последние \(visibleDays.count) дней выбранного периода")
            AppCard {
                Chart(visibleDays) { day in
                    if let date = adminAssistantParsedDate(day.date) {
                        AreaMark(
                            x: .value("День", date, unit: .day),
                            y: .value("Расход", isVisible ? day.cost : 0)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [AppTheme.primaryTint.opacity(0.30), AppTheme.primaryTint.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        LineMark(
                            x: .value("День", date, unit: .day),
                            y: .value("Расход", isVisible ? day.cost : 0)
                        )
                        .foregroundStyle(AppTheme.primaryTint)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    }
                }
                .chartLegend(.hidden)
                .frame(height: 150)

                NavigationLink {
                    AdminAssistantDailyAnalyticsScreen(days: days)
                } label: {
                    HStack {
                        Text("Открыть подробную динамику")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(AppTheme.primaryTint)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .onAppear {
                withAnimation(.snappy(duration: 0.55)) { isVisible = true }
            }
        }
    }
}

private struct AdminAssistantNavigationRow: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    var showsChevron = true

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.ink)
                Text(subtitle).font(.caption).foregroundStyle(AppTheme.mutedTint).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedTint.opacity(0.62))
            }
        }
        .contentShape(Rectangle())
    }
}

private enum AdminAssistantStageMetric: String, CaseIterable, Identifiable {
    case cost
    case tokens
    case calls

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cost: "Расход"
        case .tokens: "Токены"
        case .calls: "Вызовы"
        }
    }
}

private struct AdminAssistantAnalyticsScreen: View {
    let snapshot: AdminAssistantSnapshot

    var body: some View {
        AppScreen {
            AdminAssistantStageDonut(stages: snapshot.stages)
            AdminAssistantModelDonut(models: snapshot.models)
            AdminAssistantOutcomeDonut(values: snapshot.breakdowns.outcomes)

            AppSectionHeader(title: "Ключевые показатели")
            AppCard {
                AppStatRow(title: "Расход", value: adminAssistantMoney(snapshot.summary.totalCost), accent: .green)
                AppStatRow(title: "Токены", value: adminAssistantNumber(snapshot.summary.totalTokens))
                AppStatRow(title: "Запросы", value: adminAssistantNumber(snapshot.summary.requests))
                AppStatRow(title: "Вызовы основной модели", value: adminAssistantNumber(snapshot.summary.mainModelCalls))
                AppStatRow(title: "Среднее время ответа", value: adminAssistantDuration(snapshot.summary.averageLatencyMs))
                AppStatRow(
                    title: "Заблокировано до основной модели",
                    value: "\(adminAssistantNumber(snapshot.summary.blockedBeforeMainModel)) • \(snapshot.summary.blockedSharePercent.formatted(.number.precision(.fractionLength(1))))%"
                )
            }
        }
        .navigationTitle("Расход и токены")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AdminAssistantStageDonut: View {
    let stages: [AdminAssistantStage]
    @State private var metric: AdminAssistantStageMetric = .cost
    @State private var excluded = Set<String>()
    @State private var isVisible = false

    private var total: Double {
        stages.reduce(0) { result, stage in
            result + (excluded.contains(stage.key) ? 0 : value(for: stage))
        }
    }

    var body: some View {
        AppSectionHeader(title: "По этапам", caption: "Нажмите этап, чтобы исключить его из диаграммы")
        AppCard {
            Picker("Показатель", selection: $metric) {
                ForEach(AdminAssistantStageMetric.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)

            ZStack {
                Circle()
                    .stroke(AppTheme.border.opacity(0.55), lineWidth: 32)
                    .frame(width: 178, height: 178)

                Chart(stages) { stage in
                    SectorMark(
                        angle: .value("Значение", isVisible && !excluded.contains(stage.key) ? value(for: stage) : 0),
                        innerRadius: .ratio(0.64),
                        angularInset: 2.2
                    )
                    .cornerRadius(5)
                    .foregroundStyle(adminAssistantStageColor(stage.key))
                }
                .chartLegend(.hidden)
                .frame(width: 210, height: 210)

                VStack(spacing: 3) {
                    Text(metric.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedTint)
                    Text(totalText)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AppTheme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .contentTransition(.numericText(value: total))
                }
                .padding(.horizontal, 42)
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 3) {
                ForEach(stages) { stage in
                    Button {
                        AppHaptics.trigger(.expandCollapse)
                        withAnimation(.snappy(duration: 0.42, extraBounce: 0.06)) {
                            if excluded.contains(stage.key) {
                                excluded.remove(stage.key)
                            } else {
                                excluded.insert(stage.key)
                            }
                        }
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: excluded.contains(stage.key) ? "circle" : "checkmark.circle.fill")
                                .foregroundStyle(adminAssistantStageColor(stage.key))
                            Text(stage.label)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(excluded.contains(stage.key) ? AppTheme.mutedTint : AppTheme.ink)
                            Spacer()
                            Text(valueText(for: stage))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.mutedTint)
                        }
                        .frame(minHeight: 38)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(9)
            .background(AppTheme.subpanelSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .onAppear {
            withAnimation(.snappy(duration: 0.6, extraBounce: 0.05)) {
                isVisible = true
            }
        }
        .animation(.snappy(duration: 0.42, extraBounce: 0.06), value: metric)
    }

    private var totalText: String {
        switch metric {
        case .cost: adminAssistantMoney(total)
        case .tokens, .calls: adminAssistantNumber(Int(total))
        }
    }

    private func value(for stage: AdminAssistantStage) -> Double {
        switch metric {
        case .cost: stage.totalCost
        case .tokens: Double(stage.inputTokens + stage.outputTokens + stage.reasoningTokens)
        case .calls: Double(stage.calls)
        }
    }

    private func valueText(for stage: AdminAssistantStage) -> String {
        switch metric {
        case .cost: adminAssistantMoney(value(for: stage))
        case .tokens: "\(adminAssistantNumber(Int(value(for: stage)))) токенов"
        case .calls: "\(adminAssistantNumber(Int(value(for: stage)))) вызовов"
        }
    }
}

private struct AdminAssistantModelSlice: Identifiable {
    let model: String
    let value: Double

    var id: String { model }
}

private struct AdminAssistantModelDonut: View {
    let models: [AdminAssistantModel]
    @State private var metric: AdminAssistantStageMetric = .cost
    @State private var excluded = Set<String>()
    @State private var isVisible = false

    private var slices: [AdminAssistantModelSlice] {
        let grouped = Dictionary(grouping: models, by: \.model)
        return grouped.map { model, rows in
            AdminAssistantModelSlice(
                model: model,
                value: rows.reduce(0) { $0 + value(for: $1) }
            )
        }
        .sorted { left, right in
            if left.value == right.value { return left.model < right.model }
            return left.value > right.value
        }
    }

    private var total: Double {
        slices.reduce(0) { $0 + (excluded.contains($1.model) ? 0 : $1.value) }
    }

    var body: some View {
        AppSectionHeader(title: "По моделям", caption: "Фильтры влияют на диаграмму и итог")
        AppCard {
            if slices.isEmpty {
                Text("За выбранный период вызовов моделей не было.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.mutedTint)
            } else {
                Picker("Показатель", selection: $metric) {
                    ForEach(AdminAssistantStageMetric.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                ZStack {
                    Circle()
                        .stroke(AppTheme.border.opacity(0.55), lineWidth: 32)
                        .frame(width: 178, height: 178)

                    Chart(slices) { slice in
                        SectorMark(
                            angle: .value("Значение", isVisible && !excluded.contains(slice.model) ? slice.value : 0),
                            innerRadius: .ratio(0.64),
                            angularInset: 2.2
                        )
                        .cornerRadius(5)
                        .foregroundStyle(color(for: slice.model))
                    }
                    .chartLegend(.hidden)
                    .frame(width: 210, height: 210)

                    VStack(spacing: 3) {
                        Text(metric.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.mutedTint)
                        Text(totalText)
                            .font(.headline.weight(.bold))
                            .foregroundStyle(AppTheme.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                            .contentTransition(.numericText(value: total))
                    }
                    .padding(.horizontal, 42)
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 3) {
                    ForEach(slices) { slice in
                        Button {
                            AppHaptics.trigger(.expandCollapse)
                            withAnimation(.snappy(duration: 0.42, extraBounce: 0.06)) {
                                if excluded.contains(slice.model) {
                                    excluded.remove(slice.model)
                                } else {
                                    excluded.insert(slice.model)
                                }
                            }
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: excluded.contains(slice.model) ? "circle" : "checkmark.circle.fill")
                                    .foregroundStyle(color(for: slice.model))
                                Text(slice.model)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(excluded.contains(slice.model) ? AppTheme.mutedTint : AppTheme.ink)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(valueText(slice.value))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AppTheme.mutedTint)
                            }
                            .frame(minHeight: 38)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(9)
                .background(AppTheme.subpanelSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .onAppear {
            withAnimation(.snappy(duration: 0.6, extraBounce: 0.05)) { isVisible = true }
        }
        .animation(.snappy(duration: 0.42, extraBounce: 0.06), value: metric)
    }

    private var totalText: String { valueText(total) }

    private func value(for model: AdminAssistantModel) -> Double {
        switch metric {
        case .cost: model.totalCost
        case .tokens: Double(model.inputTokens + model.outputTokens + model.reasoningTokens)
        case .calls: Double(model.calls)
        }
    }

    private func valueText(_ value: Double) -> String {
        switch metric {
        case .cost: adminAssistantMoney(value)
        case .tokens: "\(adminAssistantNumber(Int(value))) токенов"
        case .calls: "\(adminAssistantNumber(Int(value))) вызовов"
        }
    }

    private func color(for model: String) -> Color {
        let index = slices.firstIndex { $0.model == model } ?? 0
        return adminAssistantModelColor(index)
    }
}

private struct AdminAssistantOutcomeDonut: View {
    let values: [AdminAssistantBreakdown]
    @State private var isVisible = false

    private var total: Int { values.reduce(0) { $0 + $1.count } }

    var body: some View {
        AppSectionHeader(title: "Результаты запросов")
        AppCard {
            ZStack {
                Circle()
                    .stroke(AppTheme.border.opacity(0.55), lineWidth: 28)
                    .frame(width: 158, height: 158)
                Chart(values) { value in
                    SectorMark(
                        angle: .value("Запросы", isVisible ? value.count : 0),
                        innerRadius: .ratio(0.66),
                        angularInset: 2
                    )
                    .cornerRadius(5)
                    .foregroundStyle(adminAssistantOutcomeColor(value.key))
                }
                .chartLegend(.hidden)
                .frame(width: 188, height: 188)
                VStack(spacing: 2) {
                    Text(adminAssistantNumber(total)).font(.headline.weight(.bold)).foregroundStyle(AppTheme.ink)
                    Text("запросов").font(.caption).foregroundStyle(AppTheme.mutedTint)
                }
            }
            .frame(maxWidth: .infinity)

            ForEach(values.prefix(6)) { value in
                HStack(spacing: 9) {
                    Circle().fill(adminAssistantOutcomeColor(value.key)).frame(width: 9, height: 9)
                    Text(value.label).font(.caption).foregroundStyle(AppTheme.ink)
                    Spacer()
                    Text(adminAssistantNumber(value.count)).font(.caption.weight(.semibold)).foregroundStyle(AppTheme.mutedTint)
                }
            }
        }
        .onAppear {
            withAnimation(.snappy(duration: 0.6, extraBounce: 0.05)) {
                isVisible = true
            }
        }
    }
}

private enum AdminAssistantDailyMetric: String, CaseIterable, Identifiable {
    case cost
    case tokens
    case requests

    var id: String { rawValue }
    var title: String {
        switch self {
        case .cost: "Расход"
        case .tokens: "Токены"
        case .requests: "Запросы"
        }
    }
}

private struct AdminAssistantDailyAnalyticsScreen: View {
    let days: [AdminAssistantDay]
    @State private var metric: AdminAssistantDailyMetric = .cost
    @State private var isVisible = false

    var body: some View {
        AppScreen {
            AppCard {
                Picker("Показатель", selection: $metric) {
                    ForEach(AdminAssistantDailyMetric.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                Chart(Array(days.suffix(31))) { day in
                    if let date = adminAssistantParsedDate(day.date) {
                        BarMark(
                            x: .value("День", date, unit: .day),
                            y: .value(metric.title, isVisible ? value(for: day) : 0)
                        )
                        .foregroundStyle(AppTheme.primaryTint.gradient)
                        .cornerRadius(3)
                    }
                }
                .chartLegend(.hidden)
                .frame(height: 230)
                .animation(.snappy(duration: 0.45), value: metric)

                HStack {
                    Text("Итого")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedTint)
                    Spacer()
                    Text(totalText)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AppTheme.ink)
                        .contentTransition(.numericText())
                }
            }

            AdminAssistantDailySection(days: days)
        }
        .navigationTitle("Динамика по дням")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            withAnimation(.snappy(duration: 0.55)) { isVisible = true }
        }
    }

    private var total: Double { days.reduce(0) { $0 + value(for: $1) } }
    private var totalText: String {
        switch metric {
        case .cost: adminAssistantMoney(total)
        case .tokens, .requests: adminAssistantNumber(Int(total))
        }
    }

    private func value(for day: AdminAssistantDay) -> Double {
        switch metric {
        case .cost: day.cost
        case .tokens: Double(day.tokens)
        case .requests: Double(day.requests)
        }
    }
}

private struct AdminAssistantModelsScreen: View {
    let snapshot: AdminAssistantSnapshot

    var body: some View {
        AppScreen {
            AdminAssistantStageSection(stages: snapshot.stages)
            AdminAssistantModelSection(models: snapshot.models)
        }
        .navigationTitle("Модели и этапы")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AdminAssistantRoutingScreen: View {
    let breakdowns: AdminAssistantBreakdowns

    var body: some View {
        AppScreen {
            AdminAssistantBreakdownSection(breakdowns: breakdowns)
        }
        .navigationTitle("Маршрутизация")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AdminAssistantDetailedMetricsScreen: View {
    let summary: AdminAssistantSummary

    var body: some View {
        AppScreen {
            AdminAssistantSummaryCards(summary: summary)
        }
        .navigationTitle("Все показатели")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AdminAssistantUsersScreen: View {
    let users: [AdminAssistantUser]
    let store: AdminAssistantStore
    let canManage: Bool

    var body: some View {
        AppScreen {
            AdminAssistantUserSection(users: users, store: store, canManage: canManage)
        }
        .navigationTitle("Пользователи ИИ")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AdminAssistantServiceScreen: View {
    let service: AdminAssistantService

    var body: some View {
        AppScreen {
            AdminAssistantServiceCard(service: service)
        }
        .navigationTitle("Конфигурация моделей")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AdminAssistantServiceCard: View {
    let service: AdminAssistantService

    var body: some View {
        AppSectionHeader(title: "Состояние модели", caption: "Конфигурация без секретного API-ключа")
        AppCard {
            Label(service.enabled ? "ИИ подключён" : "ИИ отключён", systemImage: service.enabled ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.headline)
                .foregroundStyle(service.enabled ? Color.green : AppTheme.dangerTint)
            AppStatRow(title: "Провайдер", value: service.provider)
            AppStatRow(title: "Сервер провайдера", value: service.endpointHost)
            AppStatRow(title: "Классификатор", value: service.routerModel)
            AppStatRow(title: "Текстовая модель", value: service.textModel)
            AppStatRow(title: "Модель изображений", value: service.visionModel)
            AppStatRow(title: "Рассуждение модели", value: service.reasoningEffort == "none" ? "Отключено" : service.reasoningEffort)
            Divider()
            AppStatRow(title: "Вход классификатора", value: "до \(service.routerMaxInputTokens.formatted()) токенов")
            AppStatRow(title: "Ответ классификатора", value: "до \(service.routerMaxOutputTokens.formatted()) токенов")
            AppStatRow(title: "Описание изображения", value: "до \(service.visionMaxOutputTokens.formatted()) токенов")
            AppStatRow(title: "Ответ основной модели", value: "до \(service.textMaxOutputTokens.formatted()) токенов")
            AppStatRow(title: "Контекст одного запроса", value: "до \(service.contextMaxTokens.formatted()) токенов / \(service.contextMaxSources) источника")
            AppStatRow(title: "Текст документа в запросе", value: "до \(service.documentMaxTokens.formatted()) токенов")
            AppStatRow(title: "Лимит одного чата", value: "\(service.conversationTokenLimit.formatted()) токенов")
            AppStatRow(title: "Сжатие памяти", value: "после \(service.conversationCompressionThreshold.formatted()) токенов контекста")
            AppStatRow(title: "Длина готового ответа", value: "до \(service.answerMaxCharacters.formatted()) символов")
            AppStatRow(title: "Хранение статистики", value: "\(service.usageRetentionDays) дней")
        }
    }
}

private struct AdminAssistantSummaryCards: View {
    let summary: AdminAssistantSummary

    var body: some View {
        AppSectionHeader(title: "Общий расход", caption: "Все учтённые вызовы за выбранный период")
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            metric("Расход", adminAssistantMoney(summary.totalCost), "rublesign.circle.fill", .green)
            metric("Всего токенов", adminAssistantNumber(summary.totalTokens), "number.circle.fill", .purple)
            metric("Запросы", adminAssistantNumber(summary.requests), "arrow.up.message.fill", AppTheme.primaryTint)
            metric("Пользователи", adminAssistantNumber(summary.uniqueUsers), "person.2.fill", .orange)
        }

        AppCard {
            AppStatRow(title: "Фактическая стоимость", value: adminAssistantMoney(summary.actualCost))
            AppStatRow(title: "Расчётная стоимость", value: adminAssistantMoney(summary.estimatedCost))
            AppStatRow(title: "Входные токены", value: adminAssistantNumber(summary.inputTokens))
            AppStatRow(title: "Выходные токены", value: adminAssistantNumber(summary.outputTokens))
            AppStatRow(title: "Токены из кеша", value: adminAssistantNumber(summary.cachedInputTokens))
            AppStatRow(title: "Токены рассуждений", value: adminAssistantNumber(summary.reasoningTokens))
            Divider()
            AppStatRow(title: "Вызовы основной модели", value: adminAssistantNumber(summary.mainModelCalls))
            if let pipelineEvents = summary.pipelineEvents {
                AppStatRow(title: "События конвейера", value: adminAssistantNumber(pipelineEvents))
            }
            AppStatRow(title: "Анализ изображений", value: adminAssistantNumber(summary.visionCalls))
            AppStatRow(title: "Документы обработаны", value: adminAssistantNumber(summary.documentRequests))
            AppStatRow(title: "Потоковые ответы", value: adminAssistantNumber(summary.streamedResponses))
            AppStatRow(title: "Сжатия памяти чатов", value: adminAssistantNumber(summary.contextCompressions))
            AppStatRow(title: "Заблокировано заранее", value: "\(adminAssistantNumber(summary.blockedBeforeMainModel)) • \(summary.blockedSharePercent.formatted(.number.precision(.fractionLength(1))))%")
            AppStatRow(title: "Ответы без основной модели", value: adminAssistantNumber(summary.deterministicAnswers))
            AppStatRow(title: "Запросы данных приложения", value: adminAssistantNumber(summary.toolRequests))
            AppStatRow(title: "Ответы ограничены по длине", value: adminAssistantNumber(summary.truncatedResponses))
            AppStatRow(title: "Повторы готовых ответов", value: adminAssistantNumber(summary.replayedRequests))
            AppStatRow(title: "Ошибки", value: adminAssistantNumber(summary.errors), accent: summary.errors > 0 ? AppTheme.dangerTint : .green)
            Divider()
            AppStatRow(title: "Диалоги за период", value: adminAssistantNumber(summary.conversations))
            AppStatRow(title: "Диалоги в хранилище", value: adminAssistantNumber(summary.storedConversations))
            AppStatRow(title: "Сообщения в хранилище", value: adminAssistantNumber(summary.storedMessages))
            AppStatRow(title: "Размер принятых изображений", value: adminAssistantBytes(summary.imageBytes))
            AppStatRow(title: "Размер документов", value: adminAssistantBytes(summary.documentBytes))
            AppStatRow(title: "Символов извлечено из документов", value: adminAssistantNumber(summary.documentCharacters))
            AppStatRow(title: "Символов в ответах", value: adminAssistantNumber(summary.responseCharacters))
            AppStatRow(title: "Средняя длина ответа", value: "\(Int(summary.averageResponseCharacters).formatted()) символов")
            AppStatRow(title: "Среднее время ответа", value: adminAssistantDuration(summary.averageLatencyMs))
            AppStatRow(title: "Максимальное время ответа", value: adminAssistantDuration(Double(summary.maximumLatencyMs)))
            AppStatRow(title: "Самый большой запрос", value: "\(adminAssistantNumber(summary.maximumRequestTokens)) токенов")
            AppStatRow(title: "Самый дорогой запрос", value: adminAssistantMoney(summary.maximumRequestCost))
        }
    }

    private func metric(_ title: String, _ value: String, _ icon: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(value).font(.headline).foregroundStyle(AppTheme.ink)
            Text(title).font(.caption).foregroundStyle(AppTheme.mutedTint)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .background(AppTheme.cardSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
    }
}

private struct AdminAssistantStageSection: View {
    let stages: [AdminAssistantStage]

    var body: some View {
        AppSectionHeader(title: "Этапы обработки", caption: "Токены и стоимость каждого слоя")
        ForEach(stages) { stage in
            AppCard {
                Text(stage.label).font(.headline).foregroundStyle(AppTheme.ink)
                AppStatRow(title: "Вызовы", value: adminAssistantNumber(stage.calls))
                AppStatRow(title: "Входные токены", value: adminAssistantNumber(stage.inputTokens))
                AppStatRow(title: "Выходные токены", value: adminAssistantNumber(stage.outputTokens))
                AppStatRow(title: "Токены из кеша", value: adminAssistantNumber(stage.cachedInputTokens))
                if stage.reasoningTokens > 0 {
                    AppStatRow(title: "Токены рассуждений", value: adminAssistantNumber(stage.reasoningTokens))
                }
                AppStatRow(title: "Фактический расход", value: adminAssistantMoney(stage.actualCost))
                AppStatRow(title: "Расчётный расход", value: adminAssistantMoney(stage.estimatedCost))
                AppStatRow(title: "Итого", value: adminAssistantMoney(stage.totalCost), accent: .green)
            }
        }
    }
}

private struct AdminAssistantModelSection: View {
    let models: [AdminAssistantModel]

    var body: some View {
        AppSectionHeader(title: "Использованные модели", caption: "Отдельно по назначению модели")
        if models.isEmpty {
            AppEmptyState(title: "Вызовов пока нет", message: "За выбранный период модели не использовались.", systemName: "brain")
        } else {
            ForEach(models) { model in
                AppCard {
                    Text(model.model).font(.headline).foregroundStyle(AppTheme.ink).textSelection(.enabled)
                    Text(model.stageLabel).font(.caption).foregroundStyle(AppTheme.mutedTint)
                    AppStatRow(title: "Вызовы", value: adminAssistantNumber(model.calls))
                    AppStatRow(title: "Вход / выход", value: "\(adminAssistantNumber(model.inputTokens)) / \(adminAssistantNumber(model.outputTokens))")
                    AppStatRow(title: "Из кеша", value: adminAssistantNumber(model.cachedInputTokens))
                    AppStatRow(title: "Расход", value: adminAssistantMoney(model.totalCost), accent: .green)
                }
            }
        }
    }
}

private struct AdminAssistantBreakdownSection: View {
    let breakdowns: AdminAssistantBreakdowns

    var body: some View {
        breakdownCard("Результаты запросов", breakdowns.outcomes)
        breakdownCard("Решения классификатора", breakdowns.routeReasons)
        breakdownCard("Подключённый контекст", breakdowns.contexts)
        breakdownCard("Завершение ответов", breakdowns.finishReasons)
        if !breakdowns.errors.isEmpty {
            breakdownCard("Ошибки и ограничения", breakdowns.errors, danger: true)
        }
    }

    @ViewBuilder
    private func breakdownCard(_ title: String, _ values: [AdminAssistantBreakdown], danger: Bool = false) -> some View {
        AppSectionHeader(title: title)
        AppCard {
            if values.isEmpty {
                Text("Нет данных за выбранный период.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.mutedTint)
            } else {
                ForEach(Array(values.enumerated()), id: \.element.id) { index, value in
                    AppStatRow(
                        title: value.label,
                        value: value.estimatedTokens.map {
                            "\(adminAssistantNumber(value.count)) • ~\(adminAssistantNumber($0)) токенов"
                        } ?? adminAssistantNumber(value.count),
                        accent: danger ? AppTheme.dangerTint : AppTheme.ink
                    )
                    if index < values.count - 1 { Divider() }
                }
            }
        }
    }
}

private struct AdminAssistantDailySection: View {
    let days: [AdminAssistantDay]

    var body: some View {
        AppSectionHeader(title: "Расход по дням", caption: "Последние значения выбранного периода")
        AppCard {
            if days.isEmpty {
                Text("Нет данных за выбранный период.").foregroundStyle(AppTheme.mutedTint)
            } else {
                ForEach(Array(days.suffix(31).reversed().enumerated()), id: \.element.id) { index, day in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(adminAssistantDate(day.date)).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(adminAssistantMoney(day.cost)).font(.subheadline.weight(.semibold)).foregroundStyle(.green)
                        }
                        Text("Запросы: \(day.requests) • токены: \(adminAssistantNumber(day.tokens)) • блокировки: \(day.blocked) • Vision: \(day.vision) • документы: \(day.documents) • поток: \(day.streamed) • сжатия: \(day.compression) • ошибки: \(day.errors)")
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedTint)
                    }
                    if index < min(days.count, 31) - 1 { Divider() }
                }
            }
        }
    }
}

private struct AdminAssistantUserSection: View {
    let users: [AdminAssistantUser]
    let store: AdminAssistantStore
    let canManage: Bool

    var body: some View {
        AppSectionHeader(title: "Расход пользователей", caption: "Без сохранения текстов запросов в статистике")
        if users.isEmpty {
            AppEmptyState(title: "Данных пока нет", message: "За выбранный период никто не использовал помощника.", systemName: "person.2")
        } else {
            VStack(spacing: 0) {
                ForEach(Array(users.enumerated()), id: \.element.id) { index, user in
                    NavigationLink {
                        AdminAssistantUserScreen(user: user, store: store, canManage: canManage)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: user.enabled ? "person.crop.circle.fill" : "person.crop.circle.badge.xmark")
                                .font(.title2)
                                .foregroundStyle(user.enabled ? AppTheme.primaryTint : AppTheme.dangerTint)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(user.displayName).font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.ink)
                                Text("\(user.requests) запр. • \(adminAssistantNumber(user.totalTokens)) токенов • \(adminAssistantMoney(user.totalCost))")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.mutedTint)
                            }
                            Spacer()
                            if user.hasCustomLimits {
                                Image(systemName: "slider.horizontal.3").foregroundStyle(.orange)
                            }
                        }
                        .padding(14)
                    }
                    .buttonStyle(.plain)
                    if index < users.count - 1 { Divider().padding(.leading, 56) }
                }
            }
            .background(AppTheme.cardSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
        }
    }
}

private struct AdminAssistantSettingsSection: View {
    let settings: AdminAssistantSettings
    let store: AdminAssistantStore
    let canManage: Bool

    var body: some View {
        AppSectionHeader(title: "Управление моделью", caption: canManage ? "Изменения применяются без нового деплоя" : "Доступен только просмотр")
        AppCard {
            NavigationLink {
                AdminAssistantPromptEditor(settings: settings, store: store, canManage: canManage)
            } label: {
                settingsRow("Системный промпт", settings.usesDefaultSystemPrompt ? "Используется стандартный" : "Задан администратором", "text.quote")
            }
            Divider()
            NavigationLink {
                AdminAssistantSynonymScreen(settings: settings, store: store, canManage: canManage)
            } label: {
                settingsRow("Словарь терминов", "\(settings.synonyms.count) соответствий", "character.book.closed.fill")
            }
            Divider()
            NavigationLink {
                AdminAssistantLimitsScreen(settings: settings, store: store, canManage: canManage)
            } label: {
                settingsRow("Общие лимиты", "Пользовательские и глобальные ограничения", "gauge.with.dots.needle.33percent")
            }
        }
    }

    private func settingsRow(_ title: String, _ subtitle: String, _ icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(.purple).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.ink)
                Text(subtitle).font(.caption).foregroundStyle(AppTheme.mutedTint)
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }
}

private struct AdminAssistantPromptEditor: View {
    @Environment(\.dismiss) private var dismiss
    let store: AdminAssistantStore
    let canManage: Bool
    private let defaultPrompt: String
    @State private var prompt: String
    @State private var instructions: String
    @State private var usesDefault: Bool

    init(settings: AdminAssistantSettings, store: AdminAssistantStore, canManage: Bool) {
        self.store = store
        self.canManage = canManage
        defaultPrompt = settings.defaultSystemPrompt
        _prompt = State(initialValue: settings.systemPrompt)
        _instructions = State(initialValue: settings.additionalInstructions)
        _usesDefault = State(initialValue: settings.usesDefaultSystemPrompt)
    }

    var body: some View {
        Form {
            Section("Системный промпт ответа") {
                Toggle("Использовать стандартный промпт", isOn: $usesDefault)
                    .disabled(!canManage)
                TextEditor(text: $prompt)
                    .frame(minHeight: 230)
                    .disabled(!canManage || usesDefault)
                    .onChange(of: usesDefault) { _, value in
                        if value { prompt = defaultPrompt }
                    }
                Text("Защитные ограничения и запрет изменения данных закреплены на сервере и этим полем не отключаются.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedTint)
            }
            Section("Дополнительные указания") {
                TextEditor(text: $instructions).frame(minHeight: 150).disabled(!canManage)
                Text("Добавляются только к основной модели. Классификатор не раздувается этими токенами.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedTint)
            }
        }
        .navigationTitle("Системный промпт")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canManage {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        Task {
                            if await store.savePrompt(
                                systemPrompt: usesDefault ? nil : prompt,
                                additionalInstructions: instructions.trimmedNil
                            ) { dismiss() }
                        }
                    }
                    .disabled(store.isSaving || (!usesDefault && prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
        }
    }
}

private struct AdminAssistantSynonymScreen: View {
    let store: AdminAssistantStore
    let canManage: Bool
    @State private var synonyms: [AdminAssistantSynonym]
    @State private var editingTerm: AdminAssistantSynonym?
    @State private var isAdding = false

    init(settings: AdminAssistantSettings, store: AdminAssistantStore, canManage: Bool) {
        self.store = store
        self.canManage = canManage
        _synonyms = State(initialValue: settings.synonyms)
    }

    var body: some View {
        List {
            Section {
                Text("В запрос добавляются только совпавшие термины. Например: «палка» → «UniTodi P8».")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.mutedTint)
            }
            Section("Термины") {
                if synonyms.isEmpty {
                    Text("Словарь пока пуст.").foregroundStyle(AppTheme.mutedTint)
                }
                ForEach(synonyms) { term in
                    Button {
                        editingTerm = term
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(term.canonical).font(.body.weight(.semibold)).foregroundStyle(AppTheme.ink)
                            Text(term.aliases.joined(separator: ", ")).font(.caption).foregroundStyle(AppTheme.mutedTint)
                            if let note = term.note, !note.isEmpty {
                                Text(note).font(.caption2).foregroundStyle(AppTheme.mutedTint)
                            }
                        }
                    }
                    .disabled(!canManage)
                }
                .onDelete { indexes in
                    guard canManage else { return }
                    synonyms.remove(atOffsets: indexes)
                    Task { _ = await store.saveSynonyms(synonyms) }
                }
            }
        }
        .navigationTitle("Словарь терминов")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canManage {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isAdding = true } label: { Image(systemName: "plus") }
                }
            }
        }
        .sheet(isPresented: $isAdding) {
            AdminAssistantSynonymEditor(term: nil) { term in
                synonyms.append(term)
                Task { _ = await store.saveSynonyms(synonyms) }
            }
        }
        .sheet(item: $editingTerm) { term in
            AdminAssistantSynonymEditor(term: term) { updated in
                if let index = synonyms.firstIndex(where: { $0.id == updated.id }) { synonyms[index] = updated }
                Task { _ = await store.saveSynonyms(synonyms) }
            }
        }
    }
}

private struct AdminAssistantSynonymEditor: View {
    @Environment(\.dismiss) private var dismiss
    private let id: String
    private let onSave: (AdminAssistantSynonym) -> Void
    @State private var canonical: String
    @State private var aliases: String
    @State private var note: String

    init(term: AdminAssistantSynonym?, onSave: @escaping (AdminAssistantSynonym) -> Void) {
        id = term?.id ?? UUID().uuidString.lowercased()
        self.onSave = onSave
        _canonical = State(initialValue: term?.canonical ?? "")
        _aliases = State(initialValue: term?.aliases.joined(separator: "\n") ?? "")
        _note = State(initialValue: term?.note ?? "")
    }

    private var parsedAliases: [String] {
        var seen = Set<String>()
        return aliases
            .components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Правильный термин") {
                    TextField("Например, UniTodi P8", text: $canonical)
                }
                Section("Синонимы") {
                    TextEditor(text: $aliases).frame(minHeight: 120)
                    Text("По одному на строке или через запятую.").font(.caption).foregroundStyle(AppTheme.mutedTint)
                }
                Section("Пояснение") {
                    TextField("Необязательно", text: $note, axis: .vertical)
                }
            }
            .navigationTitle("Термин модели")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        onSave(.init(id: id, canonical: canonical.trimmingCharacters(in: .whitespacesAndNewlines), aliases: parsedAliases, note: note.trimmedNil))
                        dismiss()
                    }
                    .disabled(canonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || parsedAliases.isEmpty)
                }
            }
        }
        .appEditorSheetStyle()
    }
}

private struct AdminAssistantLimitsScreen: View {
    @Environment(\.dismiss) private var dismiss
    let store: AdminAssistantStore
    let canManage: Bool
    @State private var defaultFields: [String: String]
    @State private var globalFields: [String: String]

    init(settings: AdminAssistantSettings, store: AdminAssistantStore, canManage: Bool) {
        self.store = store
        self.canManage = canManage
        _defaultFields = State(initialValue: adminAssistantLimitFields(settings.defaultLimits))
        _globalFields = State(initialValue: adminAssistantLimitFields(settings.globalLimits))
    }

    var body: some View {
        Form {
            limitSection("Лимиты пользователя по умолчанию", fields: $defaultFields)
            limitSection("Общие лимиты для всех пользователей", fields: $globalFields)
            Section {
                Text("Пустое поле означает «без ограничения». Проверка выполняется до платного вызова модели.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedTint)
            }
        }
        .navigationTitle("Общие лимиты")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canManage {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        Task {
                            if await store.saveLimits(
                                defaultLimits: adminAssistantLimits(from: defaultFields),
                                globalLimits: adminAssistantLimits(from: globalFields)
                            ) { dismiss() }
                        }
                    }
                    .disabled(store.isSaving)
                }
            }
        }
    }

    private func limitSection(_ title: String, fields: Binding<[String: String]>) -> some View {
        Section(title) {
            ForEach(AdminAssistantLimitSpec.allCases) { spec in
                TextField(spec.title, text: Binding(
                    get: { fields.wrappedValue[spec.rawValue] ?? "" },
                    set: { fields.wrappedValue[spec.rawValue] = adminAssistantSanitizeNumber($0, money: spec.isMoney) }
                ))
                .keyboardType(spec.isMoney ? .decimalPad : .numberPad)
                .disabled(!canManage)
            }
        }
    }
}

private struct AdminAssistantUserScreen: View {
    @Environment(\.dismiss) private var dismiss
    let user: AdminAssistantUser
    let store: AdminAssistantStore
    let canManage: Bool
    @State private var enabled: Bool
    @State private var fields: [String: String]

    init(user: AdminAssistantUser, store: AdminAssistantStore, canManage: Bool) {
        self.user = user
        self.store = store
        self.canManage = canManage
        _enabled = State(initialValue: user.enabled)
        _fields = State(initialValue: adminAssistantLimitFields(user.limits))
    }

    var body: some View {
        Form {
            Section("Использование") {
                LabeledContent("Запросы", value: adminAssistantNumber(user.requests))
                LabeledContent("Основная модель", value: adminAssistantNumber(user.mainModelCalls))
                LabeledContent("Анализ изображений", value: adminAssistantNumber(user.visionCalls))
                LabeledContent("Документы", value: adminAssistantNumber(user.documentRequests))
                LabeledContent("Потоковые ответы", value: adminAssistantNumber(user.streamedResponses))
                LabeledContent("Сжатия памяти", value: adminAssistantNumber(user.contextCompressions))
                LabeledContent("Заблокировано", value: adminAssistantNumber(user.blockedRequests))
                LabeledContent("Ошибки", value: adminAssistantNumber(user.errors))
                LabeledContent("Всего токенов", value: adminAssistantNumber(user.totalTokens))
                LabeledContent("Вход / выход", value: "\(adminAssistantNumber(user.inputTokens)) / \(adminAssistantNumber(user.outputTokens))")
                LabeledContent("Из кеша", value: adminAssistantNumber(user.cachedInputTokens))
                LabeledContent("Расход", value: adminAssistantMoney(user.totalCost))
                LabeledContent("Среднее время", value: adminAssistantDuration(user.averageLatencyMs))
            }
            Section("Доступ") {
                Toggle("Разрешить использование ИИ", isOn: $enabled).disabled(!canManage)
            }
            Section("Персональные лимиты") {
                ForEach(AdminAssistantLimitSpec.allCases) { spec in
                    TextField(spec.title, text: Binding(
                        get: { fields[spec.rawValue] ?? "" },
                        set: { fields[spec.rawValue] = adminAssistantSanitizeNumber($0, money: spec.isMoney) }
                    ))
                    .keyboardType(spec.isMoney ? .decimalPad : .numberPad)
                    .disabled(!canManage)
                }
                Text("Пустое поле наследует общий лимит пользователя.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedTint)
            }
            Section("Действия") {
                if canManage {
                    Button("Восстановить общие лимиты") {
                        Task { if await store.resetUserLimit(user: user) { dismiss() } }
                    }
                    .foregroundStyle(AppTheme.dangerTint)
                }
            }
        }
        .navigationTitle(user.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canManage {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        Task {
                            if await store.saveUserLimit(
                                user: user,
                                enabled: enabled,
                                limits: adminAssistantLimits(from: fields)
                            ) { dismiss() }
                        }
                    }
                    .disabled(store.isSaving)
                }
            }
        }
    }
}

private func adminAssistantLimitFields(_ limits: AdminAssistantLimits) -> [String: String] {
    Dictionary(uniqueKeysWithValues: AdminAssistantLimitSpec.allCases.map { spec in
        let value = limits.value(for: spec)
        return (spec.rawValue, value.map { spec.isMoney ? String($0) : String(Int($0)) } ?? "")
    })
}

private func adminAssistantLimits(from fields: [String: String]) -> AdminAssistantLimits {
    var limits = AdminAssistantLimits()
    for spec in AdminAssistantLimitSpec.allCases {
        let raw = fields[spec.rawValue]?.replacingOccurrences(of: ",", with: ".") ?? ""
        limits.set(Double(raw), for: spec)
    }
    return limits
}

private func adminAssistantSanitizeNumber(_ value: String, money: Bool) -> String {
    let allowed = money ? CharacterSet(charactersIn: "0123456789.,") : .decimalDigits
    return String(value.unicodeScalars.filter(allowed.contains))
}

private func adminAssistantNumber(_ value: Int) -> String {
    value.formatted(.number.grouping(.automatic))
}

private func adminAssistantMoney(_ value: Double) -> String {
    value.formatted(.currency(code: "RUB").precision(.fractionLength(value < 1 ? 4 : 2)))
}

private func adminAssistantDuration(_ milliseconds: Double) -> String {
    milliseconds >= 1_000
        ? "\((milliseconds / 1_000).formatted(.number.precision(.fractionLength(2)))) с"
        : "\(Int(milliseconds).formatted()) мс"
}

private func adminAssistantBytes(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

private func adminAssistantDate(_ value: String) -> String {
    guard let date = adminAssistantParsedDate(value) else { return value }
    return date.formatted(.dateTime.day().month(.wide).year())
}

private func adminAssistantDateTime(_ value: String) -> String {
    guard let date = adminAssistantParsedDate(value) else { return value }
    return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
}

private func adminAssistantParsedDate(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}

private func adminAssistantStageColor(_ key: String) -> Color {
    switch key {
    case "router": .blue
    case "vision": .orange
    case "compression": .teal
    case "main": .purple
    default: AppTheme.mutedTint
    }
}

private func adminAssistantModelColor(_ index: Int) -> Color {
    let palette: [Color] = [
        AppTheme.primaryTint,
        .purple,
        .orange,
        .teal,
        .pink,
        .green,
        .indigo,
        .cyan
    ]
    return palette[index % palette.count]
}

private func adminAssistantOutcomeColor(_ key: String) -> Color {
    switch key {
    case "model": .purple
    case "direct": .green
    case "tool_request": .blue
    case "blocked": .orange
    case "replay": .teal
    case "error": AppTheme.dangerTint
    default: AppTheme.mutedTint
    }
}

private extension String {
    var trimmedNil: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
