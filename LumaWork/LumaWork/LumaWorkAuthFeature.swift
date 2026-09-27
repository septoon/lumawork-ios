import Foundation
import Observation
import Security
import SwiftUI

struct AppUser: Codable, Hashable {
    var id: String
    var email: String
    var role: String
    var adminPermissions: [String]?
    var avatarUrl: String?
    var profile: UserProfileData?
}

enum AdminPermission: String, CaseIterable, Codable, Hashable, Identifiable {
    case viewOverview = "overview.view"
    case viewAuditLog = "audit.view"
    case viewGsmTemplate = "gsmTemplate.view"
    case replaceGsmTemplate = "gsmTemplate.replace"
    case viewUsers = "users.view"
    case notifyUsers = "users.notify"
    case blockUsers = "users.block"
    case manageUserPermissions = "users.permissions"
    case deleteUsers = "users.delete"
    case viewImages = "images.view"
    case createImages = "images.create"
    case editImages = "images.edit"
    case deleteImages = "images.delete"
    case viewFeedback = "feedback.view"
    case manageFeedback = "feedback.manage"
    case viewAssistant = "assistant.view"
    case manageAssistant = "assistant.manage"
    case viewSite = "site.view"
    case manageSite = "site.manage"
    case viewEngineerFiles = "engineerFiles.view"
    case manageEngineerFiles = "engineerFiles.manage"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .viewOverview: "Сводка админки"
        case .viewAuditLog: "Журнал действий"
        case .viewGsmTemplate: "Просмотр шаблона ГСМ"
        case .replaceGsmTemplate: "Замена шаблона ГСМ"
        case .viewUsers: "Просмотр пользователей"
        case .notifyUsers: "Рассылка обновлений"
        case .blockUsers: "Блокировка пользователей"
        case .manageUserPermissions: "Роли и права"
        case .deleteUsers: "Удаление пользователей"
        case .viewImages: "Просмотр изображений"
        case .createImages: "Добавление изображений"
        case .editImages: "Замена и переменные"
        case .deleteImages: "Удаление изображений"
        case .viewFeedback: "Просмотр обратной связи"
        case .manageFeedback: "Обработка обратной связи"
        case .viewAssistant: "Статистика ИИ"
        case .manageAssistant: "Настройки и лимиты ИИ"
        case .viewSite: "Просмотр сайта"
        case .manageSite: "Управление сайтом"
        case .viewEngineerFiles: "Просмотр файлов Инженера"
        case .manageEngineerFiles: "Управление файлами Инженера"
        }
    }

    var detail: String {
        switch self {
        case .viewOverview: "Состояние API, БД и файлового хранилища"
        case .viewAuditLog: "История изменений пользователей и изображений"
        case .viewGsmTemplate: "Просмотр и скачивание шаблона ГСМ-отчёта"
        case .replaceGsmTemplate: "Проверка и установка нового XLTX-шаблона"
        case .viewUsers: "Список и карточки пользователей"
        case .notifyUsers: "Письма об обновлении выбранному пользователю или устаревшим версиям"
        case .blockUsers: "Временная блокировка и разблокировка"
        case .manageUserPermissions: "Назначение администраторов и разрешений"
        case .deleteUsers: "Полное удаление аккаунта и связанных данных"
        case .viewImages: "Единый каталог файлов и привязок"
        case .createImages: "Новые позиции авто и терминалов"
        case .editImages: "Загрузка, замена и редактирование метаданных"
        case .deleteImages: "Удаление файлов с проверкой связей"
        case .viewFeedback: "Сообщения пользователей, снимки и данные устройства"
        case .manageFeedback: "Статусы, приоритеты, заметки и повтор отправки письма"
        case .viewAssistant: "Расходы, токены, модели и статистика пользователей"
        case .manageAssistant: "Системный промпт, словарь и ограничения пользователей"
        case .viewSite: "Состояние, тексты и галерея app.lumastack.ru"
        case .manageSite: "Доступность, тексты, скриншоты и их порядок"
        case .viewEngineerFiles: "Wiki snapshots, IPA-релизы и source.json"
        case .manageEngineerFiles: "Загрузка, замена, переименование, удаление и редактор source.json"
        }
    }

    var group: AdminPermissionGroup {
        switch self {
        case .viewOverview, .viewAuditLog, .viewGsmTemplate, .replaceGsmTemplate: .overview
        case .viewUsers, .notifyUsers, .blockUsers, .manageUserPermissions, .deleteUsers: .users
        case .viewImages, .createImages, .editImages, .deleteImages: .images
        case .viewFeedback, .manageFeedback: .feedback
        case .viewAssistant, .manageAssistant: .assistant
        case .viewSite, .manageSite: .site
        case .viewEngineerFiles, .manageEngineerFiles: .engineerFiles
        }
    }
}

