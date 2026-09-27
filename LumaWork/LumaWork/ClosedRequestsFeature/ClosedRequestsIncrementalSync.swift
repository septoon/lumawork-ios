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
}

nonisolated struct ClosedRequestsSyncContext: Hashable, Sendable {
    var generation: UInt64
    var watermark: ClosedRequestsSyncCursor?
    var knownVersionsBySysID: [String: String]
}

nonisolated extension SimpleOneRequestsService {
    private static let closedSyncPageSize = 20

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
            perPage: Self.closedSyncPageSize
        )
        guard let first = page.items.first else { return nil }
        return try await closedSyncCursor(for: first.sysID, authKey: authKey)
    }

    func fetchClosedSyncChanges(
        userID: String,
        authKey: String,
        scope: ClosedRequestsSyncScope,
        since watermark: ClosedRequestsSyncCursor?,
        knownVersionsBySysID: [String: String]
    ) async throws -> SimpleOneClosedSyncBatch {
        var changesBySysID: [String: SimpleOneClosedSyncChange] = [:]
        var latestTotalCount: Int?
        var latestWatermark = watermark

        for _ in 0 ..< 3 {
            let scan = try await scanClosedSyncChanges(
                userID: userID,
                authKey: authKey,
                scope: scope,
                since: watermark,
                knownVersionsBySysID: knownVersionsBySysID
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
            }

            // An unchanged head needs no second request. A change that arrives after
            // this check is intentionally picked up by the next polling cycle.
            guard !scan.changes.isEmpty, let anchor = scan.anchor else {
                return SimpleOneClosedSyncBatch(
                    userID: userID,
                    scope: scope,
                    changes: sortedClosedSyncChanges(changesBySysID.values),
                    watermark: latestWatermark,
                    totalCount: latestTotalCount
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
                    totalCount: latestTotalCount
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
        knownVersionsBySysID: [String: String]
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

        while true {
            try Task.checkCancellation()
            let page = try await fetchClosedSyncPage(
                userID: userID,
                authKey: authKey,
                scope: scope,
                page: pageNumber,
                perPage: Self.closedSyncPageSize
            )
            totalCount = page.totalCount ?? totalCount
            var reachedWatermark = false

            for item in page.items {
                try Task.checkCancellation()
                guard seenSysIDs.insert(item.sysID).inserted else { continue }
                let cursor = try await closedSyncCursor(for: item.sysID, authKey: authKey)
                if let previousCursor, cursor > previousCursor {
                    throw SimpleOneServiceError.invalidResponse
                }
                previousCursor = cursor
                if anchor == nil {
                    anchor = cursor
                }
                if let watermark, cursor.updatedAt < watermark.updatedAt {
                    reachedWatermark = true
                    break
                }
                if let knownVersion = knownVersionsBySysID[item.sysID],
                   knownVersion >= cursor.updatedAt {
                    continue
                }
                let row = try await completeClosedSyncExportRow(item, authKey: authKey)
                let record = XLSXRequestsParser.record(fromExportRow: row)
                changes.append(SimpleOneClosedSyncChange(
                    sysID: item.sysID,
                    requestNumber: item.requestNumber,
                    cursor: cursor,
                    record: record,
                    excludedFromArchive: record == nil
                ))
            }

            guard !reachedWatermark, page.hasMore else { break }
            pageNumber += 1
        }

        return (changes, anchor, totalCount)
    }

    private func fetchClosedSyncPage(
        userID: String,
        authKey: String,
        scope: ClosedRequestsSyncScope,
        page: Int,
        perPage: Int
    ) async throws -> SimpleOneClosedSyncPage {
        let baseCondition: String
        switch scope {
        case .narrow:
            baseCondition = closedMonthlyCondition(userID: userID)
        case .wide:
            baseCondition = closedSimpleOneCondition(userID: userID)
        }
        let condition = "\(baseCondition)^ORDERBYDESCsys_updated_at^ORDERBYDESCsys_id"
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("list/itsm_request"),
            resolvingAgainstBaseURL: false
        ) else {
            throw SimpleOneServiceError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "condition", value: condition),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: String(perPage))
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
            hasMore: totalCount.map { page * perPage < $0 } ?? (items.count == perPage)
        )
    }

    private func closedSyncListItem(from item: [String: Any]) throws -> SimpleOneClosedSyncListItem {
        let requiredColumns = [
            "number", "short_description", "state", "multicard_request_type",
            "multicard_terminal_address", "multicard_name_client", "multicard_terminal_model",
            "description", "multicard_id_terminal", "multicard_comment_ing",
            "multicard_additional_information", "assigned_user", "multicard_contact_person",
            "multicard_deadline", "pb_sn_pos_install", "pb_sn_pos_uninstall", "multicard_pos",
            "multicard_return_number_pos", "multicard_pin_pad", "multicard_return_number_pin",
            "multicard_closing_date", "resolved_at", "sys_created_at", "new_closure_code",
            "closure_notes"
        ]
        let missingColumns = Set(requiredColumns.filter {
            item[$0] == nil || !Self.closedSyncFieldIsReadable(item[$0])
        })
        let sysID = stringValue(item["sys_id"])
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
            missingColumns: missingColumns
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
                guard let detailRawValue = fieldRawValue(detailItem ?? [:], mapping.key),
                      Self.closedSyncFieldIsReadable(detailRawValue) else {
                    throw SimpleOneServiceError.invalidResponse
                }
                let value: String
                if mapping.key == "state" {
                    value = Self.closedSyncDatabaseValue(detailItem?[mapping.key])
                } else if mapping.display {
                    value = fieldDisplayString(detailItem ?? [:], mapping.key)
                } else {
                    value = fieldString(detailItem ?? [:], mapping.key)
                }
                row[mapping.label] = mapping.date ? Self.closedSyncExportDate(value) : value
            }
        }
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

    private func closedSyncCursor(for sysID: String, authKey: String) async throws -> ClosedRequestsSyncCursor {
        let updatedAt = try await fetchClosedSyncFieldValue(
            column: "sys_updated_at",
            sysID: sysID,
            authKey: authKey
        )
        guard !updatedAt.isEmpty else {
            throw SimpleOneServiceError.invalidResponse
        }
        return ClosedRequestsSyncCursor(updatedAt: updatedAt, sysID: sysID)
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
        knownVersionsBySysID: [String: String]
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
                knownVersionsBySysID: knownVersionsBySysID
            )
        } catch SimpleOneServiceError.unauthorized {
            signOut(clearUsername: false)
            throw SimpleOneServiceError.unauthorized
        }
    }
}

@MainActor
extension ClosedRequestsStore {
    @discardableResult
    func synchronizeFromSimpleOne(
        _ simpleOneStore: SimpleOneRequestsStore,
        scope: ClosedRequestsSyncScope,
        waitsForCurrentSync: Bool = false
    ) async throws -> Int {
        if waitsForCurrentSync {
            try await waitForClosedRequestsSyncAvailability()
        }

        let userID = try await simpleOneStore.closedSyncUserID()
        guard let context = beginClosedRequestsSync(userID: userID, scope: scope) else {
            if waitsForCurrentSync {
                throw SimpleOneServiceError.server(
                    "Не удалось начать обновление закрытых заявок. Повторите попытку."
                )
            }
            return 0
        }

        do {
            let batch = try await simpleOneStore.fetchClosedSyncChanges(
                scope: scope,
                since: context.watermark,
                knownVersionsBySysID: context.knownVersionsBySysID
            )
            let changedCount = batch.changes.lazy.compactMap(\.record).count
            let applied = await applyClosedRequestsSyncBatch(
                batch,
                generation: context.generation
            )
            return applied ? changedCount : 0
        } catch {
            finishClosedRequestsSync(generation: context.generation)
            throw error
        }
    }
}
