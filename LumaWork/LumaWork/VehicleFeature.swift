import CryptoKit
import Foundation
import Observation
import SwiftUI
import UIKit

struct Vehicle: Codable, Identifiable, Hashable {
    struct GsmSettings: Codable, Hashable {
        var fuelNorm: Double
        var fuelType: String
        var defaultStartOdometer: Int
        var reportStartMonth: String
    }

    var id: String
    var make: String?
    var model: String?
    var generation: String?
    var year: Int?
    var bodyType: String?
    var colorName: String?
    var customName: String?
    var licensePlate: String?
    var vin: String?
    var sts: String?
    var pts: String?
    var engineVolumeCm3: Int?
    var enginePowerHp: Int?
    var currentMileageKm: Int?
    var isPrimary: Bool
    var imageURL: URL?
    var imageStatus: String
    var gsmSettings: GsmSettings?
    var documents: [VehicleDocument]?

    var displayName: String {
        UserProfileData.clean(customName)
            ?? [make, model].compactMap(UserProfileData.clean).joined(separator: " ").nilIfBlank
            ?? "Автомобиль"
    }

    var modelLine: String {
        [make, model, generation].compactMap(UserProfileData.clean).joined(separator: " ")
    }

    func fillingMissingFields(from profile: UserProfileData) -> Vehicle {
        merging(profile: profile, overwritingExisting: false)
    }

    func merging(profile: UserProfileData, overwritingExisting: Bool) -> Vehicle {
        var result = self

        func mergedText(_ current: String?, _ legacy: String?) -> String? {
            guard let legacy = UserProfileData.clean(legacy) else { return current }
            return overwritingExisting || UserProfileData.clean(current) == nil ? legacy : current
        }

        func parsedNumber(_ value: String?) -> Int? {
            guard let value = UserProfileData.clean(value) else { return nil }
            let digits = value.filter(\.isNumber)
            return digits.isEmpty ? nil : Int(digits)
        }

        func mergedNumber(_ current: Int?, _ legacy: String?) -> Int? {
            guard let legacy = parsedNumber(legacy) else { return current }
            return overwritingExisting || current == nil ? legacy : current
        }

        result.customName = mergedText(customName, profile.vehicleModel)
        result.licensePlate = mergedText(licensePlate, profile.vehiclePlate)
        result.vin = mergedText(vin, profile.vehicleVin)
        result.sts = mergedText(sts, profile.vehicleSts)
        result.pts = mergedText(pts, profile.vehiclePts)
        result.colorName = mergedText(colorName, profile.vehicleColor)
        result.engineVolumeCm3 = mergedNumber(engineVolumeCm3, profile.engineVolumeCm3)
        result.enginePowerHp = mergedNumber(enginePowerHp, profile.enginePowerHp)
        result.currentMileageKm = mergedNumber(currentMileageKm, profile.initialMileageKm)
        return result
    }
}

struct VehicleDraft: Hashable {
    var licensePlate = ""
    var vin = ""
    var sts = ""
    var pts = ""
    var make = ""
    var model = ""
    var generation = ""
    var year = ""
    var bodyType = ""
    var colorName = ""
    var currentMileageKm = ""
    var engineVolumeCm3 = ""
    var enginePowerHp = ""
    var customName = ""
    var isPrimary = false

    init() {}

    init(vehicle: Vehicle) {
        licensePlate = vehicle.licensePlate ?? ""
        vin = vehicle.vin ?? ""
        sts = vehicle.sts ?? ""
        pts = vehicle.pts ?? ""
        make = vehicle.make ?? ""
        model = vehicle.model ?? ""
        generation = vehicle.generation ?? ""
        year = vehicle.year.map(String.init) ?? ""
        bodyType = vehicle.bodyType ?? ""
        colorName = vehicle.colorName ?? ""
        currentMileageKm = vehicle.currentMileageKm.map(String.init) ?? ""
        engineVolumeCm3 = vehicle.engineVolumeCm3.map(String.init) ?? ""
        enginePowerHp = vehicle.enginePowerHp.map(String.init) ?? ""
        customName = vehicle.customName ?? ""
        isPrimary = vehicle.isPrimary
    }

    init(profile: UserProfileData) {
        licensePlate = UserProfileData.clean(profile.vehiclePlate) ?? ""
        vin = UserProfileData.clean(profile.vehicleVin) ?? ""
        sts = UserProfileData.clean(profile.vehicleSts) ?? ""
        pts = UserProfileData.clean(profile.vehiclePts) ?? ""
        model = UserProfileData.clean(profile.vehicleModel) ?? ""
        colorName = UserProfileData.clean(profile.vehicleColor) ?? ""
        currentMileageKm = Self.numberString(profile.initialMileageKm)
        engineVolumeCm3 = Self.numberString(profile.engineVolumeCm3)
        enginePowerHp = Self.numberString(profile.enginePowerHp)
        customName = UserProfileData.clean(profile.vehicleModel) ?? ""
        isPrimary = true
    }