enum AdminPermissionGroup: String, CaseIterable, Identifiable {
    case overview
    case users
    case images
    case feedback
    case assistant
    case site
    case engineerFiles

    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "Контроль"
        case .users: "Пользователи"
        case .images: "Изображения"
        case .feedback: "Обратная связь"
        case .assistant: "ИИ-помощник"
        case .site: "Сайт"
        case .engineerFiles: "Файлы Инженера"
        }
    }
}

extension AppUser {
    var isAdminRole: Bool {
        ["admin", "administrator", "superadmin", "owner"].contains(role.lowercased())
    }

    var adminPermissionSet: Set<AdminPermission> {
        guard isAdminRole else { return [] }
        guard let adminPermissions else {
            // Backward compatibility for a Keychain session saved before granular permissions existed.
            return Set(AdminPermission.allCases)
        }
        return Set(adminPermissions.compactMap(AdminPermission.init(rawValue:)))
    }

    func can(_ permission: AdminPermission) -> Bool {
        adminPermissionSet.contains(permission)
    }

    var canAccessAdminPanel: Bool {
        !adminPermissionSet.isEmpty
    }
}

struct UserProfileData: Codable, Hashable {
    var firstName: String?
    var lastName: String?
    var middleName: String?
    var jobTitle: String?
    var departmentTitle: String?
    var departmentGroup: String?
    var personnelNumber: String?
    var city: String?
    var personalPhone: String?
    var workEmail: String?
    var vehicleModel: String?
    var vehiclePlate: String?
    var vehicleVin: String?
    var vehicleSts: String?
    var vehiclePts: String?
    var vehicleColor: String?
    var engineVolumeCm3: String?
    var enginePowerHp: String?
    var initialMileageKm: String?
    var routeWarehouseAddress: String?
    var routeHomeAddress: String?

    init(
        firstName: String? = nil,
        lastName: String? = nil,
        middleName: String? = nil,
        jobTitle: String? = nil,
        departmentTitle: String? = nil,
        departmentGroup: String? = nil,
        personnelNumber: String? = nil,
        city: String? = nil,
        personalPhone: String? = nil,
        workEmail: String? = nil,
        vehicleModel: String? = nil,
        vehiclePlate: String? = nil,
        vehicleVin: String? = nil,
        vehicleSts: String? = nil,
        vehiclePts: String? = nil,
        vehicleColor: String? = nil,
        engineVolumeCm3: String? = nil,
        enginePowerHp: String? = nil,
        initialMileageKm: String? = nil,
        routeWarehouseAddress: String? = nil,
        routeHomeAddress: String? = nil
    ) {
        self.firstName = firstName
        self.lastName = lastName
        self.middleName = middleName
        self.jobTitle = jobTitle
        self.departmentTitle = departmentTitle
        self.departmentGroup = departmentGroup
        self.personnelNumber = personnelNumber
        self.city = city
        self.personalPhone = personalPhone
        self.workEmail = workEmail
        self.vehicleModel = vehicleModel
        self.vehiclePlate = vehiclePlate
        self.vehicleVin = vehicleVin
        self.vehicleSts = vehicleSts
        self.vehiclePts = vehiclePts
        self.vehicleColor = vehicleColor
        self.engineVolumeCm3 = engineVolumeCm3
        self.enginePowerHp = enginePowerHp
        self.initialMileageKm = initialMileageKm
        self.routeWarehouseAddress = routeWarehouseAddress
        self.routeHomeAddress = routeHomeAddress
    }

