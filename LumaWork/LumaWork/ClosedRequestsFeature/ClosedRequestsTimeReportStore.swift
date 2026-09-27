import Foundation
import Observation

nonisolated enum XLSXTimeReportParser {
    nonisolated static func parse(data: Data, fileName: String) throws -> TimeReportSnapshot {
        let archive = try ZIPArchive(data: data)
        let worksheetPath = archive.entries.keys
            .filter { $0.hasPrefix("xl/worksheets/") && $0.hasSuffix(".xml") && !$0.contains("/_rels/") }
            .sorted()
            .first

        guard let worksheetPath else {
            throw ClosedRequestsImportError.worksheetNotFound
        }

        let sharedStrings: [String]
        if archive.entries["xl/sharedStrings.xml"] != nil {
            sharedStrings = try SharedStringsXMLParser.parse(data: archive.extract("xl/sharedStrings.xml"))
        } else {
            sharedStrings = []
        }

        let rows = try WorksheetXMLParser.parse(
            data: archive.extract(worksheetPath),
            sharedStrings: sharedStrings
        )
        let entries = rows
            .compactMap(makeEntry(from:))
            .sorted { $0.effectiveWorkDate > $1.effectiveWorkDate }

        guard !entries.isEmpty else {
            throw ClosedRequestsImportError.xml("В файле не найдены строки трудозатрат.")
        }

        return TimeReportSnapshot(
            fileName: fileName,
            importedAt: Date(),
            entries: entries
        )
    }

    nonisolated private static func makeEntry(from row: [String: String]) -> TimeReportEntry? {
        let activity = value(
            for: ["Активность", "Задача", "Задача.Активность", "acticvity", "activity", "task", "itsm_request", "source_task"],
            in: row
        )
        let createdAtRaw = value(for: ["Когда создано", "sys_created_at", "created_at"], in: row)
        let workDateRaw = value(for: ["Дата проведения работ", "date_of_work"], in: row)
        guard !activity.isEmpty,
              let createdAt = parseDate(createdAtRaw) ?? parseDate(workDateRaw) else {
            return nil
        }

        let workMinutes = parseWorkMinutes(
            durationText: value(for: ["Время работ", "work_time", "work_duration", "time_work"], in: row),
            hoursText: value(for: ["Время работ (ч)", "time_of_work_hours", "work_hours", "time_work_hours"], in: row),
            minutesText: value(for: ["Время работ (м)", "time_of_work_minutes", "work_minutes", "time_work_minutes"], in: row)
        )
        let travelMinutes = parseWorkMinutes(
            durationText: value(for: ["Время в дороге", "travel_time", "time_on_road"], in: row),
            hoursText: value(for: ["Время в дороге (ч)", "travel_time_hours", "travel_hours", "time_on_road_hours"], in: row),
            minutesText: value(for: ["Время в дороге (м)", "travel_time_minutes", "travel_minutes", "time_on_road_minutes"], in: row)
        )
        let overtimeMinutes = Int((parseDouble(value(for: ["Внеурочные работы (ч.)", "extracurricular_activities_hours", "overtime_hours", "over_time_hours"], in: row)) * 60).rounded())
            + Int(parseDouble(value(for: ["Внеурочные работы (м)", "overtime_minutes", "over_time_minutes"], in: row)).rounded())
        let simpleOneRecordID = value(for: ["sys_id", "ID", "Системный ID"], in: row)

        return TimeReportEntry(
            activity: activity,
            simpleOneRecordID: simpleOneRecordID.isEmpty ? nil : simpleOneRecordID,
            period: value(for: ["Период", "month", "period"], in: row),
            createdAt: createdAt,
            createdAtRaw: firstNonEmpty(createdAtRaw, workDateRaw),
            workDate: parseDate(workDateRaw),
            workDateRaw: workDateRaw.isEmpty ? nil : workDateRaw,
            workMinutes: workMinutes,
            travelMinutes: travelMinutes,
            overtimeMinutes: overtimeMinutes,
            notes: value(for: ["Рабочие заметки", "Комментарий", "result", "work_notes", "notes"], in: row),
            nonWorkCosts: value(for: ["Трудозатраты нерабочие", "non_work_costs", "non_work_time"], in: row),
            isOvertime: parseBool(value(for: ["Внеурочные работы", "extracurricular_work", "overtime", "is_overtime"], in: row)),
            executor: value(for: ["Исполнитель", "person", "person.c_full_name", "executor", "executor.c_full_name"], in: row)
        )
    }

    nonisolated private static func firstNonEmpty(_ values: String...) -> String {
        values.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
    }

    nonisolated private static func value(for key: String, in row: [String: String]) -> String {
        if let value = row[key]?.trimmingCharacters(in: .whitespacesAndNewlines) {
            return value
        }

        let normalizedKey = normalizedHeader(key)
        return row.first { normalizedHeader($0.key) == normalizedKey }?
            .value
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    nonisolated private static func value(for keys: [String], in row: [String: String]) -> String {
        for key in keys {
            let result = value(for: key, in: row)
            if !result.isEmpty {
                return result
            }
        }
        return ""
    }

    nonisolated private static func normalizedHeader(_ raw: String) -> String {
        raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    nonisolated private static func parseDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let serial = Double(trimmed.replacingOccurrences(of: ",", with: ".")) {
            let excelBaseDate = Date(timeIntervalSince1970: -2209161600)
            return excelBaseDate.addingTimeInterval(serial * 86_400)
        }

        for formatter in dateFormatters {
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }

        return nil
    }

    nonisolated private static func parseWorkMinutes(durationText: String, hoursText: String, minutesText: String) -> Int {
        let parsedMinutes = parseDurationMinutes(durationText)
        if parsedMinutes > 0 {
            return parsedMinutes
        }
        return Int((parseDouble(hoursText) * 60).rounded())
            + Int(parseDouble(minutesText).rounded())
    }

    nonisolated private static func parseDurationMinutes(_ raw: String) -> Int {
        let normalized = raw
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return 0 }

        if let numericValue = Double(normalized), numericValue > 0 {
            if numericValue >= 60_000 {
                return Int((numericValue / 60_000).rounded())
            }
            return Int(numericValue.rounded())
        }

        let hours = sumMatches(
            pattern: #"(\d+(?:\.\d+)?)\s*(?:hours?|hour|час(?:а|ов)?|ч|h)"#,
            in: normalized
        )
        let minutes = sumMatches(
            pattern: #"(\d+(?:\.\d+)?)\s*(?:minutes?|minute|мин(?:ут(?:а|ы)?)?|м|m)"#,
            in: normalized
        )
        return Int((hours * 60 + minutes).rounded())
    }

    nonisolated private static func sumMatches(pattern: String, in raw: String) -> Double {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return 0
        }

        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        return regex.matches(in: raw, range: range).reduce(0) { partialResult, match in
            guard match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: raw) else {
                return partialResult
            }
            return partialResult + (Double(raw[valueRange]) ?? 0)
        }
    }

    nonisolated private static func parseDouble(_ raw: String) -> Double {
        Double(raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    nonisolated private static func parseBool(_ raw: String) -> Bool {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "да", "истина":
            return true
        default:
            return false
        }
    }

    nonisolated private static let dateFormatters: [DateFormatter] = {
        let formats = [
            "dd.MM.yyyy HH:mm:ss",
            "dd.MM.yyyy HH:mm",
            "dd.MM.yyyy H:mm:ss",
            "dd.MM.yyyy H:mm",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd",
            "dd.MM.yyyy"
        ]

        return formats.map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            return formatter
        }
    }()
}