    var hasVehicleData: Bool {
        [
            licensePlate, vin, sts, pts, make, model, generation, year, bodyType,
            colorName, currentMileageKm, engineVolumeCm3, enginePowerHp, customName
        ].contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func numberString(_ value: String?) -> String {
        guard let value = UserProfileData.clean(value) else { return "" }
        return String(value.filter(\.isNumber))
    }

    var payload: [String: Any] {
        [
            "licensePlate": licensePlate,
            "vin": vin,
            "sts": sts,
            "pts": pts,
            "make": make,
            "model": model,
            "generation": generation,
            "year": Int(year) as Any,
            "bodyType": bodyType,
            "colorName": colorName,
            "currentMileageKm": Int(currentMileageKm) as Any,
            "engineVolumeCm3": Int(engineVolumeCm3) as Any,
            "enginePowerHp": Int(enginePowerHp) as Any,
            "customName": customName,
            "isPrimary": isPrimary
        ].compactMapValues { value in
            if let string = value as? String { return string.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank }
            if let optional = value as? OptionalProtocol, optional.isNil { return nil }
            return value
        }
    }
}

enum VehicleInputValidation {
    private static let latinToCyrillic: [Character: Character] = [
        "A": "А", "B": "В", "E": "Е", "K": "К", "M": "М", "H": "Н",
        "O": "О", "P": "Р", "C": "С", "T": "Т", "Y": "У", "X": "Х"
    ]
    private static let cyrillicToLatin = Dictionary(uniqueKeysWithValues: latinToCyrillic.map { ($0.value, $0.key) })
    private static let plateLetters = CharacterSet(charactersIn: "АВЕКМНОРСТУХ")
    private static let plateDigits = Set("0123456789")
    private static let vinCharacters = Set("ABCDEFGHJKLMNPRSTUVWXYZ0123456789")

    static func formatPlate(_ value: String) -> String {
        let normalized = value.uppercased().compactMap { character -> Character? in
            if let mapped = latinToCyrillic[character] { return mapped }
            return plateDigits.contains(character) || String(character).rangeOfCharacter(from: plateLetters) != nil ? character : nil
        }
        var masked: [Character] = []
        for character in normalized where masked.count < 9 {
            let expectsLetter = masked.count == 0 || masked.count == 4 || masked.count == 5
            let isLetter = String(character).rangeOfCharacter(from: plateLetters) != nil
            let isDigit = plateDigits.contains(character)
            if (expectsLetter && isLetter) || (!expectsLetter && isDigit) {
                masked.append(character)
            }
        }
        let compact = String(masked)
        guard compact.count > 6 else { return compact }
        return String(compact.prefix(6)) + " " + String(compact.dropFirst(6))
    }

    static func plateError(_ value: String) -> String? {
        let compact = value.replacingOccurrences(of: " ", with: "")
        guard !compact.isEmpty else { return "Введите государственный номер." }
        let pattern = #"^[АВЕКМНОРСТУХ]\d{3}[АВЕКМНОРСТУХ]{2}(\d{2,3})?$"#
        return compact.range(of: pattern, options: .regularExpression) == nil ? "Пример: А123ВС 82 или А123ВС 777." : nil
    }

    static func normalizedVIN(_ value: String) -> String {
        let normalized = value.uppercased().compactMap { character -> Character? in
            let latin = cyrillicToLatin[character] ?? character
            return vinCharacters.contains(latin) ? latin : nil
        }
        return String(normalized.prefix(24))
    }

    static func vinError(_ value: String) -> String? {
        guard !value.isEmpty else { return nil }
        return (value.count < 11 || value.count > 24) ? "VIN обычно содержит 17 символов; допустимо от 11 до 24." : nil
    }
}

struct VehicleAPI {
    private let config: AppConfig
    private let authToken: String?
    private let client = HTTPClient()

    init(config: AppConfig, authToken: String?) {
        self.config = config
        self.authToken = authToken
    }

    func fetchVehicles() async throws -> [Vehicle] {
        let response = try await request(path: "/api/v2/vehicles")
        let raw = dictionaryValue(response)?["vehicles"] as? [Any] ?? []
        return raw.compactMap(Self.vehicle)
    }

    func createVehicle(_ draft: VehicleDraft) async throws -> Vehicle {
        let response = try await request(path: "/api/v2/vehicles", method: "POST", body: draft.payload)
        guard let raw = dictionaryValue(response)?["vehicle"], let vehicle = Self.vehicle(raw) else {
            throw AppServiceError.message("Сервер не вернул созданный автомобиль.")
        }
        return vehicle
    }

    func updateVehicle(id: String, draft: VehicleDraft) async throws -> Vehicle {
        let response = try await request(path: "/api/v2/vehicles/\(id)", method: "PUT", body: draft.payload)
        guard let raw = dictionaryValue(response)?["vehicle"], let vehicle = Self.vehicle(raw) else {
            throw AppServiceError.message("Сервер не вернул обновлённый автомобиль.")
        }
        return vehicle
    }

    func uploadDocument(
        vehicleID: String,
        selection: VehicleDocumentSelection,
        kind: VehicleDocumentKind,
        progress: @MainActor (Double) -> Void
    ) async throws -> VehicleDocument {
        guard !selection.data.isEmpty else {
            throw AppServiceError.message("Выбранный документ пуст.")
        }
        guard selection.data.count <= 20 * 1024 * 1024 else {
            throw AppServiceError.message("Документ не должен превышать 20 МБ.")
        }

        let chunkSize = 512 * 1024
        let chunks = stride(from: 0, to: selection.data.count, by: chunkSize).map { offset in
            selection.data.subdata(in: offset ..< min(offset + chunkSize, selection.data.count))
        }
        let uploadID = UUID().uuidString
        var uploadedDocument: VehicleDocument?
        for (index, chunk) in chunks.enumerated() {
            let response = try await request(
                path: "/api/v2/vehicles/\(vehicleID)/documents/chunk",
                method: "POST",
                body: [
                    "uploadId": uploadID,
                    "documentId": selection.id,
                    "kind": kind.rawValue,
                    "fileName": selection.fileName,
                    "mimeType": selection.mimeType,
                    "chunkIndex": index,
                    "totalChunks": chunks.count,
                    "chunkBase64": chunk.base64EncodedString()
                ]
            )
            if let raw = dictionaryValue(response)?["document"] {
                uploadedDocument = Self.document(raw)
            }
            progress(Double(index + 1) / Double(chunks.count))
        }
        guard let uploadedDocument else {
            throw AppServiceError.message("Сервер не подтвердил загрузку документа.")
        }
        return uploadedDocument
    }

