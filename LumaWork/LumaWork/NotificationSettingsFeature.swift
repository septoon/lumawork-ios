import BackgroundTasks
import Foundation
import Observation
import OSLog
import SwiftUI
import UIKit
import UserNotifications

nonisolated struct RequestNotificationPreferences: Codable, Hashable, Sendable {
    var localNewRequests: Bool
    var localAssigneeChanges: Bool
    var emailNewRequests: Bool
    var emailAssigneeChanges: Bool
}

private enum RequestNotificationPreferenceKeys {
    static let localNewRequests = "notifications.local.new-requests"
    static let localAssigneeChanges = "notifications.local.assignee-changes"
    static let emailNewRequests = "notifications.email.new-requests"
    static let emailAssigneeChanges = "notifications.email.assignee-changes"
    static let deliveredEventIDs = "notifications.delivered-event-ids"
    static let pendingEmailEvents = "notifications.pending-email-events"

    static var current: RequestNotificationPreferences {
        let defaults = UserDefaults.standard
        return RequestNotificationPreferences(
            localNewRequests: defaults.object(forKey: localNewRequests) as? Bool ?? true,
            localAssigneeChanges: defaults.object(forKey: localAssigneeChanges) as? Bool ?? true,
            emailNewRequests: defaults.object(forKey: emailNewRequests) as? Bool ?? true,
            emailAssigneeChanges: defaults.object(forKey: emailAssigneeChanges) as? Bool ?? true
        )
    }

    static func save(_ preferences: RequestNotificationPreferences) {
        let defaults = UserDefaults.standard
        defaults.set(preferences.localNewRequests, forKey: localNewRequests)
        defaults.set(preferences.localAssigneeChanges, forKey: localAssigneeChanges)
        defaults.set(preferences.emailNewRequests, forKey: emailNewRequests)
        defaults.set(preferences.emailAssigneeChanges, forKey: emailAssigneeChanges)
    }
}

private struct RequestNotificationPreferencesResponse: Decodable {
    let preferences: RequestNotificationPreferences
}

private struct RequestNotificationEvent: Codable {
    enum Kind: String, Codable {
        case newActiveRequest = "new_active_request"
        case assigneeChanged = "assignee_changed"
    }

    let eventID: String
    let kind: Kind
    let requestID: String
    let requestNumber: String
    let shortDescription: String
    let requestType: String?
    let address: String?
    let customer: String?
    let terminalID: String?
    let oldAssignee: String?
    let newAssignee: String?
}

private struct NotificationAPIEmptyResponse: Decodable {}

private struct LumaWorkNotificationsAPI {
    private let baseURL: URL
    private let authToken: String?
    private let session: URLSession

    init(config: AppConfig, authToken: String?) {
        self.baseURL = AppConfig.configuredURL(config.lumaWorkAPIOrigin)
        self.authToken = authToken

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        self.session = URLSession(configuration: configuration)
    }

    func fetchPreferences() async throws -> RequestNotificationPreferences {
        let response: RequestNotificationPreferencesResponse = try await request(
            path: "/api/v2/notifications/preferences"
        )
        return response.preferences
    }

    func savePreferences(_ preferences: RequestNotificationPreferences) async throws {
        let _: NotificationAPIEmptyResponse = try await request(
            path: "/api/v2/notifications/preferences",
            method: "PUT",
            body: preferences
        )
    }

    func send(_ event: RequestNotificationEvent) async throws {
        let _: NotificationAPIEmptyResponse = try await request(
            path: "/api/v2/notifications/events",
            method: "POST",
            body: event
        )
    }