@MainActor
@Observable
final class TimeReportStore {
    private let legacyStorageKey = "time-report-snapshot"

    var snapshot: TimeReportSnapshot?
    var isImporting = false
    var isLoadingSnapshot = false
    var isDeleting = false
    var errorMessage: String?
    var notice: String?

    init() {
        Task {
            await loadSnapshot()
        }
    }

    var entries: [TimeReportEntry] {
        snapshot?.entries ?? []
    }

    var daySummaries: [TimeReportDaySummary] {
        Self.daySummaries(from: entries)
    }

    var deletionDateRange: ClosedRange<Date>? {
        guard let earliestDate = entries.map(\.effectiveWorkDate).min(),
              let latestDate = entries.map(\.effectiveWorkDate).max() else {
            return nil
        }

        let calendar = Calendar.autoupdatingCurrent
        return calendar.startOfDay(for: earliestDate)...calendar.startOfDay(for: latestDate)
    }

    func entryCount(from startDate: Date, through endDate: Date) -> Int {
        let bounds = Self.inclusiveDayBounds(from: startDate, through: endDate)
        return entries.lazy.filter {
            $0.effectiveWorkDate >= bounds.start && $0.effectiveWorkDate < bounds.endExclusive
        }.count
    }

    @discardableResult
    func deleteAllEntries() async -> Int {
        guard !isDeleting, !isImporting, !isLoadingSnapshot else { return 0 }

        let deletedCount = entries.count
        return await replaceSnapshotAfterDeletion(
            with: nil,
            deletedCount: deletedCount,
            notice: "Удалены все трудозатраты с устройства: \(deletedCount) строк."
        )
    }

