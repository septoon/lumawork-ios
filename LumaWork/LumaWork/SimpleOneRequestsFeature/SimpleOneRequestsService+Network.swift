import Foundation

nonisolated extension SimpleOneRequestsService {
    func fetchRequests(
        condition: String,
        source: SimpleOneRequestSource,
        authKey: String,
        page: Int? = nil,
        perPage: Int? = nil,
        columns: [String] = []
    ) async throws -> [SimpleOneRequestRecord] {
        try await fetchRequestsPage(
            condition: condition,
            source: source,
            authKey: authKey,
            page: page,
            perPage: perPage,
            columns: columns
        ).records
    }

    func fetchRequestsPage(
        condition: String,
        source: SimpleOneRequestSource,
        authKey: String,
        page: Int? = nil,
        perPage: Int? = nil,
        columns: [String] = []
    ) async throws -> SimpleOnePagedRequestRecords {
        guard var components = URLComponents(url: baseURL.appendingPathComponent("list/itsm_request"), resolvingAgainstBaseURL: false) else {
            throw SimpleOneServiceError.invalidURL
        }
        var queryItems = [
            URLQueryItem(name: "condition", value: condition)
        ]
        if let page {
            queryItems.append(URLQueryItem(name: "page", value: String(page)))
        }
        if let perPage {
            queryItems.append(URLQueryItem(name: "per_page", value: String(perPage)))
        }
        if !columns.isEmpty {
            queryItems.append(URLQueryItem(name: "columns", value: columns.joined(separator: ",")))
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw SimpleOneServiceError.invalidURL
        }

        let response = try await request(url: url, authKey: authKey)
        guard let items = listItems(from: response) else {
            throw serverError(from: response) ?? SimpleOneServiceError.invalidResponse
        }

        let records = items
            .map { makeRequestRecord(from: $0, source: source) }
            .filter { !$0.number.isEmpty }
            .sorted { lhs, rhs in
                lhs.primaryDate.localizedStandardCompare(rhs.primaryDate) == .orderedDescending
            }
        let totalCount = totalCount(from: response)
        let hasMore = totalCount.map { total in
            if let page, let perPage {
                return page * perPage < total
            }
            return false
        } ?? (perPage.map { records.count == $0 } ?? false)

        return SimpleOnePagedRequestRecords(
            records: records,
            totalCount: totalCount,
            hasMore: hasMore
        )
    }

    func fetchAllRequests(
        condition: String,
        source: SimpleOneRequestSource,
        authKey: String,
        perPage: Int = 100,
        columns: [String] = [],
        onProgress: @escaping @Sendable (Int) -> Void = { _ in }
    ) async throws -> [SimpleOneRequestRecord] {
        var page = 1
        var orderedRecords: [SimpleOneRequestRecord] = []
        var seenIDs = Set<String>()

        while true {
            let pageRecords = try await fetchRequests(
                condition: condition,
                source: source,
                authKey: authKey,
                page: page,
                perPage: perPage,
                columns: columns
            )
            let previousCount = orderedRecords.count
            for record in pageRecords {
                let id = record.id.trimmingCharacters(in: .whitespacesAndNewlines)
                guard id.isEmpty || seenIDs.insert(id).inserted else {
                    continue
                }
                orderedRecords.append(record)
            }
            onProgress(orderedRecords.count)

            guard pageRecords.count == perPage, orderedRecords.count > previousCount else {
                break
            }

            page += 1
        }

        return orderedRecords.sorted { lhs, rhs in
            lhs.primaryDate.localizedStandardCompare(rhs.primaryDate) == .orderedDescending
        }
    }

    func fetchAllTimeReportItems(
        condition: String,
        authKey: String,
        perPage: Int = 100,
        columns: [String] = [],
        onProgress: @escaping @Sendable (Int) -> Void = { _ in }
    ) async throws -> [[String: Any]] {
        var page = 1
        var orderedItems: [[String: Any]] = []
        var seenIDs = Set<String>()

        while true {
            let pageResult = try await fetchTimeReportItemsPage(
                condition: condition,
                authKey: authKey,
                page: page,
                perPage: perPage,
                columns: columns
            )
            let previousCount = orderedItems.count
            for item in pageResult.items {
                let id = fieldString(item, "sys_id", "id")
                guard id.isEmpty || seenIDs.insert(id).inserted else {
                    continue
                }
                orderedItems.append(item)
            }
            onProgress(orderedItems.count)

            guard pageResult.hasMore, orderedItems.count > previousCount else {
                break
            }

            page += 1
        }

        return orderedItems
    }

    func fetchTimeReportItemsPage(
        condition: String,
        authKey: String,
        page: Int,
        perPage: Int,
        columns: [String] = []
    ) async throws -> (items: [[String: Any]], hasMore: Bool) {
        guard var components = URLComponents(url: baseURL.appendingPathComponent("list/itsm_tchnsrv_time_report"), resolvingAgainstBaseURL: false) else {
            throw SimpleOneServiceError.invalidURL
        }
        var queryItems = [
            URLQueryItem(name: "condition", value: condition),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: String(perPage))
        ]
        if !columns.isEmpty {
            queryItems.append(URLQueryItem(name: "columns", value: columns.joined(separator: ",")))
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw SimpleOneServiceError.invalidURL
        }

        let response = try await request(url: url, authKey: authKey)
        guard let items = listItems(from: response) else {
            throw serverError(from: response) ?? SimpleOneServiceError.invalidResponse
        }

        let hasMore = totalCount(from: response).map { page * perPage < $0 } ?? (items.count == perPage)
        return (items, hasMore)
    }

    func listItems(from response: [String: Any]) -> [[String: Any]]? {
        if let data = response["data"] as? [String: Any] {
            for key in ["items", "list", "records"] {
                if let items = data[key] as? [[String: Any]] {
                    return items
                }
            }
            if let item = data["item"] as? [String: Any] {
                return [item]
            }
        }
        for key in ["items", "list", "records"] {
            if let items = response[key] as? [[String: Any]] {
                return items
            }
        }
        return nil
    }

    func totalCount(from response: [String: Any]) -> Int? {
        let data = response["data"] as? [String: Any]
        let meta = response["meta"] as? [String: Any]
        let pagination = response["pagination"] as? [String: Any]
        let dataPagination = data?["pagination"] as? [String: Any]
        let dataMeta = data?["meta"] as? [String: Any]
        let containers = [response, data, meta, pagination, dataPagination, dataMeta].compactMap { $0 }

        for container in containers {
            for key in ["total", "total_count", "totalCount", "records_total", "recordsTotal"] {
                if let value = intValue(container[key]) {
                    return value
                }
            }
        }
        return nil
    }

    func intValue(_ raw: Any?) -> Int? {
        switch raw {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        case let value as Double:
            return Int(value)
        default:
            return nil
        }
    }

    func request(
        path: String,
        method: String = "GET",
        body: Any? = nil,
        authKey: String? = nil
    ) async throws -> [String: Any] {
        try await request(url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))), method: method, body: body, authKey: authKey)
    }

    func request(
        url: URL,
        method: String = "GET",
        body: Any? = nil,
        authKey: String? = nil
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 25
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if let authKey {
            request.setValue("auth=\(authKey)", forHTTPHeaderField: "Cookie")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SimpleOneServiceError.invalidResponse
        }
        guard httpResponse.statusCode != 401 else {
            throw SimpleOneServiceError.unauthorized
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw SimpleOneServiceError.server("SimpleOne вернул HTTP \(httpResponse.statusCode).")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SimpleOneServiceError.invalidResponse
        }
        if let error = serverError(from: json) {
            throw error
        }
        return json
    }

    func updateRequest(
        sysID: String,
        authKey: String,
        fields: [String: Any]
    ) async throws {
        let attempts: [(method: String, body: [String: Any])] = [
            ("PATCH", ["data": fields]),
            ("PUT", ["data": fields]),
            ("PATCH", fields),
            ("PUT", fields)
        ]
        var lastError: Error?

        for attempt in attempts {
            try Task.checkCancellation()
            do {
                try await sendUpdateRequest(
                    sysID: sysID,
                    method: attempt.method,
                    body: attempt.body,
                    authKey: authKey
                )
                return
            } catch {
                if AppErrorPresentation.isCancellation(error) {
                    throw CancellationError()
                }
                lastError = error
            }
        }

        throw lastError ?? SimpleOneServiceError.invalidResponse
    }

    func sendUpdateRequest(
        sysID: String,
        method: String,
        body: [String: Any],
        authKey: String
    ) async throws {
        let url = baseURL
            .appendingPathComponent("record")
            .appendingPathComponent("itsm_request")
            .appendingPathComponent(sysID)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 35
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("auth=\(authKey)", forHTTPHeaderField: "Cookie")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SimpleOneServiceError.invalidResponse
        }
        guard httpResponse.statusCode != 401 else {
            throw SimpleOneServiceError.unauthorized
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw SimpleOneServiceError.server("SimpleOne вернул HTTP \(httpResponse.statusCode).")
        }
        guard !data.isEmpty else { return }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        if let error = serverError(from: json) {
            throw error
        }
    }
}