    static let empty = UserProfileData()

    var fullName: String? {
        [lastName, firstName]
            .compactMap(Self.clean)
            .joined(separator: " ")
            .nilIfBlank
    }

    var shortDisplayName: String? {
        Self.clean(firstName) ?? fullName
    }

    var requestBody: [String: String] {
        [
            "firstName": firstName,
            "lastName": lastName,
            "middleName": middleName,
            "jobTitle": jobTitle,
            "departmentTitle": departmentTitle,
            "departmentGroup": departmentGroup,
            "personnelNumber": personnelNumber,
            "city": city,
            "personalPhone": personalPhone,
            "workEmail": workEmail,
            "vehicleModel": vehicleModel,
            "vehiclePlate": vehiclePlate,
            "vehicleVin": vehicleVin,
            "vehicleSts": vehicleSts,
            "vehiclePts": vehiclePts,
            "vehicleColor": vehicleColor,
            "engineVolumeCm3": engineVolumeCm3,
            "enginePowerHp": enginePowerHp,
            "initialMileageKm": initialMileageKm,
            "routeWarehouseAddress": routeWarehouseAddress,
            "routeHomeAddress": routeHomeAddress
        ].mapValues { $0?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    }

    nonisolated static func clean(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }
}

struct AppSession: Codable, Hashable {
    var token: String
    var user: AppUser
}

struct LumaWorkAuthAPI {
    private let baseURL: URL
    private let session: URLSession

    init(config: AppConfig) {
        self.baseURL = AppConfig.configuredURL(config.lumaWorkAPIOrigin)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)
    }

    func requestCode(email: String) async throws {
        let _: EmptyResponse = try await request(
            path: "/auth/request-code",
            method: "POST",
            body: ["email": email]
        )
    }

    func verifyCode(email: String, code: String) async throws -> AppSession {
        try await request(
            path: "/auth/verify-code",
            method: "POST",
            body: ["email": email, "code": code]
        )
    }

    func currentUser(token: String) async throws -> AppUser {
        let response: CurrentUserResponse = try await request(
            path: "/me",
            token: token,
            timeoutInterval: 8,
            maxAttempts: 1
        )
        return response.user
    }

    func logout(token: String) async throws {
        let _: EmptyResponse = try await request(
            path: "/auth/logout",
            method: "POST",
            token: token
        )
    }

    func uploadAvatar(token: String, imageData: Data, mimeType: String) async throws -> AppUser {
        let response: CurrentUserResponse = try await request(
            path: "/api/v2/profile/avatar",
            method: "POST",
            body: [
                "imageBase64": imageData.base64EncodedString(),
                "mimeType": mimeType
            ],
            token: token
        )
        return response.user
    }

    func deleteAvatar(token: String) async throws -> AppUser {
        let response: CurrentUserResponse = try await request(
            path: "/api/v2/profile/avatar",
            method: "DELETE",
            token: token
        )
        return response.user
    }

    func saveProfile(token: String, profile: UserProfileData) async throws -> AppUser {
        let response: CurrentUserResponse = try await request(
            path: "/api/v2/profile",
            method: "PUT",
            body: profile.requestBody,
            token: token
        )
        return response.user
    }

    private func request<Response: Decodable>(
        path: String,
        method: String = "GET",
        body: [String: String]? = nil,
        token: String? = nil,
        timeoutInterval: TimeInterval = 45,
        maxAttempts: Int = 2
    ) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        AppBuildIdentity.apply(to: &request)

        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let urlResponse: URLResponse
        do {
            NetworkDiagnostics.logRequest(request, body: body)
            (data, urlResponse) = try await dataWithRetry(
                for: request,
                maxAttempts: maxAttempts
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            NetworkDiagnostics.logError(url: request.url ?? baseURL, method: method, error: error)
            switch AppErrorPresentation.classification(for: error) {
            case .cancellation:
                throw CancellationError()
            case .network:
                throw error
            case .domain:
                throw AppServiceError.message(Self.connectionErrorMessage(from: error))
            }
        }

        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw AppServiceError.message("Сервер авторизации вернул неизвестный ответ.")
        }