    private func request<Response: Decodable, Body: Encodable>(
        path: String,
        method: String = "GET",
        body: Body? = Optional<String>.none
    ) async throws -> Response {
        guard let authToken, !authToken.isEmpty else {
            throw AppServiceError.message("Сессия LumaWork недоступна.")
        }

        var request = URLRequest(
            url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        )
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppServiceError.message("Сервер уведомлений вернул неизвестный ответ.")
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw AppServiceError.http(status: httpResponse.statusCode, fallback: "Ошибка сервера уведомлений")
        }
        if data.isEmpty, Response.self == NotificationAPIEmptyResponse.self {
            return NotificationAPIEmptyResponse() as! Response
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

@MainActor
@Observable
final class NotificationSettingsStore {
    private let api: LumaWorkNotificationsAPI

    var preferences: RequestNotificationPreferences
    var authorizationStatus: UNAuthorizationStatus = .notDetermined
    var isLoading = false
    var errorMessage: String?
    var notice: String?

    init(config: AppConfig, authToken: String?) {
        self.api = LumaWorkNotificationsAPI(config: config, authToken: authToken)
        self.preferences = RequestNotificationPreferenceKeys.current
    }

    func load() async {
        await refreshAuthorizationStatus()
        isLoading = true
        defer { isLoading = false }

        do {
            preferences = try await api.fetchPreferences()
            RequestNotificationPreferenceKeys.save(preferences)
        } catch {
            // Локальные настройки остаются рабочими, даже если сервер еще не обновлен.
        }
    }

    func setLocalNewRequests(_ enabled: Bool) {
        preferences.localNewRequests = enabled
        persistAndSync()
        if enabled { Task { await requestAuthorizationIfNeeded() } }
    }

    func setLocalAssigneeChanges(_ enabled: Bool) {
        preferences.localAssigneeChanges = enabled
        persistAndSync()
        if enabled { Task { await requestAuthorizationIfNeeded() } }
    }

    func setEmailNewRequests(_ enabled: Bool) {
        preferences.emailNewRequests = enabled
        persistAndSync()
    }

    func setEmailAssigneeChanges(_ enabled: Bool) {
        preferences.emailAssigneeChanges = enabled
        persistAndSync()
    }

    func requestAuthorizationIfNeeded() async {
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorizationStatus()
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
        }
    }

    func refreshAuthorizationStatus() async {
        authorizationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private func persistAndSync() {
        RequestNotificationPreferenceKeys.save(preferences)
        RequestNotificationsBackgroundRefresh.schedule()
        let snapshot = preferences
        Task {
            do {
                try await api.savePreferences(snapshot)
                notice = "Настройки уведомлений сохранены."
            } catch {
                errorMessage = appUserFacingErrorMessage(
                    error,
                    fallback: "Настройки сохранены на устройстве, но сервер их не принял."
                )
            }
        }
    }
}

@MainActor
final class SimpleOneRequestNotificationCoordinator {
    private let api: LumaWorkNotificationsAPI
    private let center = UNUserNotificationCenter.current()
    private let logger = Logger(subsystem: "LumaWork", category: "RequestNotifications")

    init(config: AppConfig, authToken: String?) {
        self.api = LumaWorkNotificationsAPI(config: config, authToken: authToken)
    }

    func process(
        previous: [SimpleOneRequestRecord],
        current: [SimpleOneRequestRecord],
        isInitialSnapshot: Bool
    ) async {
        await retryPendingEmailEvents()
        guard !isInitialSnapshot else { return }
        let preferences = RequestNotificationPreferenceKeys.current
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })

        for record in current {
            if let oldRecord = previousByID[record.id] {
                let oldAssignee = oldRecord.assignedUser.trimmingCharacters(in: .whitespacesAndNewlines)
                let newAssignee = record.assignedUser.trimmingCharacters(in: .whitespacesAndNewlines)
                guard oldAssignee != newAssignee else { continue }
                let event = RequestNotificationEvent(
                    eventID: "assignee:\(record.id):\(oldAssignee):\(newAssignee)",
                    kind: .assigneeChanged,
                    requestID: record.sysID,
                    requestNumber: sutsRequestNumber(record),
                    shortDescription: record.shortDescription,
                    requestType: record.requestType,
                    address: record.address,
                    customer: record.customer,
                    terminalID: record.terminalID,
                    oldAssignee: oldAssignee,
                    newAssignee: newAssignee
                )
                await deliver(
                    event,
                    title: "Изменен исполнитель",
                    body: "В заявке \(displayNumber(record)) исполнитель изменен с \(oldAssignee.ifBlank("не указан")) на \(newAssignee.ifBlank("не указан")).",
                    localEnabled: preferences.localAssigneeChanges,
                    emailEnabled: preferences.emailAssigneeChanges
                )
            } else {
                let event = RequestNotificationEvent(
                    eventID: "new:\(record.id):\(record.registeredAt ?? "")",
                    kind: .newActiveRequest,
                    requestID: record.sysID,
                    requestNumber: sutsRequestNumber(record),
                    shortDescription: record.shortDescription,
                    requestType: record.requestType,
                    address: record.address,
                    customer: record.customer,
                    terminalID: record.terminalID,
                    oldAssignee: nil,
                    newAssignee: record.assignedUser
                )
                await deliver(
                    event,
                    title: "Новая задача",
                    body: "Появилась новая активная заявка \(displayNumber(record)): \(record.shortDescription.ifBlank("без описания")).",
                    localEnabled: preferences.localNewRequests,
                    emailEnabled: preferences.emailNewRequests
                )
            }
        }
    }

