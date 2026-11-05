import Foundation

nonisolated enum ClosedRequestsSyncScope: String, Codable, Hashable, Sendable {
    case narrow
    case wide
}

nonisolated struct SimpleOneClosedSyncListItem: Hashable, Sendable {
    var sysID: String
    var requestNumber: String
    var exportRow: [String: String]
    var missingColumns: Set<String>
    var sysUpdatedAt: String? = nil
}

nonisolated struct SimpleOneClosedSyncPage: Hashable, Sendable {
    var items: [SimpleOneClosedSyncListItem]
    var totalCount: Int?
    var hasMore: Bool
}

nonisolated struct SimpleOneClosedSyncChange: Hashable, Sendable {
    var sysID: String
    var requestNumber: String
    var cursor: ClosedRequestsSyncCursor
    var record: ClosedRequestRecord?
    var excludedFromArchive: Bool
}

nonisolated struct SimpleOneClosedSyncBatch: Hashable, Sendable {
    var userID: String
    var scope: ClosedRequestsSyncScope
    var changes: [SimpleOneClosedSyncChange]
    var watermark: ClosedRequestsSyncCursor?
    var totalCount: Int?
    var isComplete = true
    var establishesWideBaseline = true
}

nonisolated struct SimpleOneClosedSyncProgress: Sendable {
    var scannedCount: Int
    var totalCount: Int?
    var changes: [SimpleOneClosedSyncChange]
}

nonisolated struct ClosedRequestsSyncContext: Hashable, Sendable {
    var generation: UInt64
    var watermark: ClosedRequestsSyncCursor?
    var knownVersionsBySysID: [String: String]
}