    func documentData(vehicleID: String, documentID: String) async throws -> Data {
        guard let authToken, let origin = config.lumaWorkAPIOrigin, let base = URL(string: origin) else {
            throw AppServiceError.message("Требуется авторизация.")
        }
        let url = base.appendingPathComponent(
            "/api/v2/vehicles/\(vehicleID)/documents/\(documentID)".trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )
        )
        var request = URLRequest(url: url)
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200 ..< 300).contains(response.statusCode) else {
            throw AppServiceError.message("Не удалось загрузить документ.")
        }
        return data
    }

    func deleteDocument(vehicleID: String, documentID: String) async throws {
        _ = try await request(
            path: "/api/v2/vehicles/\(vehicleID)/documents/\(documentID)",
            method: "DELETE"
        )
    }

    private func request(path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Any? {
        guard let authToken, let origin = config.lumaWorkAPIOrigin, let base = URL(string: origin) else {
            throw AppServiceError.message("Требуется авторизация.")
        }
        return try await client.request(
            base.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
            method: method,
            body: body,
            authToken: authToken
        ).json
    }

    static func vehicle(_ raw: Any) -> Vehicle? {
        guard let dictionary = dictionaryValue(raw) else { return nil }
        let id = stringValue(dictionary["id"])
        guard !id.isEmpty else { return nil }
        let settingsRaw = dictionaryValue(dictionary["gsmSettings"])
        let settings = settingsRaw.map {
            Vehicle.GsmSettings(
                fuelNorm: doubleValue($0["fuelNorm"]) ?? 0,
                fuelType: stringValue($0["fuelType"]),
                defaultStartOdometer: intValue($0["defaultStartOdometer"]) ?? 0,
                reportStartMonth: stringValue($0["reportStartMonth"]).nilIfBlank ?? "2026-04"
            )
        }
        return Vehicle(
            id: id,
            make: stringValue(dictionary["make"]).nilIfBlank,
            model: stringValue(dictionary["model"]).nilIfBlank,
            generation: stringValue(dictionary["generation"]).nilIfBlank,
            year: intValue(dictionary["year"]),
            bodyType: stringValue(dictionary["bodyType"]).nilIfBlank,
            colorName: stringValue(dictionary["colorName"]).nilIfBlank,
            customName: stringValue(dictionary["customName"]).nilIfBlank,
            licensePlate: stringValue(dictionary["licensePlate"]).nilIfBlank,
            vin: stringValue(dictionary["vin"]).nilIfBlank,
            sts: stringValue(dictionary["sts"]).nilIfBlank,
            pts: stringValue(dictionary["pts"]).nilIfBlank,
            engineVolumeCm3: intValue(dictionary["engineVolumeCm3"]),
            enginePowerHp: intValue(dictionary["enginePowerHp"]),
            currentMileageKm: intValue(dictionary["currentMileageKm"]),
            isPrimary: dictionary["isPrimary"] as? Bool ?? false,
            imageURL: URL(string: stringValue(dictionary["imageUrl"])),
            imageStatus: stringValue(dictionary["imageStatus"]),
            gsmSettings: settings,
            documents: (dictionary["documents"] as? [Any] ?? []).compactMap { Self.document($0) }
        )
    }

    private static func document(_ raw: Any) -> VehicleDocument? {
        guard let dictionary = dictionaryValue(raw) else { return nil }
        let id = stringValue(dictionary["id"])
        let fileName = stringValue(dictionary["fileName"])
        guard !id.isEmpty, !fileName.isEmpty else { return nil }
        return VehicleDocument(
            id: id,
            kind: VehicleDocumentKind(rawValue: stringValue(dictionary["kind"])) ?? .other,
            fileName: fileName,
            mimeType: stringValue(dictionary["mimeType"]),
            sizeBytes: intValue(dictionary["sizeBytes"]) ?? 0,
            createdAt: stringValue(dictionary["createdAt"])
        )
    }
}

@MainActor
@Observable
final class VehicleStore {
    private let api: VehicleAPI
    private let legacyProfile: UserProfileData
    private let selectionKey: String
    private let cacheKey: String
    var vehicles: [Vehicle] = []
    var selectedVehicleID: String?
    var lastUpdatedAt: Date?
    var isLoading = false
    var isSaving = false
    var documentUploadProgress: Double?
    var loadingDocumentID: String?
    var deletingDocumentID: String?
    var errorMessage: String?

