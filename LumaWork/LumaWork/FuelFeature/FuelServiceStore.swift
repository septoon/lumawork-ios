import Foundation
import Observation
import OSLog

struct FuelSummaryMonth: Hashable {
    var key: String
    var label: String
    var totalMileage: Double
    var totalLiters: Double
    var fuelNorm: Double
    var fuelCost: Double
    var fuelDiff: Double
    var diffLabel: String
    var approvedRate: Double
    var compensation: Double
    var paidCompensation: Double
    var debtDeductionAmount: Double
    var debtDeductionLiters: Double
    var effectiveDebtDeductionAmount: Double
    var effectiveDebtDeductionLiters: Double
    var effectiveAppliedCompensation: Double
    var remainingCompensation: Double
    var incomingCarryoverDebtRub: Double
    var incomingCarryoverDebtLiters: Double
    var monthCarryoverDebtRub: Double
    var monthCarryoverDebtLiters: Double
    var projectedDebtDeductionFromCarryover: Double
    var projectedPayout: Double
    var isCompensationClosed: Bool
    var compensationStatusLabel: String
    var adjustments: [FuelRecord]
}

struct FuelSummaryTotals: Hashable {
    var totalMileage: Double = 0
    var totalLiters: Double = 0
    var fuelNorm: Double = 0
    var totalFuelCost: Double = 0
    var totalCompensation: Double = 0
    var totalPaidCompensation: Double = 0
    var totalDebtDeductionAmount: Double = 0
    var totalDebtDeductionLiters: Double = 0
    var effectiveDebtDeductionAmount: Double = 0
    var effectiveDebtDeductionLiters: Double = 0
    var hasEstimatedDebtDeductionAmount = false
    var hasEstimatedDebtDeductionLiters = false
    var carryoverDebtRub: Double = 0
    var carryoverDebtLiters: Double = 0
    var netCompensation: Double = 0
    var fuelDiff: Double = 0
    var diffLabel: String = ""
    var adjustedFuelDiff: Double = 0
    var adjustedDiffLabel: String = ""
}

struct FuelSummary: Hashable {
    var monthly: [FuelSummaryMonth] = []
    var totals = FuelSummaryTotals()
    var explanation = ""
    var hasData = false
}

struct FuelService {
    private let config: AppConfig
    private let authToken: String?
    private let client = HTTPClient()
    private let reportStartDate = "2026-04-01"

    init(config: AppConfig, authToken: String? = nil) {
        self.config = config
        self.authToken = authToken
    }

    func fetchRecords() async throws -> [FuelRecord] {
        guard let authToken, let url = v2URL(path: "/api/v2/fuel") else {
            throw AppServiceError.message("Требуется авторизация.")
        }
        let response = try await client.request(url, authToken: authToken)
        guard let rawRecords = dictionaryValue(response.json)?["records"] as? [Any] else {
            throw AppServiceError.message("Ответ сервера должен содержать records.")
        }
        return rawRecords.map(normalizeRecord)
    }

    func fetchFuelTypes() async throws -> [String] {
        guard let authToken, let url = v2URL(path: "/api/v2/gsm/profile") else {
            throw AppServiceError.message("Требуется авторизация.")
        }
        let response = try await client.request(url, authToken: authToken)
        let root = dictionaryValue(response.json) ?? [:]
        let profile = dictionaryValue(root["profile"]) ?? [:]
        let selected = (profile["fuelTypes"] as? [Any])?.map { stringValue($0) }.filter { !$0.isEmpty } ?? []
        if !selected.isEmpty { return selected }
        let legacy = stringValue(profile["fuelType"])
        return legacy.isEmpty ? [] : [legacy]
    }

    func create(_ input: FuelRecordInput) async throws -> FuelRecord {
        let normalizedRecord = normalizeInput(input)
        try validate(normalizedRecord)
        let recordForCreate = FuelRecord(
            id: UUID().uuidString,
            recordType: normalizedRecord.recordType,
            adjustmentKind: normalizedRecord.adjustmentKind,
            monthKey: normalizedRecord.monthKey,
            amount: normalizedRecord.amount,
            carryoverDebtRub: normalizedRecord.carryoverDebtRub,
            comment: normalizedRecord.comment,
            date: normalizedRecord.date,
            mileage: normalizedRecord.mileage,
            liters: normalizedRecord.liters,
            fuelCost: normalizedRecord.fuelCost,
            fuelType: normalizedRecord.fuelType
        )
        let payload = requestPayload(for: recordForCreate)

        guard let authToken, let url = v2URL(path: "/api/v2/fuel") else {
            throw AppServiceError.message("Требуется авторизация.")
        }
        let response = try await client.request(url, method: "POST", body: payload, authToken: authToken)
        guard let data = response.json else {
            return recordForCreate
        }
        return normalizeRecord(data)
    }

