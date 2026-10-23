import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct GsmReportResponse: Codable, Hashable {
    let success: Bool
    let month: String
    let force: Bool?
    let skipEmail: Bool?
    let generated: Bool?
    let sent: Bool?
    let status: String?
    let outputFileName: String?
    let sentToEmail: String?
    let durationMs: Int?
    let output: String?
    let errorOutput: String?
}

private struct GsmOdometerSuggestionResponse: Decodable {
    let month: String
    let sourceMonth: String
    let startOdometer: Int?
}

nonisolated struct GsmProjectOption: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let budgetCode: String
}

struct GsmProfileLoadResult {
    let profile: GsmProfile
    let availableFuelTypes: [String]
    let profileExists: Bool
}

nonisolated struct GsmProfile: Codable, Hashable, Sendable {
    var vehicleID: String?
    var posProjectID: String?
    var armProjectID: String?
    var budgetCode: String
    var employeeFullName: String
    var employeeShortName: String
    var employeeReportSignName: String
    var authorizedFullName: String
    var authorizedShortName: String
    var employeeJobTitle: String
    var employeeCompany: String
    var employeeAddress: String
    var employeePhone: String
    var employeeTitleCompany: String
    var employeeAddressPhone: String
    var driverLicenseNumber: String
    var fuelCardNumber: String
    var carModel: String
    var licensePlate: String
    var fuelNorm: Double
    var fuelType: String
    var fuelTypes: [String]
    var defaultStartOdometer: Int
    var reportStartMonth: String
    var projectName: String

    enum CodingKeys: String, CodingKey {
        case vehicleID = "vehicleId"
        case posProjectID = "posProjectId"
        case armProjectID = "armProjectId"
        case budgetCode, employeeFullName, employeeShortName, employeeReportSignName
        case authorizedFullName, authorizedShortName, employeeJobTitle, employeeCompany
        case employeeAddress, employeePhone, employeeTitleCompany, employeeAddressPhone
        case driverLicenseNumber, fuelCardNumber, carModel, licensePlate, fuelNorm, fuelType, fuelTypes
        case defaultStartOdometer, reportStartMonth, projectName
    }

    static let empty = GsmProfile(
        vehicleID: nil,
        posProjectID: nil,
        armProjectID: nil,
        budgetCode: "",
        employeeFullName: "",
        employeeShortName: "",
        employeeReportSignName: "",
        authorizedFullName: "",
        authorizedShortName: "",
        employeeJobTitle: "",
        employeeCompany: "",
        employeeAddress: "",
        employeePhone: "",
        employeeTitleCompany: "",
        employeeAddressPhone: "",
        driverLicenseNumber: "",
        fuelCardNumber: "",
        carModel: "",
        licensePlate: "",
        fuelNorm: 0,
        fuelType: "",
        fuelTypes: [],
        defaultStartOdometer: 0,
        reportStartMonth: "2026-04",
        projectName: ""
    )
}

protocol GsmProfileServing {
    func fetchProfile() async throws -> GsmProfileLoadResult
    func fetchProjects() async throws -> [GsmProjectOption]
    func saveProfile(_ profile: GsmProfile) async throws -> GsmProfile
}

extension Notification.Name {
    static let gsmProfileSaved = Notification.Name("LumaWork.gsmProfileSaved")
}

struct GsmProfileAPI: GsmProfileServing {
    private let apiOrigin: String?
    private let authToken: String?
    private let client = HTTPClient()

    init(config: AppConfig, authToken: String?) {
        self.apiOrigin = config.lumaWorkAPIOrigin
        self.authToken = authToken
    }

    func fetchProfile() async throws -> GsmProfileLoadResult {
        guard let authToken, let url = url(path: "/api/v2/gsm/profile") else {
            throw AppServiceError.message("Требуется авторизация.")
        }
        let response = try await client.request(url, authToken: authToken)
        let root = dictionaryValue(response.json) ?? [:]
        let availableFuelTypes = (root["availableFuelTypes"] as? [Any])?
            .map { stringValue($0) }
            .filter { !$0.isEmpty } ?? []
        guard let dictionary = profileDictionary(from: response.json) else {
            guard root["profile"] is NSNull else {
                throw AppServiceError.message("Сервер не подтвердил состояние ГСМ-профиля.")
            }
            return GsmProfileLoadResult(profile: .empty, availableFuelTypes: availableFuelTypes, profileExists: false)
        }
        return GsmProfileLoadResult(profile: mapProfile(dictionary), availableFuelTypes: availableFuelTypes, profileExists: true)
    }

    func fetchProjects() async throws -> [GsmProjectOption] {
        guard let authToken, let url = url(path: "/api/v2/gsm/projects") else {
            throw AppServiceError.message("Требуется авторизация.")
        }
        let response = try await client.request(url, authToken: authToken)
        let root = dictionaryValue(response.json) ?? [:]
        guard let rawProjects = root["projects"] as? [Any] else { return [] }
        return rawProjects.compactMap { raw in
            guard let value = dictionaryValue(raw) else { return nil }
            let id = stringValue(value["id"])
            let name = stringValue(value["name"])
            let budgetCode = stringValue(value["budgetCode"])
            guard !id.isEmpty, !name.isEmpty, !budgetCode.isEmpty else { return nil }
            return GsmProjectOption(id: id, name: name, budgetCode: budgetCode)
        }
    }