        if let url = request.url {
            NetworkDiagnostics.logResponse(url: url, statusCode: httpResponse.statusCode, data: data)
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw Self.authError(statusCode: httpResponse.statusCode, data: data)
        }

        if Response.self == EmptyResponse.self, data.isEmpty {
            return EmptyResponse() as! Response
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            if Response.self == EmptyResponse.self {
                return EmptyResponse() as! Response
            }
            throw AppServiceError.message("Сервер авторизации вернул некорректный ответ.")
        }
    }

    private func dataWithRetry(
        for request: URLRequest,
        maxAttempts: Int
    ) async throws -> (Data, URLResponse) {
        var lastError: Error?

        for attempt in 0 ..< max(maxAttempts, 1) {
            do {
                return try await session.data(for: request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if AppErrorPresentation.isCancellation(error) {
                    throw CancellationError()
                }
                lastError = error
                guard attempt + 1 < maxAttempts, Self.shouldRetryConnectionError(error) else {
                    throw error
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        throw lastError ?? AppServiceError.message("Не удалось подключиться к серверу авторизации.")
    }

    private static func authError(statusCode: Int, data: Data) -> Error {
        if let payload = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
            switch payload.error {
            case "CODE_RECENTLY_SENT":
                return AppServiceError.message(payload.message ?? "Код уже отправлен. Повторите через минуту.")
            case "INVALID_CODE":
                return AppServiceError.message("Код не подошел или истек.")
            case "USER_BLOCKED":
                return LumaWorkAuthError.accessRevoked
            default:
                break
            }
        }
        return AppServiceError.http(status: statusCode, fallback: "Ошибка авторизации")
    }

    private static func connectionErrorMessage(from error: Error) -> String {
        guard let urlError = error as? URLError else {
            return "Не удалось подключиться к серверу авторизации."
        }

        switch urlError.code {
        case .notConnectedToInternet:
            return "Нет подключения к интернету для сервера авторизации."
        case .timedOut:
            return "Сервер авторизации не ответил вовремя."
        case .cannotFindHost, .dnsLookupFailed:
            return "Не удалось найти сервер авторизации."
        case .cannotConnectToHost, .networkConnectionLost:
            return "Не удалось подключиться к серверу авторизации."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return "Не удалось установить защищённое соединение с сервером авторизации."
        default:
            return "Не удалось подключиться к серверу авторизации."
        }
    }

    private static func shouldRetryConnectionError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet:
            return true
        default:
            return false
        }
    }
}

private enum LumaWorkAuthError: LocalizedError {
    case accessRevoked

    var errorDescription: String? {
        switch self {
        case .accessRevoked:
            return "Доступ был отозван. Для восстановления обратитесь в поддержку."
        }
    }

    static func isAccessRevoked(_ error: Error) -> Bool {
        guard case .accessRevoked = error as? LumaWorkAuthError else { return false }
        return true
    }
}

@MainActor
@Observable
final class AppSessionStore {
    private let api: LumaWorkAuthAPI
    private let emailStorageKey = "LumaWork.auth.email"

    var session: AppSession?
    var email = ""
    var code = ""
    var isCodeSent = false
    var isLoading = false
    var errorMessage: String?
    var notice: String?
    var isAccessRevoked = false
    var isAvatarUploading = false
    var isOfflineMode = false

    init() {
        self.api = LumaWorkAuthAPI(config: AppConfig())
        self.session = LumaWorkSessionKeychain.readSession()
        self.email = session?.user.email ?? UserDefaults.standard.string(forKey: emailStorageKey) ?? ""
    }