    private func deliver(
        _ event: RequestNotificationEvent,
        title: String,
        body: String,
        localEnabled: Bool,
        emailEnabled: Bool
    ) async {
        if localEnabled, markLocalEventDeliveredIfNeeded(event.eventID) {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.userInfo = ["requestID": event.requestID]
            do {
                try await center.add(UNNotificationRequest(identifier: event.eventID, content: content, trigger: nil))
            } catch {
                logger.error("Local notification failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        if emailEnabled {
            do {
                try await api.send(event)
            } catch {
                enqueuePendingEmailEvent(event)
                logger.error("Email notification event failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func displayNumber(_ record: SimpleOneRequestRecord) -> String {
        record.incomingNumber.trimmingCharacters(in: .whitespacesAndNewlines).ifBlank(record.number)
    }

    private func sutsRequestNumber(_ record: SimpleOneRequestRecord) -> String {
        for candidate in [record.incomingNumber, record.shortDescription] {
            if let range = candidate.range(
                of: #"SUTSPROD-\d+"#,
                options: [.regularExpression, .caseInsensitive]
            ) {
                return String(candidate[range]).uppercased()
            }
        }
        return displayNumber(record)
    }

    private func markLocalEventDeliveredIfNeeded(_ eventID: String) -> Bool {
        let defaults = UserDefaults.standard
        var ids = defaults.stringArray(forKey: RequestNotificationPreferenceKeys.deliveredEventIDs) ?? []
        guard !ids.contains(eventID) else { return false }
        ids.append(eventID)
        if ids.count > 500 {
            ids.removeFirst(ids.count - 500)
        }
        defaults.set(ids, forKey: RequestNotificationPreferenceKeys.deliveredEventIDs)
        return true
    }

    private func retryPendingEmailEvents() async {
        let pending = pendingEmailEvents()
        guard !pending.isEmpty else { return }

        var failed: [RequestNotificationEvent] = []
        for event in pending {
            do {
                try await api.send(event)
            } catch {
                failed.append(event)
            }
        }
        savePendingEmailEvents(failed)
    }

    private func enqueuePendingEmailEvent(_ event: RequestNotificationEvent) {
        var pending = pendingEmailEvents()
        guard !pending.contains(where: { $0.eventID == event.eventID }) else { return }
        pending.append(event)
        if pending.count > 200 {
            pending.removeFirst(pending.count - 200)
        }
        savePendingEmailEvents(pending)
    }

    private func pendingEmailEvents() -> [RequestNotificationEvent] {
        guard let data = UserDefaults.standard.data(forKey: RequestNotificationPreferenceKeys.pendingEmailEvents) else {
            return []
        }
        return (try? JSONDecoder().decode([RequestNotificationEvent].self, from: data)) ?? []
    }

    private func savePendingEmailEvents(_ events: [RequestNotificationEvent]) {
        if events.isEmpty {
            UserDefaults.standard.removeObject(forKey: RequestNotificationPreferenceKeys.pendingEmailEvents)
            return
        }
        if let data = try? JSONEncoder().encode(events) {
            UserDefaults.standard.set(data, forKey: RequestNotificationPreferenceKeys.pendingEmailEvents)
        }
    }
}

enum RequestNotificationsBackgroundRefresh {
    static let taskIdentifier = "septon.LumaWork.simpleone-refresh"

    static func schedule() {
        let preferences = RequestNotificationPreferenceKeys.current
        guard preferences.localNewRequests
                || preferences.localAssigneeChanges
                || preferences.emailNewRequests
                || preferences.emailAssigneeChanges else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
            return
        }

        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    @MainActor
    static func perform() async {
        defer { schedule() }
        guard let session = LumaWorkSessionKeychain.readSession() else { return }
        let coordinator = SimpleOneRequestNotificationCoordinator(
            config: AppConfig(),
            authToken: session.token
        )
        let store = SimpleOneRequestsStore(
            notificationCoordinator: coordinator,
            automaticallyRefresh: false
        )
        await store.refresh()
    }
}

struct NotificationSettingsScreen: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.appIsOfflineMode) private var isOfflineMode
    @State private var store: NotificationSettingsStore

    private let email: String

    init(sessionStore: AppSessionStore, config: AppConfig = AppConfig()) {
        self.email = sessionStore.currentEmail
        _store = State(initialValue: NotificationSettingsStore(
            config: config,
            authToken: sessionStore.authToken
        ))
    }

    var body: some View {
        Form {
            Section("На устройстве") {
                Toggle("Новая активная заявка", isOn: Binding(
                    get: { store.preferences.localNewRequests },
                    set: store.setLocalNewRequests
                ))
                Toggle("Изменение исполнителя", isOn: Binding(
                    get: { store.preferences.localAssigneeChanges },
                    set: store.setLocalAssigneeChanges
                ))

                if store.authorizationStatus == .denied {
                    Button("Открыть системные настройки") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    }
                }
            }

            Section("По электронной почте") {
                LabeledContent("Получатель", value: email)
                Toggle("Новая активная заявка", isOn: Binding(
                    get: { store.preferences.emailNewRequests },
                    set: store.setEmailNewRequests
                ))
                Toggle("Изменение исполнителя", isOn: Binding(
                    get: { store.preferences.emailAssigneeChanges },
                    set: store.setEmailAssigneeChanges
                ))
                Text("Письма отправляет сервер LumaWork. SMTP-пароль не хранится в приложении.")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.mutedTint)
            }

            if let errorMessage = store.errorMessage,
               AppOfflineWarningPolicy.shouldDisplay(errorMessage, isOfflineMode: isOfflineMode) {
                AppNoticeBanner(
                    text: errorMessage,
                    tint: AppTheme.dangerTint,
                    isCritical: true,
                    style: .error
                )
            } else if let notice = store.notice {
                AppNoticeBanner(
                    text: notice,
                    tint: AppTheme.primaryTint,
                    style: .success
                )
            }
        }
        .navigationTitle("Уведомления")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
        .task {
            await store.load()
        }
    }
}

private extension String {
    func ifBlank(_ fallback: String) -> String {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : self
    }
}
