import Foundation
import Observation
import OSLog
import SwiftUI

struct RouteMonthlyMileage: Hashable {
    let monthKey: String
    let latestDate: String
    let totalKm: Int
}

@MainActor
@Observable
    final class HomeRouteStore {
    private let service: RouteDayService
    private let storage = RouteLocalStorage()
    private var hasLoaded = false
    private let reportStartDate = "2026-04-01"
    private let appleDistanceCalculator = AppleRouteDistanceCalculator()
    private var appleDistanceTask: Task<Void, Never>?
    private var appleDistanceRevision = UUID()
    private var appleDistanceInput: AppleDistanceInput?

    private struct AppleDistanceInput: Equatable {
        let key: String
        let plan: AppleRoutePlan
    }

    var selectedDate = Date()
    var workType: RouteWorkType = .pos
    var record: RouteDayRecord {
        didSet { refreshAppleDistance() }
    }
    var addressOptions: [String] = []
    private(set) var officeAddresses: [String] = []
    private(set) var isLoadingOfficeAddresses = false
    var isSending = false
    var isLoadingRemote = false
    var notice: String?
    var errorMessage: String?
    var routeSettings: RouteSettings
    private(set) var dailyMileageByDate: [String: Int] = [:]
    private(set) var isMileageHistoryReady = false
    private(set) var appleRouteSnapshot: AppleRouteDistanceSnapshot?
    var appleDistanceKm: Int? { appleRouteSnapshot?.distanceKm }
    private(set) var isCalculatingAppleDistance = false
    private(set) var appleDistanceError: String?

    init(service: RouteDayService) {
        self.service = service
        let todayKey = RouteDateFormatter.dayKey(from: Date())
        self.routeSettings = storage.loadSettings()
        self.record = storage.loadDay(todayKey, workType: .pos)
        self.dailyMileageByDate = storage.loadDailyMileageByDate()
        refreshAddressOptions()
        refreshAppleDistance()
    }

    func refreshAppleDistance(force: Bool = false) {
        let input = AppleDistanceInput(
            key: record.workType.storageKey(for: record.date),
            plan: AppleRoutePlan(addresses: record.stops.map(\.address))
        )
        guard force || input != appleDistanceInput else { return }
        appleDistanceInput = input
        appleDistanceTask?.cancel()
        let revision = UUID()
        appleDistanceRevision = revision
        appleDistanceError = nil
        appleRouteSnapshot = nil
        isCalculatingAppleDistance = false

        guard !input.plan.isEmpty else {
            appleRouteSnapshot = AppleRouteDistanceSnapshot(addresses: input.plan.addresses, distanceKm: 0)
            return
        }
        guard input.plan.isComplete else {
            appleDistanceError = AppleRouteDistanceError.incompleteRoute.localizedDescription
            return
        }
        if !force, let cached = storage.loadAppleMileage(for: input.key),
           cached.addresses == input.plan.addresses, cached.hasGeometry {
            appleRouteSnapshot = cached
            return
        }

        isCalculatingAppleDistance = true
        let calculator = appleDistanceCalculator
        appleDistanceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
                let snapshot = try await calculator.route(for: input.plan)
                try Task.checkCancellation()
                guard let self, self.appleDistanceRevision == revision else { return }
                self.appleRouteSnapshot = snapshot
                self.isCalculatingAppleDistance = false
                self.storage.saveAppleMileage(
                    snapshot,
                    for: input.key
                )
            } catch {
                guard !Task.isCancelled, let self, self.appleDistanceRevision == revision else { return }
                self.isCalculatingAppleDistance = false
                self.appleDistanceError = (error as? AppleRouteDistanceError)?.localizedDescription
                    ?? "Не удалось рассчитать пробег через Apple Maps. Проверьте подключение и повторите."
            }
        }
    }

    var selectedDateKey: String {
        RouteDateFormatter.dayKey(from: selectedDate)
    }

    var selectedDateTitle: String {
        RouteDateFormatter.humanDate(from: selectedDate)
    }

    var isToday: Bool {
        selectedDateKey == RouteDateFormatter.dayKey(from: Date())
    }

    var selectedMonthKey: String {
        String(selectedDateKey.prefix(7))
    }

    var selectedMonthMileage: RouteMonthlyMileage? {
        guard isMileageHistoryReady else { return nil }
        let entries = dailyMileageByDate.filter { date, _ in
            date.hasPrefix("\(selectedMonthKey)-")
        }
        guard let latestDate = entries.keys.map({ String($0.prefix(10)) }).max() else { return nil }
        return RouteMonthlyMileage(
            monthKey: selectedMonthKey,
            latestDate: latestDate,
            totalKm: entries.values.reduce(0, +)
        )
    }

    var canSendCurrentRecord: Bool {
        Self.hasDataToSend(record) &&
            (!usesAppleMaps || reportDistanceKm != nil) &&
            validateReportFields(reportRecord) == nil &&
            !isSending
    }

    var usesAppleMaps: Bool { routeSettings.mapsProvider == .apple }

    var reportDistanceKm: Int? {
        routeSettings.mapsProvider.reportDistanceKm(
            manualKm: record.distanceKm,
            apple: appleRouteSnapshot,
            plan: AppleRoutePlan(addresses: record.stops.map(\.address)),
            isCalculating: isCalculatingAppleDistance
        )
    }

    private var reportRecord: RouteDayRecord {
        var report = record
        report.distanceKm = reportDistanceKm
        return report
    }

    var canOpenAppleRouteMap: Bool {
        !isCalculatingAppleDistance && appleRouteSnapshot?.hasGeometry == true
    }

    var hasCurrentRouteData: Bool {
        Self.hasDataToSend(record)
    }

    var requiresOfficeAddressSelection: Bool {
        workType == .arm
    }

    func makeRoutesArchiveStore() -> RouteArchiveStore {
        RouteArchiveStore(service: service, settings: routeSettings)
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        setSelectedDate(selectedDate)
        await processQueue()
        await refreshMileageHistory()
    }

    func setWorkType(_ newValue: RouteWorkType) {
        guard workType != newValue else { return }
        workType = newValue
        setSelectedDate(selectedDate)
        if newValue == .arm {
            Task { await refreshOfficeAddressesIfNeeded(force: true) }
        }
    }

    func setSelectedDate(_ date: Date) {
        selectedDate = date
        notice = nil
        errorMessage = nil

        let dateKey = selectedDateKey
        let selectedWorkType = workType
        record = storage.loadDay(dateKey, workType: selectedWorkType)
        refreshAddressOptions()

        guard shouldFetchRemote(for: record, dateKey: dateKey) else {
            isLoadingRemote = false
            return
        }

        isLoadingRemote = true
        let settings = routeSettings

        Task {
            do {
                let remote = try await service.fetchDay(
                    date: dateKey,
                    workType: selectedWorkType,
                    settings: settings
                )
                await MainActor.run {
                    guard self.selectedDateKey == dateKey, self.workType == selectedWorkType else { return }
                    if let remote {
                        self.record = remote
                        self.storage.saveDay(remote)
                        if let distanceKm = remote.distanceKm {
                            self.dailyMileageByDate[remote.workType.storageKey(for: remote.date)] = distanceKm
                        }
                        self.refreshAddressOptions()
                    }
                    self.isLoadingRemote = false
                }
            } catch {
                await MainActor.run {
                    guard self.selectedDateKey == dateKey, self.workType == selectedWorkType else { return }
                    self.isLoadingRemote = false
                }
            }
        }
    }

    func addMiddleStop() {
        let newStop = RouteStop(
            id: UUID().uuidString,
            address: "",
            org: "",
            tid: "",
            reason: "",
            status: .pending,
            declineReason: "",
            requestNumber: ""
        )

        var stops = record.stops
        stops.insert(newStop, at: max(1, stops.count - 1))
        record.stops = stops
        invalidateCalculatedDistance()
        persistCurrentRecord()
    }

    func removeStop(_ id: String) {
        guard record.stops.count > 3 else { return }
        guard let index = record.stops.firstIndex(where: { $0.id == id }),
              index != 0,
              index != record.stops.count - 1 else {
            return
        }

        record.stops.remove(at: index)
        invalidateCalculatedDistance()
        persistCurrentRecord()
    }

    func duplicateStop(_ id: String) {
        guard let index = record.stops.firstIndex(where: { $0.id == id }),
              index != record.stops.count - 1 else {
            return
        }

        let source = record.stops[index]
        let duplicate = RouteStop(
            id: UUID().uuidString,
            address: source.address,
            org: source.org,
            tid: source.tid,
            reason: source.reason,
            status: source.status,
            declineReason: source.declineReason,
            requestNumber: source.requestNumber
        )

        record.stops.insert(duplicate, at: index + 1)
        invalidateCalculatedDistance()
        persistCurrentRecord()
    }

    func updateStop(_ id: String, address: String? = nil, requestNumber: String? = nil) {
        guard let index = record.stops.firstIndex(where: { $0.id == id }) else { return }
        var shouldInvalidateDistance = false

        if let address {
            let normalizedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
            if record.stops[index].address.trimmingCharacters(in: .whitespacesAndNewlines) != normalizedAddress {
                shouldInvalidateDistance = true
            }
            record.stops[index].address = address
        }
        if let requestNumber {
            record.stops[index].requestNumber = requestNumber
        }

        if shouldInvalidateDistance {
            invalidateCalculatedDistance()
        } else {
            record.sent = false
        }
        persistCurrentRecord()
    }

    func updateDistanceKm(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let distanceKm = trimmed.isEmpty ? nil : Int(trimmed)
        record.distanceKm = distanceKm
        let mileageKey = workType.storageKey(for: selectedDateKey)
        storage.saveDailyMileage(distanceKm, for: selectedDateKey, workType: workType)
        if let distanceKm {
            dailyMileageByDate[mileageKey] = distanceKm
        } else {
            dailyMileageByDate.removeValue(forKey: mileageKey)
        }
        record.sent = false
        persistCurrentRecord()
    }

    func updatePeriodStartOdometer(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let odometer = trimmed.isEmpty ? nil : Int(trimmed)
        storage.savePeriodStartOdometer(odometer, for: selectedMonthKey)
        record.periodStartOdometer = odometer
        record.sent = false
        persistCurrentRecord()
    }

    @discardableResult
    func applySuggestedPeriodStartOdometer(_ value: Int, for monthKey: String) -> Bool {
        guard value >= 0,
              selectedMonthKey == monthKey,
              record.periodStartOdometer == nil,
              storage.loadPeriodStartOdometer(for: monthKey) == nil else {
            return false
        }
        storage.savePeriodStartOdometer(value, for: monthKey)
        record.periodStartOdometer = value
        record.sent = false
        persistCurrentRecord()
        return true
    }

    func selectedEndpointKind(for role: RouteEndpointRole) -> RouteEndpointKind {
        endpointKind(for: endpointAddress(for: role), settings: routeSettings)
    }

    func updateEndpoint(_ role: RouteEndpointRole, kind: RouteEndpointKind) {
        errorMessage = nil
        notice = nil

        let address = routeSettings.address(for: kind)
        guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Заполните адрес \(kind.title.lowercased()) в настройках."
            return
        }

        guard let index = endpointIndex(for: role), record.stops.indices.contains(index) else {
            errorMessage = "Не удалось обновить \(role.title.lowercased())."
            return
        }

        if record.stops[index].address.normalizedRouteEndpointAddress() != address.normalizedRouteEndpointAddress() {
            record.stops[index].address = address
            invalidateCalculatedDistance()
        } else {
            record.sent = false
        }
        persistCurrentRecord()
    }

    func updateRouteSettings(_ settings: RouteSettings) {
        let oldSettings = routeSettings
        let normalized = RouteLocalStorage.migrateLegacyOfficeAddress(in: settings)
        routeSettings = normalized
        storage.saveSettings(normalized)
        applySettingsAddressChanges(oldSettings: oldSettings, newSettings: normalized)
        refreshAddressOptions()
        notice = "Настройки маршрута сохранены."
    }

    func moveStop(_ id: String, direction: RouteMoveDirection) {
        guard let index = record.stops.firstIndex(where: { $0.id == id }) else { return }
        let targetIndex: Int

        switch direction {
        case .up:
            targetIndex = index - 1
        case .down:
            targetIndex = index + 1
        }

        guard index > 0,
              index < record.stops.count - 1,
              targetIndex > 0,
              targetIndex < record.stops.count - 1 else {
            return
        }

        let moved = record.stops.remove(at: index)
        record.stops.insert(moved, at: targetIndex)
        invalidateCalculatedDistance()
        persistCurrentRecord()
    }

    @discardableResult
    func reorderStop(_ draggedID: String, targetID: String) -> Bool {
        guard draggedID != targetID,
              let sourceIndex = record.stops.firstIndex(where: { $0.id == draggedID }),
              let targetIndex = record.stops.firstIndex(where: { $0.id == targetID }),
              sourceIndex > 0,
              sourceIndex < record.stops.count - 1,
              targetIndex > 0,
              targetIndex < record.stops.count - 1 else {
            return false
        }

        let destination = targetIndex > sourceIndex ? targetIndex + 1 : targetIndex
        record.stops.move(fromOffsets: IndexSet(integer: sourceIndex), toOffset: destination)
        invalidateCalculatedDistance()
        persistCurrentRecord()
        return true
    }

    func makeYandexMapsRouteURL() -> URL? {
        errorMessage = nil
        notice = nil

        let addresses = record.stops.map(\.address)

        guard addresses.lazy.filter({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }).count >= 2 else {
            errorMessage = "Для маршрута нужны минимум два адреса."
            return nil
        }

        guard let url = YandexRouteLinks.webURL(
            baseURL: AppConfig().mapsRouteURL,
            addresses: addresses
        ) else {
            errorMessage = "Не удалось собрать ссылку Яндекс.Карт."
            return nil
        }
        return url
    }

    func importClosedRequests(_ requests: [ClosedRequestRecord]) {
        errorMessage = nil
        notice = nil

        guard workType == .pos else { return }

        guard !requests.isEmpty else {
            errorMessage = "За выбранную дату нет закрытых заявок для импорта."
            return
        }

        guard let firstStop = record.stops.first, let lastStop = record.stops.last else {
            errorMessage = "Не удалось подготовить маршрут для импорта."
            return
        }

        let importedStops = requests.map { request in
            RouteStop(
                id: UUID().uuidString,
                address: request.address.normalizedAddressStartingFromAlushta(),
                org: request.customer,
                tid: request.terminalID,
                reason: "",
                status: .done,
                declineReason: "",
                requestNumber: requestIncomingNumber(request)
            )
        }

        record.stops = [firstStop] + importedStops + [lastStop]
        invalidateCalculatedDistance()
        persistCurrentRecord()

        notice = "Импортировано \(importedStops.count) точек из закрытых заявок."
    }

    @discardableResult
    func appendClosedRequests(_ requests: [ClosedRequestRecord]) -> Int {
        guard workType == .pos,
              !requests.isEmpty,
              let firstStop = record.stops.first,
              let lastStop = record.stops.last else {
            return 0
        }

        var knownRequestNumbers = Set(
            record.stops
                .map(\.requestNumber)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        let addedStops = requests.compactMap { request -> RouteStop? in
            let requestNumber = requestIncomingNumber(request)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !requestNumber.isEmpty,
                  knownRequestNumbers.insert(requestNumber).inserted else {
                return nil
            }
            return RouteStop(
                id: UUID().uuidString,
                address: request.address.normalizedAddressStartingFromAlushta(),
                org: request.customer,
                tid: request.terminalID,
                reason: "",
                status: .done,
                declineReason: "",
                requestNumber: requestNumber
            )
        }
        guard !addedStops.isEmpty else { return 0 }

        let currentMiddleStops = Array(record.stops.dropFirst().dropLast())
        record.stops = [firstStop] + currentMiddleStops + addedStops + [lastStop]
        invalidateCalculatedDistance()
        persistCurrentRecord()
        notice = "Добавлено закрытых заявок в маршрут: \(addedStops.count)."
        return addedStops.count
    }

    func importActiveRequests(_ requests: [SimpleOneRequestRecord]) {
        errorMessage = nil
        notice = nil

        guard workType == .pos else { return }

        let importableRequests = requests.filter {
            !$0.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !importableRequests.isEmpty else {
            errorMessage = "В активных заявках нет адресов для импорта."
            return
        }
        guard let firstStop = record.stops.first, let lastStop = record.stops.last else {
            errorMessage = "Не удалось подготовить маршрут для импорта."
            return
        }

        let existingRequestNumbers = Set(record.stops.map(\.requestNumber).filter { !$0.isEmpty })
        let importedStops = importableRequests.compactMap { request -> RouteStop? in
            let requestNumber = request.incomingNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? request.number
                : request.incomingNumber
            guard !existingRequestNumbers.contains(requestNumber) else { return nil }
            return RouteStop(
                id: UUID().uuidString,
                address: request.address.normalizedAddressStartingFromAlushta(),
                org: request.customer,
                tid: request.terminalID,
                reason: request.shortDescription,
                status: .pending,
                declineReason: "",
                requestNumber: requestNumber
            )
        }

        guard !importedStops.isEmpty else {
            notice = "Все активные заявки уже добавлены в маршрут."
            return
        }
        let currentMiddleStops = Array(record.stops.dropFirst().dropLast())
        record.stops = [firstStop] + currentMiddleStops + importedStops + [lastStop]
        invalidateCalculatedDistance()
        persistCurrentRecord()
        notice = "Добавлено \(importedStops.count) точек из активных заявок."
    }

    func autoImportClosedRequestsIfEmpty(_ requests: [ClosedRequestRecord]) -> Bool {
        guard workType == .pos else { return false }
        guard !hasCurrentRouteData, !requests.isEmpty else { return false }
        guard let firstStop = record.stops.first, let lastStop = record.stops.last else { return false }

        let importedStops = requests.map { request in
            RouteStop(
                id: UUID().uuidString,
                address: request.address.normalizedAddressStartingFromAlushta(),
                org: request.customer,
                tid: request.terminalID,
                reason: "",
                status: .done,
                declineReason: "",
                requestNumber: requestIncomingNumber(request)
            )
        }

        record.stops = [firstStop] + importedStops + [lastStop]
        invalidateCalculatedDistance()
        persistCurrentRecord()
        return true
    }

    private func requestIncomingNumber(_ request: ClosedRequestRecord) -> String {
        let directValue = request.incomingNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        if !directValue.isEmpty {
            return directValue
        }

        for key in ["Входящий номер", "Номер заявки Мультикарты", "Номер заявки Мультикарта", "Номер заявки"] {
            let value = request.infoFields
                .first { normalizedRequestInfoKey($0.key) == normalizedRequestInfoKey(key) }?
                .value
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty {
                return value
            }
        }

        let shortDescription = request.shortDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if shortDescription.hasPrefix("SUTS") {
            return shortDescription
        }

        return request.requestNumber.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedRequestInfoKey(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    private static func percentEncodedYandexRoutePoint(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    func suggestions(for stop: RouteStop) -> [String] {
        let query = stop.address.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = addressOptions.filter { $0 != query }

        if query.isEmpty {
            return Array(base.prefix(6)).map { $0 }
        }

        let normalizedQuery = query.lowercased()
        let startsWithMatches = base.filter { $0.lowercased().hasPrefix(normalizedQuery) }
        let containsMatches = base.filter {
            !$0.lowercased().hasPrefix(normalizedQuery) &&
                $0.localizedCaseInsensitiveContains(query)
        }

        return Array((startsWithMatches + containsMatches).prefix(6))
    }

    func refreshOfficeAddressesIfNeeded(force: Bool = false) async {
        guard workType == .arm, !isLoadingOfficeAddresses else { return }
        guard force || officeAddresses.isEmpty else { return }
        isLoadingOfficeAddresses = true
        defer { isLoadingOfficeAddresses = false }
        do {
            officeAddresses = try await service.fetchOfficeAddresses()
        } catch is CancellationError {
            return
        } catch {
            AppErrorPresentation.presentIfNeeded(
                message: appUserFacingErrorMessage(error, fallback: "Не удалось загрузить отделения.")
                    ?? "Не удалось загрузить отделения."
            )
        }
    }

    @discardableResult
    func sendCurrentDay() async -> Bool {
        guard !isSending else { return false }
        errorMessage = nil
        notice = nil

        guard Self.hasDataToSend(record) else {
            errorMessage = "Нет данных для отправки."
            return false
        }

        let mapsProvider = routeSettings.mapsProvider
        if usesAppleMaps, reportDistanceKm == nil {
            errorMessage = isCalculatingAppleDistance
                ? "Дождитесь расчёта пробега через Apple Maps."
                : appleDistanceError ?? "Рассчитайте пробег через Apple Maps перед отправкой."
            return false
        }

        let currentRecord = reportRecord
        if let validationError = validateReportFields(currentRecord) {
            errorMessage = validationError
            return false
        }

        let dateKey = selectedDateKey
        // Persist the selected mileage before sending so queued reports and the archive use it too.
        record = currentRecord
        persistCurrentRecord()
        if let distanceKm = currentRecord.distanceKm {
            dailyMileageByDate[currentRecord.workType.storageKey(for: dateKey)] = distanceKm
        }

        isSending = true
        defer { isSending = false }

        do {
            try await service.sendDay(currentRecord, date: dateKey)
            markSubmitted(currentRecord)
            notice = "Отправлено!"
            return true
        } catch is CancellationError {
            return false
        } catch let error as RouteDayServiceError {
            if error.shouldQueue {
                storage.enqueue(dateKey, workType: currentRecord.workType, mapsProvider: mapsProvider)
                AppErrorPresentation.presentIfNeeded(
                    message: error.errorDescription ?? AppNetworkBannerKind.cannotConnectToServer.message
                )
                notice = "День поставлен в очередь."
            } else {
                errorMessage = appUserFacingErrorMessage(error)
            }
            return false
        } catch {
            errorMessage = appUserFacingErrorMessage(error, fallback: "Не удалось отправить данные.")
            return false
        }
    }

    private func shouldFetchRemote(for record: RouteDayRecord, dateKey: String) -> Bool {
        if dateKey == RouteDateFormatter.dayKey(from: Date()), !record.sent {
            return false
        }

        let hasLocalDraft = record.date == dateKey && Self.hasDataToSend(record) && !record.sent
        return !hasLocalDraft
    }

    private func markSubmitted(_ submitted: RouteDayRecord) {
        // Keep edits made while the request was in flight, including another day.
        guard storage.loadDay(submitted.date, workType: submitted.workType) == submitted else { return }
        var saved = submitted
        saved.sent = true
        storage.saveDay(saved)
        storage.dequeue(submitted.date, workType: submitted.workType)
        if selectedDateKey == submitted.date, workType == submitted.workType, record == submitted {
            record = saved
        }
    }

    private func persistCurrentRecord() {
        storage.saveDay(record)
        refreshAddressOptions()
    }

    private func invalidateCalculatedDistance() {
        record.distanceKm = nil
        record.sent = false
    }

    private func refreshAddressOptions() {
        var addresses = Set<String>()
        let all = storage.loadAllDays()

        for day in all.values {
            for stop in day.stops {
                let trimmed = stop.address.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    addresses.insert(trimmed)
                }
            }
        }

        for stop in record.stops {
            let trimmed = stop.address.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                addresses.insert(trimmed)
            }
        }

        for address in [routeSettings.warehouseAddress, routeSettings.homeAddress] {
            let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                addresses.insert(trimmed)
            }
        }

        addressOptions = Array(addresses).sorted().prefix(100).map { $0 }
    }

    private func processQueue() async {
        let queue = storage.loadQueue()
        guard !queue.isEmpty else { return }

        for item in queue {
            var day = storage.loadDay(item.date, workType: item.workType)
            guard Self.hasDataToSend(day) else {
                storage.dequeue(item.date, workType: item.workType)
                continue
            }

            if item.mapsProvider == .apple {
                let key = item.workType.storageKey(for: item.date)
                guard let distanceKm = item.mapsProvider.reportDistanceKm(
                    manualKm: day.distanceKm,
                    apple: storage.loadAppleMileage(for: key),
                    plan: AppleRoutePlan(addresses: day.stops.map(\.address)),
                    isCalculating: false
                ) else { continue }
                day.distanceKm = distanceKm
                storage.saveDay(day)
                if record.date == day.date, record.workType == day.workType, record.stops == day.stops {
                    record.distanceKm = distanceKm
                }
            }
            guard validateReportFields(day) == nil else { continue }

            do {
                try await service.sendDay(day, date: item.date)
                markSubmitted(day)
            } catch let error as RouteDayServiceError where error.shouldQueue {
                break
            } catch {
                break
            }
        }
    }

    private func refreshMileageHistory() async {
        var mileageByDate = storage.loadDailyMileageByDate()
        var remoteKeys = Set<String>()

        do {
            let remoteRecords = try await service.fetchAllDays(settings: routeSettings)
            for record in remoteRecords {
                remoteKeys.insert(record.workType.storageKey(for: record.date))
                if let distanceKm = record.distanceKm {
                    mileageByDate[record.workType.storageKey(for: record.date)] = distanceKm
                } else {
                    mileageByDate.removeValue(forKey: record.workType.storageKey(for: record.date))
                }
            }
        } catch {
            // The persisted mileage index remains usable while offline.
        }

        for record in storage.loadAllDays().values {
            if !remoteKeys.contains(record.workType.storageKey(for: record.date)), let distanceKm = record.distanceKm {
                mileageByDate[record.workType.storageKey(for: record.date)] = distanceKm
            }
        }
        if let distanceKm = record.distanceKm {
            mileageByDate[record.workType.storageKey(for: selectedDateKey)] = distanceKm
        }

        dailyMileageByDate = mileageByDate
        storage.saveDailyMileageByDate(mileageByDate)
        isMileageHistoryReady = true
    }

    private static func hasDataToSend(_ record: RouteDayRecord?) -> Bool {
        guard let record, record.stops.count >= 3 else { return false }
        let lastIndex = record.stops.count - 1
        return record.stops.enumerated().contains { index, stop in
            guard index != 0, index != lastIndex else { return false }
            let address = stop.address.trimmingCharacters(in: .whitespacesAndNewlines)
            let number = stop.requestNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            return !address.isEmpty || !number.isEmpty
        }
    }

    private func validateReportFields(_ record: RouteDayRecord?) -> String? {
        guard let record, record.date >= reportStartDate else { return nil }

        if record.distanceKm == nil {
            return "Начиная с 2026-04-01 заполните пробег за день."
        }

        if record.periodStartOdometer == nil {
            return "Начиная с 2026-04-01 заполните одометр на начало месяца."
        }

        if record.workType == .arm {
            let middleStops = record.stops.dropFirst().dropLast()
            if middleStops.contains(where: { $0.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                return "Для АРМ выберите адрес отделения у каждой точки."
            }
        }

        return nil
    }

    private func endpointIndex(for role: RouteEndpointRole) -> Int? {
        switch role {
        case .start:
            return record.stops.isEmpty ? nil : 0
        case .finish:
            return record.stops.isEmpty ? nil : record.stops.count - 1
        }
    }

    private func endpointAddress(for role: RouteEndpointRole) -> String {
        guard let index = endpointIndex(for: role), record.stops.indices.contains(index) else { return "" }
        return record.stops[index].address
    }

    private func applySettingsAddressChanges(oldSettings: RouteSettings, newSettings: RouteSettings) {
        guard !record.stops.isEmpty else { return }

        let knownOldAddresses = [
            oldSettings.warehouseAddress,
            oldSettings.homeAddress,
            oldSettings.startAddress,
            oldSettings.endAddress
        ]
        .map { $0.normalizedRouteEndpointAddress() }
        .filter { !$0.isEmpty }

        var didChange = false
        for role in [RouteEndpointRole.start, .finish] {
            guard let index = endpointIndex(for: role), record.stops.indices.contains(index) else { continue }
            let currentAddress = record.stops[index].address.normalizedRouteEndpointAddress()
            guard currentAddress.isEmpty || knownOldAddresses.contains(currentAddress) else { continue }

            let kind = endpointKind(for: record.stops[index].address, settings: oldSettings)
            let newAddress = newSettings.address(for: kind)
            guard !newAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if record.stops[index].address.normalizedRouteEndpointAddress() != newAddress.normalizedRouteEndpointAddress() {
                record.stops[index].address = newAddress
                didChange = true
            }
        }

        if didChange {
            invalidateCalculatedDistance()
            persistCurrentRecord()
        }
    }

    private func endpointKind(for address: String, settings: RouteSettings) -> RouteEndpointKind {
        let normalizedAddress = address.normalizedRouteEndpointAddress()
        let home = settings.homeAddress.normalizedRouteEndpointAddress()
        if !home.isEmpty, normalizedAddress == home {
            return .home
        }
        return .warehouse
    }
}

@MainActor
@Observable
final class RouteArchiveStore {
    private let service: RouteDayService
    private let settings: RouteSettings
    private let storage = RouteLocalStorage()
    private var hasLoaded = false

    var records: [RouteDayRecord] = []
    var isLoading = false
    var errorMessage: String?

    init(service: RouteDayService, settings: RouteSettings) {
        self.service = service
        self.settings = settings
        self.records = storage.loadAllDays().values.sorted {
            $0.date == $1.date ? $0.workType.rawValue > $1.workType.rawValue : $0.date > $1.date
        }
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await reload(showsNetworkBanner: records.isEmpty)
    }

    func reload(showsNetworkBanner: Bool = true) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let remoteRecords = try await service.fetchAllDays(settings: settings)
            records = remoteRecords
            for record in remoteRecords {
                storage.saveDay(record)
            }
        } catch is CancellationError {
            return
        } catch let error as RouteDayServiceError {
            errorMessage = appUserFacingErrorMessage(
                error,
                showsNetworkBanner: showsNetworkBanner
            )
        } catch {
            errorMessage = appUserFacingErrorMessage(
                error,
                fallback: "Не удалось загрузить маршруты.",
                showsNetworkBanner: showsNetworkBanner
            )
        }

    }

}

private extension String {
    func normalizedRouteEndpointAddress() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: AppLocale.russian)
            .replacingOccurrences(of: "ё", with: "е")
    }
}
