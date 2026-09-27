import Foundation
import Observation

nonisolated private struct CoordinationCachedRegion: Codable, Hashable, Sendable {
    let requests: [SimpleOneRequestRecord]
    let updatedAt: Date
}

nonisolated private struct CoordinationOfflineSnapshot: Codable, Hashable, Sendable {
    let sessionID: String
    let regions: [String: CoordinationCachedRegion]
    let returnEquipment: CoordinationCachedRegion?
}

@MainActor
@Observable
final class CoordinationStore {
    private(set) var region: CoordinationRegion?
    private(set) var sessionID: String?
    private(set) var requests: [SimpleOneRequestRecord] = []
    private(set) var isLoading = false
    private(set) var lastUpdatedAt: Date?
    var errorMessage: String?
    private(set) var returnEquipmentSessionID: String?
    private(set) var returnEquipmentRequests: [SimpleOneRequestRecord] = []
    private(set) var isReturnEquipmentLoading = false
    private(set) var returnEquipmentUpdatedAt: Date?
    var returnEquipmentErrorMessage: String?

    private let cacheKey: String
    private var activeSessionID: String?
    private var latestRequestID: UUID?
    private var latestReturnEquipmentRequestID: UUID?
    private var cachedSessionID = ""
    private var cachedRegions: [String: CoordinationCachedRegion] = [:]
    private var cachedReturnEquipment: CoordinationCachedRegion?

    private static let returnEquipmentSerialLabels = [
        "Серийный номер демонтируемого ТО",
        "S/N терминала",
        "Номер принятого оборудования POS",
        "Оборудование POS"
    ]

    init(cacheID: String? = nil) {
        cacheKey = AppOfflineSnapshotStore.scopedKey("coordination", userID: cacheID)
        guard let snapshot = AppOfflineSnapshotStore.load(
            CoordinationOfflineSnapshot.self,
            key: cacheKey
        ) else {
            return
        }
        cachedSessionID = snapshot.value.sessionID
        cachedRegions = snapshot.value.regions
        cachedReturnEquipment = snapshot.value.returnEquipment
    }

    var hasCurrentSnapshot: Bool {
        lastUpdatedAt != nil
    }

    var hasReturnEquipmentSnapshot: Bool {
        returnEquipmentUpdatedAt != nil
    }

    var returnEquipmentSerialNumbers: Set<String> {
        let values = returnEquipmentRequests.flatMap { request in
            Self.returnEquipmentSerialValues(for: request)
        }
        return Set(values.flatMap(Self.serialNumberCandidates))
    }

    func returnEquipmentSerialNumber(for request: SimpleOneRequestRecord) -> String? {
        Self.returnEquipmentSerialValues(for: request).first
    }