    func saveProfile(_ profile: GsmProfile) async throws -> GsmProfile {
        guard let authToken, let url = url(path: "/api/v2/gsm/profile") else {
            throw AppServiceError.message("Требуется авторизация.")
        }
        var profile = profile
        profile.employeePhone = GsmPhoneFormatter.format(profile.employeePhone)
        guard GsmPhoneFormatter.isComplete(profile.employeePhone) else {
            throw AppServiceError.message("Введите телефон полностью: +7(XXX)XXX-XX-XX.")
        }
        var body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any] ?? [:]
        body["vehicleId"] = profile.vehicleID ?? NSNull()
        body["posProjectId"] = profile.posProjectID ?? NSNull()
        body["armProjectId"] = profile.armProjectID ?? NSNull()
        for key in ["budgetCode", "projectName", "employeeTitleCompany", "employeeAddressPhone"] {
            if (body[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                body.removeValue(forKey: key)
            }
        }
        let response = try await client.request(url, method: "PUT", body: body, authToken: authToken)
        guard let dictionary = profileDictionary(from: response.json) else {
            throw AppServiceError.message("Сервер не подтвердил сохранение ГСМ-профиля.")
        }
        return mapProfile(dictionary)
    }

    private func url(path: String) -> URL? {
        guard let apiOrigin,
              let originURL = URL(string: apiOrigin.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return originURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    private func profileDictionary(from raw: Any?) -> [String: Any]? {
        guard let dictionary = dictionaryValue(raw) else { return nil }

        for key in ["profile", "gsmProfile", "gsm_profile", "data"] {
            guard let value = dictionary[key], !(value is NSNull) else { continue }
            if let nested = dictionaryValue(value) {
                return nested
            }
        }

        return dictionary.keys.contains { $0.lowercased().contains("employee") || $0.lowercased().contains("budget") }
            ? dictionary
            : nil
    }

    private func mapProfile(_ dictionary: [String: Any]) -> GsmProfile {
        GsmProfile(
            vehicleID: gsmString(dictionary, "vehicleId", "vehicle_id").nilIfEmpty,
            posProjectID: gsmString(dictionary, "posProjectId", "pos_project_id").nilIfEmpty,
            armProjectID: gsmString(dictionary, "armProjectId", "arm_project_id").nilIfEmpty,
            budgetCode: gsmString(dictionary, "budgetCode", "budget_code"),
            employeeFullName: gsmString(dictionary, "employeeFullName", "employee_full_name"),
            employeeShortName: gsmString(dictionary, "employeeShortName", "employee_short_name"),
            employeeReportSignName: gsmString(dictionary, "employeeReportSignName", "employee_report_sign_name"),
            authorizedFullName: gsmString(dictionary, "authorizedFullName", "authorized_full_name"),
            authorizedShortName: gsmString(dictionary, "authorizedShortName", "authorized_short_name"),
            employeeJobTitle: gsmString(dictionary, "employeeJobTitle", "employee_job_title"),
            employeeCompany: gsmString(dictionary, "employeeCompany", "employee_company"),
            employeeAddress: gsmString(dictionary, "employeeAddress", "employee_address"),
            employeePhone: GsmPhoneFormatter.format(
                gsmString(dictionary, "employeePhone", "employee_phone")
            ),
            employeeTitleCompany: gsmString(dictionary, "employeeTitleCompany", "employee_title_company"),
            employeeAddressPhone: gsmString(dictionary, "employeeAddressPhone", "employee_address_phone"),
            driverLicenseNumber: gsmString(dictionary, "driverLicenseNumber", "driver_license_number"),
            fuelCardNumber: gsmString(dictionary, "fuelCardNumber", "fuel_card_number"),
            carModel: gsmString(dictionary, "carModel", "car_model"),
            licensePlate: gsmString(dictionary, "licensePlate", "license_plate"),
            fuelNorm: gsmDouble(dictionary, "fuelNorm", "fuel_norm") ?? 0,
            fuelType: gsmString(dictionary, "fuelType", "fuel_type"),
            fuelTypes: gsmStringArray(dictionary, "fuelTypes", "fuel_types"),
            defaultStartOdometer: gsmInt(dictionary, "defaultStartOdometer", "default_start_odometer") ?? 0,
            reportStartMonth: gsmString(dictionary, "reportStartMonth", "report_start_month", default: "2026-04"),
            projectName: gsmString(dictionary, "projectName", "project_name")
        )
    }

    private func gsmString(_ dictionary: [String: Any], _ keys: String..., default fallback: String = "") -> String {
        keys
            .map { stringValue(dictionary[$0]) }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            ?? fallback
    }

    private func gsmDouble(_ dictionary: [String: Any], _ keys: String...) -> Double? {
        keys.lazy.compactMap { doubleValue(dictionary[$0]) }.first
    }

    private func gsmInt(_ dictionary: [String: Any], _ keys: String...) -> Int? {
        keys.lazy.compactMap { intValue(dictionary[$0]) }.first
    }

    private func gsmStringArray(_ dictionary: [String: Any], _ keys: String...) -> [String] {
        for key in keys {
            if let values = dictionary[key] as? [Any] {
                let result = values.map { stringValue($0) }.filter { !$0.isEmpty }
                if !result.isEmpty { return result }
            }
        }
        let legacy = gsmString(dictionary, "fuelType", "fuel_type")
        return legacy.isEmpty ? [] : [legacy]
    }
}

@MainActor
@Observable
final class GsmProfileSettingsStore {
    private struct Draft: Codable {
        let profile: GsmProfile
        let imported: GsmProfileImport?
    }
    private static let fallbackFuelTypes = [
        "АИ-92", "АИ-92 Фирменное", "АИ-95", "АИ-95 Фирменное",
        "АИ-98", "АИ-100", "ДТ", "ДТ Зимнее"
    ]
    private let api: any GsmProfileServing
    private let cacheKey: String
    private let draftKey: String
    private let offerKey: String
    private let accountID: String?
    private var baseline = GsmProfile.empty
    private var isApplying = false
    private var hasDraft = false
    private var revision = 0

    var profile = GsmProfile.empty {
        didSet {
            guard !isApplying, profile != oldValue else { return }
            revision += 1
            hasDraft = true
            persistDraft()
        }
    }
    private(set) var imported: GsmProfileImport?
    var projects: [GsmProjectOption] = []
    var availableFuelTypes: [String] = fallbackFuelTypes
    var lastUpdatedAt: Date?
    var isLoading = false
    var isSaving = false
    var isImporting = false
    private(set) var isProfileReady = false
    private(set) var isServerConfirmedEmpty = false
    var isImportOfferPresented = false
    var notice: String?
    var errorMessage: String?
    var isBusy: Bool { isLoading || isSaving || isImporting }
    var hasUnsavedChanges: Bool { hasDraft || profile != baseline }
    var canImport: Bool { isServerConfirmedEmpty && !isBusy }
    var canSave: Bool { isProfileReady && !isBusy }
    var expectedImportMonth: String { GsmProfileXlsx.previousMonth() }
    var needsImportOfferCheck: Bool { !UserDefaults.standard.bool(forKey: offerKey) }

    init(api: any GsmProfileServing, cacheID: String? = nil) {
        self.api = api
        accountID = cacheID
        cacheKey = AppOfflineSnapshotStore.scopedKey("gsm-profile", userID: cacheID)
        draftKey = AppOfflineSnapshotStore.scopedKey("gsm-profile-draft", userID: cacheID)
        offerKey = AppOfflineSnapshotStore.scopedKey("gsm-profile-import-offered", userID: cacheID)
        isApplying = true
        if let snapshot = AppOfflineSnapshotStore.load(GsmProfile.self, key: cacheKey) {
            baseline = snapshot.value
            baseline.employeePhone = GsmPhoneFormatter.format(baseline.employeePhone)
            profile = baseline
            lastUpdatedAt = snapshot.updatedAt
        }
        if let draft = AppOfflineSnapshotStore.load(Draft.self, key: draftKey)?.value {
            profile = draft.profile
            imported = draft.imported
            hasDraft = true
        }
        isApplying = false
    }

    func load() async {
        guard !isBusy else { return }
        isLoading = true
        isProfileReady = false
        isServerConfirmedEmpty = false
        errorMessage = nil
        let startedRevision = revision
        defer { isLoading = false }
        do {
            let loaded = try await api.fetchProfile()
            try Task.checkCancellation()
            baseline = loaded.profile
            isProfileReady = true
            isServerConfirmedEmpty = !loaded.profileExists
            if loaded.profileExists { UserDefaults.standard.set(true, forKey: offerKey) }
            availableFuelTypes = loaded.availableFuelTypes.isEmpty ? Self.fallbackFuelTypes : loaded.availableFuelTypes
            if !hasDraft, revision == startedRevision {
                isApplying = true
                profile = loaded.profile
                isApplying = false
            }
            lastUpdatedAt = Date()
            AppOfflineSnapshotStore.save(loaded.profile, key: cacheKey)
            do { projects = try await api.fetchProjects() }
            catch is CancellationError { throw CancellationError() }
            catch { /* Keep the last catalog; unresolved import fields remain manual. */ }
            if isServerConfirmedEmpty, !hasDraft, !UserDefaults.standard.bool(forKey: offerKey) {
                isImportOfferPresented = true
            }
        } catch is CancellationError { return }
        catch { errorMessage = appUserFacingErrorMessage(error) }
    }

    func acknowledgeImportOffer() {
        UserDefaults.standard.set(true, forKey: offerKey)
        isImportOfferPresented = false
    }

    func importReport(_ url: URL) async {
        guard canImport else { return }
        acknowledgeImportOffer()
        isImporting = true
        errorMessage = nil
        notice = nil
        defer { isImporting = false }
        let expectedMonth = expectedImportMonth
        let catalog = projects
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try GsmProfileXlsx.read(url, expectedMonth: expectedMonth, projects: catalog)
            }.value
            try Task.checkCancellation()
            imported = result
            profile = result.profile
            hasDraft = true
            persistDraft()
            notice = "Проверьте все поля. Данные сохранятся только после нажатия «Сохранить»."
        } catch is CancellationError { return }
        catch { errorMessage = appUserFacingErrorMessage(error) }
    }

