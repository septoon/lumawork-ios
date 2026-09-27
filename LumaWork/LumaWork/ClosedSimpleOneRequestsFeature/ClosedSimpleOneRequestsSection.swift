import Foundation
import SwiftUI

struct ClosedSimpleOneRequestsSection: View {
    let store: ClosedSimpleOneRequestsStore
    let simpleOneStore: SimpleOneRequestsStore
    let searchText: String
    let onOpen: (SimpleOneRequestRecord) -> Void

    @State private var loadingRequestID: String?
    @State private var currentPage = 1

    private var filteredRecords: [SimpleOneRequestRecord] {
        let query = normalizedSearchQuery
        guard !query.isEmpty else {
            return datedRecords
        }
        return datedRecords.filter { $0.searchText.contains(query) }
    }

    private var datedRecords: [SimpleOneRequestRecord] {
        store.records
            .filter { !dateText(for: $0).isEmpty }
            .sorted { lhs, rhs in
                if let lhsDate = date(for: lhs), let rhsDate = date(for: rhs) {
                    return lhsDate > rhsDate
                }
                return dateText(for: lhs).localizedStandardCompare(dateText(for: rhs)) == .orderedDescending
            }
    }

    private var filteredItems: [ClosedSimpleOneListItem] {
        filteredRecords.map(makeListItem)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                AppSectionHeader(title: "Закрытые SO", caption: sectionCaption)
                Spacer(minLength: 0)
                if store.isLoading {
                    ProgressView()
                        .tint(AppTheme.primaryTint)
                } else if simpleOneStore.isAuthorized {
                    Button {
                        Task {
                            currentPage = 1
                            await store.load(using: simpleOneStore, force: true)
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.headline.weight(.semibold))
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.primaryTint)
                    .background(AppTheme.secondaryTint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityLabel("Обновить закрытые SO")
                }
            }

            if let errorMessage = store.errorMessage {
                AppNoticeBanner(text: errorMessage, tint: AppTheme.dangerTint, isCritical: true)
            }

            if !simpleOneStore.isAuthorized {
                AppEmptyState(
                    title: "Войдите в SimpleOne",
                    message: "Закрытые SO загрузятся по текущей SimpleOne-сессии.",
                    systemName: "person.crop.circle.badge.exclamationmark"
                )
            } else if store.isLoading && store.records.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    AppLoadingView(title: "Получаю полный архив SimpleOne")
                    HStack(spacing: 10) {
                        ProgressView(value: store.progressFraction)
                            .tint(AppTheme.primaryTint)
                        Text("\(store.progressPercent)%")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.primaryTint)
                    }
                    Text(store.progressText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.primaryTint)
                }
            } else if store.records.isEmpty {
                AppEmptyState(
                    title: "Закрытых SO нет",
                    message: "SimpleOne ничего не вернул по текущему фильтру.",
                    systemName: "checklist"
                )
            } else {
                if store.isLoading {
                    AppCard {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Синхронизация закрытых SO")
                                .font(.headline)
                                .foregroundStyle(AppTheme.ink)
                                Spacer(minLength: 0)
                                Text("\(store.progressPercent)%")
                                    .font(.headline.weight(.semibold))
                                    .foregroundStyle(AppTheme.primaryTint)
                            }
                            ProgressView(value: store.progressFraction)
                                .tint(AppTheme.primaryTint)
                            Text(store.progressText)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.primaryTint)
                        }
                    }
                }

                if filteredRecords.isEmpty {
                    AppEmptyState(
                        title: "Ничего не найдено",
                        message: "Измените строку поиска.",
                        systemName: "magnifyingglass"
                    )
                } else {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(paginatedDayGroups) { group in
                            ClosedSimpleOneDayHeader(title: group.title, caption: group.caption)
                            ForEach(group.records) { item in
                                closedSimpleOneRequestCard(item)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if pageCount > 1 {
                        paginationCard
                    }
                }
            }
        }
        .task(id: loadTaskID) {
            await store.load(using: simpleOneStore)
        }
        .task(id: store.errorMessage) {
            await appDismissTransientMessage(store.errorMessage) { value in
                if store.errorMessage == value {
                    store.errorMessage = nil
                }
            }
        }
        .onChange(of: searchText) { _, _ in
            currentPage = 1
        }
    }

    private var sectionCaption: String {
        if store.records.isEmpty {
            return "тестовый источник SimpleOne"
        }
        if filteredRecords.count == store.records.count {
            return "\(store.records.count)"
        }
        return "\(filteredRecords.count) из \(store.records.count)"
    }

    private var loadTaskID: String {
        [
            simpleOneStore.isAuthorized ? "authorized" : "anonymous",
            simpleOneStore.currentUser?.sysID ?? ""
        ].joined(separator: "|")
    }

    private var normalizedSearchQuery: String {
        searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    private func makeListItem(for record: SimpleOneRequestRecord) -> ClosedSimpleOneListItem {
        let rawDate = dateText(for: record)
        let parsedDate = parsedDate(rawDate)
        return ClosedSimpleOneListItem(
            record: record,
            requestType: requestTypeText(for: record),
            closedAtText: formattedDate(rawDate),
            dayKey: dayKey(for: parsedDate, fallback: rawDate),
            dayTitle: dayTitle(for: parsedDate, fallback: rawDate),
            dayCaption: dayCaption(for: parsedDate)
        )
    }

    private func dateText(for record: SimpleOneRequestRecord) -> String {
        record.resolvedAt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func date(for record: SimpleOneRequestRecord) -> Date? {
        parsedDate(dateText(for: record))
    }

    private func parsedDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        for formatter in Self.dateParsingFormatters {
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return nil
    }

    private func dayKey(for date: Date?, fallback: String) -> String {
        if let date {
            return Self.dayKeyFormatter.string(from: date)
        }
        return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func dayTitle(for date: Date?, fallback: String) -> String {
        guard let date else {
            return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if Calendar.current.isDateInToday(date) {
            return "Сегодня"
        }
        if Calendar.current.isDateInYesterday(date) {
            return "Вчера"
        }
        return Self.dayTitleFormatter.string(from: date)
    }

    private func dayCaption(for date: Date?) -> String {
        guard let date else { return "" }
        return Self.dayCaptionFormatter.string(from: date)
    }

    private var pageCount: Int {
        max(1, Int(ceil(Double(filteredItems.count) / Double(store.pageSize))))
    }

    private var visiblePageNumbers: [Int] {
        let current = safeCurrentPage
        let maxPage = pageCount
        let start = max(1, min(current - 2, maxPage - 4))
        let end = max(start, min(maxPage, start + 4))
        return Array(start...end)
    }

    private var safeCurrentPage: Int {
        min(max(currentPage, 1), pageCount)
    }

    private var paginatedItems: [ClosedSimpleOneListItem] {
        let startIndex = (safeCurrentPage - 1) * store.pageSize
        guard filteredItems.indices.contains(startIndex) else { return [] }
        let endIndex = min(startIndex + store.pageSize, filteredItems.count)
        return Array(filteredItems[startIndex..<endIndex])
    }

    private var paginatedDayGroups: [ClosedSimpleOneDayGroup] {
        var groups: [ClosedSimpleOneDayGroup] = []
        for item in paginatedItems {
            if let lastIndex = groups.indices.last,
               groups[lastIndex].dayKey == item.dayKey {
                groups[lastIndex].records.append(item)
            } else {
                groups.append(ClosedSimpleOneDayGroup(
                    dayKey: item.dayKey,
                    title: item.dayTitle,
                    caption: item.dayCaption,
                    records: [item]
                ))
            }
        }
        return groups
    }

    private var paginationCard: some View {
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

                Text("Страница \(safeCurrentPage) из \(pageCount) - \(paginatedItems.count) заявок")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedTint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
    }

    private func closedSimpleOneRequestCard(_ item: ClosedSimpleOneListItem) -> some View {
        let record = item.record
        let primaryNumber = primaryNumberText(for: record)
        let statusText = completionStatusText(for: record)
        let isReturnEquipment = isReturnEquipmentRequest(record)

        return AppCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        AppSelectableText(
                            text: primaryNumber,
                            textStyle: .headline,
                            weight: .semibold
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if !record.number.isEmpty, primaryNumber != record.number {
                            Text(record.number)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(AppTheme.mutedTint)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .trailing, spacing: 6) {
                        RequestBadge(text: item.requestType, style: .requestType(item.requestType))
                        if !statusText.isEmpty {
                            RequestBadge(text: statusText, style: .status(statusText))
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }

                if loadingRequestID == record.id {
                    AppLoadingView(title: "Загружаю детали")
                }

                if !statusText.isEmpty {
                    infoRow(title: "Статус", value: statusText)
                }
                infoRow(title: "Выполнена", value: item.closedAtText)
                if !isReturnEquipment {
                    infoRow(title: "Заказчик", value: nonEmpty(record.customer))
                }

                let address = addressText(for: record)
                if !address.isEmpty {
                    addressRow(address.normalizedAddressStartingFromAlushta())
                }

                infoRow(title: "ID терминала", value: nonEmpty(terminalIDText(for: record)))
            }
            .contentShape(Rectangle())
            .onTapGesture {
                open(record)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func open(_ record: SimpleOneRequestRecord) {
        AppHaptics.trigger()
        guard loadingRequestID == nil else { return }

        loadingRequestID = record.id
        Task {
            defer { loadingRequestID = nil }
            do {
                let detailedRecord = try await simpleOneStore.fetchDetailedRequest(record)
                onOpen(detailedRecord)
            } catch {
                store.errorMessage = appUserFacingErrorMessage(error)
            }
        }
    }

    private func infoRow(title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.mutedTint)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 12)
            AppSelectableText(
                text: value,
                textStyle: .subheadline,
                weight: .semibold,
                textAlignment: .right
            )
            .frame(maxWidth: .infinity, alignment: .trailing)
            .layoutPriority(1)
        }
    }

    private func addressRow(_ address: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Адрес")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.mutedTint)
            AppSelectableText(
                text: address,
                textStyle: .subheadline,
                weight: .semibold
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func primaryNumberText(for record: SimpleOneRequestRecord) -> String {
        firstNonEmpty([
            record.incomingNumber,
            infoValue(in: record, labels: ["Номер заявки Мультикарты", "Номер заявки"]),
            record.shortDescription.hasPrefix("SUTS") ? record.shortDescription : nil,
            record.number
        ])
    }

    private func requestTypeText(for record: SimpleOneRequestRecord) -> String {
        localizedRequestType(firstNonEmpty([
            record.requestType,
            infoValue(in: record, labels: ["Тип заявки", "Тип работ", "Вид заявки", "Тип обращения"])
        ]))
    }

    private func addressText(for record: SimpleOneRequestRecord) -> String {
        firstNonEmpty([
            record.address,
            infoValue(in: record, labels: ["Адрес ТСП", "Адрес установки терминала", "Адрес"])
        ])
    }

    private func terminalIDText(for record: SimpleOneRequestRecord) -> String {
        firstNonEmpty([
            record.terminalID,
            infoValue(in: record, labels: ["ID терминал", "ID терминала", "Оборудование POS"])
        ])
    }

    private func completionStatusText(for record: SimpleOneRequestRecord) -> String {
        let closureCode = firstNonEmpty([
            record.closureCode,
            infoValue(in: record, labels: ["Код закрытия"])
        ])
        let normalizedClosureCode = closureCode
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "ru_RU"))

        return normalizedClosureCode.hasPrefix("решено с выездом") ? "Выполнена" : "Отказ"
    }

    private func isReturnEquipmentRequest(_ record: SimpleOneRequestRecord) -> Bool {
        let rawType = firstNonEmpty([
            record.requestType,
            infoValue(in: record, labels: ["Тип заявки", "Тип работ", "Вид заявки", "Тип обращения"])
        ])
        let localizedType = localizedRequestType(rawType)
        let normalizedType = "\(rawType) \(localizedType)"
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "ru_RU"))
        return normalizedType.contains("returnequip") || normalizedType.contains("возврат то")
    }

    private func infoValue(in record: SimpleOneRequestRecord, labels: [String]) -> String {
        let normalizedLabels = labels.map(normalizedLabel)
        return informationFields(in: record)
            .first { normalizedLabels.contains(normalizedLabel($0.key)) }?
            .value
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func informationFields(in record: SimpleOneRequestRecord) -> [ClosedRequestInfoField] {
        let rawTexts = [
            record.additionalInformation ?? "",
            record.description,
            record.informationText
        ] + (record.tableFields ?? []).map(\.value)

        return (record.tableFields ?? []) + rawTexts.flatMap(parseInformationFields)
    }

    private func parseInformationFields(_ text: String) -> [ClosedRequestInfoField] {
        text
            .components(separatedBy: .newlines)
            .compactMap { rawLine -> ClosedRequestInfoField? in
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty, let separator = line.firstIndex(of: ":") else {
                    return nil
                }
                let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { return nil }
                return ClosedRequestInfoField(key: key, value: value)
            }
    }

    private func localizedRequestType(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstToken = trimmed.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? trimmed
        switch firstToken {
        case "install":
            return "Установка"
        case "dismounting":
            return "Демонтаж"
        case "returnEquip":
            return "Возврат ТО"
        case "serviceStd":
            return "Сервисная"
        case "replacement":
            return "Замена"
        default:
            return trimmed.isEmpty ? "Тип не указан" : trimmed
        }
    }

    private func formattedDate(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Информация отсутствует"
        }

        if let date = parsedDate(trimmed) {
            return Self.dateOutputFormatter.string(from: date)
        }
        return trimmed
    }

    private func nonEmpty(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Информация отсутствует" : trimmed
    }

    private func firstNonEmpty(_ values: [String?]) -> String {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    private func normalizedLabel(_ raw: String) -> String {
        raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    private static let dateParsingFormatters: [DateFormatter] = {
        [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "dd.MM.yyyy HH:mm:ss",
            "dd.MM.yyyy HH:mm",
            "dd.MM.yyyy H:mm",
            "MM.dd.yyyy HH:mm:ss",
            "MM.dd.yyyy HH:mm",
            "MM.dd.yyyy H:mm"
        ].map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            return formatter
        }
    }()

    private static let dateOutputFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter
    }()

    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let dayTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMMM yyyy"
        return formatter
    }()

    private static let dayCaptionFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "EEEE"
        return formatter
    }()
}