    init(api: VehicleAPI, userID: String?, legacyProfile: UserProfileData) {
        self.api = api
        self.legacyProfile = legacyProfile
        selectionKey = "vehicle.last-selected.\(userID ?? "anonymous")"
        cacheKey = AppOfflineSnapshotStore.scopedKey("vehicles", userID: userID)
        selectedVehicleID = UserDefaults.standard.string(forKey: selectionKey)
        if let snapshot = AppOfflineSnapshotStore.load([Vehicle].self, key: cacheKey) {
            vehicles = snapshot.value
            lastUpdatedAt = snapshot.updatedAt
        }
    }

    var selectedVehicle: Vehicle? { vehicles.first { $0.id == selectedVehicleID } }

    func load(showsNetworkBanner: Bool = true) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            var fetchedVehicles = try await api.fetchVehicles()
            var synchronizationError: Error?
            var synchronizationIndex = fetchedVehicles.firstIndex(where: \.isPrimary)
            if synchronizationIndex == nil {
                synchronizationIndex = fetchedVehicles.indices.first
            }
            if let index = synchronizationIndex {
                let vehicle = fetchedVehicles[index]
                let mergedVehicle = vehicle.fillingMissingFields(from: legacyProfile)
                if VehicleDraft(vehicle: mergedVehicle) != VehicleDraft(vehicle: vehicle) {
                    do {
                        fetchedVehicles[index] = try await api.updateVehicle(
                            id: vehicle.id,
                            draft: VehicleDraft(vehicle: mergedVehicle)
                        )
                    } catch {
                        fetchedVehicles[index] = mergedVehicle
                        synchronizationError = error
                    }
                }
            }
            vehicles = fetchedVehicles
            lastUpdatedAt = Date()
            AppOfflineSnapshotStore.save(vehicles, key: cacheKey)
            if !vehicles.contains(where: { $0.id == selectedVehicleID }) {
                select(vehicles.first(where: \.isPrimary) ?? vehicles.first, haptic: false)
            }
            if let synchronizationError {
                errorMessage = appUserFacingErrorMessage(
                    synchronizationError,
                    showsNetworkBanner: showsNetworkBanner
                )
            }
        } catch {
            errorMessage = appUserFacingErrorMessage(
                error,
                showsNetworkBanner: showsNetworkBanner
            )
        }
    }

    func select(_ vehicle: Vehicle?, haptic: Bool = true) {
        guard selectedVehicleID != vehicle?.id else { return }
        selectedVehicleID = vehicle?.id
        UserDefaults.standard.set(vehicle?.id, forKey: selectionKey)
        if haptic { AppHaptics.trigger(.expandCollapse) }
    }

    func create(_ draft: VehicleDraft) async -> Bool {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let vehicle = try await api.createVehicle(draft)
            vehicles.append(vehicle)
            vehicles.sort { ($0.isPrimary ? 0 : 1, $0.displayName) < ($1.isPrimary ? 0 : 1, $1.displayName) }
            AppOfflineSnapshotStore.save(vehicles, key: cacheKey)
            select(vehicle)
            return true
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
            return false
        }
    }

    func update(_ vehicle: Vehicle, draft: VehicleDraft) async -> Bool {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let updated = try await api.updateVehicle(id: vehicle.id, draft: draft)
            if let index = vehicles.firstIndex(where: { $0.id == updated.id }) { vehicles[index] = updated }
            if updated.isPrimary {
                vehicles = vehicles.map { item in
                    var item = item
                    item.isPrimary = item.id == updated.id
                    return item
                }
            }
            AppOfflineSnapshotStore.save(vehicles, key: cacheKey)
            select(updated, haptic: false)
            return true
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
            return false
        }
    }

    func savePrimaryVehicle(_ draft: VehicleDraft, existingVehicleID: String?) async -> Bool {
        var primaryDraft = draft
        primaryDraft.isPrimary = true

        if let existingVehicleID,
           let vehicle = vehicles.first(where: { $0.id == existingVehicleID }) {
            return await update(vehicle, draft: primaryDraft)
        }
        if let vehicle = vehicles.first(where: \.isPrimary) ?? selectedVehicle ?? vehicles.first {
            return await update(vehicle, draft: primaryDraft)
        }
        guard primaryDraft.hasVehicleData else { return true }
        return await create(primaryDraft)
    }

    func uploadDocument(
        vehicleID: String,
        selection: VehicleDocumentSelection,
        kind: VehicleDocumentKind
    ) async -> Bool {
        documentUploadProgress = 0
        defer { documentUploadProgress = nil }
        do {
            let document = try await api.uploadDocument(
                vehicleID: vehicleID,
                selection: selection,
                kind: kind
            ) { [weak self] progress in
                self?.documentUploadProgress = progress
            }
            guard let index = vehicles.firstIndex(where: { $0.id == vehicleID }) else { return true }
            var documents = vehicles[index].documents ?? []
            documents.removeAll { $0.id == document.id }
            documents.insert(document, at: 0)
            vehicles[index].documents = documents
            AppOfflineSnapshotStore.save(vehicles, key: cacheKey)
            return true
        } catch is CancellationError {
            return false
        } catch {
            if let message = appUserFacingErrorMessage(error, fallback: "Не удалось прикрепить документ.") {
                AppBannerCenter.shared.show(message, style: .error)
            }
            return false
        }
    }

    func documentData(vehicleID: String, documentID: String) async -> Data? {
        loadingDocumentID = documentID
        defer { loadingDocumentID = nil }
        do {
            return try await api.documentData(vehicleID: vehicleID, documentID: documentID)
        } catch is CancellationError {
            return nil
        } catch {
            if let message = appUserFacingErrorMessage(error, fallback: "Не удалось открыть документ.") {
                AppBannerCenter.shared.show(message, style: .error)
            }
            return nil
        }
    }

    func deleteDocument(vehicleID: String, documentID: String) async -> Bool {
        deletingDocumentID = documentID
        defer { deletingDocumentID = nil }
        do {
            try await api.deleteDocument(vehicleID: vehicleID, documentID: documentID)
            guard let index = vehicles.firstIndex(where: { $0.id == vehicleID }) else { return true }
            vehicles[index].documents?.removeAll { $0.id == documentID }
            AppOfflineSnapshotStore.save(vehicles, key: cacheKey)
            return true
        } catch is CancellationError {
            return false
        } catch {
            if let message = appUserFacingErrorMessage(error, fallback: "Не удалось удалить документ.") {
                AppBannerCenter.shared.show(message, style: .error)
            }
            return false
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}

private actor VehicleImageDiskCache {
    static let shared = VehicleImageDiskCache()
    private var memory: [URL: Data] = [:]
    private let directory: URL
    private var hasPruned = false

    init() {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        directory = root.appendingPathComponent("LumaWork/VehicleImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func data(for url: URL) async -> Data? {
        if !hasPruned {
            pruneIfNeeded()
            hasPruned = true
        }
        if let cached = memory[url] { return cached }
        let fileURL = directory.appendingPathComponent(cacheKey(url))
        if let data = try? Data(contentsOf: fileURL), UIImage(data: data) != nil {
            memory[url] = data
            return data
        }
        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .returnCacheDataElseLoad
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, UIImage(data: data) != nil else { return nil }
            try? data.write(to: fileURL, options: .atomic)
            memory[url] = data
            return data
        } catch {
            return nil
        }
    }

    private func cacheKey(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined() + ".image"
    }

    private func pruneIfNeeded() {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }
        let entries = files.compactMap { url -> (URL, Date, Int)? in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }
        var totalSize = entries.reduce(0) { $0 + $1.2 }
        guard totalSize > 100 * 1_024 * 1_024 else { return }
        for entry in entries.sorted(by: { $0.1 < $1.1 }) where totalSize > 80 * 1_024 * 1_024 {
            try? FileManager.default.removeItem(at: entry.0)
            totalSize -= entry.2
        }
    }
}