    private func persistDraft() {
        AppOfflineSnapshotStore.save(Draft(profile: profile, imported: imported), key: draftKey)
    }

    func save(vehicleStore: VehicleStore? = nil, sessionStore: AppSessionStore? = nil) async -> Bool {
        guard canSave else { return false }
        isSaving = true
        acknowledgeImportOffer()
        notice = nil
        errorMessage = nil
        defer { isSaving = false }
        do {
            var pending = profile
            pending.employeePhone = GsmPhoneFormatter.format(pending.employeePhone)
            guard GsmPhoneFormatter.isComplete(pending.employeePhone) else {
                throw AppServiceError.message("Введите телефон полностью: +7(XXX)XXX-XX-XX.")
            }
            if let pos = projects.first(where: { $0.id == pending.posProjectID }) {
                pending.budgetCode = pos.budgetCode
                pending.projectName = pos.name
            }
            var existingVehicle: Vehicle?
            let needsVehicleLink = pending.vehicleID == nil && !pending.carModel.isEmpty && !pending.licensePlate.isEmpty
            if needsVehicleLink, let vehicleStore {
                existingVehicle = try await vehicleStore.gsmVehicle(matching: pending.licensePlate)
                pending.vehicleID = existingVehicle?.id
            }
            var accepted = try await api.saveProfile(pending)
            // A partially saved profile must remain recoverable as a local draft.
            baseline = accepted
            isServerConfirmedEmpty = false
            AppOfflineSnapshotStore.save(accepted, key: cacheKey)
            if needsVehicleLink, let vehicleStore {
                do {
                    let vehicle: Vehicle
                    if let existingVehicle { vehicle = existingVehicle }
                    else { vehicle = try await vehicleStore.createGsmVehicle(from: accepted) }
                    if accepted.vehicleID != vehicle.id {
                        accepted.vehicleID = vehicle.id
                        accepted = try await api.saveProfile(accepted)
                    }
                } catch {
                    throw AppServiceError.message("Профиль принят, но связь с «Авто» не сохранена. Повторите «Сохранить»: \(error.localizedDescription)")
                }
            }
            let confirmed = try await api.fetchProfile()
            guard confirmed.profileExists, confirmed.profile == accepted else {
                throw AppServiceError.message("Сервер не подтвердил сохранённые данные ГСМ-профиля. Повторите «Сохранить».")
            }
            if let vehicleID = accepted.vehicleID, let vehicleStore {
                try await vehicleStore.confirmGsmVehicle(id: vehicleID)
                vehicleStore.applyGsmProfile(confirmed.profile)
            }
            if imported != nil {
                guard let sessionStore else {
                    throw AppServiceError.message("Откройте ГСМ профиль заново для заполнения профиля LumaWork.")
                }
                do { try await sessionStore.fillProfileFromGsm(confirmed.profile, expectedAccountID: accountID) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    throw AppServiceError.message("ГСМ и авто сохранены, но профиль LumaWork не заполнен. Повторите «Сохранить»: \(error.localizedDescription)")
                }
            }
            accepted = confirmed.profile
            isApplying = true
            profile = accepted
            isApplying = false
            baseline = accepted
            imported = nil
            hasDraft = false
            isServerConfirmedEmpty = false
            revision += 1
            lastUpdatedAt = Date()
            AppOfflineSnapshotStore.save(accepted, key: cacheKey)
            AppOfflineSnapshotStore.remove(key: draftKey)
            AppOfflineSnapshotStore.save(accepted.fuelTypes, key: AppOfflineSnapshotStore.scopedKey("fuel-types", userID: accountID))
            NotificationCenter.default.post(name: .gsmProfileSaved, object: nil, userInfo: ["accountID": accountID ?? "", "fuelTypes": accepted.fuelTypes])
            notice = "ГСМ профиль сохранён."
            return true
        } catch is CancellationError { return false }
        catch {
            hasDraft = true
            persistDraft()
            errorMessage = appUserFacingErrorMessage(error)
            return false
        }
    }
}