    func update(target: FuelRecord, input: FuelRecordInput) async throws -> FuelRecord {
        let normalizedRecord = normalizeInput(input)
        try validate(normalizedRecord)
        let recordForUpdate = FuelRecord(
            id: target.id,
            recordType: normalizedRecord.recordType,
            adjustmentKind: normalizedRecord.adjustmentKind,
            monthKey: normalizedRecord.monthKey,
            amount: normalizedRecord.amount,
            carryoverDebtRub: normalizedRecord.carryoverDebtRub,
            comment: normalizedRecord.comment,
            date: normalizedRecord.date,
            mileage: normalizedRecord.mileage,
            liters: normalizedRecord.liters,
            fuelCost: normalizedRecord.fuelCost,
            fuelType: normalizedRecord.fuelType
        )
        let payload = requestPayload(for: recordForUpdate)

        guard let targetID = target.id, !targetID.isEmpty else {
            throw AppServiceError.message("Запись топлива для обновления не найдена.")
        }
        guard let authToken, let url = v2URL(path: "/api/v2/fuel/\(targetID)") else {
            throw AppServiceError.message("Требуется авторизация.")
        }
        let response = try await client.request(url, method: "PUT", body: payload, authToken: authToken)
        guard let data = response.json else {
            return recordForUpdate
        }
        return normalizeRecord(data)
    }

    func delete(_ target: FuelRecord) async throws {
        guard let targetID = target.id, !targetID.isEmpty else {
            throw AppServiceError.message("Запись топлива для удаления не найдена.")
        }
        guard let authToken, let url = v2URL(path: "/api/v2/fuel/\(targetID)") else {
            throw AppServiceError.message("Требуется авторизация.")
        }
        _ = try await client.request(url, method: "DELETE", authToken: authToken)
    }

    private func normalizeRecord(_ raw: Any) -> FuelRecord {
        let dictionary = dictionaryValue(raw) ?? [:]
        let rawType = stringValue(dictionary["recordType"]).lowercased()
        let type: FuelRecord.RecordType = rawType == FuelRecord.RecordType.adjustment.rawValue ? .adjustment : .fuel
        let adjustmentKindValue = stringValue(dictionary["adjustmentKind"]).lowercased()
        let adjustmentKind: FuelRecord.AdjustmentKind? = adjustmentKindValue == FuelRecord.AdjustmentKind.compensationPayment.rawValue
            || adjustmentKindValue == "compensation_payment"
            ? .compensationPayment
            : adjustmentKindValue == FuelRecord.AdjustmentKind.debtDeduction.rawValue
                || adjustmentKindValue == "debt_deduction" ? .debtDeduction : nil
        let primaryID = stringValue(dictionary["id"]).nilIfEmpty

        return FuelRecord(
            id: primaryID ?? stringValue(dictionary["_id"]).nilIfEmpty,
            recordType: type,
            adjustmentKind: adjustmentKind,
            monthKey: stringValue(dictionary["monthKey"]).nilIfEmpty,
            amount: doubleValue(dictionary["amount"]),
            carryoverDebtRub: doubleValue(dictionary["carryoverDebtRub"]),
            comment: stringValue(dictionary["comment"]).nilIfEmpty,
            date: stringValue(dictionary["date"]),
            mileage: doubleValue(dictionary["mileage"]),
            liters: doubleValue(dictionary["liters"]),
            fuelCost: doubleValue(dictionary["fuelCost"]),
            fuelType: stringValue(dictionary["fuelType"]).nilIfEmpty,
            fuelConsumptionRate: doubleValue(dictionary["fuelConsumptionRate"]),
            source: stringValue(dictionary["source"]).nilIfEmpty,
            sourceImportId: stringValue(dictionary["sourceImportId"]).nilIfEmpty
        )
    }