nonisolated extension SimpleOneRequestsService {
    private static let closedSyncPageSize = 20
    private static let closedSyncConcurrency = 6
    private struct ClosedSyncCompletedRow: Sendable {
        var cursor: ClosedRequestsSyncCursor
        var change: SimpleOneClosedSyncChange?
    }

    func fetchClosedSyncHead(
        userID: String,
        authKey: String,
        scope: ClosedRequestsSyncScope
    ) async throws -> ClosedRequestsSyncCursor? {
        let page = try await fetchClosedSyncPage(
            userID: userID,
            authKey: authKey,
            scope: scope,
            page: 1,
            perPage: 1
        )
        guard let first = page.items.first else { return nil }
        return try await closedSyncCursor(for: first, authKey: authKey)
    }

    func fetchClosedSyncChanges(
        userID: String,
        authKey: String,
        scope: ClosedRequestsSyncScope,
        since watermark: ClosedRequestsSyncCursor?,
        knownVersionsBySysID: [String: String],
        onProgress: @escaping @Sendable (SimpleOneClosedSyncProgress) async throws -> Void = { _ in }
    ) async throws -> SimpleOneClosedSyncBatch {
        var changesBySysID: [String: SimpleOneClosedSyncChange] = [:]
        var latestTotalCount: Int?
        var latestWatermark = watermark
        var scanKnownVersions = knownVersionsBySysID
        if let watermark, Self.closedSyncCanonicalVersion(watermark.updatedAt) == nil {
            throw SimpleOneServiceError.invalidResponse
        }

        for _ in 0 ..< 3 {
            let scan = try await scanClosedSyncChanges(
                userID: userID,
                authKey: authKey,
                scope: scope,
                since: watermark,
                knownVersionsBySysID: scanKnownVersions,
                onProgress: onProgress
            )
            latestTotalCount = scan.totalCount ?? latestTotalCount
            if let anchor = scan.anchor, latestWatermark == nil || latestWatermark! < anchor {
                latestWatermark = anchor
            }
            for change in scan.changes {
                if let current = changesBySysID[change.sysID], current.cursor >= change.cursor {
                    continue
                }
                changesBySysID[change.sysID] = change
                scanKnownVersions[change.sysID] = change.cursor.updatedAt
            }

            // An unchanged head needs no second request. A change that arrives after
            // this check is intentionally picked up by the next polling cycle.
            guard !scan.changes.isEmpty, let anchor = scan.anchor else {
                return SimpleOneClosedSyncBatch(
                    userID: userID,
                    scope: scope,
                    changes: sortedClosedSyncChanges(changesBySysID.values),
                    watermark: latestWatermark,
                    totalCount: latestTotalCount,
                    establishesWideBaseline: watermark == nil
                )
            }

            let currentHead = try await fetchClosedSyncHead(
                userID: userID,
                authKey: authKey,
                scope: scope
            )
            guard let currentHead, currentHead > anchor else {
                return SimpleOneClosedSyncBatch(
                    userID: userID,
                    scope: scope,
                    changes: sortedClosedSyncChanges(changesBySysID.values),
                    watermark: latestWatermark,
                    totalCount: latestTotalCount,
                    establishesWideBaseline: watermark == nil
                )
            }
        }

        // Do not advance a watermark while the head keeps moving. The next cycle
        // safely retries from the previously committed cursor.
        throw SimpleOneServiceError.server("Список закрытых заявок изменяется слишком быстро. Повторите синхронизацию.")
    }

    private func scanClosedSyncChanges(
        userID: String,
        authKey: String,
        scope: ClosedRequestsSyncScope,
        since watermark: ClosedRequestsSyncCursor?,
        knownVersionsBySysID: [String: String],
        onProgress: @escaping @Sendable (SimpleOneClosedSyncProgress) async throws -> Void
    ) async throws -> (
        changes: [SimpleOneClosedSyncChange],
        anchor: ClosedRequestsSyncCursor?,
        totalCount: Int?
    ) {
        var pageNumber = 1
        var changes: [SimpleOneClosedSyncChange] = []
        var seenSysIDs = Set<String>()
        var anchor: ClosedRequestsSyncCursor?
        var previousCursor: ClosedRequestsSyncCursor?
        var totalCount: Int?
        var scannedCount = 0
        // Recent requests become visible after a small page; historical checks
        // amortize list latency over larger pages supported by the same endpoint.
        let perPage = scope == .wide ? 100 : Self.closedSyncPageSize

        while true {
            try Task.checkCancellation()
            let page = try await fetchClosedSyncPage(
                userID: userID,
                authKey: authKey,
                scope: scope,
                page: pageNumber,
                perPage: perPage,
                since: watermark
            )
            totalCount = page.totalCount ?? totalCount
            var reachedWatermark = false
            let firstChangeIndex = changes.count

            let previousCount = seenSysIDs.count
            let items = page.items.filter { seenSysIDs.insert($0.sysID).inserted }
            // Keep a small sliding window, but consume results in server order.
            // Speculative errors after the stopping boundary must not fail the scan.
            try await withThrowingTaskGroup(of: (Int, Result<ClosedSyncCompletedRow, Error>).self) { group in
                var nextToSchedule = 0
                var nextToConsume = 0
                var completed: [Int: Result<ClosedSyncCompletedRow, Error>] = [:]
                func enqueue() {
                    guard nextToSchedule < items.count else { return }
                    let index = nextToSchedule
                    let item = items[index]
                    nextToSchedule += 1
                    group.addTask {
                        do {
                            try Task.checkCancellation()
                            let cursor = try await closedSyncCursor(for: item, authKey: authKey)
                            let needsDetails = (watermark == nil || cursor.updatedAt >= watermark!.updatedAt)
                                && !(knownVersionsBySysID[item.sysID].map { $0 >= cursor.updatedAt } ?? false)
                            var change: SimpleOneClosedSyncChange?
                            if needsDetails {
                                let row = try await completeClosedSyncExportRow(item, authKey: authKey)
                                let record = XLSXRequestsParser.record(fromExportRow: row)
                                change = SimpleOneClosedSyncChange(
                                    sysID: item.sysID, requestNumber: item.requestNumber,
                                    cursor: cursor, record: record, excludedFromArchive: record == nil
                                )
                            }
                            return (index, .success(ClosedSyncCompletedRow(cursor: cursor, change: change)))
                        } catch {
                            return (index, .failure(error))
                        }
                    }
                }
                for _ in 0..<min(Self.closedSyncConcurrency, items.count) { enqueue() }
                defer { group.cancelAll() }
                while let (index, result) = try await group.next() {
                    completed[index] = result
                    while let result = completed.removeValue(forKey: nextToConsume) {
                        try Task.checkCancellation()
                        let row = try result.get()
                        scannedCount += 1
                        let cursor = row.cursor
                        if let previousCursor, cursor > previousCursor {
                            throw SimpleOneServiceError.invalidResponse
                        }
                        previousCursor = cursor
                        if anchor == nil { anchor = cursor }
                        if let watermark, cursor.updatedAt < watermark.updatedAt {
                            reachedWatermark = true
                            return
                        }
                        if let change = row.change { changes.append(change) }
                        nextToConsume += 1
                        enqueue()
                    }
                }
            }
            let hasMore = page.totalCount.map { seenSysIDs.count < $0 } ?? page.hasMore
            if !reachedWatermark, hasMore, seenSysIDs.count == previousCount {
                throw SimpleOneServiceError.invalidResponse
            }
            try await onProgress(SimpleOneClosedSyncProgress(
                scannedCount: scannedCount,
                totalCount: totalCount,
                changes: Array(changes[firstChangeIndex...])
            ))

            guard !reachedWatermark, hasMore else { break }
            pageNumber += 1
        }

        return (changes, anchor, totalCount)
    }

    private func fetchClosedSyncPage(
        userID: String,
        authKey: String,
        scope: ClosedRequestsSyncScope,
        page: Int,
        perPage: Int,
        since watermark: ClosedRequestsSyncCursor? = nil
    ) async throws -> SimpleOneClosedSyncPage {
        let baseCondition: String
        switch scope {
        case .narrow:
            baseCondition = closedMonthlyCondition(userID: userID)
        case .wide:
            baseCondition = closedSimpleOneCondition(userID: userID)
        }
        // Keep the whole same-second cohort: a newly assigned row can have a
        // smaller sys_id than the saved head. Known versions deduplicate it.
        let incrementalCondition = watermark.map { "(\(baseCondition))^sys_updated_at>=\($0.updatedAt)" } ?? baseCondition
        let condition = "\(incrementalCondition)^ORDERBYDESCsys_updated_at^ORDERBYDESCsys_id"
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("list/itsm_request"),
            resolvingAgainstBaseURL: false
        ) else {
            throw SimpleOneServiceError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "condition", value: condition),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: String(perPage)),
            URLQueryItem(name: "columns", value: (["sys_id", "sys_updated_at", "multicard_merchant_tin"] + Self.closedSyncRequiredColumns).joined(separator: ","))
        ]
        guard let url = components.url else {
            throw SimpleOneServiceError.invalidURL
        }

        let response = try await request(url: url, authKey: authKey)
        guard let rawItems = listItems(from: response) else {
            throw SimpleOneServiceError.invalidResponse
        }
        let items = try rawItems.map(closedSyncListItem(from:))
        let totalCount = totalCount(from: response)
        return SimpleOneClosedSyncPage(
            items: items,
            totalCount: totalCount,
            // A server-side cap can be smaller than the requested page size.
            // The scanner uses its accumulated unique count when a total exists;
            // otherwise an empty page is the authoritative end of the list.
            hasMore: !items.isEmpty
        )
    }

    private static let closedSyncRequiredColumns = [
            "number", "short_description", "state", "multicard_request_type",
            "multicard_terminal_address", "multicard_name_client", "multicard_terminal_model",
            "description", "multicard_id_terminal", "multicard_comment_ing",
            "multicard_additional_information", "assigned_user", "multicard_contact_person",
            "multicard_deadline", "pb_sn_pos_install", "pb_sn_pos_uninstall", "multicard_pos",
            "multicard_return_number_pos", "multicard_pin_pad", "multicard_return_number_pin",
            "multicard_closing_date", "resolved_at", "sys_created_at", "new_closure_code",
            "closure_notes"
        ]

    private func closedSyncListItem(from item: [String: Any]) throws -> SimpleOneClosedSyncListItem {
        let missingColumns = Set(Self.closedSyncRequiredColumns.filter {
            item[$0] == nil || !Self.closedSyncFieldIsReadable(item[$0])
        })
        let sysID = fieldString(item, "sys_id")
        let number = fieldString(item, "number")
        guard !sysID.isEmpty, !number.isEmpty else {
            throw SimpleOneServiceError.invalidResponse
        }

        var row: [String: String] = [:]
        let mappings: [(label: String, key: String, display: Bool, date: Bool)] = [
            ("Номер заявки", "number", false, false),
            ("Краткое описание", "short_description", false, false),
            ("Статус", "state", false, false),
            ("Тип заявки", "multicard_request_type", false, false),
            ("Адрес установки терминала", "multicard_terminal_address", false, false),
            ("Заказчик", "multicard_name_client", false, false),
            ("Модель POS-терминала", "multicard_terminal_model", false, false),
            ("Информация", "description", false, false),
            ("ID терминал", "multicard_id_terminal", false, false),
            ("Комментарий инженера", "multicard_comment_ing", false, false),
            ("Доп. информация", "multicard_additional_information", false, false),
            ("Модель терминала", "terminal_model", false, false),
            ("Исполнитель", "assigned_user", true, false),
            ("Kонтактное лицо", "multicard_contact_person", false, false),
            ("Предельный срок СУТС", "multicard_deadline", false, true),
            ("SN POS установка", "pb_sn_pos_install", false, false),
            ("SN POS демонтаж", "pb_sn_pos_uninstall", false, false),
            ("Оборудование POS", "multicard_pos", false, false),
            ("Номер принятого оборудования POS", "multicard_return_number_pos", false, false),
            ("Оборудование Pin Pad", "multicard_pin_pad", false, false),
            ("Номер принятого оборудования PIN", "multicard_return_number_pin", false, false),
            ("Дата закрытия в МК", "multicard_closing_date", false, false),
            ("Время \"Выполнена\"", "resolved_at", false, true),
            ("Время регистрации", "sys_created_at", false, true),
            ("Код закрытия", "new_closure_code", true, false),
            ("Решение", "closure_notes", false, false)
        ]
        for mapping in mappings {
            let value: String
            if mapping.key == "state" {
                value = Self.closedSyncDatabaseValue(item[mapping.key])
            } else {
                value = mapping.display
                    ? fieldDisplayString(item, mapping.key)
                    : fieldString(item, mapping.key)
            }
            row[mapping.label] = mapping.date ? Self.closedSyncExportDate(value) : value
        }
        row["ИНН ТСП"] = fieldString(
            item,
            "multicard_merchant_tin",
            "multicard_tsp_inn",
            "merchant_tin",
            "inn_tsp",
            "ИНН ТСП"
        )
        return SimpleOneClosedSyncListItem(
            sysID: sysID,
            requestNumber: number,
            exportRow: row,
            missingColumns: missingColumns,
            sysUpdatedAt: Self.closedSyncCanonicalVersion(item["sys_updated_at"])
        )
    }

    private func completeClosedSyncExportRow(
        _ item: SimpleOneClosedSyncListItem,
        authKey: String
    ) async throws -> [String: String] {
        var row = item.exportRow
        var detailItem: [String: Any]?
        if !item.missingColumns.isEmpty {
            detailItem = try await fetchClosedSyncDetailItem(sysID: item.sysID, authKey: authKey)
            let fallbackMappings: [(label: String, key: String, display: Bool, date: Bool)] = [
                ("Краткое описание", "short_description", false, false),
                ("Статус", "state", false, false),
                ("Тип заявки", "multicard_request_type", false, false),
                ("Адрес установки терминала", "multicard_terminal_address", false, false),
                ("Заказчик", "multicard_name_client", false, false),
                ("Модель POS-терминала", "multicard_terminal_model", false, false),
                ("Информация", "description", false, false),
                ("ID терминал", "multicard_id_terminal", false, false),
                ("Комментарий инженера", "multicard_comment_ing", false, false),
                ("Доп. информация", "multicard_additional_information", false, false),
                ("Исполнитель", "assigned_user", true, false),
                ("Kонтактное лицо", "multicard_contact_person", false, false),
                ("Предельный срок СУТС", "multicard_deadline", false, true),
                ("SN POS установка", "pb_sn_pos_install", false, false),
                ("SN POS демонтаж", "pb_sn_pos_uninstall", false, false),
                ("Оборудование POS", "multicard_pos", false, false),
                ("Номер принятого оборудования POS", "multicard_return_number_pos", false, false),
                ("Оборудование Pin Pad", "multicard_pin_pad", false, false),
                ("Номер принятого оборудования PIN", "multicard_return_number_pin", false, false),
                ("Дата закрытия в МК", "multicard_closing_date", false, false),
                ("Время \"Выполнена\"", "resolved_at", false, true),
                ("Время регистрации", "sys_created_at", false, true),
                ("Код закрытия", "new_closure_code", true, false),
                ("Решение", "closure_notes", false, false)
            ]
            for mapping in fallbackMappings where item.missingColumns.contains(mapping.key) {
                let detailRawValue = fieldRawValue(detailItem ?? [:], mapping.key)
                let value: String
                if !Self.closedSyncFieldIsReadable(detailRawValue) {
                    // Some readable list cells are absent even from the record form.
                    value = try await fetchClosedSyncFieldValue(column: mapping.key, sysID: item.sysID, authKey: authKey)
                } else if mapping.key == "state" {
                    value = Self.closedSyncDatabaseValue(detailItem?[mapping.key])
                } else if mapping.display {
                    value = fieldDisplayString(detailItem ?? [:], mapping.key)
                } else {
                    value = fieldString(detailItem ?? [:], mapping.key)
                }
                row[mapping.label] = mapping.date ? Self.closedSyncExportDate(value) : value
            }
        }
        row["ИНН ТСП"] = ClosedRequestsMerchantTINSupport.resolvedTIN(
            directTIN: row["ИНН ТСП"] ?? "", information: row["Информация"] ?? ""
        )
        if ClosedRequestsMerchantTINSupport.needsRepair(row["ИНН ТСП"]) {
            if detailItem == nil {
                detailItem = try await fetchClosedSyncDetailItem(sysID: item.sysID, authKey: authKey)
            }
            let detailInformation = fieldString(detailItem ?? [:], "description")
            let directTIN = fieldString(
                detailItem ?? [:],
                "multicard_merchant_tin",
                "multicard_tsp_inn",
                "merchant_tin",
                "inn_tsp",
                "ИНН ТСП"
            )
            row["ИНН ТСП"] = ClosedRequestsMerchantTINSupport.resolvedTIN(
                directTIN: directTIN,
                information: detailInformation
            )
            if !detailInformation.isEmpty {
                row["Информация"] = detailInformation
            }
        }
        let textColumns = [
            (label: "Информация", key: "description"),
            (label: "Комментарий инженера", key: "multicard_comment_ing"),
            (label: "Доп. информация", key: "multicard_additional_information"),
            (label: "Решение", key: "closure_notes")
        ]
        for column in textColumns {
            let value = row[column.label] ?? ""
            guard Self.closedSyncValueMayBeTruncated(value) else { continue }
            do {
                row[column.label] = try await fetchClosedSyncFieldValue(
                    column: column.key,
                    sysID: item.sysID,
                    authKey: authKey
                )
            } catch {
                if detailItem == nil {
                    detailItem = try await fetchClosedSyncDetailItem(sysID: item.sysID, authKey: authKey)
                }
                let detailValue = fieldString(detailItem ?? [:], column.key)
                guard !detailValue.isEmpty || value.isEmpty else { throw error }
                row[column.label] = detailValue
            }
        }
        return row
    }

    private func fetchClosedSyncDetailItem(sysID: String, authKey: String) async throws -> [String: Any] {
        guard var components = URLComponents(
            url: baseURL
                .appendingPathComponent("record")
                .appendingPathComponent("itsm_request")
                .appendingPathComponent(sysID),
            resolvingAgainstBaseURL: false
        ) else {
            throw SimpleOneServiceError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "open_first_rel_list", value: "0")]
        guard let url = components.url else { throw SimpleOneServiceError.invalidURL }
        let response = try await request(url: url, authKey: authKey)
        guard let item = recordItem(from: response) else {
            throw SimpleOneServiceError.invalidResponse
        }
        var flattened = flattenedRecordItem(from: item)
        for section in item["sections"] as? [[String: Any]] ?? [] {
            for element in section["elements"] as? [[String: Any]] ?? []
            where element["read_access"] as? Bool == false {
                for keyName in ["sys_column_name", "system_name", "name"] {
                    guard let key = element[keyName] as? String, !key.isEmpty else { continue }
                    flattened[key] = ["read_access": false]
                }
            }
        }
        return flattened
    }

    private func closedSyncCursor(for item: SimpleOneClosedSyncListItem, authKey: String) async throws -> ClosedRequestsSyncCursor {
        if let updatedAt = item.sysUpdatedAt {
            return ClosedRequestsSyncCursor(updatedAt: updatedAt, sysID: item.sysID)
        }
        let updatedAt = try await fetchClosedSyncFieldValue(
            column: "sys_updated_at",
            sysID: item.sysID,
            authKey: authKey
        )
        guard !updatedAt.isEmpty else {
            throw SimpleOneServiceError.invalidResponse
        }
        return ClosedRequestsSyncCursor(updatedAt: updatedAt, sysID: item.sysID)
    }

    private static func closedSyncCanonicalVersion(_ raw: Any?) -> String? {
        guard closedSyncFieldIsReadable(raw) else { return nil }
        let value = closedSyncDatabaseValue(raw)
        // Localized/display-only timestamps must use the authoritative cell endpoint.
        guard value.count == 19,
              value.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$"#, options: .regularExpression) != nil else { return nil }
        return value
    }

    private func fetchClosedSyncFieldValue(
        column: String,
        sysID: String,
        authKey: String
    ) async throws -> String {
        let url = baseURL
            .appendingPathComponent("list-cell-value")
            .appendingPathComponent("itsm_request")
            .appendingPathComponent(column)
            .appendingPathComponent(sysID)
        let response = try await request(url: url, authKey: authKey)
        guard let data = response["data"] as? [String: Any],
              data["read_access"] as? Bool != false,
              let rawValue = data["value"] else {
            throw SimpleOneServiceError.invalidResponse
        }
        return fieldValueString(rawValue)
    }

    private func closedMonthlyCondition(userID: String) -> String {
        guard let firstOptionID = AppConfig.resolveFirst("SIMPLEONE_CLOSED_MONTH_FIRST_OPTION_ID"),
              let secondOptionID = AppConfig.resolveFirst("SIMPLEONE_CLOSED_MONTH_SECOND_OPTION_ID") else {
            return "sys_idISEMPTY^sys_idISNOTEMPTY"
        }
        return "((multicard_engineer=\(userID)^ORassigned_user=\(userID)^ORengineer_schedule.employee=\(userID))^(resolved_atONopt:\(firstOptionID)^ORresolved_atONopt:\(secondOptionID)))"
    }

    private static func closedSyncValueMayBeTruncated(_ value: String) -> Bool {
        value.count >= 500 || (value.count >= 497 && value.hasSuffix("..."))
    }

    private static func closedSyncDatabaseValue(_ raw: Any?) -> String {
        guard let raw else { return "" }
        if let dictionary = raw as? [String: Any] {
            let databaseValue = stringValue(dictionary["database_value"])
            if !databaseValue.isEmpty {
                return databaseValue
            }
            if let value = dictionary["value"] {
                return closedSyncDatabaseValue(value)
            }
        }
        return fieldValueString(raw)
    }

    private static func closedSyncFieldIsReadable(_ raw: Any?) -> Bool {
        guard let raw else { return false }
        guard let dictionary = raw as? [String: Any] else { return true }
        if dictionary["read_access"] as? Bool == false {
            return false
        }
        if let value = dictionary["value"] {
            return closedSyncFieldIsReadable(value)
        }
        return true
    }

    private static func closedSyncExportDate(_ raw: String) -> String {
        let sourceFormatter = DateFormatter()
        sourceFormatter.locale = Locale(identifier: "en_US_POSIX")
        sourceFormatter.calendar = Calendar(identifier: .gregorian)
        sourceFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        sourceFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard !raw.isEmpty, let date = sourceFormatter.date(from: raw) else {
            return raw
        }
        let exportFormatter = DateFormatter()
        exportFormatter.locale = Locale(identifier: "en_US_POSIX")
        exportFormatter.calendar = Calendar(identifier: .gregorian)
        exportFormatter.timeZone = TimeZone(secondsFromGMT: 3 * 60 * 60)
        exportFormatter.dateFormat = "dd.MM.yyyy HH:mm:ss"
        return exportFormatter.string(from: date)
    }

    private func sortedClosedSyncChanges<S: Sequence>(_ changes: S) -> [SimpleOneClosedSyncChange]
    where S.Element == SimpleOneClosedSyncChange {
        changes.sorted { lhs, rhs in lhs.cursor > rhs.cursor }
    }

}