    init(api: LumaWorkAuthAPI) {
        self.api = api
        self.session = LumaWorkSessionKeychain.readSession()
        self.email = session?.user.email ?? UserDefaults.standard.string(forKey: emailStorageKey) ?? ""
    }

    var isAuthenticated: Bool {
        session != nil
    }

    var currentEmail: String {
        session?.user.email ?? email
    }

    var authToken: String? {
        session?.token
    }

    var avatarUrl: String? {
        session?.user.avatarUrl
    }

    var userProfile: UserProfileData {
        session?.user.profile ?? .empty
    }

    func restoreSession(showsNetworkBanner: Bool = false) async {
        guard let session else { return }
        isOfflineMode = false
        do {
            let user = try await api.currentUser(token: session.token)
            self.session = AppSession(token: session.token, user: user)
            try? LumaWorkSessionKeychain.saveSession(self.session!)
            email = user.email
            UserDefaults.standard.set(user.email, forKey: emailStorageKey)
        } catch is CancellationError {
            return
        } catch {
            switch AppErrorPresentation.classification(for: error) {
            case .cancellation:
                return
            case .network:
                _ = appUserFacingErrorMessage(
                    error,
                    showsNetworkBanner: showsNetworkBanner
                )
                isOfflineMode = true
                return
            case .domain:
                break
            }
            if LumaWorkAuthError.isAccessRevoked(error) {
                markAccessRevoked()
            } else if case let AppServiceError.http(status, _) = error,
                      status == 401 || status == 403 {
                clearLocalSession()
            } else {
                isOfflineMode = true
            }
        }
    }

    func requestCode() async {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedEmail.isEmpty else {
            errorMessage = "Введите почту."
            return
        }

        isLoading = true
        errorMessage = nil
        notice = nil
        isAccessRevoked = false
        do {
            try await api.requestCode(email: normalizedEmail)
            email = normalizedEmail
            code = ""
            isCodeSent = true
            notice = "Код отправлен на \(normalizedEmail)."
            UserDefaults.standard.set(normalizedEmail, forKey: emailStorageKey)
        } catch {
            handleAuthError(error)
        }
        isLoading = false
    }

    func verifyCode() async {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedCode.count == 6 else {
            errorMessage = "Введите 6-значный код."
            return
        }

        isLoading = true
        errorMessage = nil
        isAccessRevoked = false
        do {
            let session = try await api.verifyCode(email: normalizedEmail, code: normalizedCode)
            try LumaWorkSessionKeychain.saveSession(session)
            self.session = session
            email = session.user.email
            code = ""
            isCodeSent = false
            UserDefaults.standard.set(session.user.email, forKey: emailStorageKey)
        } catch {
            handleAuthError(error)
        }
        isLoading = false
    }

    func logout() async {
        let token = session?.token
        isLoading = true
        if let token {
            try? await api.logout(token: token)
        }
        clearLocalSession()
        isLoading = false
    }

    func uploadAvatar(imageData: Data, mimeType: String = "image/jpeg") async {
        guard let session else {
            errorMessage = "Требуется авторизация."
            return
        }
        isAvatarUploading = true
        errorMessage = nil
        do {
            let user = try await api.uploadAvatar(token: session.token, imageData: imageData, mimeType: mimeType)
            self.session = AppSession(token: session.token, user: user)
            try? LumaWorkSessionKeychain.saveSession(self.session!)
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
        }
        isAvatarUploading = false
    }

    func deleteAvatar() async {
        guard let session else {
            errorMessage = "Требуется авторизация."
            return
        }
        isAvatarUploading = true
        errorMessage = nil
        do {
            let user = try await api.deleteAvatar(token: session.token)
            self.session = AppSession(token: session.token, user: user)
            try? LumaWorkSessionKeychain.saveSession(self.session!)
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
        }
        isAvatarUploading = false
    }