struct GsmReportAPI {
    private struct RequestBody: Encodable {
        let month: String
    }

    private static let monthPattern = #"^\d{4}-(0[1-9]|1[0-2])$"#

    private let apiOrigin: String?
    private let authToken: String?
    private let session: URLSession

    init(config: AppConfig, authToken: String?, session: URLSession = .shared) {
        self.apiOrigin = config.lumaWorkAPIOrigin
        self.authToken = authToken
        self.session = session
    }

    func sendReport(month: String) async throws -> GsmReportResponse {
        let normalizedMonth = month.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidMonth(normalizedMonth) else {
            throw AppServiceError.message("Месяц должен быть в формате YYYY-MM.")
        }

        guard let authToken, !authToken.isEmpty, let reportURL else {
            throw AppServiceError.message("Требуется авторизация.")
        }

        var request = URLRequest(url: reportURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(RequestBody(month: normalizedMonth))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            switch AppErrorPresentation.classification(for: error) {
            case .cancellation:
                throw CancellationError()
            case .network:
                throw error
            case .domain:
                throw AppServiceError.message("Не удалось отправить отчет.")
            }
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppServiceError.message("Сервер вернул неизвестный ответ.")
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw AppServiceError.message(
                "\(backendMessage(from: data) ?? "Ошибка отправки отчета"). HTTP \(httpResponse.statusCode)"
            )
        }

        let result = try JSONDecoder().decode(GsmReportResponse.self, from: data)
        guard result.success else {
            throw AppServiceError.message(
                "\(backendMessage(from: data) ?? "Сервер не подтвердил отправку отчета"). HTTP \(httpResponse.statusCode)"
            )
        }
        return result
    }

