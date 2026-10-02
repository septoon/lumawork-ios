import Foundation
import Observation

@MainActor
@Observable
final class ClosedRequestsStore {
    private let legacyStorageKey = "closed-requests-snapshot"
    private let merchantTINRepairStorageKey = "closed-requests-merchant-tin-repair-v2"

    var snapshot: ClosedRequestsSnapshot?
    var isImporting = false
    var isLoadingSnapshot = false
    var isDeleting = false
    var isSynchronizingClosedRequests = false
    var errorMessage: String?
    var notice: String?
    private(set) var recordsRevision: UInt64 = 0
    @ObservationIgnored private var closedSyncGeneration: UInt64 = 0

    init() {
        Task {
            await loadSnapshot()
        }
    }

    var records: [ClosedRequestRecord] {
        snapshot?.records ?? []
    }

    var needsMerchantTINRepair: Bool {
        snapshot != nil && !UserDefaults.standard.bool(forKey: merchantTINRepairStorageKey)
    }

    func markMerchantTINRepairCompleted() {
        UserDefaults.standard.set(true, forKey: merchantTINRepairStorageKey)
    }

    nonisolated static func deletionDateRange(in records: [ClosedRequestRecord]) -> ClosedRange<Date>? {
        let dates = records.compactMap(Self.deletionDate(for:))
        guard let earliestDate = dates.min(), let latestDate = dates.max() else {
            return nil
        }

        let calendar = Calendar.autoupdatingCurrent
        return calendar.startOfDay(for: earliestDate)...calendar.startOfDay(for: latestDate)
    }

    func recordCount(from startDate: Date, through endDate: Date) -> Int {
        let bounds = Self.inclusiveDayBounds(from: startDate, through: endDate)
        return records.lazy.filter { record in
            guard let date = Self.deletionDate(for: record) else { return false }
            return date >= bounds.start && date < bounds.endExclusive
        }.count
    }

    @discardableResult
    func deleteAllRecords() async -> Int {
        guard !isDeleting, !isImporting, !isLoadingSnapshot, !isSynchronizingClosedRequests else { return 0 }

        let deletedCount = records.count
        return await replaceSnapshotAfterDeletion(
            with: nil,
            deletedCount: deletedCount,
            notice: "Удалены все закрытые заявки с устройства: \(deletedCount)."
        )
    }

    @discardableResult
    func deleteRecords(from startDate: Date, through endDate: Date) async -> Int {
        guard !isDeleting, !isImporting, !isLoadingSnapshot, !isSynchronizingClosedRequests, let snapshot else { return 0 }

        let bounds = Self.inclusiveDayBounds(from: startDate, through: endDate)
        let remainingRecords = snapshot.records.filter { record in
            guard let date = Self.deletionDate(for: record) else { return true }
            return date < bounds.start || date >= bounds.endExclusive
        }
        let deletedCount = snapshot.records.count - remainingRecords.count
        guard deletedCount > 0 else {
            notice = "За выбранный период закрытые заявки не найдены."
            return 0
        }

        let updatedSnapshot: ClosedRequestsSnapshot? = remainingRecords.isEmpty
            ? nil
            : ClosedRequestsSnapshot(
                fileName: snapshot.fileName,
                importedAt: snapshot.importedAt,
                records: Self.sortRecords(remainingRecords),
                syncState: snapshot.syncState
            )
        return await replaceSnapshotAfterDeletion(
            with: updatedSnapshot,
            deletedCount: deletedCount,
            notice: "Удалено закрытых заявок: \(deletedCount)."
        )
    }

    func routeTemplateRecords(for dayKey: String, warehouseAddress: String = RouteSettings.officeAddress) async -> [ClosedRequestRecord] {
        let records = records
        return await Task.detached(priority: .userInitiated) {
            Self.routeTemplateRecords(
                from: records,
                dayKey: dayKey,
                warehouseAddress: warehouseAddress
            )
        }.value
    }

    func importSpreadsheet(from url: URL) async {
        guard !isDeleting, !isImporting, !isLoadingSnapshot, !isSynchronizingClosedRequests else { return }
        closedSyncGeneration &+= 1
        isImporting = true
        errorMessage = nil
        notice = nil

        let didAccess = url.startAccessingSecurityScopedResource()
        let existingSnapshot = snapshot
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
            isImporting = false
        }