    func saveProfile(_ profile: UserProfileData) async {
        guard let session else {
            errorMessage = "Требуется авторизация."
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            let user = try await api.saveProfile(token: session.token, profile: profile)
            self.session = AppSession(token: session.token, user: user)
            try? LumaWorkSessionKeychain.saveSession(self.session!)
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
        }
        isLoading = false
    }

    private func clearLocalSession() {
        LumaWorkSessionKeychain.deleteSession()
        session = nil
        code = ""
        isCodeSent = false
        isAccessRevoked = false
        isOfflineMode = false
        notice = nil
    }

    func resetAccessRevoked() {
        code = ""
        isCodeSent = false
        isAccessRevoked = false
        errorMessage = nil
        notice = nil
    }

    private func handleAuthError(_ error: Error) {
        if LumaWorkAuthError.isAccessRevoked(error) {
            markAccessRevoked()
            return
        }
        errorMessage = appUserFacingErrorMessage(error)
    }

    private func markAccessRevoked() {
        LumaWorkSessionKeychain.deleteSession()
        session = nil
        code = ""
        isCodeSent = false
        isAccessRevoked = true
        isOfflineMode = false
        errorMessage = nil
        notice = nil
    }
}

private extension String {
    nonisolated var nilIfBlank: String? {
        isEmpty ? nil : self
    }
}

struct LumaWorkSessionKeychain {
    private static let service = "LumaWork.AppSession"
    private static let account = "auth"

    static func readSession() -> AppSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(AppSession.self, from: data)
    }

    static func saveSession(_ session: AppSession) throws {
        let data = try JSONEncoder().encode(session)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess {
            return
        }
        if status != errSecItemNotFound {
            throw AppServiceError.message("Не удалось обновить сессию.")
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AppServiceError.message("Не удалось сохранить сессию.")
        }
    }

    static func deleteSession() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

struct AppAuthScreen: View {
    @Bindable var store: AppSessionStore
    @FocusState private var focusedField: Field?
    @State private var lastSubmittedCode = ""

    private enum Field {
        case email
    }