    func fetchStartOdometerSuggestion(month: String) async throws -> Int? {
        let normalizedMonth = month.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidMonth(normalizedMonth) else {
            throw AppServiceError.message("Месяц должен быть в формате YYYY-MM.")
        }
        guard let authToken, !authToken.isEmpty,
              let endpoint = endpointURL(path: "api/v2/gsm/odometer-suggestion"),
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw AppServiceError.message("Требуется авторизация.")
        }
        components.queryItems = [URLQueryItem(name: "month", value: normalizedMonth)]
        guard let url = components.url else {
            throw AppServiceError.message("Не удалось подготовить запрос одометра.")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode) else {
            throw AppServiceError.message(backendMessage(from: data) ?? "Не удалось получить одометр из прошлого отчёта.")
        }
        let suggestion = try JSONDecoder().decode(GsmOdometerSuggestionResponse.self, from: data)
        guard suggestion.month == normalizedMonth else { return nil }
        return suggestion.startOdometer
    }

    static func isValidMonth(_ value: String) -> Bool {
        value.range(of: monthPattern, options: .regularExpression) != nil
    }

    private var reportURL: URL? {
        endpointURL(path: "api/v2/gsm/report")
    }

    private func endpointURL(path: String) -> URL? {
        guard let apiOrigin,
              let originURL = URL(string: apiOrigin.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return originURL.appendingPathComponent(path)
    }

    private func backendMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }

        if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if stringValue(payload["error"]) == "GSM_PROFILE_REQUIRED" {
                return "Заполните ГСМ профиль в настройках."
            }

            if let message = [
                stringValue(payload["message"]),
                stringValue(payload["error"]),
                stringValue(payload["errorOutput"]),
                stringValue(payload["output"])
            ]
            .compactMap({ $0.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty })
            .first {
                return message
            }
        }

        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }
}

@Observable
final class GsmReportStore {
    enum SendOutcome: Equatable {
        case success(String)
        case failure(String)
        case cancelled
    }

    private let api: GsmReportAPI
    private var odometerSuggestions: [String: Int] = [:]
    private var monthsWithoutOdometerSuggestion = Set<String>()
    private var odometerSuggestionRequestsInFlight: [String: UUID] = [:]

    private(set) var isSending = false
    var notice: String?
    var errorMessage: String?

    init(api: GsmReportAPI) {
        self.api = api
    }

    func invalidateOdometerSuggestions() {
        monthsWithoutOdometerSuggestion.removeAll()
        odometerSuggestions.removeAll()
        odometerSuggestionRequestsInFlight.removeAll()
    }

    func suggestedStartOdometer(for month: String) async -> Int? {
        if let cached = odometerSuggestions[month] { return cached }
        guard !monthsWithoutOdometerSuggestion.contains(month),
              odometerSuggestionRequestsInFlight[month] == nil else { return nil }
        let requestID = UUID()
        odometerSuggestionRequestsInFlight[month] = requestID
        defer {
            if odometerSuggestionRequestsInFlight[month] == requestID {
                odometerSuggestionRequestsInFlight.removeValue(forKey: month)
            }
        }

        do {
            let fetched = try await api.fetchStartOdometerSuggestion(month: month)
            guard odometerSuggestionRequestsInFlight[month] == requestID else { return nil }
            guard let value = fetched else {
                monthsWithoutOdometerSuggestion.insert(month)
                return nil
            }
            odometerSuggestions[month] = value
            return value
        } catch {
            return nil
        }
    }

    func send(month: String) async -> SendOutcome {
        guard !isSending else { return .cancelled }

        let normalizedMonth = month.trimmingCharacters(in: .whitespacesAndNewlines)
        guard GsmReportAPI.isValidMonth(normalizedMonth) else {
            let message = "Месяц должен быть в формате YYYY-MM."
            errorMessage = message
            notice = nil
            return .failure(message)
        }

        isSending = true
        notice = nil
        errorMessage = nil
        defer { isSending = false }

        do {
            let response = try await api.sendReport(month: normalizedMonth)
            if response.skipEmail != true, !response.confirmsEmailDelivery {
                let message = "ГСМ отчет сформирован, но письмо не отправлено. Повторите попытку."
                errorMessage = message
                return .failure(message)
            }
            let message = successMessage(from: response)
            notice = message
            return .success(message)
        } catch is CancellationError {
            return .cancelled
        } catch {
            guard let message = failureMessage(from: error) else {
                return .cancelled
            }
            errorMessage = message
            return .failure(message)
        }
    }

    private func failureMessage(from error: Error) -> String? {
        switch AppErrorPresentation.classification(for: error) {
        case .cancellation:
            return nil
        case let .network(kind):
            return kind.message
        case .domain:
            return appUserFacingErrorMessage(
                error,
                fallback: "Не удалось отправить ГСМ отчет.",
                showsNetworkBanner: false
            ) ?? "Не удалось отправить ГСМ отчет."
        }
    }

    private func successMessage(from response: GsmReportResponse) -> String {
        let fileName = response.outputFileName?.nilIfEmpty ?? "Excel-отчет"
        guard response.confirmsEmailDelivery,
              let email = response.sentToEmail?.nilIfEmpty else {
            return "\(fileName) сформирован."
        }
        return "\(fileName) отправлен на \(email)."
    }
}

private extension GsmReportResponse {
    var confirmsEmailDelivery: Bool {
        sent == true || status?.uppercased() == "SENT"
    }
}

struct GsmReportScreen: View {
    @State var store: GsmReportStore
    @State private var selectedYear: Int
    @State private var selectedMonth: Int
    private let onFinished: () -> Void

