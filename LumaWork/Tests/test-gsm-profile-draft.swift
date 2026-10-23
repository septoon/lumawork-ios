import Foundation
import OSLog

// Network/Auto boundaries are test doubles; editor and disk snapshots use production sources.
enum NetworkDiagnostics { static let logger = Logger(subsystem: "GsmProfileImportTests", category: "cache") }
enum AppServiceError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
func appUserFacingErrorMessage(_ error: Error) -> String? { error.localizedDescription }
struct Vehicle { var id: String }
@MainActor
final class VehicleStore {
    var created = 0
    var existing: Vehicle?
    var applied = false
    var failCreate = false
    func gsmVehicle(matching: String) async throws -> Vehicle? { existing }
    func createGsmVehicle(from: GsmProfile) async throws -> Vehicle {
        if failCreate { throw AppServiceError.message("Auto unavailable") }
        created += 1
        let vehicle = Vehicle(id: "vehicle")
        existing = vehicle
        return vehicle
    }
    func confirmGsmVehicle(id: String) async throws {
        guard existing?.id == id else { throw AppServiceError.message("Vehicle not found") }
    }
    func applyGsmProfile(_ profile: GsmProfile) { applied = profile.vehicleID != nil }
}
@MainActor
final class AppSessionStore {
    var profile = UserProfileData(workEmail: "Keep@Example.COM")
    var attempts = 0
    var fail = false
    func fillProfileFromGsm(_ gsm: GsmProfile, expectedAccountID: String?) async throws {
        attempts += 1
        if fail { throw AppServiceError.message("User profile unavailable") }
        profile = gsm.fillingUserProfile(profile)
    }
}
@MainActor
final class ProfileAPI: GsmProfileServing {
    var value = GsmProfile.empty
    var exists = false
    var failFetch = false
    var failSave = false
    var saves: [GsmProfile] = []
    var pauseFetch = false
    var fetchWaiter: CheckedContinuation<Void, Never>?
    func fetchProfile() async throws -> GsmProfileLoadResult {
        if pauseFetch { await withCheckedContinuation { fetchWaiter = $0 } }
        if failFetch { throw AppServiceError.message("offline") }
        return GsmProfileLoadResult(profile: value, availableFuelTypes: ["АИ-95"], profileExists: exists)
    }
    func fetchProjects() async throws -> [GsmProjectOption] { [] }
    func saveProfile(_ profile: GsmProfile) async throws -> GsmProfile {
        if failSave { throw AppServiceError.message("save failed") }
        saves.append(profile)
        value = profile
        exists = true
        return profile
    }
}

