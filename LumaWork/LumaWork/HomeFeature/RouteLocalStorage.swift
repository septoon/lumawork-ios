import Foundation

struct RouteQueueItem: Codable, Hashable {
    var date: String
    var workType: RouteWorkType
    var mapsProvider: RouteMapsProvider

    init(date: String, workType: RouteWorkType = .pos, mapsProvider: RouteMapsProvider = .yandex) {
        self.date = date
        self.workType = workType
        self.mapsProvider = mapsProvider
    }

    private enum CodingKeys: String, CodingKey {
        case date
        case workType
        case mapsProvider
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(String.self, forKey: .date)
        workType = try container.decodeIfPresent(RouteWorkType.self, forKey: .workType) ?? .pos
        mapsProvider = try container.decodeIfPresent(RouteMapsProvider.self, forKey: .mapsProvider) ?? .yandex
    }
}

final class RouteLocalStorage {
    private let daysKey = "route.pwa.days"
    private let queueKey = "route.pwa.queue"
    private let settingsKey = "route.pwa.settings"
    private let periodStartOdometerKey = "route.pwa.period-start-odometers"
    private let dailyMileageKey = "route.pwa.daily-mileages"
    private let appleMileageKey = "route.apple-map-mileages"
    private let defaults: UserDefaults
    private var daysCache: [String: RouteDayRecord]?
    private var settingsCache: RouteSettings?
    private var queueCache: [RouteQueueItem]?
    private var periodStartOdometerCache: [String: Int]?
    private var dailyMileageCache: [String: Int]?
    private var pendingDaysSave: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    deinit {
        pendingDaysSave?.cancel()
        if let daysCache {
            saveAllDaysImmediately(daysCache)
        }
    }

    func loadDay(_ date: String, workType: RouteWorkType = .pos) -> RouteDayRecord {
        let settings = loadSettings()
        var all = loadAllDays()
        let storageKey = workType.storageKey(for: date)
        let migrated = Self.migrateLegacyOfficeAddress(
            in: all[storageKey] ?? Self.defaultDay(for: date, workType: workType, settings: settings),
            settings: settings
        )
        let monthKey = Self.monthKey(for: date)
        var periodStartOdometer = loadPeriodStartOdometer(for: monthKey)
        if periodStartOdometer == nil, let recordValue = migrated.periodStartOdometer {
            savePeriodStartOdometer(recordValue, for: monthKey)
            periodStartOdometer = recordValue
        }
        let normalized = Self.normalize(
            migrated,
            date: date,
            workType: workType,
            settings: settings,
            periodStartOdometer: periodStartOdometer
        )
        all[storageKey] = normalized
        saveAllDays(all)
        return normalized
    }

    func saveDay(_ record: RouteDayRecord) {
        var all = loadAllDays()
        let settings = loadSettings()
        let monthKey = Self.monthKey(for: record.date)
        if let periodStartOdometer = record.periodStartOdometer {
            savePeriodStartOdometer(periodStartOdometer, for: monthKey)
        }
        if let distanceKm = record.distanceKm {
            saveDailyMileage(distanceKm, for: record.date, workType: record.workType)
        }
        let migrated = Self.migrateLegacyOfficeAddress(in: record, settings: settings)
        all[record.workType.storageKey(for: record.date)] = Self.normalize(
            migrated,
            date: record.date,
            workType: record.workType,
            settings: settings,
            periodStartOdometer: loadPeriodStartOdometer(for: monthKey)
        )
        saveAllDays(all)
    }

    func loadAllDays() -> [String: RouteDayRecord] {
        if let daysCache {
            return daysCache
        }
        guard let raw = defaults.data(forKey: daysKey),
              let decoded = try? JSONDecoder().decode([String: RouteDayRecord].self, from: raw) else {
            daysCache = [:]
            return [:]
        }
        daysCache = decoded
        return decoded
    }