struct CachedVehicleImage: View {
    let url: URL?
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image("CarPlaceholder").resizable().scaledToFit()
            }
        }
        .task(id: url) {
            image = nil
            guard let url, let data = await VehicleImageDiskCache.shared.data(for: url) else { return }
            image = UIImage(data: data)
        }
    }
}

struct VehicleCarousel: View {
    private static let addID = "add-vehicle"

    @Environment(\.colorScheme) private var colorScheme
    @Bindable var store: VehicleStore
    let addAction: () -> Void
    let editAction: (Vehicle) -> Void
    @State private var scrollID: String?
    @State private var isScrolling = false

    private var displayedVehicle: Vehicle? {
        guard let scrollID else { return store.selectedVehicle }
        return store.vehicles.first { $0.id == scrollID }
    }

    private var displaysAddPage: Bool {
        store.vehicles.isEmpty || scrollID == Self.addID
    }

    var body: some View {
        VStack(spacing: 0) {
                titleBlock
                    .frame(height: 90, alignment: .top)
                    .padding(.top, 18)

                GeometryReader { geometry in
                    let pageWidth = geometry.size.width * 0.86
                    let centeringInset = (geometry.size.width - pageWidth) / 2

                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 0) {
                            ForEach(store.vehicles) { vehicle in
                                CachedVehicleImage(url: vehicle.imageURL)
                                    .frame(width: pageWidth, height: 190, alignment: .center)
                                    .scaleEffect(1.46)
                                    .id(vehicle.id)
                            }
                            Image("CarPlaceholder")
                                .resizable()
                                .scaledToFit()
                                .opacity(0.94)
                                .frame(width: pageWidth, height: 190, alignment: .center)
                                .scaleEffect(1.46)
                                .id(Self.addID)
                                .onTapGesture(perform: addAction)
                        }
                        .scrollTargetLayout()
                    }
                    .contentMargins(.horizontal, centeringInset, for: .scrollContent)
                    .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
                    .scrollPosition(id: $scrollID)
                    .onScrollPhaseChange { _, newPhase in
                        withAnimation(.easeOut(duration: 0.16)) { isScrolling = newPhase != .idle }
                        guard newPhase == .idle, let scrollID else { return }
                        if let vehicle = store.vehicles.first(where: { $0.id == scrollID }) {
                            guard store.selectedVehicleID != vehicle.id else { return }
                            store.select(vehicle, haptic: false)
                            AppHaptics.trigger(.carouselSelection)
                        } else if scrollID == Self.addID {
                            AppHaptics.trigger(.carouselSelection)
                        }
                    }
                }
                .frame(height: 190)

                pageIndicator
                    .frame(height: 40)