    init(
        store: GsmReportStore,
        calendar: Calendar = .current,
        now: Date = .now,
        onFinished: @escaping () -> Void = {}
    ) {
        _store = State(initialValue: store)
        let components = calendar.dateComponents([.year, .month], from: now)
        _selectedYear = State(initialValue: components.year ?? 2026)
        _selectedMonth = State(initialValue: components.month ?? 1)
        self.onFinished = onFinished
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("ГСМ отчет")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(AppTheme.ink)

                    Text("Выберите месяц и отправьте отчет на почту.")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.mutedTint)
                }

                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Месяц")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(AppTheme.ink)
                        Spacer()
                        AppBadge(text: monthKey, tint: AppTheme.secondaryTint)
                    }

                    HStack(spacing: 12) {
                        Picker("Месяц", selection: $selectedMonth) {
                            ForEach(1 ... 12, id: \.self) { month in
                                Text(monthName(month)).tag(month)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Picker("Год", selection: $selectedYear) {
                            ForEach(yearRange, id: \.self) { year in
                                Text(String(year)).tag(year)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12)
                    .background(AppTheme.softFill.opacity(0.66), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(AppTheme.border, lineWidth: 1)
                    )

                    Button {
                        Task {
                            await sendReport()
                        }
                    } label: {
                        HStack(spacing: 10) {
                            if store.isSending {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "paperplane.fill")
                            }
                            Text(store.isSending ? "Отправляем" : "Отправить ГСМ отчет")
                        }
                    }
                    .buttonStyle(AppActionButtonStyle())
                    .disabled(store.isSending || !GsmReportAPI.isValidMonth(monthKey))
                }
                .padding(18)
                .background(AppTheme.cardSurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(AppTheme.border, lineWidth: 1)
                )
            }
            .padding(20)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle("ГСМ")
        .navigationBarTitleDisplayMode(.inline)
        .appSidebarBackButton()
    }

    @MainActor
    private func sendReport() async {
        switch await store.send(month: monthKey) {
        case let .success(message):
            AppBannerCenter.shared.show(message, style: .success)
            onFinished()
        case let .failure(message):
            AppBannerCenter.shared.show(message, style: .error)
            onFinished()
        case .cancelled:
            break
        }
    }

    private var monthKey: String {
        String(format: "%04d-%02d", selectedYear, selectedMonth)
    }

    private var yearRange: ClosedRange<Int> {
        let currentYear = Calendar.current.component(.year, from: .now)
        return max(2020, currentYear - 5) ... currentYear + 1
    }

    private func monthName(_ month: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = AppLocale.russian
        return formatter.standaloneMonthSymbols[max(0, month - 1)]
            .capitalized(with: AppLocale.russian)
    }
}