    var engineers: [CoordinationEngineer] {
        var groups: [String: (name: String, count: Int)] = [:]

        for request in requests {
            let name = request.assignedUser.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = Self.engineerKey(for: request)
            let displayName: String
            if key == CoordinationEngineer.unassignedID {
                displayName = "Назначено на группу"
            } else if name.isEmpty {
                displayName = "Исполнитель не определён"
            } else {
                displayName = name
            }

            if let group = groups[key] {
                groups[key] = (group.name, group.count + 1)
            } else {
                groups[key] = (displayName, 1)
            }
        }

        return groups.map { key, group in
            CoordinationEngineer(
                id: key,
                name: group.name,
                requestCount: group.count
            )
        }
        .sorted { lhs, rhs in
            if lhs.isUnassigned != rhs.isUnassigned {
                return lhs.isUnassigned
            }
            if lhs.requestCount != rhs.requestCount {
                return lhs.requestCount > rhs.requestCount
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    func refresh(
        region: CoordinationRegion,
        sessionID: String,
        simpleOneStore: SimpleOneRequestsStore
    ) async {
        activateSession(sessionID)
        if isLoading, self.region == region, self.sessionID == sessionID {
            return
        }

        let requestID = UUID()
        latestRequestID = requestID

        if self.region != region || self.sessionID != sessionID {
            self.region = region
            self.sessionID = sessionID
            applyCachedRegion(region, sessionID: sessionID)
        }

        isLoading = true
        errorMessage = nil
        defer {
            if latestRequestID == requestID {
                isLoading = false
            }
        }

        do {
            let fetchedRequests = try await simpleOneStore.fetchCoordinationRequests(
                region: region,
                includesDetails: false
            )
            guard latestRequestID == requestID,
                  activeSessionID == sessionID,
                  self.sessionID == sessionID,
                  self.region == region,
                  !Task.isCancelled else { return }
            let updatedAt = Date()
            requests = Self.preservingCachedDetails(
                in: fetchedRequests,
                cachedRequests: requests
            )
            lastUpdatedAt = updatedAt
            saveCurrentRegion(
                region,
                sessionID: sessionID,
                updatedAt: updatedAt
            )
        } catch is CancellationError {
            return
        } catch {
            guard latestRequestID == requestID,
                  activeSessionID == sessionID,
                  self.sessionID == sessionID,
                  self.region == region,
                  !Task.isCancelled else { return }
            errorMessage = appUserFacingErrorMessage(error)
        }
    }

    func refreshReturnEquipment(
        sessionID: String,
        simpleOneStore: SimpleOneRequestsStore,
        showsNetworkBanner: Bool = true
    ) async {
        activateSession(sessionID)
        if isReturnEquipmentLoading, returnEquipmentSessionID == sessionID {
            return
        }

        let requestID = UUID()
        latestReturnEquipmentRequestID = requestID

        if returnEquipmentSessionID != sessionID {
            returnEquipmentSessionID = sessionID
            applyCachedReturnEquipment(sessionID: sessionID)
        }

        isReturnEquipmentLoading = true
        returnEquipmentErrorMessage = nil
        defer {
            if latestReturnEquipmentRequestID == requestID {
                isReturnEquipmentLoading = false
            }
        }

        do {
            let fetchedRequests = try await simpleOneStore.fetchReturnEquipmentRequestsForCurrentUser()
            guard latestReturnEquipmentRequestID == requestID,
                  activeSessionID == sessionID,
                  returnEquipmentSessionID == sessionID,
                  !Task.isCancelled else { return }
            let updatedAt = Date()
            returnEquipmentRequests = Self.preservingCachedDetails(
                in: fetchedRequests,
                cachedRequests: returnEquipmentRequests
            )
            returnEquipmentUpdatedAt = updatedAt
            saveReturnEquipment(sessionID: sessionID, updatedAt: updatedAt)
        } catch is CancellationError {
            return
        } catch {
            guard latestReturnEquipmentRequestID == requestID,
                  activeSessionID == sessionID,
                  returnEquipmentSessionID == sessionID,
                  !Task.isCancelled else { return }
            returnEquipmentErrorMessage = appUserFacingErrorMessage(
                error,
                showsNetworkBanner: showsNetworkBanner
            )
        }
    }

    func reset() {
        activeSessionID = nil
        latestRequestID = UUID()
        latestReturnEquipmentRequestID = UUID()
        region = nil
        sessionID = nil
        requests = []
        isLoading = false
        lastUpdatedAt = nil
        errorMessage = nil
        returnEquipmentSessionID = nil
        returnEquipmentRequests = []
        isReturnEquipmentLoading = false
        returnEquipmentUpdatedAt = nil
        returnEquipmentErrorMessage = nil
    }

    private func activateSession(_ sessionID: String) {
        guard activeSessionID != sessionID else { return }
        activeSessionID = sessionID
        latestRequestID = UUID()
        latestReturnEquipmentRequestID = UUID()
        isLoading = false
        isReturnEquipmentLoading = false
    }

    func requests(for engineerID: String) -> [SimpleOneRequestRecord] {
        requests
            .filter { Self.engineerKey(for: $0) == engineerID }
            .sorted { lhs, rhs in
                let lhsDate = lhs.registeredDate ?? .distantPast
                let rhsDate = rhs.registeredDate ?? .distantPast
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
                return lhs.number.localizedStandardCompare(rhs.number) == .orderedDescending
            }
    }

    func replace(_ record: SimpleOneRequestRecord) {
        replace([record])
    }

    func replace(_ updatedRecords: [SimpleOneRequestRecord]) {
        let updatedByID = Dictionary(updatedRecords.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        if requests.contains(where: { updatedByID[$0.id] != nil }) {
            requests = requests.map { updatedByID[$0.id] ?? $0 }
            if let region, let sessionID, let lastUpdatedAt {
                saveCurrentRegion(region, sessionID: sessionID, updatedAt: lastUpdatedAt)
            }
        }
        if returnEquipmentRequests.contains(where: { updatedByID[$0.id] != nil }) {
            returnEquipmentRequests = returnEquipmentRequests.map { updatedByID[$0.id] ?? $0 }
            if let returnEquipmentSessionID, let returnEquipmentUpdatedAt {
                saveReturnEquipment(sessionID: returnEquipmentSessionID, updatedAt: returnEquipmentUpdatedAt)
            }
        }
    }

    private func applyCachedRegion(
        _ region: CoordinationRegion,
        sessionID: String
    ) {
        guard cachedSessionID == sessionID,
              let cachedRegion = cachedRegions[region.rawValue] else {
            requests = []
            lastUpdatedAt = nil
            return
        }
        requests = cachedRegion.requests
        lastUpdatedAt = cachedRegion.updatedAt
    }

    private func applyCachedReturnEquipment(sessionID: String) {
        guard cachedSessionID == sessionID,
              let cachedReturnEquipment else {
            returnEquipmentRequests = []
            returnEquipmentUpdatedAt = nil
            return
        }
        returnEquipmentRequests = cachedReturnEquipment.requests
        returnEquipmentUpdatedAt = cachedReturnEquipment.updatedAt
    }

    private func saveCurrentRegion(
        _ region: CoordinationRegion,
        sessionID: String,
        updatedAt: Date
    ) {
        if cachedSessionID != sessionID {
            cachedSessionID = sessionID
            cachedRegions = [:]
            cachedReturnEquipment = nil
        }
        cachedRegions[region.rawValue] = CoordinationCachedRegion(
            requests: requests,
            updatedAt: updatedAt
        )
        saveSnapshot()
    }

    private func saveReturnEquipment(sessionID: String, updatedAt: Date) {
        if cachedSessionID != sessionID {
            cachedSessionID = sessionID
            cachedRegions = [:]
            cachedReturnEquipment = nil
        }
        cachedReturnEquipment = CoordinationCachedRegion(
            requests: returnEquipmentRequests,
            updatedAt: updatedAt
        )
        saveSnapshot()
    }

    private func saveSnapshot() {
        AppOfflineSnapshotStore.save(
            CoordinationOfflineSnapshot(
                sessionID: cachedSessionID,
                regions: cachedRegions,
                returnEquipment: cachedReturnEquipment
            ),
            key: cacheKey
        )
    }

    private static func preservingCachedDetails(
        in fetchedRequests: [SimpleOneRequestRecord],
        cachedRequests: [SimpleOneRequestRecord]
    ) -> [SimpleOneRequestRecord] {
        let cachedByID = Dictionary(
            cachedRequests.map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )

        return fetchedRequests.map { fetched in
            guard let cached = cachedByID[fetched.id],
                  let version = fetched.sysUpdatedAt, !version.isEmpty,
                  version == cached.sysUpdatedAt else { return fetched }

            var merged = fetched
            merged.waitingReason = nonEmpty(fetched.waitingReason, fallback: cached.waitingReason)
            merged.initiator = nonEmpty(fetched.initiator, fallback: cached.initiator)
            merged.priority = nonEmpty(fetched.priority, fallback: cached.priority)
            merged.closedAt = nonEmpty(fetched.closedAt, fallback: cached.closedAt)
            merged.closureCode = nonEmpty(fetched.closureCode, fallback: cached.closureCode)
            merged.resolution = nonEmpty(fetched.resolution, fallback: cached.resolution)
            merged.installedFiscalStorageSerialNumber = nonEmpty(
                fetched.installedFiscalStorageSerialNumber,
                fallback: cached.installedFiscalStorageSerialNumber
            )
            merged.ofdTariffActivationCode = nonEmpty(
                fetched.ofdTariffActivationCode,
                fallback: cached.ofdTariffActivationCode
            )
            merged.usedSIMCard = nonEmpty(fetched.usedSIMCard, fallback: cached.usedSIMCard)
            merged.tableFields = preservingCachedTableFields(
                in: fetched.tableFields,
                cachedFields: cached.tableFields
            )
            return merged
        }
    }

    private static func preservingCachedTableFields(
        in fetchedFields: [ClosedRequestInfoField]?,
        cachedFields: [ClosedRequestInfoField]?
    ) -> [ClosedRequestInfoField]? {
        guard let cachedFields, !cachedFields.isEmpty else { return fetchedFields }

        var merged = fetchedFields ?? []
        var indexByKey: [String: Int] = [:]
        for (index, field) in merged.enumerated() {
            let key = normalizedTableFieldKey(field.key)
            if indexByKey[key] == nil {
                indexByKey[key] = index
            }
        }

        for cachedField in cachedFields {
            let key = normalizedTableFieldKey(cachedField.key)
            let cachedValue = cachedField.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard detailedTableFieldKeys.contains(key), !cachedValue.isEmpty else { continue }

            if let index = indexByKey[key] {
                guard merged[index].value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                merged[index].value = cachedField.value
            } else {
                indexByKey[key] = merged.endIndex
                merged.append(cachedField)
            }
        }

        return merged.isEmpty ? nil : merged
    }

    private static func nonEmpty(_ value: String?, fallback: String?) -> String? {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallback
        }
        return value
    }

    private static func normalizedTableFieldKey(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func serialNumberCandidates(_ raw: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: ",;/|"))
        return ([raw] + raw.components(separatedBy: separators))
            .map(normalizedSerialNumber)
            .filter { $0.count >= 4 }
    }

    private static func returnEquipmentSerialValues(
        for request: SimpleOneRequestRecord
    ) -> [String] {
        let fields = warehouseInformationFields(request)
        return returnEquipmentSerialLabels.compactMap { label in
            let serial = value(for: [label], in: fields)
            return serial.isEmpty ? nil : serial
        }
    }

    nonisolated static func normalizedSerialNumber(_ raw: String) -> String {
        raw
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber }
            .lowercased()
    }

    private static let detailedTableFieldKeys = Set([
        "ID СБП",
        "Код закрытия",
        "Решение",
        "Дата закрытия в МК",
        "Оборудование POS",
        "Терминал вендора POS",
        "Номер принятого оборудования POS",
        "Оборудование Pin Pad",
        "Терминал вендора PIN",
        "Модель PIN-Pad",
        "Номер принятого оборудования PIN",
        "Серийный номер демонтируемого ТО",
        "Серийный номер демонтируемого PIN",
        "Производитель устанавливаемого ТО",
        "Модель устанавливаемого ТО",
        "Тип устанавливаемого ТО",
        "Принадлежность оборудования по заявке",
        "Время создания в МК",
        "МК Сотрудник склада",
        "Город склада"
    ].map(normalizedTableFieldKey))

    private static func engineerKey(for request: SimpleOneRequestRecord) -> String {
        let normalizedName = normalizedEngineerName(request.assignedUser)
        if !normalizedName.isEmpty {
            return "name:\(normalizedName)"
        }

        let assignedUserID = request.assignedUserID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !assignedUserID.isEmpty {
            return "id:\(assignedUserID)"
        }

        return CoordinationEngineer.unassignedID
    }

    private static func normalizedEngineerName(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