    private func normalizeInput(_ input: FuelRecordInput) -> FuelRecord {
        FuelRecord(
            id: nil,
            recordType: input.recordType,
            adjustmentKind: input.adjustmentKind,
            monthKey: input.monthKey?.prefix(7).description,
            amount: input.amount,
            carryoverDebtRub: input.carryoverDebtRub,
            comment: input.comment?.nilIfEmpty,
            date: input.date,
            mileage: input.mileage,
            liters: input.liters,
            fuelCost: input.fuelCost,
            fuelType: input.fuelType?.nilIfEmpty
        )
    }

    private func validate(_ record: FuelRecord) throws {
        if record.date.isEmpty {
            throw AppServiceError.message(record.recordType == .adjustment ? "Укажите дату корректировки." : "Укажите дату записи топлива.")
        }

        if record.recordType == .fuel {
            if record.mileage == nil, record.liters == nil, record.fuelCost == nil {
                throw AppServiceError.message("Укажите пробег, бензин или стоимость перед отправкой.")
            }
            for value in [record.mileage, record.liters, record.fuelCost] {
                if let value, value < 0 {
                    throw AppServiceError.message("Числовые значения должны быть неотрицательными.")
                }
            }
            let hasRefuelingData = record.liters != nil || record.fuelCost != nil
            if record.date >= reportStartDate, hasRefuelingData {
                if record.fuelType == nil {
                    throw AppServiceError.message("Выберите тип топлива.")
                }
                if record.liters == nil {
                    throw AppServiceError.message("Начиная с 2026-04-01 укажите литры для Excel-отчёта.")
                }
                if record.fuelCost == nil {
                    throw AppServiceError.message("Начиная с 2026-04-01 укажите сумму заправки для Excel-отчёта.")
                }
            }
            return
        }

        guard let adjustmentKind = record.adjustmentKind else {
            throw AppServiceError.message("Укажите тип корректировки.")
        }

        if let monthKey = record.monthKey, !monthKey.isEmpty,
           !monthKey.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression).map({ _ in true }, default: false) {
            throw AppServiceError.message("Некорректный месяц корректировки.")
        }

        if let amount = record.amount, amount < 0 {
            throw AppServiceError.message("Некорректная сумма корректировки.")
        }
        if let liters = record.liters, liters < 0 {
            throw AppServiceError.message("Некорректное значение литров.")
        }
        if let carryover = record.carryoverDebtRub, carryover < 0 {
            throw AppServiceError.message("Некорректный остаток долга.")
        }

        if adjustmentKind == .compensationPayment, record.amount == nil {
            throw AppServiceError.message("Для выплаты укажите сумму.")
        }
        if adjustmentKind == .debtDeduction, record.amount == nil, record.liters == nil {
            throw AppServiceError.message("Для вычета долга укажите сумму или литры.")
        }
    }

    private func requestPayload(for record: FuelRecord) -> [String: Any] {
        [
            "id": record.id as Any,
            "date": record.date,
            "recordType": record.recordType.rawValue,
            "adjustmentKind": record.adjustmentKind?.rawValue as Any,
            "monthKey": record.monthKey as Any,
            "amount": record.amount as Any,
            "carryoverDebtRub": record.carryoverDebtRub as Any,
            "comment": record.comment as Any,
            "mileage": record.mileage as Any,
            "liters": record.liters as Any,
            "fuelCost": record.fuelCost as Any,
            "fuelType": record.fuelType as Any
        ].compactMapValues { value in
            if let optional = value as? OptionalProtocol, optional.isNil {
                return nil
            }
            return value
        }
    }

    private func v2URL(path: String) -> URL? {
        guard let origin = config.lumaWorkAPIOrigin?.trimmingCharacters(in: .whitespacesAndNewlines), !origin.isEmpty else {
            return nil
        }
        return URL(string: origin)?.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
}

@MainActor
@Observable
final class FuelStore {
    private static let routeMonthlyMileageCommentPrefix = "route_monthly_mileage"

    private let service: FuelService
    let importAPI: FuelImportAPI
    private let cacheKey: String
    private let fuelTypesCacheKey: String
    private var loadTask: Task<Void, Never>?
    private var pendingMonthlyMileage: [String: RouteMonthlyMileage] = [:]
    private var persistedMonthlyMileageComments: [String: String] = [:]