                contextualAction
                    .padding(.horizontal, 22)
                    .padding(.bottom, 24)
        }
        .frame(height: 446)
        .clipped()
        .onAppear { restoreScrollPosition() }
        .onChange(of: store.selectedVehicleID) { _, _ in restoreScrollPosition() }
        .onChange(of: store.vehicles.map(\.id)) { _, _ in restoreScrollPosition() }
    }

    @ViewBuilder private var titleBlock: some View {
        VStack(spacing: 0) {
            if displaysAddPage {
                Text("Добавьте автомобиль")
                    .font(.system(size: 31, weight: .bold, design: .rounded))
            } else if let vehicle = displayedVehicle {
                HStack(spacing: 8) {
                    Text(vehicle.displayName)
                        .lineLimit(1)
                    if vehicle.isPrimary {
                        Image(systemName: "star.circle.fill")
                            .font(.title3)
                    }
                }
                .font(.system(size: 31, weight: .bold, design: .rounded))
                if let plate = vehicle.licensePlate {
                    Text(plate)
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }
        }
        .foregroundStyle(colorScheme == .dark ? Color.white : Color(red: 0.10, green: 0.12, blue: 0.13))
        .opacity(isScrolling ? 0.12 : 1)
        .blur(radius: isScrolling ? 1.4 : 0)
        .scaleEffect(isScrolling ? 0.985 : 1)
        .animation(.easeOut(duration: 0.16), value: isScrolling)
        .contentTransition(.opacity)
    }

    private var pageIndicator: some View {
        HStack(spacing: 7) {
            ForEach(store.vehicles) { vehicle in
                Circle()
                    .fill(scrollID == vehicle.id ? activeIndicator : inactiveIndicator)
                    .frame(width: scrollID == vehicle.id ? 8 : 6, height: scrollID == vehicle.id ? 8 : 6)
            }
            Image(systemName: "plus")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(displaysAddPage ? activeIndicator : inactiveIndicator)
        }
        .animation(.easeInOut(duration: 0.18), value: scrollID)
    }

    @ViewBuilder private var contextualAction: some View {
        Button {
            if let vehicle = displayedVehicle, !displaysAddPage { editAction(vehicle) }
            else { addAction() }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: displaysAddPage ? "car.badge.plus" : "car.side")
                    .font(.title2.weight(.semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(displaysAddPage ? "Добавить по госномеру" : "Данные автомобиля")
                        .font(.headline.weight(.bold))
                    Text(displaysAddPage ? "Пошаговое заполнение" : "Изменить параметры и основное авто")
                        .font(.caption)
                        .opacity(0.72)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.bold))
                    .opacity(0.66)
            }
            .foregroundStyle(colorScheme == .dark ? Color.white : AppTheme.ink)
            .padding(.horizontal, 20)
            .frame(height: 84)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var activeIndicator: Color { colorScheme == .dark ? .white : AppTheme.primaryTint }
    private var inactiveIndicator: Color { colorScheme == .dark ? .white.opacity(0.26) : .black.opacity(0.16) }

    private func restoreScrollPosition() {
        let desired = store.vehicles.contains(where: { $0.id == store.selectedVehicleID })
            ? store.selectedVehicleID
            : (store.vehicles.first?.id ?? Self.addID)
        guard scrollID != desired, !isScrolling else { return }
        scrollID = desired
    }
}

struct AddVehicleFlow: View {
    enum Step: Int, CaseIterable { case plate, vin, identity, details, review }
    private struct SummarySpec: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: VehicleStore
    let editingVehicle: Vehicle?
    @State private var step: Step = .plate
    @State private var draft: VehicleDraft
    @State private var isEditingExisting = false
    @State private var showsDiscardConfirmation = false