    @discardableResult
    func deleteEntries(from startDate: Date, through endDate: Date) async -> Int {
        guard !isDeleting, !isImporting, !isLoadingSnapshot, let snapshot else { return 0 }

        let bounds = Self.inclusiveDayBounds(from: startDate, through: endDate)
        let remainingEntries = snapshot.entries.filter {
            $0.effectiveWorkDate < bounds.start || $0.effectiveWorkDate >= bounds.endExclusive
        }
        let deletedCount = snapshot.entries.count - remainingEntries.count
        guard deletedCount > 0 else {
            notice = "За выбранный период трудозатраты не найдены."
            return 0
        }

        let updatedSnapshot = remainingEntries.isEmpty
            ? nil
            : TimeReportSnapshot(
                fileName: snapshot.fileName,
                importedAt: snapshot.importedAt,
                entries: Self.sortEntries(remainingEntries)
            )
        return await replaceSnapshotAfterDeletion(
            with: updatedSnapshot,
            deletedCount: deletedCount,
            notice: "Удалено строк трудозатрат: \(deletedCount)."
        )
    }

    func importSpreadsheet(from url: URL) async {
        guard !isDeleting, !isImporting, !isLoadingSnapshot else { return }
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
                let parsed = try XLSXTimeReportParser.parse(
                    data: data,
                    fileName: url.lastPathComponent.isEmpty ? "Трудозатраты.xlsx" : url.lastPathComponent
                )
                let merged = Self.mergeSnapshot(existing: existingSnapshot, incoming: parsed)
                try Self.saveSnapshotToDisk(merged.snapshot)
                return merged
            }.value