    var records: [FuelRecord] = []
    var availableFuelTypes: [String] = []
    var lastUpdatedAt: Date?
    var isLoading = false
    var isSubmitting = false
    var errorMessage: String?
    var notice: String?
    var importPreviewItems: [FuelImportPreviewItem] = []
    var pendingImportUploads: [FuelImportUpload] = []
    var isPreviewingImport = false
    var isCommittingImport = false
    var importErrorMessage: String?
    private var hasLoaded = false

    init(service: FuelService, importAPI: FuelImportAPI, cacheID: String? = nil) {
        self.service = service
        self.importAPI = importAPI
        cacheKey = AppOfflineSnapshotStore.scopedKey("fuel", userID: cacheID)
        fuelTypesCacheKey = AppOfflineSnapshotStore.scopedKey("fuel-types", userID: cacheID)
        if let snapshot = AppOfflineSnapshotStore.load([FuelRecord].self, key: cacheKey) {
            records = snapshot.value
            lastUpdatedAt = snapshot.updatedAt
        }
        if let snapshot = AppOfflineSnapshotStore.load([String].self, key: fuelTypesCacheKey) {
            availableFuelTypes = snapshot.value
        }
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await load(showsNetworkBanner: records.isEmpty)
    }

    func load() async {
        await load(showsNetworkBanner: true)
    }