    func loadSettings() -> RouteSettings {
        if let settingsCache {
            return settingsCache
        }
        guard let raw = defaults.data(forKey: settingsKey),
              let decoded = try? JSONDecoder().decode(RouteSettings.self, from: raw) else {
            settingsCache = .default
            return .default
        }

        let migrated = Self.migrateLegacyOfficeAddress(in: decoded)
        if migrated != decoded {
            saveSettings(migrated)
        }
        settingsCache = migrated
        return migrated
    }

    func loadQueue() -> [RouteQueueItem] {
        if let queueCache {
            return queueCache
        }
        guard let raw = defaults.data(forKey: queueKey),
              let decoded = try? JSONDecoder().decode([RouteQueueItem].self, from: raw) else {
            queueCache = []
            return []
        }
        queueCache = decoded
        return decoded
    }

    func loadPeriodStartOdometer(for monthKey: String) -> Int? {
        loadPeriodStartOdometers()[monthKey]
    }

    func savePeriodStartOdometer(_ value: Int?, for monthKey: String) {
        guard !monthKey.isEmpty else { return }
        var all = loadPeriodStartOdometers()
        if let value {
            all[monthKey] = value
        } else {
            all.removeValue(forKey: monthKey)
        }
        savePeriodStartOdometers(all)
    }

    func loadDailyMileageByDate() -> [String: Int] {
        var mileageByDate = loadDailyMileages()
        for record in loadAllDays().values {
            if let distanceKm = record.distanceKm {
                mileageByDate[record.workType.storageKey(for: record.date)] = distanceKm
            }
        }
        saveDailyMileages(mileageByDate)
        return mileageByDate
    }

    func saveDailyMileage(_ value: Int?, for date: String, workType: RouteWorkType = .pos) {
        guard !date.isEmpty else { return }
        var all = loadDailyMileages()
        let storageKey = workType.storageKey(for: date)
        if let value {
            all[storageKey] = value
        } else {
            all.removeValue(forKey: storageKey)
        }
        saveDailyMileages(all)
    }

    func saveDailyMileageByDate(_ values: [String: Int]) {
        saveDailyMileages(values)
    }

    func loadAppleMileage(for key: String) -> AppleRouteDistanceSnapshot? {
        guard let snapshot = loadAppleMileages()[key],
              snapshot.geocodingVersion == AppleRouteDistanceSnapshot.currentGeocodingVersion else { return nil }
        return snapshot
    }

    func saveAppleMileage(_ value: AppleRouteDistanceSnapshot, for key: String) {
        var all = loadAppleMileages()
        all[key] = value
        guard let data = try? JSONEncoder().encode(all) else { return }
        defaults.set(data, forKey: appleMileageKey)
    }

    private func loadAppleMileages() -> [String: AppleRouteDistanceSnapshot] {
        guard let data = defaults.data(forKey: appleMileageKey),
              let decoded = try? JSONDecoder().decode([String: AppleRouteDistanceSnapshot].self, from: data) else {
            return [:]
        }
        return decoded
    }

    func enqueue(_ date: String, workType: RouteWorkType = .pos, mapsProvider: RouteMapsProvider = .yandex) {
        var queue = loadQueue()
        queue.removeAll { $0.date == date && $0.workType == workType }
        queue.append(RouteQueueItem(date: date, workType: workType, mapsProvider: mapsProvider))
        saveQueue(queue)
    }

    func dequeue(_ date: String, workType: RouteWorkType = .pos) {
        let queue = loadQueue().filter { $0.date != date || $0.workType != workType }
        saveQueue(queue)
    }