@MainActor
extension SimpleOneRequestsStore {
    func closedSyncUserID() async throws -> String {
        guard let authKey = browserAuthKey else {
            throw SimpleOneServiceError.missingCredentials
        }
        do {
            if currentUser == nil {
                currentUser = try await service.fetchCurrentUser(authKey: authKey)
            }
            guard let userID = currentUser?.sysID, !userID.isEmpty else {
                throw SimpleOneServiceError.invalidResponse
            }
            return userID
        } catch SimpleOneServiceError.unauthorized {
            signOut(clearUsername: false)
            throw SimpleOneServiceError.unauthorized
        }
    }

    func fetchClosedSyncHead(scope: ClosedRequestsSyncScope) async throws -> (userID: String, cursor: ClosedRequestsSyncCursor?) {
        let userID = try await closedSyncUserID()
        guard let authKey = browserAuthKey else {
            throw SimpleOneServiceError.missingCredentials
        }
        do {
            return (
                userID,
                try await service.fetchClosedSyncHead(userID: userID, authKey: authKey, scope: scope)
            )
        } catch SimpleOneServiceError.unauthorized {
            signOut(clearUsername: false)
            throw SimpleOneServiceError.unauthorized
        }
    }

    func fetchClosedSyncChanges(
        scope: ClosedRequestsSyncScope,
        since watermark: ClosedRequestsSyncCursor?,
        knownVersionsBySysID: [String: String],
        onProgress: @escaping @Sendable (SimpleOneClosedSyncProgress) async throws -> Void = { _ in }
    ) async throws -> SimpleOneClosedSyncBatch {
        let userID = try await closedSyncUserID()
        guard let authKey = browserAuthKey else {
            throw SimpleOneServiceError.missingCredentials
        }
        do {
            return try await service.fetchClosedSyncChanges(
                userID: userID,
                authKey: authKey,
                scope: scope,
                since: watermark,
                knownVersionsBySysID: knownVersionsBySysID,
                onProgress: onProgress
            )
        } catch SimpleOneServiceError.unauthorized {
            signOut(clearUsername: false)
            throw SimpleOneServiceError.unauthorized
        }
    }
}