    private func load(showsNetworkBanner: Bool) async {
        if let loadTask {
            await loadTask.value
            return
        }

        isLoading = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performLoad(showsNetworkBanner: showsNetworkBanner)
        }
        loadTask = task
        await task.value
    }

    private func performLoad(showsNetworkBanner: Bool) async {
        defer {
            isLoading = false
            loadTask = nil
        }

        do {
            errorMessage = nil
            async let recordsResult = service.fetchRecords()
            async let fuelTypesResult = service.fetchFuelTypes()
            let (loadedRecords, loadedFuelTypes) = try await (recordsResult, fuelTypesResult)
            records = loadedRecords
            availableFuelTypes = loadedFuelTypes
            AppOfflineSnapshotStore.save(availableFuelTypes, key: fuelTypesCacheKey)
            persistedMonthlyMileageComments = [:]
            for record in records {
                guard record.recordType == .fuel,
                      let comment = record.comment,
                      comment.hasPrefix(Self.routeMonthlyMileageCommentPrefix) else {
                    continue
                }
                persistedMonthlyMileageComments[String(record.date.prefix(7))] = comment
            }
            for mileage in pendingMonthlyMileage.values {
                applyMonthlyMileageLocally(mileage)
            }
            lastUpdatedAt = Date()
            AppOfflineSnapshotStore.save(records, key: cacheKey)
            hasLoaded = true

            let pendingMileage = Array(pendingMonthlyMileage.values)
            if !pendingMileage.isEmpty {
                Task { @MainActor [weak self] in
                    for mileage in pendingMileage {
                        guard !Task.isCancelled else { return }
                        await self?.persistMonthlyMileage(mileage)
                    }
                }
            }
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            errorMessage = appUserFacingErrorMessage(
                error,
                showsNetworkBanner: showsNetworkBanner
            )
            if !records.isEmpty {
                hasLoaded = true
            }
        }
    }

    func save(editing target: FuelRecord?, input: FuelRecordInput) async -> Bool {
        do {
            isSubmitting = true
            errorMessage = nil
            if let target {
                _ = try await service.update(target: target, input: input)
                notice = input.recordType == .adjustment ? "Корректировка обновлена." : "Запись топлива обновлена."
            } else {
                _ = try await service.create(input)
                notice = input.recordType == .adjustment ? "Корректировка добавлена." : "Запись топлива добавлена."
            }
            await load()
            isSubmitting = false
            return true
        } catch {
            isSubmitting = false
            errorMessage = appUserFacingErrorMessage(error)
            return false
        }
    }

    func delete(_ record: FuelRecord) async {
        do {
            errorMessage = nil
            try await service.delete(record)
            notice = record.recordType == .adjustment ? "Корректировка удалена." : "Запись топлива удалена."
            await load()
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
        }
    }

    func syncMonthlyMileage(_ mileage: RouteMonthlyMileage) async {
        pendingMonthlyMileage[mileage.monthKey] = mileage
        applyMonthlyMileageLocally(mileage)
        AppOfflineSnapshotStore.save(records, key: cacheKey)

        guard hasLoaded, !Task.isCancelled else { return }
        await persistMonthlyMileage(mileage)
    }

    private func persistMonthlyMileage(_ mileage: RouteMonthlyMileage) async {
        applyMonthlyMileageLocally(mileage)
        let candidate = monthlyMileageRecord(for: mileage.monthKey)
        let target: FuelRecord? = if let candidate,
                                    let id = candidate.id,
                                    !id.isEmpty {
            candidate
        } else {
            nil
        }
        guard mileage.totalKm > 0 || target != nil else { return }
        let syncComment = "\(Self.routeMonthlyMileageCommentPrefix)|\(mileage.latestDate)|\(mileage.totalKm)"

        if persistedMonthlyMileageComments[mileage.monthKey] == syncComment {
            pendingMonthlyMileage.removeValue(forKey: mileage.monthKey)
            return
        }

        let input = FuelRecordInput(
            recordType: .fuel,
            adjustmentKind: nil,
            monthKey: nil,
            amount: nil,
            carryoverDebtRub: nil,
            comment: syncComment,
            date: mileage.latestDate,
            mileage: Double(mileage.totalKm),
            liters: nil,
            fuelCost: nil
        )

        do {
            let savedRecord: FuelRecord
            if let target {
                savedRecord = try await service.update(target: target, input: input)
            } else {
                savedRecord = try await service.create(input)
            }
            guard !Task.isCancelled else { return }

            replaceMonthlyMileageRecord(savedRecord, monthKey: mileage.monthKey)
            persistedMonthlyMileageComments[mileage.monthKey] = syncComment
            if pendingMonthlyMileage[mileage.monthKey] == mileage {
                pendingMonthlyMileage.removeValue(forKey: mileage.monthKey)
            }
            lastUpdatedAt = Date()
            AppOfflineSnapshotStore.save(records, key: cacheKey)
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            NetworkDiagnostics.logger.debug(
                "Background fuel mileage sync postponed for \(mileage.monthKey, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func applyMonthlyMileageLocally(_ mileage: RouteMonthlyMileage) {
        let comment = "\(Self.routeMonthlyMileageCommentPrefix)|\(mileage.latestDate)|\(mileage.totalKm)"
        let record = FuelRecord(
            id: monthlyMileageRecord(for: mileage.monthKey)?.id,
            recordType: .fuel,
            adjustmentKind: nil,
            monthKey: nil,
            amount: nil,
            carryoverDebtRub: nil,
            comment: comment,
            date: mileage.latestDate,
            mileage: Double(mileage.totalKm),
            liters: nil,
            fuelCost: nil
        )

        if let index = monthlyMileageRecordIndex(for: mileage.monthKey) {
            records[index] = record
        } else if mileage.totalKm > 0 {
            records.append(record)
        }
    }

    private func replaceMonthlyMileageRecord(_ record: FuelRecord, monthKey: String) {
        if let index = monthlyMileageRecordIndex(for: monthKey) {
            records[index] = record
        } else {
            records.append(record)
        }
    }

    private func monthlyMileageRecordIndex(for monthKey: String) -> Int? {
        let monthIndices = records.indices.filter { index in
            let record = records[index]
            return record.recordType == .fuel && String(record.date.prefix(7)) == monthKey
        }

        if let taggedIndex = monthIndices.first(where: {
            records[$0].comment?.hasPrefix(Self.routeMonthlyMileageCommentPrefix) == true
        }) {
            return taggedIndex
        }

        return monthIndices
            .filter {
                let record = records[$0]
                return record.mileage != nil && record.liters == nil && record.fuelCost == nil
            }
            .max { lhs, rhs in
                let left = records[lhs]
                let right = records[rhs]
                if left.date != right.date {
                    return left.date < right.date
                }
                return left.stableID < right.stableID
            }
    }

    private func monthlyMileageRecord(for monthKey: String) -> FuelRecord? {
        monthlyMileageRecordIndex(for: monthKey).map { records[$0] }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension Optional where Wrapped == Range<String.Index> {
    func map(_ predicate: (Wrapped) -> Bool, default defaultValue: Bool) -> Bool {
        switch self {
        case .some(let range):
            return predicate(range)
        case .none:
            return defaultValue
        }
    }
}