    init(store: VehicleStore, editingVehicle: Vehicle? = nil) {
        self.store = store
        self.editingVehicle = editingVehicle
        if let editingVehicle {
            _draft = State(initialValue: VehicleDraft(vehicle: editingVehicle))
        } else {
            _draft = State(initialValue: VehicleDraft())
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let editingVehicle, !isEditingExisting {
                        vehicleSummary(editingVehicle)
                    } else if editingVehicle != nil {
                        existingVehicleEditor
                        if let error = existingEditorError {
                            AppNoticeBanner(text: error, tint: AppTheme.dangerTint, isCritical: true)
                        }
                    } else {
                        ProgressView(value: Double(step.rawValue + 1), total: Double(Step.allCases.count))
                        stepContent
                        if let error = currentError {
                            AppNoticeBanner(text: error, tint: AppTheme.dangerTint, isCritical: true)
                        }
                    }
                    if let vehicleID = editingVehicle?.id {
                        VehicleDocumentsSection(store: store, vehicleID: vehicleID)
                    }
                    if let error = store.errorMessage { AppNoticeBanner(text: error, tint: AppTheme.dangerTint, isCritical: true) }
                }.padding(20)
            }
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(hasUnsavedChanges)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if editingVehicle == nil, step != .plate {
                        Button {
                            step = Step(rawValue: step.rawValue - 1) ?? .plate
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .accessibilityLabel("Назад")
                    } else {
                        ModalCloseButton(action: requestClose)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let editingVehicle, !isEditingExisting {
                        Button("Редактировать автомобиль", systemImage: "pencil") {
                            AppHaptics.trigger(.expandCollapse)
                            draft = VehicleDraft(vehicle: editingVehicle)
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isEditingExisting = true
                            }
                        }
                        .labelStyle(.iconOnly)
                    } else if editingVehicle != nil, isEditingExisting {
                        ModalConfirmButton(
                            action: saveExistingVehicle,
                            isDisabled: existingEditorError != nil,
                            isLoading: store.isSaving,
                            accessibilityLabel: "Сохранить автомобиль"
                        )
                    } else if editingVehicle == nil, step == .review {
                        ModalConfirmButton(
                            action: advance,
                            isDisabled: currentError != nil,
                            isLoading: store.isSaving,
                            accessibilityLabel: "Добавить автомобиль"
                        )
                    } else if editingVehicle == nil {
                        Button("Далее", action: advance)
                            .disabled(currentError != nil || store.isSaving)
                    }
                }
            }
            .confirmationDialog(editingVehicle == nil ? "Удалить введённые данные?" : "Не сохранять изменения?", isPresented: $showsDiscardConfirmation) {
                Button(editingVehicle == nil ? "Удалить" : "Не сохранять", role: .destructive) { dismiss() }
                Button("Продолжить заполнение", role: .cancel) {}
            }
        }
    }

    private func vehicleSummary(_ vehicle: Vehicle) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(AppTheme.primaryTint.opacity(0.12))
                        .frame(width: 230, height: 150)
                        .blur(radius: 34)

                    CachedVehicleImage(url: vehicle.imageURL)
                        .frame(maxWidth: .infinity)
                        .frame(height: 185)
                        .scaleEffect(1.46)
                }
                .frame(height: 190)

                if let plate = vehicle.licensePlate {
                    Text(plate)
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                }

                HStack(spacing: 8) {
                    summaryChip(vehicle.year.map(String.init) ?? "Год не указан", systemName: "calendar")
                    summaryChip(cleanValue(vehicle.colorName), systemName: "paintpalette")
                    if vehicle.isPrimary {
                        summaryChip("Основной", systemName: "star.fill")
                    }
                }
                .frame(maxWidth: .infinity)
            }

            specificationSection(
                title: "Автомобиль",
                systemName: "car.side",
                specs: [
                    SummarySpec(label: "Марка", value: cleanValue(vehicle.make)),
                    SummarySpec(label: "Модель", value: cleanValue(vehicle.model)),
                    SummarySpec(label: "Поколение", value: cleanValue(vehicle.generation)),
                    SummarySpec(label: "Кузов", value: cleanValue(vehicle.bodyType))
                ]
            )

            specificationSection(
                title: "Документы",
                systemName: "doc.text",
                specs: [
                    SummarySpec(label: "VIN", value: cleanValue(vehicle.vin)),
                    SummarySpec(label: "СТС", value: cleanValue(vehicle.sts)),
                    SummarySpec(label: "ПТС", value: cleanValue(vehicle.pts)),
                    SummarySpec(label: "Название", value: cleanValue(vehicle.customName))
                ],
                monospaced: true
            )

            specificationSection(
                title: "Параметры",
                systemName: "gauge.with.dots.needle.50percent",
                specs: [
                    SummarySpec(label: "Пробег", value: vehicle.currentMileageKm.map { "\($0) км" } ?? "Не указано"),
                    SummarySpec(label: "Объём", value: vehicle.engineVolumeCm3.map { "\($0) см³" } ?? "Не указано"),
                    SummarySpec(label: "Мощность", value: vehicle.enginePowerHp.map { "\($0) л.с." } ?? "Не указано"),
                    SummarySpec(label: "Цвет", value: cleanValue(vehicle.colorName))
                ]
            )
        }
    }

    private func specificationSection(
        title: String,
        systemName: String,
        specs: [SummarySpec],
        monospaced: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title.uppercased(), systemImage: systemName)
                .font(.caption.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(AppTheme.mutedTint)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 18, alignment: .topLeading),
                    GridItem(.flexible(), spacing: 18, alignment: .topLeading)
                ],
                alignment: .leading,
                spacing: 0
            ) {
                ForEach(specs) { spec in
                    VStack(alignment: .leading, spacing: 5) {
                        Rectangle()
                            .fill(AppTheme.border)
                            .frame(height: 1)
                        Text(spec.label)
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedTint)
                        Text(spec.value)
                            .font(monospaced ? .system(.body, design: .monospaced).weight(.semibold) : .body.weight(.semibold))
                            .foregroundStyle(AppTheme.ink)
                            .lineLimit(2)
                            .minimumScaleFactor(0.72)
                    }
                    .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
                }
            }
        }
    }

    private func summaryChip(_ title: String, systemName: String) -> some View {
        Label(title, systemImage: systemName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppTheme.ink)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(AppTheme.border, lineWidth: 1))
    }

    private func cleanValue(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? "Не указано"
    }

    private var existingVehicleEditor: some View {
        VStack(alignment: .leading, spacing: 18) {
            plateInput
            vinInput
            input("СТС", placeholder: "00 00 000000", text: $draft.sts, capitalization: .characters, keyboard: .asciiCapable, monospaced: true)
            input("ПТС", placeholder: "00 АА 000000", text: $draft.pts, capitalization: .characters, keyboard: .asciiCapable, monospaced: true)
            input("Марка", text: $draft.make, capitalization: .words)
            input("Модель", text: $draft.model, capitalization: .words)
            input("Поколение (необязательно)", text: $draft.generation, capitalization: .words)
            input("Год выпуска", text: $draft.year, keyboard: .numberPad)
            input("Тип кузова", text: $draft.bodyType, capitalization: .words)
            input("Цвет", text: $draft.colorName, capitalization: .words)
            input("Текущий пробег, км", text: $draft.currentMileageKm, keyboard: .numberPad)
            input("Объём двигателя, см³", text: $draft.engineVolumeCm3, keyboard: .numberPad)
            input("Мощность, л.с.", text: $draft.enginePowerHp, keyboard: .numberPad)
            input("Моё название (необязательно)", text: $draft.customName, capitalization: .sentences)
            Toggle("Основной автомобиль", isOn: $draft.isPrimary)
                .tint(AppTheme.primaryTint)
        }
    }

    @ViewBuilder private var stepContent: some View {
        switch step {
        case .plate:
            plateInput
            Text("Можно продолжить без региона и дописать его позже.").font(.footnote).foregroundStyle(AppTheme.mutedTint)
        case .vin:
            vinInput
            Text("Латинские буквы и цифры без I, O и Q. Стандартный VIN — 17 символов.")
                .font(.footnote)
                .foregroundStyle(AppTheme.mutedTint)
        case .identity:
            input("Марка", text: $draft.make, capitalization: .words)
            input("Модель", text: $draft.model, capitalization: .words)
            input("Поколение (необязательно)", text: $draft.generation, capitalization: .words)
            input("Год выпуска", text: $draft.year, keyboard: .numberPad)
        case .details:
            input("Тип кузова", text: $draft.bodyType, capitalization: .words)
            input("Цвет", text: $draft.colorName, capitalization: .words)
            input("Текущий пробег, км", text: $draft.currentMileageKm, keyboard: .numberPad)
            input("Объём двигателя, см³", text: $draft.engineVolumeCm3, keyboard: .numberPad)
            input("Мощность, л.с.", text: $draft.enginePowerHp, keyboard: .numberPad)
            input("Моё название (необязательно)", text: $draft.customName, capitalization: .sentences)
            Toggle("Основной автомобиль", isOn: $draft.isPrimary).tint(AppTheme.primaryTint)
        case .review:
            reviewRow("Автомобиль", [draft.make, draft.model, draft.generation].filter { !$0.isEmpty }.joined(separator: " "))
            reviewRow("Госномер", draft.licensePlate)
            reviewRow("VIN", draft.vin.nilIfBlank ?? "Не указан")
            reviewRow("Год", draft.year.nilIfBlank ?? "Не указан")
            reviewRow("Кузов и цвет", [draft.bodyType, draft.colorName].filter { !$0.isEmpty }.joined(separator: ", ").nilIfBlank ?? "Не указаны")
        }
    }

    private var plateInput: some View {
        input(
            "Государственный номер",
            placeholder: "А123ВС 00",
            text: Binding(get: { draft.licensePlate }, set: { draft.licensePlate = VehicleInputValidation.formatPlate($0) }),
            capitalization: .characters,
            keyboard: .asciiCapable,
            monospaced: true
        )
    }

    private var vinInput: some View {
        input(
            "VIN (необязательно)",
            placeholder: "17 символов VIN",
            text: Binding(get: { draft.vin }, set: { draft.vin = VehicleInputValidation.normalizedVIN($0) }),
            capitalization: .characters,
            keyboard: .asciiCapable,
            monospaced: true
        )
    }

    private var currentError: String? {
        switch step {
        case .plate: VehicleInputValidation.plateError(draft.licensePlate)
        case .vin: VehicleInputValidation.vinError(draft.vin)
        case .identity: draft.make.trimmingCharacters(in: .whitespaces).isEmpty || draft.model.trimmingCharacters(in: .whitespaces).isEmpty ? "Укажите марку и модель." : nil
        case .details, .review: nil
        }
    }

    private var navigationTitle: String {
        if let editingVehicle {
            return isEditingExisting ? "Редактирование" : editingVehicle.displayName
        }
        return ["Госномер", "VIN", "Автомобиль", "Детали", "Проверка"][step.rawValue]
    }

    private var existingEditorError: String? {
        VehicleInputValidation.plateError(draft.licensePlate)
            ?? VehicleInputValidation.vinError(draft.vin)
            ?? (draft.make.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Укажите марку и модель."
                : nil)
    }

    private var hasUnsavedChanges: Bool {
        if let editingVehicle {
            return isEditingExisting && draft != VehicleDraft(vehicle: editingVehicle)
        }
        return draft != VehicleDraft()
    }

    private func requestClose() {
        if hasUnsavedChanges { showsDiscardConfirmation = true }
        else { dismiss() }
    }

    private func advance() {
        guard currentError == nil else { AppHaptics.trigger(.error); return }
        if step == .review {
            Task {
                let saved = await store.create(draft)
                if saved { dismiss() }
            }
        } else {
            withAnimation(.easeInOut(duration: 0.2)) { step = Step(rawValue: step.rawValue + 1) ?? .review }
        }
    }

    private func saveExistingVehicle() {
        guard existingEditorError == nil, let editingVehicle else {
            AppHaptics.trigger(.error)
            return
        }
        AppHaptics.trigger()
        Task {
            if await store.update(editingVehicle, draft: draft) {
                dismiss()
            }
        }
    }

    private func input(
        _ title: String,
        placeholder: String? = nil,
        text: Binding<String>,
        capitalization: TextInputAutocapitalization = .never,
        keyboard: UIKeyboardType = .default,
        monospaced: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(AppTheme.mutedTint)
            TextField(placeholder ?? title, text: text)
                .textInputAutocapitalization(capitalization)
                .keyboardType(keyboard)
                .autocorrectionDisabled()
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .padding(13).background(AppTheme.cardSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
        }
    }

    private func reviewRow(_ title: String, _ value: String) -> some View {
        AppStatRow(title: title, value: value)
    }

    private func summaryRow(_ title: String, _ value: String?) -> some View {
        AppStatRow(title: title, value: value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? "Не указано")
    }
}