        do {
            let merged = try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: url)
                let parsed = try XLSXRequestsParser.parse(
                    data: data,
                    fileName: url.lastPathComponent.isEmpty ? "Заявки.xlsx" : url.lastPathComponent
                )
                let merged = Self.mergeSnapshot(existing: existingSnapshot, incoming: parsed)
                try Self.saveSnapshotToDisk(merged.snapshot)
                return merged
            }.value

            snapshot = merged.snapshot
            recordsRevision &+= 1
            notice = merged.notice
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
        }
    }

    func importSpreadsheet(data: Data, fileName: String) async {
        guard !isDeleting, !isImporting, !isLoadingSnapshot, !isSynchronizingClosedRequests else { return }
        closedSyncGeneration &+= 1
        isImporting = true
        errorMessage = nil
        notice = nil

        let existingSnapshot = snapshot
        defer {
            isImporting = false
        }

        do {
            let merged = try await Task.detached(priority: .userInitiated) {
                let parsed = try XLSXRequestsParser.parse(data: data, fileName: fileName)
                let merged = Self.mergeSnapshot(existing: existingSnapshot, incoming: parsed)
                try Self.saveSnapshotToDisk(merged.snapshot)
                return merged
            }.value

            snapshot = merged.snapshot
            recordsRevision &+= 1
            notice = merged.notice
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
        }
    }

    func mergeSimpleOneClosedRequests(_ records: [SimpleOneRequestRecord]) async {
        // Closed requests are intentionally imported only from the XLSX table.
        _ = records
    }

    func beginClosedRequestsSync(
        userID: String,
        scope: ClosedRequestsSyncScope
    ) -> ClosedRequestsSyncContext? {
        guard snapshot != nil,
              !userID.isEmpty,
              !isDeleting,
              !isImporting,
              !isLoadingSnapshot,
              !isSynchronizingClosedRequests else {
            return nil
        }

        closedSyncGeneration &+= 1
        isSynchronizingClosedRequests = true
        let state = snapshot?.syncState
        let storedRequestNumbers = Set(snapshot?.records.map(\.requestNumber) ?? [])
        let unclassifiedMissingRecords: [ClosedRequestsSyncCursor] = state?.recordsBySysID.compactMap { sysID, metadata in
            guard !storedRequestNumbers.contains(metadata.requestNumber),
                  metadata.excludedFromArchive != true else {
                return nil
            }
            return ClosedRequestsSyncCursor(updatedAt: metadata.sysUpdatedAt, sysID: sysID)
        } ?? []
        let requiresWideRestart = scope == .wide
            && ClosedRequestsArchiveQuery.requiresWideRestart(
                storedRevision: state?.wideConditionRevision
            )
        let watermark: ClosedRequestsSyncCursor?
        if requiresWideRestart {
            watermark = nil
        } else if scope == .narrow, state?.requiresNarrowFullReconciliation == true {
            watermark = nil
        } else if let recoveryWatermark = unclassifiedMissingRecords.min() {
            watermark = recoveryWatermark
        } else if state?.userID == userID {
            watermark = scope == .narrow ? state?.narrowWatermark : state?.wideWatermark
        } else {
            watermark = nil
        }
        let knownVersionsBySysID: [String: String]
        if (watermark != nil || requiresWideRestart), state?.userID == userID {
            knownVersionsBySysID = state?.recordsBySysID.reduce(into: [:]) { result, entry in
                let metadata = entry.value
                if storedRequestNumbers.contains(metadata.requestNumber)
                    || metadata.excludedFromArchive == true {
                    result[entry.key] = metadata.sysUpdatedAt
                }
            } ?? [:]
        } else {
            knownVersionsBySysID = [:]
        }
        return ClosedRequestsSyncContext(
            generation: closedSyncGeneration,
            watermark: watermark,
            knownVersionsBySysID: knownVersionsBySysID
        )
    }

    func finishClosedRequestsSync(generation: UInt64) {
        guard generation == closedSyncGeneration else { return }
        isSynchronizingClosedRequests = false
    }

    func waitForClosedRequestsSyncAvailability() async throws {
        let deadline = Date().addingTimeInterval(30)
        while isLoadingSnapshot || isImporting || isSynchronizingClosedRequests {
            try Task.checkCancellation()
            guard Date() < deadline else {
                throw SimpleOneServiceError.server(
                    "Предыдущее обновление закрытых заявок не завершилось. Повторите попытку."
                )
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        guard !isDeleting else {
            throw SimpleOneServiceError.server(
                "Дождитесь завершения удаления закрытых заявок."
            )
        }
    }

    @discardableResult
    func applyClosedRequestsSyncBatch(
        _ batch: SimpleOneClosedSyncBatch,
        generation: UInt64
    ) async -> Bool {
        guard generation == closedSyncGeneration,
              isSynchronizingClosedRequests,
              let existingSnapshot = snapshot else {
            return false
        }

        do {
            let application = try await Task.detached(priority: .utility) {
                try Self.prepareClosedRequestsSyncBatch(batch, existingSnapshot: existingSnapshot)
            }.value
            guard generation == closedSyncGeneration else { return false }
            if let conflictRequestNumber = application.conflictRequestNumber {
                isSynchronizingClosedRequests = false
                errorMessage = "SimpleOne вернул конфликт идентификаторов для заявки \(conflictRequestNumber). Автообновление не применено."
                return false
            }
            snapshot = application.snapshot
            if application.recordsChanged {
                recordsRevision &+= 1
            }
            isSynchronizingClosedRequests = false
            if application.recordsChanged {
                notice = "Закрытые заявки: +\(application.addedCount), обновлено \(application.updatedCount)."
            }
            return true
        } catch {
            if generation == closedSyncGeneration {
                isSynchronizingClosedRequests = false
                errorMessage = appUserFacingErrorMessage(error)
            }
            return false
        }
    }

    func setClosedRequestsSyncBaseline(
        userID: String,
        narrow: ClosedRequestsSyncCursor?,
        wide: ClosedRequestsSyncCursor?
    ) async {
        guard !userID.isEmpty, var snapshot else { return }
        let now = Date()
        snapshot.syncState = ClosedRequestsSyncState(
            userID: userID,
            narrowWatermark: narrow,
            wideWatermark: wide,
            wideConditionRevision: wide == nil ? nil : ClosedRequestsArchiveQuery.revision,
            lastNarrowSuccessAt: narrow == nil ? nil : now,
            lastWideSuccessAt: wide == nil ? nil : now,
            isWideBaselineTrusted: wide != nil,
            requiresNarrowFullReconciliation: false,
            recordsBySysID: snapshot.syncState?.userID == userID
                ? snapshot.syncState?.recordsBySysID ?? [:]
                : [:]
        )
        do {
            try await Task.detached(priority: .utility) {
                try Self.saveSnapshotToDisk(snapshot)
            }.value
            self.snapshot = snapshot
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
        }
    }

    func shouldRunWideClosedRequestsSync(userID: String, now: Date = Date()) -> Bool {
        guard let state = snapshot?.syncState,
              state.userID == userID,
              state.isWideBaselineTrusted else {
            return false
        }
        if ClosedRequestsArchiveQuery.requiresWideRestart(
            storedRevision: state.wideConditionRevision
        ) {
            return true
        }
        guard let lastSuccess = state.lastWideSuccessAt else { return true }
        return now.timeIntervalSince(lastSuccess) >= 6 * 60 * 60
    }

    private func loadSnapshot() async {
        guard !isImporting, !isDeleting else { return }
        isLoadingSnapshot = true
        defer { isLoadingSnapshot = false }
        let legacyStorageKey = self.legacyStorageKey

        do {
            snapshot = try await Task.detached(priority: .utility) {
                try Self.loadSnapshotFromDiskOrLegacy(legacyStorageKey: legacyStorageKey)
            }.value
            if snapshot != nil {
                recordsRevision &+= 1
            }
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
        }
    }

    private func replaceSnapshotAfterDeletion(
        with updatedSnapshot: ClosedRequestsSnapshot?,
        deletedCount: Int,
        notice successNotice: String
    ) async -> Int {
        isDeleting = true
        errorMessage = nil
        notice = nil
        let legacyStorageKey = self.legacyStorageKey
        defer { isDeleting = false }

        do {
            try await Task.detached(priority: .userInitiated) {
                try Self.replaceStoredSnapshot(
                    with: updatedSnapshot,
                    legacyStorageKey: legacyStorageKey
                )
            }.value
            snapshot = updatedSnapshot
            recordsRevision &+= 1
            notice = successNotice
            return deletedCount
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
            return 0
        }
    }

    nonisolated private struct ClosedRequestsSyncApplication: Sendable {
        let snapshot: ClosedRequestsSnapshot
        let addedCount: Int
        let updatedCount: Int
        let conflictRequestNumber: String?

        var recordsChanged: Bool {
            addedCount > 0 || updatedCount > 0
        }
    }

    nonisolated private static func prepareClosedRequestsSyncBatch(
        _ batch: SimpleOneClosedSyncBatch,
        existingSnapshot: ClosedRequestsSnapshot
    ) throws -> ClosedRequestsSyncApplication {
        var recordsByNumber: [String: ClosedRequestRecord] = [:]
        for record in existingSnapshot.records {
            recordsByNumber[record.requestNumber] = record
        }
        var state = existingSnapshot.syncState?.userID == batch.userID
            ? existingSnapshot.syncState!
            : ClosedRequestsSyncState(
                userID: batch.userID,
                narrowWatermark: nil,
                wideWatermark: nil,
                wideConditionRevision: nil,
                lastNarrowSuccessAt: nil,
                lastWideSuccessAt: nil,
                isWideBaselineTrusted: false,
                requiresNarrowFullReconciliation: false,
                recordsBySysID: [:]
            )
        var addedCount = 0
        var updatedCount = 0
        let now = Date()

        for change in batch.changes {
            if let record = change.record {
                let conflictsWithSameID = state.recordsBySysID[change.sysID].map {
                    $0.requestNumber != record.requestNumber
                } ?? false
                let conflictsWithSameNumber = state.recordsBySysID.contains { sysID, metadata in
                    sysID != change.sysID && metadata.requestNumber == record.requestNumber
                }
                if conflictsWithSameID || conflictsWithSameNumber {
                    return ClosedRequestsSyncApplication(
                        snapshot: existingSnapshot,
                        addedCount: 0,
                        updatedCount: 0,
                        conflictRequestNumber: record.requestNumber
                    )
                }
                if let current = recordsByNumber[record.requestNumber] {
                    let mergedRecord = preservingMerchantTIN(in: record, from: current)
                    if current != mergedRecord {
                        recordsByNumber[record.requestNumber] = mergedRecord
                        updatedCount += 1
                    }
                } else {
                    recordsByNumber[record.requestNumber] = record
                    addedCount += 1
                }
            }
            state.recordsBySysID[change.sysID] = ClosedRequestsSyncRecordMetadata(
                requestNumber: change.requestNumber,
                sysUpdatedAt: change.cursor.updatedAt,
                lastSeenAt: now,
                excludedFromArchive: change.excludedFromArchive
            )
        }

        switch batch.scope {
        case .narrow:
            state.narrowWatermark = batch.watermark ?? state.narrowWatermark
            state.lastNarrowSuccessAt = now
            state.requiresNarrowFullReconciliation = false
        case .wide:
            state.wideWatermark = batch.watermark ?? state.wideWatermark
            state.wideConditionRevision = ClosedRequestsArchiveQuery.revision
            state.lastWideSuccessAt = now
        }

        let updatedSnapshot = ClosedRequestsSnapshot(
            fileName: existingSnapshot.fileName,
            importedAt: existingSnapshot.importedAt,
            records: sortRecords(Array(recordsByNumber.values)),
            syncState: state
        )
        try saveSnapshotToDisk(updatedSnapshot)
        return ClosedRequestsSyncApplication(
            snapshot: updatedSnapshot,
            addedCount: addedCount,
            updatedCount: updatedCount,
            conflictRequestNumber: nil
        )
    }

    nonisolated private static func mergeSnapshot(
        existing: ClosedRequestsSnapshot?,
        incoming: ClosedRequestsSnapshot
    ) -> (snapshot: ClosedRequestsSnapshot, notice: String) {
        let duplicateCount = incoming.records.count
            - Set(incoming.records.map(\.requestNumber)).count
        guard let existing else {
            var recordsByRequestNumber: [String: ClosedRequestRecord] = [:]
            for record in incoming.records {
                recordsByRequestNumber[record.requestNumber] = record
            }
            let snapshot = ClosedRequestsSnapshot(
                fileName: incoming.fileName,
                importedAt: incoming.importedAt,
                records: sortRecords(Array(recordsByRequestNumber.values)),
                syncState: manualImportSyncState(previous: nil)
            )
            let notice = "Загружено \(snapshot.records.count) заявок из \(incoming.fileName).\(duplicateImportNotice(duplicateCount)) \(closureCodeImportSummary(for: snapshot.records))"
            return (snapshot, notice)
        }

        var recordsByRequestNumber: [String: ClosedRequestRecord] = [:]
        for record in existing.records {
            recordsByRequestNumber[record.requestNumber] = record
        }
        var addedCount = 0
        var updatedCount = 0

        for record in incoming.records {
            if let current = recordsByRequestNumber[record.requestNumber] {
                if current != record {
                    recordsByRequestNumber[record.requestNumber] = record
                    updatedCount += 1
                }
            } else {
                recordsByRequestNumber[record.requestNumber] = record
                addedCount += 1
            }
        }

        let resetSyncState = manualImportSyncState(previous: existing.syncState)

        let mergedSnapshot = ClosedRequestsSnapshot(
            fileName: incoming.fileName,
            importedAt: incoming.importedAt,
            records: sortRecords(Array(recordsByRequestNumber.values)),
            syncState: resetSyncState
        )

        let notice = "Импорт: +\(addedCount) новых, \(updatedCount) обновлено, всего \(mergedSnapshot.records.count).\(duplicateImportNotice(duplicateCount)) \(closureCodeImportSummary(for: mergedSnapshot.records))"
        return (mergedSnapshot, notice)
    }

    nonisolated private static func duplicateImportNotice(_ count: Int) -> String {
        guard count > 0 else { return "" }
        return " Дубли в файле: \(count); использована последняя строка."
    }

    nonisolated private static func manualImportSyncState(
        previous: ClosedRequestsSyncState?
    ) -> ClosedRequestsSyncState {
        ClosedRequestsSyncState(
            userID: previous?.userID ?? "",
            narrowWatermark: nil,
            wideWatermark: nil,
            wideConditionRevision: nil,
            lastNarrowSuccessAt: nil,
            lastWideSuccessAt: nil,
            isWideBaselineTrusted: false,
            requiresNarrowFullReconciliation: true,
            recordsBySysID: previous?.recordsBySysID ?? [:]
        )
    }

    nonisolated private static func closureCodeImportSummary(for records: [ClosedRequestRecord]) -> String {
        let withClosureCode = records.filter { !($0.closureCode ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        let completedWithVisit = records.filter { isCompletedWithVisitClosureCode($0.closureCode) }.count
        return "Код закрытия: \(withClosureCode), с выездом: \(completedWithVisit)"
    }

    nonisolated private static func isCompletedWithVisitClosureCode(_ raw: String?) -> Bool {
        let normalizedClosureCode = (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "ru_RU"))
        return normalizedClosureCode.hasPrefix("решено с выездом")
    }

    nonisolated private static func sortRecords(_ records: [ClosedRequestRecord]) -> [ClosedRequestRecord] {
        records.sorted { lhs, rhs in
            let leftDate = parseClosedAt(sortDateText(for: lhs)) ?? .distantPast
            let rightDate = parseClosedAt(sortDateText(for: rhs)) ?? .distantPast

            if leftDate != rightDate {
                return leftDate > rightDate
            }

            return lhs.requestNumber.localizedStandardCompare(rhs.requestNumber) == .orderedDescending
        }
    }

    nonisolated private static func sortDateText(for record: ClosedRequestRecord) -> String {
        if isReturnEquipment(record.requestType) {
            let registeredAt = record.registeredAt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !registeredAt.isEmpty, parseClosedAt(registeredAt) != nil {
                return registeredAt
            }
        }
        return record.closedAt
    }

    nonisolated private static func deletionDate(for record: ClosedRequestRecord) -> Date? {
        parseClosedAt(sortDateText(for: record))
    }

    nonisolated private static func isReturnEquipment(_ rawType: String) -> Bool {
        let type = rawType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return type == "returnequip"
            || type == "return_equip"
            || type.contains("возврат то")
            || type.contains("возврат")
    }

    nonisolated static func closedRequestRecord(from record: SimpleOneRequestRecord) -> ClosedRequestRecord {
        let infoFields = simpleOneInfoFields(from: record)
        let merchantTIN = simpleOneInfoValue(for: "ИНН ТСП", in: infoFields)
        let closureCode = simpleOneInfoValue(for: "Код закрытия", in: infoFields)
        let resolution = simpleOneInfoValue(for: "Решение", in: infoFields)
        return ClosedRequestRecord(
            requestNumber: record.number,
            shortDescription: record.shortDescription,
            status: record.state.isEmpty ? "Закрыта" : record.state,
            rawStatus: record.stateRaw,
            engineerShift: "",
            workgroup: record.assignmentGroup,
            requestType: record.requestType,
            address: record.address,
            customer: record.customer,
            contactPerson: record.contactPerson.isEmpty ? nil : record.contactPerson,
            contactPhone: record.contactPhone,
            engineerName: record.assignedUser,
            terminalModel: record.terminalModel,
            merchantTIN: merchantTIN.isEmpty ? nil : merchantTIN,
            posEquipment: nil,
            dismantledEquipmentSerialNumber: nil,
            engineerComment: record.engineerComment,
            closedAt: record.resolvedAt,
            deadline: record.deadline,
            completedAt: record.completedAt,
            closedInMulticardAt: record.closedAt,
            additionalInformation: record.additionalInformation,
            registeredAt: record.registeredAt,
            closureCode: firstNonEmptySimpleOneValue(record.closureCode, closureCode),
            resolution: firstNonEmptySimpleOneValue(record.resolution, resolution),
            terminalID: record.terminalID,
            incomingNumber: record.incomingNumber.isEmpty ? record.number : record.incomingNumber,
            infoFields: infoFields,
            rawInfo: infoFields.map { "\($0.key): \($0.value)" }.joined(separator: "\n"),
            installedFiscalStorageSerialNumber: record.installedFiscalStorageSerialNumber,
            ofdTariffActivationCode: record.ofdTariffActivationCode,
            usedSIMCard: record.usedSIMCard
        )
    }

    nonisolated private static func preservingMerchantTIN(
        in incoming: ClosedRequestRecord,
        from current: ClosedRequestRecord
    ) -> ClosedRequestRecord {
        guard ClosedRequestsMerchantTINSupport.needsRepair(incoming.merchantTIN),
              let currentTIN = current.merchantTIN,
              !ClosedRequestsMerchantTINSupport.normalizedValidTIN(currentTIN).isEmpty,
              !currentTIN.isEmpty else {
            return incoming
        }

        var merged = incoming
        merged.merchantTIN = ClosedRequestsMerchantTINSupport.normalizedValidTIN(currentTIN)
        if !merged.infoFields.contains(where: {
            normalizedSimpleOneInfoKey($0.key) == normalizedSimpleOneInfoKey("ИНН ТСП")
        }) {
            merged.infoFields.append(ClosedRequestInfoField(
                key: "ИНН ТСП",
                value: merged.merchantTIN ?? ""
            ))
        }
        return merged
    }

    nonisolated private static func simpleOneInfoFields(from record: SimpleOneRequestRecord) -> [ClosedRequestInfoField] {
        let tableInformation = record.tableFields?
            .first { normalizedSimpleOneInfoKey($0.key) == normalizedSimpleOneInfoKey("Информация") }?
            .value ?? ""
        let tableAdditionalInformation = record.tableFields?
            .first { normalizedSimpleOneInfoKey($0.key) == normalizedSimpleOneInfoKey("Доп. информация") }?
            .value ?? ""
        let tableFields = record.tableFields?
            .compactMap { field -> ClosedRequestInfoField? in
                let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !field.key.isEmpty, !value.isEmpty else { return nil }
                return ClosedRequestInfoField(key: field.key, value: value)
            } ?? []
        let parsedFields = parseSimpleOneInfoFields(
            [
                record.additionalInformation ?? "",
                record.description,
                tableInformation,
                tableAdditionalInformation
            ]
        )

        let explicitFields = [
            ("Источник", "SimpleOne"),
            ("SimpleOne sys_id", record.sysID),
            ("Номер заявки", record.number),
            ("Краткое описание", record.shortDescription),
            ("Рабочая группа", record.assignmentGroup),
            ("Тип заявки", record.requestType),
            ("Контактное лицо", record.contactPerson),
            ("Модель POS-терминала", record.terminalModel),
            ("Комментарий инженера", record.engineerComment),
            ("Код закрытия", record.closureCode ?? ""),
            ("Решение", record.resolution ?? ""),
            ("Доп. информация", record.additionalInformation ?? ""),
            ("Описание", record.description),
            ("Серийный номер установленного ФН", record.installedFiscalStorageSerialNumber ?? ""),
            ("Использованный код активации тарифа ОФД", record.ofdTariffActivationCode ?? ""),
            ("Использованная SIM карта", record.usedSIMCard ?? "")
        ]
        .compactMap { key, value -> ClosedRequestInfoField? in
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedValue.isEmpty else { return nil }
            return ClosedRequestInfoField(key: key, value: trimmedValue)
        }

        let parsedKeys = Set(parsedFields.map { normalizedSimpleOneInfoKey($0.key) })
        let tableFieldsWithoutParsedDuplicates = tableFields.filter { !parsedKeys.contains(normalizedSimpleOneInfoKey($0.key)) }
        let parsedAndTableKeys = parsedKeys.union(tableFieldsWithoutParsedDuplicates.map { normalizedSimpleOneInfoKey($0.key) })
        let explicitFieldsWithoutDuplicates = explicitFields.filter { !parsedAndTableKeys.contains(normalizedSimpleOneInfoKey($0.key)) }
        return parsedFields + tableFieldsWithoutParsedDuplicates + explicitFieldsWithoutDuplicates
    }

    nonisolated private static func simpleOneInfoValue(
        for key: String,
        in fields: [ClosedRequestInfoField]
    ) -> String {
        let normalizedKey = normalizedSimpleOneInfoKey(key)
        return fields
            .first { normalizedSimpleOneInfoKey($0.key) == normalizedKey }?
            .value
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    nonisolated private static func firstNonEmptySimpleOneValue(_ values: String?...) -> String? {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    nonisolated private static func parseSimpleOneInfoFields(_ texts: [String]) -> [ClosedRequestInfoField] {
        texts.flatMap { text in
            text
                .split(whereSeparator: \.isNewline)
                .compactMap { rawLine -> ClosedRequestInfoField? in
                    let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !line.isEmpty else { return nil }

                    guard let separator = line.firstIndex(of: ":") else {
                        return ClosedRequestInfoField(key: line, value: "")
                    }

                    let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !key.isEmpty else { return nil }
                    return ClosedRequestInfoField(key: key, value: value)
                }
        }
    }

    nonisolated private static func normalizedSimpleOneInfoKey(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    nonisolated private static func parseClosedAt(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let serial = Double(trimmed) {
            let excelBaseDate = Date(timeIntervalSince1970: -2209161600)
            return excelBaseDate.addingTimeInterval(serial * 86_400)
        }

        for formatter in closedAtParsingFormatters {
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }

        return nil
    }

    nonisolated private static func routeTemplateRecords(
        from records: [ClosedRequestRecord],
        dayKey targetDayKey: String,
        warehouseAddress: String
    ) -> [ClosedRequestRecord] {
        let filtered = records
            .compactMap { record -> (record: ClosedRequestRecord, date: Date, normalizedAddress: String)? in
                guard let date = routeTemplateDate(for: record, targetDayKey: targetDayKey) else {
                    return nil
                }

                let normalizedAddress = routeTemplateAddress(for: record)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedAddress.isEmpty else { return nil }

                var routeRecord = record
                routeRecord.address = normalizedAddress
                return (routeRecord, date, normalizedAddress)
            }
            .sorted { lhs, rhs in
                if lhs.date != rhs.date {
                    return lhs.date < rhs.date
                }
                return lhs.record.requestNumber.localizedStandardCompare(rhs.record.requestNumber) == .orderedAscending
        }

        var deduped = [ClosedRequestRecord]()
        var previousAddressIdentity: String?

        for item in filtered {
            let addressIdentity = routeAddressIdentity(item.normalizedAddress)
            guard previousAddressIdentity != addressIdentity else { continue }
            deduped.append(item.record)
            previousAddressIdentity = addressIdentity
        }

        return removingWarehouseEdges(from: deduped, warehouseAddress: warehouseAddress)
    }

    nonisolated private static func routeTemplateAddress(for record: ClosedRequestRecord) -> String {
        if isReturnEquipment(record.requestType) {
            return RouteSettings.officeAddress
        }

        return record.address.normalizedAddressStartingFromAlushta()
    }

    nonisolated private static func removingWarehouseEdges(
        from records: [ClosedRequestRecord],
        warehouseAddress: String
    ) -> [ClosedRequestRecord] {
        let warehouseIdentity = routeAddressIdentity(warehouseAddress.normalizedAddressStartingFromAlushta())
        guard !warehouseIdentity.isEmpty else { return records }

        var filtered = records
        while let first = filtered.first,
              routeAddressIdentity(first.address) == warehouseIdentity {
            filtered.removeFirst()
        }

        while let last = filtered.last,
              routeAddressIdentity(last.address) == warehouseIdentity {
            filtered.removeLast()
        }

        return filtered
    }

    nonisolated private static func routeAddressIdentity(_ raw: String) -> String {
        let locale = Locale(identifier: "ru_RU")
        let folded = raw
            .normalizedAddressStartingFromAlushta()
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: locale)
            .lowercased(with: locale)
            .replacingOccurrences(of: "ё", with: "е")

        return folded.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    nonisolated private static func routeTemplateDate(
        for record: ClosedRequestRecord,
        targetDayKey: String
    ) -> Date? {
        let dateTexts: [String]
        if isReturnEquipment(record.requestType) {
            dateTexts = [record.registeredAt ?? "", record.closedAt]
        } else {
            dateTexts = [record.closedAt]
        }

        return dateTexts
            .compactMap(parseClosedAt)
            .first { dayKey(from: $0) == targetDayKey }
    }

    nonisolated private static func loadSnapshotFromDiskOrLegacy(legacyStorageKey: String) throws -> ClosedRequestsSnapshot? {
        let fileURL = snapshotFileURL()
        let decoder = JSONDecoder()

        if let data = try? Data(contentsOf: fileURL),
           let snapshot = try? decoder.decode(ClosedRequestsSnapshot.self, from: data) {
            return ClosedRequestsSnapshot(
                fileName: snapshot.fileName,
                importedAt: snapshot.importedAt,
                records: sortRecords(snapshot.records.map(normalizedStoredRecord(_:))),
                syncState: snapshot.syncState
            )
        }

        guard let legacyData = UserDefaults.standard.data(forKey: legacyStorageKey),
              let legacySnapshot = try? decoder.decode(ClosedRequestsSnapshot.self, from: legacyData) else {
            return nil
        }

        let normalizedSnapshot = ClosedRequestsSnapshot(
            fileName: legacySnapshot.fileName,
            importedAt: legacySnapshot.importedAt,
            records: sortRecords(legacySnapshot.records.map(normalizedStoredRecord(_:))),
            syncState: legacySnapshot.syncState
        )
        try saveSnapshotToDisk(normalizedSnapshot)
        UserDefaults.standard.removeObject(forKey: legacyStorageKey)
        return normalizedSnapshot
    }

    nonisolated private static func saveSnapshotToDisk(_ snapshot: ClosedRequestsSnapshot) throws {
        let fileURL = snapshotFileURL()
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: fileURL, options: [.atomic])
    }

    nonisolated private static func replaceStoredSnapshot(
        with snapshot: ClosedRequestsSnapshot?,
        legacyStorageKey: String
    ) throws {
        if let snapshot {
            try saveSnapshotToDisk(snapshot)
            UserDefaults.standard.removeObject(forKey: legacyStorageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: legacyStorageKey)
            let fileURL = snapshotFileURL()
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    nonisolated private static func normalizedStoredRecord(_ record: ClosedRequestRecord) -> ClosedRequestRecord {
        let closureCode = firstNonEmptyStoredValue(
            record.closureCode,
            storedInfoValue(for: ["Код закрытия", "Код закрытия МК", "Код закрытия заявки", "Код решения", "Результат закрытия"], in: record.infoFields)
        )
        let resolution = firstNonEmptyStoredValue(
            record.resolution,
            storedInfoValue(for: ["Решение"], in: record.infoFields)
        )

        guard closureCode != record.closureCode || resolution != record.resolution else {
            return record
        }

        return ClosedRequestRecord(
            requestNumber: record.requestNumber,
            shortDescription: record.shortDescription,
            status: record.status,
            engineerShift: record.engineerShift,
            workgroup: record.workgroup,
            requestType: record.requestType,
            address: record.address,
            customer: record.customer,
            contactPerson: record.contactPerson,
            engineerName: record.engineerName,
            terminalModel: record.terminalModel,
            merchantTIN: record.merchantTIN,
            posEquipment: record.posEquipment,
            dismantledEquipmentSerialNumber: record.dismantledEquipmentSerialNumber,
            engineerComment: record.engineerComment,
            closedAt: record.closedAt,
            registeredAt: record.registeredAt,
            closureCode: closureCode,
            resolution: resolution,
            terminalID: record.terminalID,
            incomingNumber: record.incomingNumber,
            infoFields: record.infoFields,
            rawInfo: record.rawInfo,
            installedFiscalStorageSerialNumber: record.installedFiscalStorageSerialNumber,
            ofdTariffActivationCode: record.ofdTariffActivationCode,
            usedSIMCard: record.usedSIMCard
        )
    }

    nonisolated private static func firstNonEmptyStoredValue(_ values: String?...) -> String? {
        for value in values {
            let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    nonisolated private static func storedInfoValue(for keys: [String], in infoFields: [ClosedRequestInfoField]) -> String? {
        for key in keys {
            let normalizedKey = normalizedStoredInfoKey(key)
            if let value = infoFields.first(where: { normalizedStoredInfoKey($0.key) == normalizedKey })?.value {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    nonisolated private static func normalizedStoredInfoKey(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    nonisolated private static func snapshotFileURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("LumaWork", isDirectory: true)
            .appendingPathComponent("closed-requests-snapshot.json", isDirectory: false)
    }

    nonisolated private static func inclusiveDayBounds(
        from startDate: Date,
        through endDate: Date
    ) -> (start: Date, endExclusive: Date) {
        let calendar = Calendar.autoupdatingCurrent
        let firstDate = min(startDate, endDate)
        let lastDate = max(startDate, endDate)
        let start = calendar.startOfDay(for: firstDate)
        let lastDayStart = calendar.startOfDay(for: lastDate)
        let endExclusive = calendar.date(byAdding: .day, value: 1, to: lastDayStart)
            ?? lastDayStart.addingTimeInterval(86_400)
        return (start, endExclusive)
    }

    nonisolated private static let closedAtParsingFormatters: [DateFormatter] = {
        let formats = [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "dd.MM.yyyy HH:mm:ss",
            "dd.MM.yyyy HH:mm",
            "dd.MM.yyyy H:mm",
            "MM.dd.yyyy HH:mm:ss",
            "MM.dd.yyyy HH:mm",
            "MM.dd.yyyy H:mm",
            "yyyy-MM-dd",
            "dd.MM.yyyy",
            "MM.dd.yyyy"
        ]

        return formats.map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            return formatter
        }
    }()

    nonisolated private static let routeDayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    nonisolated private static func dayKey(from date: Date) -> String {
        routeDayKeyFormatter.string(from: date)
    }
}
