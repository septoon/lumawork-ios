import Foundation
import SwiftUI

extension ClosedRequestsScreen {
    var paginationCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 8), count: min(max(visiblePageNumbers.count + 2, 1), 7)), alignment: .leading, spacing: 8) {
                    Button {
                        AppHaptics.trigger()
                        currentPage = max(1, safeCurrentPage - 1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.caption.weight(.semibold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(safeCurrentPage == 1 ? AppTheme.mutedTint : AppTheme.primaryTint)
                    .background(AppTheme.secondaryTint.opacity(safeCurrentPage == 1 ? 0.08 : 0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .disabled(safeCurrentPage == 1)

                    ForEach(visiblePageNumbers, id: \.self) { page in
                        Button {
                            AppHaptics.trigger()
                            currentPage = page
                        } label: {
                            Text("\(page)")
                                .font(.caption.weight(page == safeCurrentPage ? .semibold : .medium))
                                .foregroundStyle(page == safeCurrentPage ? Color.white : AppTheme.ink)
                                .frame(width: 28, height: 28)
                                .background(
                                    Group {
                                        if page == safeCurrentPage {
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .fill(AppTheme.primaryTint)
                                        } else {
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .fill(AppTheme.secondaryTint.opacity(0.12))
                                        }
                                    }
                                )
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        AppHaptics.trigger()
                        currentPage = min(pageCount, safeCurrentPage + 1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(safeCurrentPage == pageCount ? AppTheme.mutedTint : AppTheme.primaryTint)
                    .background(AppTheme.secondaryTint.opacity(safeCurrentPage == pageCount ? 0.08 : 0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .disabled(safeCurrentPage == pageCount)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text("Страница \(safeCurrentPage) из \(pageCount) • \(paginatedRecords.count) заявок")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedTint)
                
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
    }

    var pageCount: Int {
        max(1, Int(ceil(Double(filteredRecordsCache.count) / Double(pageSize))))
    }

    var visiblePageNumbers: [Int] {
        guard pageCount > 1 else { return [1] }

        let windowSize = 5
        let halfWindow = windowSize / 2

        var start = max(1, safeCurrentPage - halfWindow)
        let end = min(pageCount, start + windowSize - 1)

        if end - start + 1 < windowSize {
            start = max(1, end - windowSize + 1)
        }

        return Array(start...end)
    }

    var safeCurrentPage: Int {
        min(max(currentPage, 1), pageCount)
    }

    var paginatedRecords: [ClosedRequestListItem] {
        let startIndex = max(0, (safeCurrentPage - 1) * pageSize)
        let endIndex = min(filteredRecordsCache.count, startIndex + pageSize)
        guard startIndex < endIndex else {
            return []
        }
        return Array(filteredRecordsCache[startIndex..<endIndex])
    }

    var paginatedDayGroups: [ClosedRequestDayGroup] {
        var groups: [ClosedRequestDayGroup] = []
        for record in paginatedRecords {
            if let lastIndex = groups.indices.last,
               groups[lastIndex].dayKey == record.dayKey {
                groups[lastIndex].records.append(record)
            } else {
                groups.append(ClosedRequestDayGroup(
                    dayKey: record.dayKey,
                    title: record.dayTitle,
                    caption: record.dayCaption,
                    records: [record]
                ))
            }
        }
        return groups
    }

    func rebuildSearchIndex() async {
        let records = store.records
        let prepared = await Task.detached(priority: .utility) {
            let entries = ClosedRequestsIndexBuilder.build(records: records)
            let defaultRange = ClosedRequestsFilterSupport.defaultRange(
                availableDates: entries.compactMap(\.item.date)
            )
            let deletionRange = ClosedRequestsStore.deletionDateRange(in: records)
            return (entries, defaultRange, deletionRange)
        }.value
        guard !Task.isCancelled else { return }
        closedRequestsCache = records
        searchEntries = prepared.0
        automaticClosedDateRange = prepared.1
        closedDeletionDateRange = prepared.2
        currentPage = 1
        refreshFilteredRecords()
    }

    func refreshFilteredRecords() {
        let query = normalizedClosedSearchQuery
        let dateRange = closedDateRange ?? (query.isEmpty ? automaticClosedDateRange : nil)
        filteredRecordsCache = searchEntries
            .filter { entry in
                guard query.isEmpty || entry.searchText.contains(query) else { return false }
                guard let dateRange else { return true }
                return entry.item.date.map { closedDateRangeContains($0, range: dateRange) } ?? false
            }
            .map(\.item)
    }

    var effectiveClosedDateRange: ClosedRange<Date>? {
        closedDateRange ?? (normalizedClosedSearchQuery.isEmpty ? automaticClosedDateRange : nil)
    }

    var todayAndYesterdayClosedDateRange: ClosedRange<Date> {
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        return yesterday...today
    }

    func closedDateRangeContains(_ date: Date, range: ClosedRange<Date>) -> Bool {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: range.lowerBound)
        let endDay = calendar.startOfDay(for: range.upperBound)
        let endExclusive = calendar.date(byAdding: .day, value: 1, to: endDay)
            ?? endDay.addingTimeInterval(86_400)
        return date >= start && date < endExclusive
    }

    var normalizedSearchQuery: String {
        searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    var normalizedClosedSearchQuery: String {
        committedClosedSearchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    var closedSearchTaskID: String {
        "\(requestsMode.rawValue)|\(searchText)"
    }

    func commitClosedSearchAfterDelay() async {
        guard requestsMode == .closed else { return }
        if searchText != committedClosedSearchText {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
        }
        guard !Task.isCancelled, requestsMode == .closed else { return }
        committedClosedSearchText = searchText
        currentPage = 1
        refreshFilteredRecords()
    }

    func makeListItem(for record: ClosedRequestRecord) -> ClosedRequestListItem {
        let requestType = localizedRequestType(record.requestType)
        let timeText = closedRequestTimeText(for: record)
        let statusText = closedRequestStatusText(for: record)
        let date = closedAtDate(timeText.value)
        return ClosedRequestListItem(
            record: record,
            date: date,
            requestType: requestType,
            statusText: statusText,
            closedAtText: formatClosedAt(timeText.value),
            timeTitle: timeText.title,
            normalizedAddress: normalizedAddress(record.address),
            dayKey: closedRequestDayKey(for: date, fallback: timeText.value),
            dayTitle: closedRequestDayTitle(for: date, fallback: timeText.value),
            dayCaption: closedRequestDayCaption(for: date),
            searchText: [
                record.requestNumber,
                record.shortDescription,
                record.customer,
                record.contactPerson,
                record.address,
                record.terminalID,
                record.incomingNumber,
                record.engineerName,
                record.merchantTIN,
                record.posEquipment,
                record.dismantledEquipmentSerialNumber,
                record.installedFiscalStorageSerialNumber,
                record.ofdTariffActivationCode,
                record.usedSIMCard,
                record.closureCode,
                statusText,
                timeText.value,
                formatClosedAt(timeText.value),
                closedRequestDateSearchText(for: date, fallback: timeText.value),
                searchInfoValue(for: "ИНН ТСП", in: record),
                searchInfoValue(for: "Оборудование POS", in: record),
                searchInfoValue(for: "Серийный номер демонтируемого ТО", in: record),
                searchInfoValue(for: "Серийный номер установленного ФН", in: record),
                searchInfoValue(for: "Использованный код активации тарифа ОФД", in: record),
                searchInfoValue(for: "Использованная SIM карта", in: record)
            ]
            .compactMap { $0 }
            .joined(separator: "\n")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        )
    }

    func closedRequestStatusText(for record: ClosedRequestRecord) -> String {
        if isReturnEquipment(record.requestType) {
            return localizedClosedRequestStatus(record.status)
        }
        return record.completionStatus.title
    }

    func closedRequestTimeText(for record: ClosedRequestRecord) -> (title: String, value: String) {
        if isReturnEquipment(record.requestType) {
            let registeredAt = record.registeredAt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ("Время регистрации", closedAtDate(registeredAt) == nil ? record.closedAt : registeredAt)
        }
        return ("Выполнена", record.closedAt)
    }

    func searchInfoValue(for key: String, in record: ClosedRequestRecord) -> String? {
        let normalizedKey = normalizedSearchInfoKey(key)
        let value = record.infoFields
            .first { normalizedSearchInfoKey($0.key) == normalizedKey }?
            .value
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return value?.isEmpty == false ? value : nil
    }

    func closedRequestDayKey(for date: Date?, fallback: String) -> String {
        if let date {
            return Self.dayKeyFormatter.string(from: date)
        }
        let fallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? "unknown" : fallback
    }

    func closedRequestDayTitle(for date: Date?, fallback: String) -> String {
        guard let date else {
            let fallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
            return fallback.isEmpty ? "Дата не указана" : fallback
        }

        if Calendar.current.isDateInToday(date) {
            return "Сегодня"
        }
        if Calendar.current.isDateInYesterday(date) {
            return "Вчера"
        }
        return Self.dayTitleFormatter.string(from: date)
    }

    func closedRequestDayCaption(for date: Date?) -> String {
        guard let date else { return "" }
        return Self.dayCaptionFormatter.string(from: date)
    }

    func closedRequestDateSearchText(for date: Date?, fallback: String) -> String {
        guard let date else {
            return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return [
            Self.searchDayMonthFormatter.string(from: date),
            Self.searchFullDateFormatter.string(from: date),
            Self.searchShortYearDateFormatter.string(from: date),
            Self.searchSpacedDateFormatter.string(from: date),
            Self.dayTitleFormatter.string(from: date),
            Self.dayCaptionFormatter.string(from: date)
        ]
        .joined(separator: "\n")
    }

    func normalizedSearchInfoKey(_ raw: String) -> String {
        raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }
}