struct GsmProfileSettingsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: GsmProfileSettingsStore
    @Bindable var vehicleStore: VehicleStore
    let sessionStore: AppSessionStore
    var importOnOpen = false
    @State private var didOpenInitialImporter = false
    @State private var pendingVehicle: Vehicle?
    @State private var isAddVehiclePresented = false
    @State private var isFileImporterPresented = false
    @State private var isReplaceDraftPresented = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if store.isLoading || store.isImporting { ProgressView().frame(maxWidth: .infinity) }
                if store.isServerConfirmedEmpty { importCard }
                gsmVehicleCard
                if store.profile.vehicleID == nil {
                    field("Марка и модель для отчёта", text: $store.profile.carModel)
                    field("Госномер для отчёта", text: $store.profile.licensePlate)
                }
                projectSelector(title: "Проект POS", selection: $store.profile.posProjectID)
                projectSelector(title: "Проект АРМ", selection: $store.profile.armProjectID)
                field("ФИО сотрудника", text: $store.profile.employeeFullName)
                field("Короткое имя", text: $store.profile.employeeShortName)
                field("Имя для подписи", text: $store.profile.employeeReportSignName)
                field("Уполномоченный ФИО", text: $store.profile.authorizedFullName)
                field("Уполномоченный кратко", text: $store.profile.authorizedShortName)
                field("Должность", text: $store.profile.employeeJobTitle)
                field("Компания", text: $store.profile.employeeCompany)
                field("Адрес", text: $store.profile.employeeAddress)
                phoneField
                field("Водительское удостоверение", text: $store.profile.driverLicenseNumber)
                field("Топливная карта", text: $store.profile.fuelCardNumber)
                fuelTypesSelector
                reportStartMonthSelector
                numberField("Норма топлива", value: $store.profile.fuelNorm)
                field("Стартовый одометр", text: Binding(
                    get: { String(store.profile.defaultStartOdometer) },
                    set: { store.profile.defaultStartOdometer = Int($0.filter(\.isNumber)) ?? 0 }
                ))
                .keyboardType(.numberPad)
                .disabled(!store.isServerConfirmedEmpty)
                if let imported = store.imported {
                    importDetails(imported)
                }

                if let notice = store.notice {
                    AppNoticeBanner(text: notice, tint: AppTheme.secondaryTint)
                }
                if let errorMessage = store.errorMessage {
                    AppNoticeBanner(text: errorMessage, tint: AppTheme.dangerTint, isCritical: true)
                }
            }
            .padding(20)
            .disabled(store.isBusy)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle("ГСМ профиль")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ModalConfirmButton(
                    action: {
                        Task {
                            guard await store.save(vehicleStore: vehicleStore, sessionStore: sessionStore) else { return }
                            AppHaptics.trigger()
                            dismiss()
                        }
                    },
                    isDisabled: !store.canSave,
                    isLoading: store.isSaving,
                    accessibilityLabel: "Сохранить ГСМ профиль"
                )
            }
        }
        .task {
            async let profile: Void = store.load()
            async let vehicles: Void = vehicleStore.loadForGsm()
            _ = await (profile, vehicles)
            if importOnOpen, !didOpenInitialImporter, store.canImport {
                didOpenInitialImporter = true
                store.acknowledgeImportOffer()
                if store.hasUnsavedChanges { isReplaceDraftPresented = true }
                else { isFileImporterPresented = true }
            }
        }
        .fileImporter(isPresented: $isFileImporterPresented, allowedContentTypes: [UTType(filenameExtension: "xlsx") ?? .spreadsheet], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { Task { await store.importReport(url) } }
            case .failure(let error):
                store.errorMessage = appUserFacingErrorMessage(error)
            }
        }
        .confirmationDialog("Заменить текущий черновик?", isPresented: $isReplaceDraftPresented, titleVisibility: .visible) {
            Button("Выбрать XLSX", role: .destructive) { isFileImporterPresented = true }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Поля будут заменены только после успешного чтения файла.")
        }
        .interactiveDismissDisabled(store.isSaving || store.isImporting)
        .navigationBarBackButtonHidden(store.isSaving || store.isImporting)
        .confirmationDialog(
            "Изменить автомобиль для ГСМ-отчёта?",
            isPresented: Binding(get: { pendingVehicle != nil }, set: { if !$0 { pendingVehicle = nil } })
        ) {
            Button("Подтвердить") {
                if let vehicle = pendingVehicle { apply(vehicle) }
                pendingVehicle = nil
            }
            Button("Отмена", role: .cancel) { pendingVehicle = nil }
        } message: {
            Text("Выбор в карусели и назначение основного авто не меняют рабочий автомобиль автоматически.")
        }
        .sheet(isPresented: $isAddVehiclePresented) {
            AddVehicleFlow(store: vehicleStore)
                .appEditorSheetStyle()
        }
    }

    private var importCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Первое заполнение").font(.headline)
            Text("Загрузите отчёт ГСМ за \(store.expectedImportMonth) или заполните поля вручную.")
                .font(.subheadline).foregroundStyle(AppTheme.mutedTint)
            Button("Загрузить отчёт XLSX", systemImage: "square.and.arrow.down") {
                store.acknowledgeImportOffer()
                if store.hasUnsavedChanges { isReplaceDraftPresented = true }
                else { isFileImporterPresented = true }
            }
            .buttonStyle(.bordered)
            .disabled(!store.canImport)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func importDetails(_ imported: GsmProfileImport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Проверьте все поля").font(.headline)
            Text("При сохранении ФИО и должность дополнят пустые поля профиля LumaWork. Город переносится только при явном указании в адресе; заполненные поля сохранятся.")
                .font(.caption).foregroundStyle(AppTheme.mutedTint)
            if let city = store.profile.fillingUserProfile(.empty).city {
                Text("Город из адреса: \(city)").font(.caption)
            }
            ForEach(imported.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(AppTheme.mutedTint) }
            DisclosureGroup("Источники данных") {
                ForEach(imported.sources.keys.sorted(), id: \.self) { key in
                    Text("\(key): \(imported.sources[key] ?? "")")
                        .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var gsmVehicleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Автомобиль для ГСМ-отчёта")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppTheme.mutedTint)

            if let vehicle = selectedVehicle {
                HStack(spacing: 12) {
                    Group {
                        CachedVehicleImage(url: vehicle.imageURL)
                    }
                    .frame(width: 104, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(vehicle.displayName).font(.headline).foregroundStyle(AppTheme.ink)
                        Text(vehicle.licensePlate ?? "Номер не указан")
                            .font(.subheadline.monospaced()).foregroundStyle(AppTheme.mutedTint)
                    }
                    Spacer()
                }
            } else if !store.profile.carModel.isEmpty || !store.profile.licensePlate.isEmpty {
                Text(store.profile.carModel).font(.headline).foregroundStyle(AppTheme.ink)
                Text(store.profile.licensePlate).font(.subheadline.monospaced()).foregroundStyle(AppTheme.mutedTint)
                Text("Автомобиль будет связан с профилем после «Сохранить».")
                    .font(.caption).foregroundStyle(AppTheme.mutedTint)
            } else {
                Text("Автомобиль не выбран").font(.headline).foregroundStyle(AppTheme.ink)
            }

            if vehicleStore.vehicles.isEmpty {
                Button("Добавить автомобиль") { isAddVehiclePresented = true }
                    .buttonStyle(.borderedProminent)
            } else {
                Menu("Выбрать другой автомобиль") {
                    ForEach(vehicleStore.vehicles) { vehicle in
                        Button(vehicle.displayName) { pendingVehicle = vehicle }
                    }
                }
                if let primary = vehicleStore.vehicles.first(where: \.isPrimary), primary.id != store.profile.vehicleID {
                    Button("Использовать основное авто") { pendingVehicle = primary }
                }
            }

            Text("Марка, модель и госномер редактируются в разделе «Авто».")
                .font(.caption).foregroundStyle(AppTheme.mutedTint)
        }
        .padding(14)
        .background(AppTheme.cardSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
    }

    private var selectedVehicle: Vehicle? {
        vehicleStore.vehicles.first { $0.id == store.profile.vehicleID }
    }

    private func apply(_ vehicle: Vehicle) {
        store.profile.vehicleID = vehicle.id
        store.profile.carModel = vehicle.modelLine
        store.profile.licensePlate = vehicle.licensePlate ?? ""
        if let settings = vehicle.gsmSettings {
            store.profile.fuelNorm = settings.fuelNorm
            if store.profile.fuelTypes.isEmpty, !settings.fuelType.isEmpty {
                store.profile.fuelTypes = [settings.fuelType]
                store.profile.fuelType = settings.fuelType
            }
            store.profile.reportStartMonth = settings.reportStartMonth
        }
    }

    private func projectSelector(title: String, selection: Binding<String?>) -> some View {
        let selected = store.projects.first { $0.id == selection.wrappedValue }
        return VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppTheme.mutedTint)
            Menu {
                ForEach(store.projects) { project in
                    Button {
                        selection.wrappedValue = project.id
                    } label: {
                        Label(project.name, systemImage: project.id == selection.wrappedValue ? "checkmark" : "circle")
                    }
                }
                if title.contains("АРМ"), selection.wrappedValue != nil {
                    Divider()
                    Button("Не использовать АРМ", role: .destructive) {
                        selection.wrappedValue = nil
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(selected?.name ?? "Выбрать проект")
                            .foregroundStyle(selected == nil ? AppTheme.mutedTint : AppTheme.ink)
                            .lineLimit(2)
                        if let selected {
                            Text(selected.budgetCode)
                                .font(.caption.monospaced())
                                .foregroundStyle(AppTheme.mutedTint)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedTint)
                }
                .padding(12)
                .background(AppTheme.cardSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    private var fuelTypesSelector: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Типы топлива")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppTheme.mutedTint)
            Menu {
                ForEach(store.availableFuelTypes, id: \.self) { fuelType in
                    Button {
                        toggleFuelType(fuelType)
                    } label: {
                        Label(
                            fuelType,
                            systemImage: store.profile.fuelTypes.contains(fuelType) ? "checkmark.circle.fill" : "circle"
                        )
                    }
                }
            } label: {
                HStack {
                    Text(store.profile.fuelTypes.isEmpty ? "Выбрать типы" : store.profile.fuelTypes.joined(separator: ", "))
                        .foregroundStyle(store.profile.fuelTypes.isEmpty ? AppTheme.mutedTint : AppTheme.ink)
                        .multilineTextAlignment(.leading)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedTint)
                }
                .padding(12)
                .background(AppTheme.cardSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    private var reportStartMonthSelector: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Стартовый месяц")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppTheme.mutedTint)
            HStack(spacing: 10) {
                Picker("Месяц", selection: reportStartMonthBinding) {
                    ForEach(1 ... 12, id: \.self) { month in
                        Text(monthName(month)).tag(month)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)

                Picker("Год", selection: reportStartYearBinding) {
                    ForEach(2020 ... Calendar.current.component(.year, from: Date()) + 2, id: \.self) { year in
                        Text(String(year)).tag(year)
                    }
                }
                .pickerStyle(.menu)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(AppTheme.cardSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
        }
    }

    private var phoneField: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Телефон")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppTheme.mutedTint)
            GsmPhoneTextField(text: $store.profile.employeePhone)
                .padding(12)
                .background(AppTheme.cardSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
        }
    }

    private var reportStartMonthBinding: Binding<Int> {
        Binding(
            get: { Int(store.profile.reportStartMonth.split(separator: "-").last ?? "4") ?? 4 },
            set: { setReportStart(year: reportStartYearBinding.wrappedValue, month: $0) }
        )
    }

    private var reportStartYearBinding: Binding<Int> {
        Binding(
            get: { Int(store.profile.reportStartMonth.split(separator: "-").first ?? "2026") ?? 2026 },
            set: { setReportStart(year: $0, month: reportStartMonthBinding.wrappedValue) }
        )
    }

    private func setReportStart(year: Int, month: Int) {
        store.profile.reportStartMonth = String(format: "%04d-%02d", year, month)
    }

    private func monthName(_ month: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = AppLocale.russian
        return formatter.standaloneMonthSymbols[month - 1]
            .capitalized(with: AppLocale.russian)
    }

    private func toggleFuelType(_ fuelType: String) {
        if let index = store.profile.fuelTypes.firstIndex(of: fuelType) {
            guard store.profile.fuelTypes.count > 1 else { return }
            store.profile.fuelTypes.remove(at: index)
        } else {
            store.profile.fuelTypes.append(fuelType)
        }
        store.profile.fuelType = store.profile.fuelTypes.first ?? ""
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppTheme.mutedTint)
            TextField(title, text: text)
                .textInputAutocapitalization(.never)
                .padding(12)
                .background(AppTheme.cardSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
        }
    }

    private func numberField(_ title: String, value: Binding<Double>) -> some View {
        field(title, text: Binding(
            get: { value.wrappedValue == 0 ? "" : String(value.wrappedValue) },
            set: { value.wrappedValue = Double($0.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        ))
        .keyboardType(.decimalPad)
    }

}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

#Preview {
    NavigationStack {
        GsmReportScreen(store: GsmReportStore(api: GsmReportAPI(config: AppConfig(), authToken: nil)))
    }
}