private struct ClosedSimpleOneListItem: Identifiable {
    let record: SimpleOneRequestRecord
    let requestType: String
    let closedAtText: String
    let dayKey: String
    let dayTitle: String
    let dayCaption: String

    var id: String {
        record.id
    }
}

private struct ClosedSimpleOneDayGroup: Identifiable {
    let dayKey: String
    let title: String
    let caption: String
    var records: [ClosedSimpleOneListItem]

    var id: String {
        dayKey
    }
}

private struct ClosedSimpleOneDayHeader: View {
    let title: String
    let caption: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(AppTheme.ink)

            if !caption.isEmpty {
                Text(caption.capitalized)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.mutedTint)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }
}

private struct RequestBadge: View {
    let text: String
    let style: RequestBadgeStyle

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .foregroundStyle(style.foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(style.background, in: Capsule())
    }
}

private struct RequestBadgeStyle {
    let background: Color
    let foreground: Color

    static func status(_ raw: String) -> RequestBadgeStyle {
        let value = normalized(raw)
        if value.contains("ожидан") || value.contains("waiting") || value.contains("pending") {
            return RequestBadgeStyle(background: Color(red: 0.95, green: 0.55, blue: 0.11), foreground: Color(red: 0.17, green: 0.11, blue: 0.03))
        }
        if value.contains("работ") || value.contains("progress") || value.contains("active") {
            return RequestBadgeStyle(background: Color(red: 0.04, green: 0.48, blue: 0.19), foreground: .white)
        }
        if value.contains("выполн") || value.contains("закрыт") || value.contains("done") || value.contains("closed") {
            return RequestBadgeStyle(background: Color(red: 0.12, green: 0.43, blue: 0.78), foreground: .white)
        }
        if value.contains("отказ") || value.contains("отклон") || value.contains("cancel") || value.contains("reject") {
            return RequestBadgeStyle(background: Color(red: 0.74, green: 0.20, blue: 0.18), foreground: .white)
        }
        return RequestBadgeStyle(background: AppTheme.mutedTint.opacity(0.22), foreground: AppTheme.ink)
    }

    static func requestType(_ raw: String) -> RequestBadgeStyle {
        let value = normalized(raw)
        if value.contains("установ") || value.contains("install") {
            return RequestBadgeStyle(background: Color(red: 0.14, green: 0.52, blue: 0.34), foreground: .white)
        }
        if value.contains("демонтаж") || value.contains("dismount") {
            return RequestBadgeStyle(background: Color(red: 0.72, green: 0.25, blue: 0.24), foreground: .white)
        }
        if value.contains("возврат") || value.contains("return") {
            return RequestBadgeStyle(background: Color(red: 0.82, green: 0.42, blue: 0.13), foreground: .white)
        }
        if value.contains("сервис") || value.contains("service") {
            return RequestBadgeStyle(background: Color(red: 0.18, green: 0.42, blue: 0.78), foreground: .white)
        }
        if value.contains("замен") || value.contains("replacement") {
            return RequestBadgeStyle(background: Color(red: 0.46, green: 0.32, blue: 0.72), foreground: .white)
        }
        return RequestBadgeStyle(background: Color(red: 0.34, green: 0.38, blue: 0.42), foreground: .white)
    }

    private static func normalized(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }
}