            snapshot = merged.snapshot
            notice = merged.notice
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
        }
    }

    func importSpreadsheet(data: Data, fileName: String) async {
        guard !isDeleting, !isImporting, !isLoadingSnapshot else { return }
        isImporting = true
        errorMessage = nil
        notice = nil

        let existingSnapshot = snapshot
        defer { isImporting = false }

        do {
            let merged = try await Task.detached(priority: .userInitiated) {
                let parsed = try XLSXTimeReportParser.parse(
                    data: data,
                    fileName: fileName.isEmpty ? "Трудозатраты.xlsx" : fileName
                )
                let merged = Self.mergeSnapshot(existing: existingSnapshot, incoming: parsed)
                try Self.saveSnapshotToDisk(merged.snapshot)
                return merged
            }.value

            snapshot = merged.snapshot
            notice = merged.notice
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
        }
    }

    @discardableResult
    func mergeSimpleOneTimeReportEntries(
        _ entries: [TimeReportEntry],
        showsNotice: Bool = true
    ) async -> Int {
        guard !isDeleting, !isImporting, !isLoadingSnapshot else { return 0 }
        guard !entries.isEmpty else {
            if showsNotice {
                notice = "SimpleOne не вернул трудозатрат."
            }
            return 0
        }

        var existingEntriesByID: [String: TimeReportEntry] = [:]
        for entry in self.entries {
            existingEntriesByID[entry.stableID] = entry
        }
        let changedCount = entries.reduce(into: 0) { count, entry in
            if existingEntriesByID[entry.stableID] != entry {
                count += 1
            }
        }
        guard changedCount > 0 else {
            if showsNotice {
                notice = "Трудозатраты актуальны."
            }
            return 0
        }

        isImporting = true
        errorMessage = nil
        notice = nil

        let existingSnapshot = snapshot
        defer { isImporting = false }

        do {
            let merged = try await Task.detached(priority: .userInitiated) {
                let incoming = TimeReportSnapshot(
                    fileName: "SimpleOne",
                    importedAt: Date(),
                    entries: entries
                )
                let merged = Self.mergeSnapshot(existing: existingSnapshot, incoming: incoming)
                try Self.saveSnapshotToDisk(merged.snapshot)
                return merged
            }.value

            snapshot = merged.snapshot
            notice = showsNotice ? merged.notice : nil
            return changedCount
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
            return 0
        }
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
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
        }
    }

    private func replaceSnapshotAfterDeletion(
        with updatedSnapshot: TimeReportSnapshot?,
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
            notice = successNotice
            return deletedCount
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
            return 0
        }
    }

    nonisolated private static func mergeSnapshot(
        existing: TimeReportSnapshot?,
        incoming: TimeReportSnapshot
    ) -> (snapshot: TimeReportSnapshot, notice: String) {
        guard let existing else {
            let normalizedEntries = removingDuplicateREQEntries(from: incoming.entries)
            let removedDuplicateCount = incoming.entries.count - normalizedEntries.count
            let snapshot = TimeReportSnapshot(
                fileName: incoming.fileName,
                importedAt: incoming.importedAt,
                entries: sortEntries(normalizedEntries)
            )
            let duplicateNotice = removedDuplicateCount > 0
                ? ", удалено дублей REQ: \(removedDuplicateCount)"
                : ""
            let notice = "Загружено \(snapshot.entries.count) строк трудозатрат из \(incoming.fileName)\(duplicateNotice)"
            return (snapshot, notice)
        }

        let existingIDs = Set(existing.entries.map(\.stableID))
        var entriesByID: [String: TimeReportEntry] = [:]
        for entry in existing.entries {
            entriesByID[entry.stableID] = entry
        }

        for entry in incoming.entries {
            entriesByID[entry.stableID] = entry
        }

        let entriesBeforeDuplicateRemoval = Array(entriesByID.values)
        let normalizedEntries = removingDuplicateREQEntries(from: entriesBeforeDuplicateRemoval)
        let finalIDs = Set(normalizedEntries.map(\.stableID))
        let incomingIDs = Set(incoming.entries.map(\.stableID))
        let addedCount = finalIDs.intersection(incomingIDs).subtracting(existingIDs).count
        let updatedCount = finalIDs.intersection(incomingIDs).intersection(existingIDs).count
        let removedDuplicateCount = entriesBeforeDuplicateRemoval.count - normalizedEntries.count
        let mergedSnapshot = TimeReportSnapshot(
            fileName: incoming.fileName,
            importedAt: incoming.importedAt,
            entries: sortEntries(normalizedEntries)
        )
        let duplicateNotice = removedDuplicateCount > 0
            ? ", удалено дублей REQ: \(removedDuplicateCount)"
            : ""
        let notice = "Трудозатраты: +\(addedCount) новых, \(updatedCount) обновлено, всего \(mergedSnapshot.entries.count)\(duplicateNotice)"
        return (mergedSnapshot, notice)
    }

    nonisolated static func daySummaries(from entries: [TimeReportEntry]) -> [TimeReportDaySummary] {
        Dictionary(grouping: entries) { dayKey(from: $0.effectiveWorkDate) }
            .map { dateKey, entries in
                let sortedEntries = entries.sorted { $0.effectiveWorkDate > $1.effectiveWorkDate }
                return TimeReportDaySummary(
                    dateKey: dateKey,
                    title: dayTitle(from: dateKey),
                    entries: sortedEntries,
                    workMinutes: sortedEntries.reduce(0) { $0 + $1.workMinutes },
                    travelMinutes: sortedEntries.reduce(0) { $0 + $1.travelMinutes },
                    overtimeMinutes: sortedEntries.reduce(0) { $0 + $1.overtimeMinutes }
                )
            }
            .sorted { $0.dateKey > $1.dateKey }
    }

    nonisolated private static func sortEntries(_ entries: [TimeReportEntry]) -> [TimeReportEntry] {
        entries.sorted { lhs, rhs in
            if lhs.effectiveWorkDate != rhs.effectiveWorkDate {
                return lhs.effectiveWorkDate > rhs.effectiveWorkDate
            }
            return lhs.activity.localizedStandardCompare(rhs.activity) == .orderedAscending
        }
    }

    nonisolated private static func removingDuplicateREQEntries(
        from entries: [TimeReportEntry]
    ) -> [TimeReportEntry] {
        let nonREQTimestamps = Set(entries.lazy
            .filter { !isREQActivity($0.activity) }
            .map { minuteKey(from: $0.effectiveWorkDate) })

        return entries.filter { entry in
            !isREQActivity(entry.activity)
                || !nonREQTimestamps.contains(minuteKey(from: entry.effectiveWorkDate))
        }
    }

    nonisolated private static func isREQActivity(_ activity: String) -> Bool {
        activity
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased(with: Locale(identifier: "en_US_POSIX"))
            .hasPrefix("REQ")
    }

    nonisolated private static func minuteKey(from date: Date) -> Int64 {
        Int64(floor(date.timeIntervalSince1970 / 60))
    }

    nonisolated private static func loadSnapshotFromDiskOrLegacy(legacyStorageKey: String) throws -> TimeReportSnapshot? {
        let fileURL = snapshotFileURL()
        let decoder = JSONDecoder()

        if let data = try? Data(contentsOf: fileURL),
           let snapshot = try? decoder.decode(TimeReportSnapshot.self, from: data) {
            let normalizedSnapshot = TimeReportSnapshot(
                fileName: snapshot.fileName,
                importedAt: snapshot.importedAt,
                entries: sortEntries(removingDuplicateREQEntries(from: snapshot.entries))
            )
            if normalizedSnapshot.entries.count != snapshot.entries.count {
                try saveSnapshotToDisk(normalizedSnapshot)
            }
            return normalizedSnapshot
        }

        guard let legacyData = UserDefaults.standard.data(forKey: legacyStorageKey),
              let legacySnapshot = try? decoder.decode(TimeReportSnapshot.self, from: legacyData) else {
            return nil
        }

        let normalizedSnapshot = TimeReportSnapshot(
            fileName: legacySnapshot.fileName,
            importedAt: legacySnapshot.importedAt,
            entries: sortEntries(removingDuplicateREQEntries(from: legacySnapshot.entries))
        )
        try saveSnapshotToDisk(normalizedSnapshot)
        UserDefaults.standard.removeObject(forKey: legacyStorageKey)
        return normalizedSnapshot
    }

    nonisolated private static func saveSnapshotToDisk(_ snapshot: TimeReportSnapshot) throws {
        let fileURL = snapshotFileURL()
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: fileURL, options: [.atomic])
    }

    nonisolated private static func replaceStoredSnapshot(
        with snapshot: TimeReportSnapshot?,
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

    nonisolated private static func snapshotFileURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("LumaWork", isDirectory: true)
            .appendingPathComponent("time-report-snapshot.json", isDirectory: false)
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

    nonisolated private static func dayKey(from date: Date) -> String {
        dayKeyFormatter.string(from: date)
    }

    nonisolated private static func dayTitle(from key: String) -> String {
        guard let date = dayKeyFormatter.date(from: key) else {
            return key
        }
        return dayTitleFormatter.string(from: date)
    }

    nonisolated private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    nonisolated private static let dayTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMMM yyyy"
        return formatter
    }()
}