    private func saveAllDays(_ days: [String: RouteDayRecord]) {
        daysCache = days
        pendingDaysSave?.cancel()
        pendingDaysSave = Task.detached(priority: .utility) { [days, daysKey, defaults] in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                guard let data = try? JSONEncoder().encode(days) else { return }
                defaults.set(data, forKey: daysKey)
            } catch {
                return
            }
        }
    }

    private func saveAllDaysImmediately(_ days: [String: RouteDayRecord]) {
        guard let data = try? JSONEncoder().encode(days) else { return }
        defaults.set(data, forKey: daysKey)
    }

    func saveSettings(_ settings: RouteSettings) {
        settingsCache = settings
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: settingsKey)
    }

    private func loadPeriodStartOdometers() -> [String: Int] {
        if let periodStartOdometerCache {
            return periodStartOdometerCache
        }
        guard let raw = defaults.data(forKey: periodStartOdometerKey),
              let decoded = try? JSONDecoder().decode([String: Int].self, from: raw) else {
            periodStartOdometerCache = [:]
            return [:]
        }
        periodStartOdometerCache = decoded
        return decoded
    }

    private func savePeriodStartOdometers(_ values: [String: Int]) {
        periodStartOdometerCache = values
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: periodStartOdometerKey)
    }

    private func loadDailyMileages() -> [String: Int] {
        if let dailyMileageCache {
            return dailyMileageCache
        }
        guard let raw = defaults.data(forKey: dailyMileageKey),
              let decoded = try? JSONDecoder().decode([String: Int].self, from: raw) else {
            dailyMileageCache = [:]
            return [:]
        }
        dailyMileageCache = decoded
        return decoded
    }

    private func saveDailyMileages(_ values: [String: Int]) {
        dailyMileageCache = values
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: dailyMileageKey)
    }

    private func saveQueue(_ queue: [RouteQueueItem]) {
        queueCache = queue
        guard let data = try? JSONEncoder().encode(queue) else { return }
        defaults.set(data, forKey: queueKey)
    }

    static func defaultDay(
        for date: String,
        workType: RouteWorkType = .pos,
        settings: RouteSettings
    ) -> RouteDayRecord {
        RouteDayRecord(
            date: date,
            workType: workType,
            stops: [
                makeStop(
                    id: "start-\(date)",
                    address: settings.startAddress,
                    reason: "Подготовка оборудования",
                    status: .done
                ),
                makeStop(id: "middle-\(date)", status: .pending),
                makeStop(
                    id: "finish-\(date)",
                    address: settings.endAddress,
                    reason: "Сдача оборудования",
                    status: .done
                )
            ],
            distanceKm: nil,
            periodStartOdometer: nil,
            sent: false
        )
    }

    static func hydrateStops(raw: [RouteStop]?, base: [RouteStop]) -> [RouteStop] {
        let firstReason = base.first?.reason.nilIfEmpty ?? "Подготовка оборудования"
        let lastReason = base.last?.reason.nilIfEmpty ?? "Сдача оборудования"

        guard let raw, !raw.isEmpty else {
            return base.enumerated().map { index, stop in
                var copy = stop
                copy.status = index == 0 || index == base.count - 1 ? .done : .pending
                copy.reason = index == 0 ? firstReason : index == base.count - 1 ? lastReason : stop.reason
                return copy
            }
        }

        var cloned = raw.enumerated().map { index, stop -> RouteStop in
            let isEdge = index == 0 || index == raw.count - 1
            let fallbackStatus: RouteStopStatus = isEdge ? .done : .pending
            return RouteStop(
                id: stop.id.nilIfEmpty ?? base[safe: index]?.id ?? UUID().uuidString,
                address: stop.address,
                org: stop.org,
                tid: stop.tid,
                reason: stop.reason,
                status: normalizeStatus(stop.status.rawValue, fallback: fallbackStatus),
                declineReason: stop.declineReason,
                requestNumber: stop.requestNumber
            )
        }

        if cloned.count < 2 {
            return defaultFallback(base: base, firstReason: firstReason, lastReason: lastReason)
        }

        if cloned.count == 2 {
            cloned.insert(base[safe: 1] ?? makeStop(status: .pending), at: 1)
        }

        let lastIndex = cloned.count - 1
        cloned[0].reason = cloned[0].reason.nilIfEmpty ?? firstReason
        cloned[0].status = .done
        cloned[lastIndex].reason = cloned[lastIndex].reason.nilIfEmpty ?? lastReason
        cloned[lastIndex].status = .done

        return cloned
    }

    static func normalize(
        _ record: RouteDayRecord,
        date: String,
        workType: RouteWorkType,
        settings: RouteSettings,
        periodStartOdometer: Int?
    ) -> RouteDayRecord {
        let base = defaultDay(for: date, workType: workType, settings: settings)
        return RouteDayRecord(
            date: date,
            workType: workType,
            stops: hydrateStops(raw: record.stops, base: base.stops),
            distanceKm: record.distanceKm,
            periodStartOdometer: periodStartOdometer,
            reportedDistanceKm: record.reportedDistanceKm,
            routeSummary: record.routeSummary,
            requestNumbersSummary: record.requestNumbersSummary,
            reportedPeriodStartOdometer: record.reportedPeriodStartOdometer,
            fuelDate: record.fuelDate,
            fuelLiters: record.fuelLiters,
            fuelCostRub: record.fuelCostRub,
            sent: record.sent
        )
    }

    static func migrateLegacyOfficeAddress(in settings: RouteSettings) -> RouteSettings {
        RouteSettings(
            warehouseAddress: migrateLegacyOfficeAddress(settings.warehouseAddress),
            homeAddress: migrateLegacyOfficeAddress(settings.homeAddress, fallback: ""),
            mapsProvider: settings.mapsProvider
        )
    }

    static func migrateLegacyOfficeAddress(in record: RouteDayRecord, settings: RouteSettings) -> RouteDayRecord {
        guard !record.stops.isEmpty else { return record }

        var migrated = record
        let lastIndex = migrated.stops.count - 1

        if migrated.stops.indices.contains(0) {
            migrated.stops[0].address = migrateLegacyOfficeAddress(
                migrated.stops[0].address,
                fallback: settings.startAddress
            )
        }

        if migrated.stops.indices.contains(lastIndex) {
            migrated.stops[lastIndex].address = migrateLegacyOfficeAddress(
                migrated.stops[lastIndex].address,
                fallback: settings.endAddress
            )
        }

        return migrated
    }

    private static func defaultFallback(base: [RouteStop], firstReason: String, lastReason: String) -> [RouteStop] {
        base.enumerated().map { index, stop in
            var copy = stop
            copy.status = index == 0 || index == base.count - 1 ? .done : .pending
            copy.reason = index == 0 ? firstReason : index == base.count - 1 ? lastReason : stop.reason
            return copy
        }
    }

    private static func makeStop(
        id: String = UUID().uuidString,
        address: String = "",
        org: String = "",
        tid: String = "",
        reason: String = "",
        status: RouteStopStatus = .pending,
        declineReason: String = "",
        requestNumber: String = ""
    ) -> RouteStop {
        RouteStop(
            id: id,
            address: address,
            org: org,
            tid: tid,
            reason: reason,
            status: status,
            declineReason: declineReason,
            requestNumber: requestNumber
        )
    }

    private static func normalizeStatus(_ raw: String, fallback: RouteStopStatus) -> RouteStopStatus {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered == RouteStopStatus.pending.rawValue {
            return .pending
        }
        if lowered == RouteStopStatus.done.rawValue || lowered.contains("done") || lowered.contains("выполн") {
            return .done
        }
        if lowered == RouteStopStatus.declined.rawValue || lowered.contains("decline") || lowered.contains("отказ") {
            return .declined
        }
        return fallback
    }

    private static func migrateLegacyOfficeAddress(_ value: String, fallback: String = RouteSettings.officeAddress) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        return trimmed == RouteSettings.legacyOfficeAddress ? RouteSettings.officeAddress : trimmed
    }

    private static func monthKey(for date: String) -> String {
        String(date.prefix(7))
    }
}

enum RouteDateFormatter {
    static func dayKey(from date: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 2000
        let month = components.month ?? 1
        let day = components.day ?? 1
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func humanDate(from date: Date) -> String {
        humanDate(from: dayKey(from: date))
    }

    static func humanDate(from dayKey: String) -> String {
        guard let date = storageFormatter.date(from: dayKey) else {
            return dayKey
        }
        return humanFormatter.string(from: date)
    }

    static let storageFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = AppLocale.russian
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let humanFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = AppLocale.russian
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "d MMMM"
        return formatter
    }()
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