    var body: some View {
        ZStack {
            AppTheme.background
                .ignoresSafeArea()

            VStack(spacing: 22) {
                Spacer(minLength: 20)

                VStack(spacing: 10) {
                    Image(systemName: "person.badge.key.fill")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(AppTheme.primaryTint)

                    Text(authTitle)
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(AppTheme.ink)

                    Text(authSubtitle)
                        .font(.body)
                        .foregroundStyle(AppTheme.mutedTint)
                        .multilineTextAlignment(.center)
                }
                .padding(.bottom, 8)

                VStack(spacing: 14) {
                    if store.isAccessRevoked {
                        AuthAccessRevokedNotice {
                            AppHaptics.trigger()
                            store.resetAccessRevoked()
                            focusedField = .email
                        }
                    } else if !store.isCodeSent {
                        TextField("Почта", text: $store.email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .email)
                            .padding(.horizontal, 16)
                            .frame(height: 54)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                        Button {
                            AppHaptics.trigger()
                            Task { await store.requestCode() }
                        } label: {
                            HStack(spacing: 8) {
                                if store.isLoading {
                                    ProgressView()
                                }
                                Text("Получить код")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .frame(minWidth: 178)
                            .frame(height: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.isLoading)
                    } else {
                        AppOneTimeCodeInput(code: $store.code, isLoading: store.isLoading)
                            .padding(.top, 2)

                        Button("Отправить код повторно") {
                            AppHaptics.trigger()
                            lastSubmittedCode = ""
                            Task { await store.requestCode() }
                        }
                        .font(.subheadline.weight(.medium))
                        .disabled(store.isLoading)
                    }
                }

                if let notice = store.notice {
                    AppNoticeBanner(
                        text: notice,
                        tint: AppTheme.primaryTint,
                        style: .success
                    )
                }

                if let errorMessage = store.errorMessage {
                    AppNoticeBanner(
                        text: errorMessage,
                        tint: AppTheme.dangerTint,
                        isCritical: true,
                        style: .error
                    )
                }

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 24)
        }
        .task {
            focusedField = store.isCodeSent || store.isAccessRevoked ? nil : .email
        }
        .onChange(of: store.code) { _, newValue in
            guard !store.isAccessRevoked else { return }
            let normalizedCode = String(newValue.filter(\.isNumber).prefix(6))
            if normalizedCode != newValue {
                store.code = normalizedCode
                return
            }

            guard store.isCodeSent,
                  normalizedCode.count == 6,
                  normalizedCode != lastSubmittedCode,
                  !store.isLoading else { return }

            lastSubmittedCode = normalizedCode
            AppHaptics.trigger()
            Task { await store.verifyCode() }
        }
        .onChange(of: store.isCodeSent) { _, isCodeSent in
            if !isCodeSent {
                focusedField = store.isAccessRevoked ? nil : .email
                lastSubmittedCode = ""
            }
        }
        .onChange(of: store.isAccessRevoked) { _, isAccessRevoked in
            focusedField = isAccessRevoked || store.isCodeSent ? nil : .email
            lastSubmittedCode = ""
        }
    }

    private var authTitle: String {
        if store.isAccessRevoked {
            return "Доступ отозван"
        }
        return store.isCodeSent ? "Введите код" : "Вход"
    }

    private var authSubtitle: String {
        if store.isAccessRevoked {
            return "Авторизация для этого аккаунта недоступна."
        }
        return store.isCodeSent
            ? "Введите 6 цифр из письма."
            : "Введите почту: если аккаунта нет, он будет создан после подтверждения кода."
    }
}

private struct AuthAccessRevokedNotice: View {
    let onReset: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.slash.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(AppTheme.dangerTint)

            Text("Доступ был отозван.")
                .font(.headline.weight(.semibold))
                .foregroundStyle(AppTheme.ink)
                .multilineTextAlignment(.center)

            VStack(spacing: 4) {
                Text("Для восстановления обратитесь в поддержку:")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.mutedTint)
                    .multilineTextAlignment(.center)

                if let supportEmail, let supportEmailURL {
                    Link(supportEmail, destination: supportEmailURL)
                        .font(.subheadline.weight(.semibold))
                }
            }

            Button("Ввести другую почту", action: onReset)
                .font(.subheadline.weight(.medium))
                .buttonStyle(.bordered)
                .padding(.top, 4)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var supportEmail: String? {
        AppConfig().supportEmail
    }

    private var supportEmailURL: URL? {
        guard let supportEmail else { return nil }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Отозван доступ к приложению Инженер")
        ]
        return components.url
    }
}

struct AppOneTimeCodeInput: View {
    @Binding var code: String
    var isLoading: Bool
    @FocusState private var isFocused: Bool

    private let length = 6

    var body: some View {
        ZStack {
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($isFocused)
                .disabled(isLoading)
                .frame(width: 1, height: 1)
                .opacity(0.01)

            HStack(spacing: 9) {
                ForEach(0..<length, id: \.self) { index in
                    Text(character(at: index))
                        .font(.title2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(AppTheme.ink)
                        .frame(width: 46, height: 54)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(isFocused && index == activeIndex ? AppTheme.primaryTint.opacity(0.8) : .white.opacity(0.08), lineWidth: 1)
                        }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                isFocused = true
            }
        }
        .frame(height: 58)
        .onAppear {
            isFocused = true
        }
        .onChange(of: code) { _, newValue in
            let normalizedCode = String(newValue.filter(\.isNumber).prefix(length))
            if normalizedCode != newValue {
                code = normalizedCode
            }
        }
    }

    private var activeIndex: Int {
        min(code.count, length - 1)
    }

    private func character(at index: Int) -> String {
        guard index < code.count else { return "" }
        let characterIndex = code.index(code.startIndex, offsetBy: index)
        return String(code[characterIndex])
    }
}

private struct CurrentUserResponse: Decodable {
    var user: AppUser
}

private struct ErrorResponse: Decodable {
    var error: String?
    var message: String?
}

private struct EmptyResponse: Decodable {}