@main
struct GsmDraftTests {
    @MainActor static func main() async throws {
        var importedGsm = GsmProfile.empty
        importedGsm.employeeFullName = "  Иванов  Иван Иванович "
        importedGsm.employeeJobTitle = " Инженер "
        importedGsm.employeeAddress = "Республика Крым, г. Алушта, ул. Тестовая, 1"
        let existingUser = UserProfileData(workEmail: "Keep@Example.COM", vehicleVin: "VIN")
        let filled = importedGsm.fillingUserProfile(existingUser)
        precondition(filled == UserProfileData(firstName: "Иван", lastName: "Иванов", middleName: "Иванович", jobTitle: "Инженер", city: "Алушта", workEmail: "Keep@Example.COM", vehicleVin: "VIN"), "Fill requested user fields and preserve unrelated data")
        precondition(importedGsm.fillingUserProfile(filled) == filled, "Never overwrite existing fields")
        for name in ["Иванов И. И.", "Иванов Иван", "Иванов Иван Иванович Дополнение", "Иванов 123 Иванович"] {
            importedGsm.employeeFullName = name
            let result = importedGsm.fillingUserProfile(.empty)
            precondition(result.firstName == nil && result.lastName == nil && result.middleName == nil)
        }
        for address in ["Республика Крым, ул. Тестовая", "г. Ялта, г. Алушта"] {
            importedGsm.employeeAddress = address
            precondition(importedGsm.fillingUserProfile(.empty).city == nil)
        }
        for address in ["г.Москва, ул. Тестовая", "город Москва; ул. Тестовая", "Г. Москва, ул. Тестовая"] {
            importedGsm.employeeAddress = address
            precondition(importedGsm.fillingUserProfile(.empty).city == "Москва")
        }
        let owner = "gsm-test-" + UUID().uuidString
        let other = owner + "-other"
        defer {
            for id in [owner, other] {
                for key in ["gsm-profile", "gsm-profile-draft", "fuel-types"] {
                    AppOfflineSnapshotStore.remove(key: AppOfflineSnapshotStore.scopedKey(key, userID: id))
                }
                UserDefaults.standard.removeObject(forKey: AppOfflineSnapshotStore.scopedKey("gsm-profile-import-offered", userID: id))
            }
        }
        let api = ProfileAPI()
        let store = GsmProfileSettingsStore(api: api, cacheID: owner)
        precondition(!store.canImport && !store.isImportOfferPresented, "Cache is never evidence of empty server profile")
        api.failFetch = true
        await store.load()
        precondition(!store.canImport && !store.isLoading, "Offline must not enable import or leave loading stuck")
        api.failFetch = false
        await store.load()
        precondition(store.canImport && store.isImportOfferPresented)
        store.acknowledgeImportOffer()
        store.profile.carModel = "Manual draft"
        precondition(api.saves.isEmpty, "Editing must not save")
        let restored = GsmProfileSettingsStore(api: api, cacheID: owner)
        precondition(restored.profile.carModel == "Manual draft", "Draft must survive reopening")
        let isolated = GsmProfileSettingsStore(api: api, cacheID: other)
        precondition(isolated.profile.carModel.isEmpty, "Draft must be account scoped")
        await restored.load()
        precondition(restored.profile.carModel == "Manual draft" && !restored.isImportOfferPresented, "Late GET must preserve draft and declined offer")
        let importURL = URL(fileURLWithPath: CommandLine.arguments[1])
        await restored.importReport(importURL)
        precondition(restored.profile.defaultStartOdometer == 123456 && restored.imported != nil && api.saves.isEmpty, "Import fills draft without saving")
        restored.profile.carModel = "Manual draft"
        let cancelled = Task { await restored.importReport(importURL) }
        cancelled.cancel()
        await cancelled.value
        precondition(restored.profile.carModel == "Manual draft", "Cancellation must preserve edits")
        let invalidURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".xlsx")
        try Data("invalid".utf8).write(to: invalidURL)
        defer { try? FileManager.default.removeItem(at: invalidURL) }
        await restored.importReport(invalidURL)
        precondition(restored.profile.carModel == "Manual draft" && api.saves.isEmpty, "Bad XLSX must preserve draft and never save")
        let lateAPI = ProfileAPI()
        lateAPI.pauseFetch = true
        let late = GsmProfileSettingsStore(api: lateAPI, cacheID: other)
        let load = Task { await late.load() }
        while lateAPI.fetchWaiter == nil { await Task.yield() }
        late.profile.carModel = "Typed during GET"
        lateAPI.fetchWaiter?.resume()
        await load.value
        precondition(late.profile.carModel == "Typed during GET", "In-flight GET must not overwrite edits")
        api.failSave = true
        restored.profile.employeePhone = "+7(900)111-22-33"
        let failed = await restored.save()
        precondition(!failed && restored.hasUnsavedChanges, "Save failure retains draft")
        api.failSave = false
        restored.profile.carModel = "Imported model"
        restored.profile.licensePlate = "А001АА999"
        let auto = VehicleStore()
        auto.failCreate = true
        let partial = await restored.save(vehicleStore: auto)
        precondition(!partial && api.saves.count == 1 && restored.hasUnsavedChanges, "Partial Auto failure retains editable draft")
        auto.failCreate = false
        let userSession = AppSessionStore()
        userSession.fail = true
        let failedUserProfile = await restored.save(vehicleStore: auto, sessionStore: userSession)
        precondition(!failedUserProfile && restored.hasUnsavedChanges && restored.imported != nil && auto.created == 1, "User profile failure must preserve imported draft for retry")
        let restoredAfterPartial = GsmProfileSettingsStore(api: api, cacheID: owner)
        precondition(restoredAfterPartial.imported != nil, "Import marker survives partial save and reopen")
        userSession.fail = false
        let saved = await restored.save(vehicleStore: auto, sessionStore: userSession)
        precondition(userSession.profile.firstName == "Тест" && userSession.profile.lastName == "Тестов" && userSession.profile.workEmail == "Keep@Example.COM", "Explicit Save fills LumaWork profile and preserves unrelated fields")
        precondition(saved && auto.created == 1 && restored.profile.vehicleID == "vehicle" && auto.applied)
        precondition(!restored.hasUnsavedChanges && !restored.canImport, "Success clears draft and first-fill import")
        let clean = GsmProfileSettingsStore(api: api, cacheID: owner)
        precondition(clean.profile.vehicleID == "vehicle" && !clean.hasUnsavedChanges, "Confirmed cache survives and draft is removed")
        await clean.load()
        precondition(!clean.canImport && !clean.isImportOfferPresented, "Populated accounts never offer import")
        let retry = GsmProfileSettingsStore(api: api, cacheID: other)
        await retry.load()
        retry.profile = api.value
        retry.profile.vehicleID = nil
        let reused = await retry.save(vehicleStore: auto)
        precondition(reused && auto.created == 1 && retry.profile.vehicleID == "vehicle", "Reuse existing Auto on retry")
        api.failFetch = true
        let readbackFailed = await retry.save(vehicleStore: auto)
        precondition(!readbackFailed && retry.hasUnsavedChanges, "Readback failure must keep draft")
        api.failFetch = false
        let confirmedRetry = await retry.save(vehicleStore: auto)
        precondition(confirmedRetry && auto.created == 1, "Readback retry must reuse Auto")
        precondition(VehicleInputValidation.canonicalPlate(" А001АА 999 ") == VehicleInputValidation.canonicalPlate("a001aa999"))
        precondition(VehicleInputValidation.canonicalPlate("А001АА9991") != VehicleInputValidation.canonicalPlate("А001АА9992"), "Never truncate plate matching")
        print("GSM draft isolation, persistence, delayed GET, explicit/partial save and Auto retry: PASS")
    }
}
