import Foundation

struct SimpleOneExportedFile: Sendable {
    let data: Data
    let fileName: String
}

nonisolated extension SimpleOneRequestsService {
    static let closedRequestsExportColumns = [
        "number",
        "short_description",
        "state",
        "multicard_request_type",
        "multicard_terminal_address",
        "multicard_name_client",
        "multicard_terminal_model",
        "description",
        "multicard_id_terminal",
        "multicard_comment_ing",
        "multicard_additional_information",
        "assigned_user",
        "multicard_contact_person",
        "multicard_deadline",
        "pb_sn_pos_install",
        "pb_sn_pos_uninstall",
        "multicard_pos",
        "multicard_return_number_pos",
        "multicard_pin_pad",
        "multicard_return_number_pin",
        "multicard_closing_date",
        "resolved_at",
        "sys_created_at",
        "new_closure_code",
        "closure_notes"
    ]
    static let timeReportExportColumns = [
        "sys_id",
        "acticvity",
        "month",
        "sys_created_at",
        "date_of_work",
        "time_of_work_hours",
        "time_of_work_minutes",
        "time_of_work",
        "extracurricular_activities_hours",
        "travel_time_hours",
        "travel_time_minutes",
        "travel_time",
        "extracurricular_time",
        "extracurricular_work",
        "result",
        "person"
    ]

    func exportClosedRequestsXLSX(
        userID: String,
        authKey: String
    ) async throws -> SimpleOneExportedFile {
        let condition = closedRequestsExportCondition(userID: userID)
        let payload: [String: Any] = [
            "export": [
                "condition": condition,
                "type": "excel",
                "tableName": "itsm_request",
                "columns": Self.closedRequestsExportColumns
            ],
            "confirmExportLimitExceeded": false,
            "userId": userID
        ]
        return try await createAndDownloadExport(
            payload: payload,
            userID: userID,
            authKey: authKey,
            defaultFileName: "itsm_request.xlsx",
            timeoutMessage: "SimpleOne не подготовил XLSX-выгрузку."
        )
    }

    func exportTimeReportXLSX(userID: String, authKey: String) async throws -> SimpleOneExportedFile {
        let payload: [String: Any] = [
            "export": [
                "condition": timeReportCondition(),
                "type": "excel",
                "tableName": "itsm_tchnsrv_time_report",
                "columns": Self.timeReportExportColumns
            ],
            "confirmExportLimitExceeded": false,
            "userId": userID
        ]
        return try await createAndDownloadExport(
            payload: payload,
            userID: userID,
            authKey: authKey,
            defaultFileName: "itsm_tchnsrv_time_report.xlsx",
            timeoutMessage: "SimpleOne не подготовил XLSX-выгрузку трудозатрат."
        )
    }

    private func createAndDownloadExport(
        payload: [String: Any],
        userID: String,
        authKey: String,
        defaultFileName: String,
        timeoutMessage: String
    ) async throws -> SimpleOneExportedFile {
        let existingExportIDs: Set<String>?
        do {
            existingExportIDs = Set(try await availableExportIDs(userID: userID, authKey: authKey))
        } catch SimpleOneServiceError.server {
            existingExportIDs = nil
        }

        var currentExportIDs: [String] = []
        do {
            let createResponse = try await exportRequest(
                path: "/exports",
                method: "POST",
                body: payload,
                authKey: authKey
            )
            currentExportIDs = exportIDs(from: createResponse).filter { exportID in
                existingExportIDs?.contains(exportID) != true
            }
        } catch SimpleOneServiceError.server {
            guard existingExportIDs != nil else {
                throw SimpleOneServiceError.server(timeoutMessage)
            }
        }

        for attempt in 0 ..< 120 {
            if currentExportIDs.isEmpty, let existingExportIDs {
                do {
                    currentExportIDs = try await availableExportIDs(userID: userID, authKey: authKey)
                        .filter { !existingExportIDs.contains($0) }
                } catch SimpleOneServiceError.server {
                    currentExportIDs = []
                }
            }

            if !currentExportIDs.isEmpty,
               let downloadURL = try await downloadURL(
                   exportIDs: currentExportIDs,
                   userID: userID,
                   authKey: authKey
               ) {
                let data = try await downloadFileData(from: downloadURL)
                return SimpleOneExportedFile(
                    data: data,
                    fileName: fileName(from: downloadURL) ?? defaultFileName
                )
            }

            try await Task.sleep(nanoseconds: UInt64(attempt < 8 ? 500_000_000 : 1_000_000_000))
        }

        throw SimpleOneServiceError.server(timeoutMessage)
    }

    private func fetchExports(userID: String, authKey: String) async throws -> [String: Any] {
        guard var components = URLComponents(url: baseURL.appendingPathComponent("exports"), resolvingAgainstBaseURL: false) else {
            throw SimpleOneServiceError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "userId", value: userID)]
        guard let url = components.url else {
            throw SimpleOneServiceError.invalidURL
        }
        return try await exportRequest(url: url, authKey: authKey)
    }

    private func availableExportIDs(userID: String, authKey: String) async throws -> [String] {
        exportIDs(from: try await fetchExports(userID: userID, authKey: authKey))
    }

    private func downloadURL(
        exportIDs: [String],
        userID: String,
        authKey: String
    ) async throws -> URL? {
        var lastError: Error?
        for exportID in exportIDs {
            try Task.checkCancellation()
            do {
                let response = try await exportRequest(
                    path: "/exports/download-url",
                    method: "POST",
                    body: [
                        "sysIds": [exportID],
                        "userId": userID
                    ],
                    authKey: authKey
                )
                if let url = downloadURLs(from: response).first {
                    return url
                }
            } catch SimpleOneServiceError.server {
                continue
            } catch {
                if AppErrorPresentation.isCancellation(error) {
                    throw CancellationError()
                }
                lastError = error
            }
        }

        if let lastError {
            throw lastError
        }
        return nil
    }

    private func downloadFileData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 45
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SimpleOneServiceError.invalidResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode), !data.isEmpty else {
            throw SimpleOneServiceError.server("Не удалось скачать XLSX: HTTP \(httpResponse.statusCode).")
        }
        return data
    }

    private func exportRequest(
        path: String,
        method: String = "GET",
        body: Any? = nil,
        authKey: String
    ) async throws -> [String: Any] {
        try await exportRequest(
            url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
            method: method,
            body: body,
            authKey: authKey
        )
    }

    private func exportRequest(
        url: URL,
        method: String = "GET",
        body: Any? = nil,
        authKey: String
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 45
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        request.setValue("true", forHTTPHeaderField: "Access-Control-Allow-Credentials")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        if let webOrigin = AppConfig().simpleOneWebOrigin {
            request.setValue(webOrigin, forHTTPHeaderField: "Origin")
            request.setValue(
                AppConfig.configuredURL(webOrigin)
                    .appendingPathComponent("list/itsm_request")
                    .absoluteString,
                forHTTPHeaderField: "Referer"
            )
        }
        request.setValue("auth=\(authKey)", forHTTPHeaderField: "Cookie")
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
            throw SimpleOneServiceError.server(exportHTTPError(statusCode: httpResponse.statusCode, data: data))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SimpleOneServiceError.invalidResponse
        }
        if let error = serverError(from: json) {
            throw error
        }
        return json
    }

    private func exportHTTPError(statusCode: Int, data: Data) -> String {
        let fallback = "SimpleOne вернул HTTP \(statusCode)."
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return fallback
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = serverError(from: json) {
            return error.errorDescription ?? fallback
        }
        return "\(fallback) \(String(text.prefix(180)))"
    }

    private func closedRequestsExportCondition(userID: String) -> String {
        closedSimpleOneCondition(userID: userID)
    }

    private func exportIDs(from response: [String: Any]) -> [String] {
        var ids: [String] = []
        appendExportIDs(from: response["data"], to: &ids)
        appendExportIDs(from: response, to: &ids)
        return uniqueNonEmpty(ids)
    }

    private func appendExportIDs(from raw: Any?, to ids: inout [String]) {
        switch raw {
        case let dictionary as [String: Any]:
            for key in ["sys_id", "sysId", "id"] {
                let value = stringValue(dictionary[key])
                if !value.isEmpty {
                    ids.append(value)
                }
            }
            for key in ["items", "list", "records", "exports"] {
                appendExportIDs(from: dictionary[key], to: &ids)
            }
        case let array as [Any]:
            for item in array {
                appendExportIDs(from: item, to: &ids)
            }
        default:
            break
        }
    }

    private func downloadURLs(from response: [String: Any]) -> [URL] {
        guard let data = response["data"] as? [String: Any],
              let rawURLs = data["downloadUrls"] as? [Any] else {
            return []
        }
        return rawURLs
            .compactMap { stringValue($0) }
            .compactMap(URL.init(string:))
    }

    private func fileName(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let disposition = components.queryItems?
            .first { $0.name == "response-content-disposition" }?
            .value ?? ""
        let marker = "filename=\""
        guard let markerRange = disposition.range(of: marker) else {
            return url.lastPathComponent.isEmpty ? nil : url.lastPathComponent
        }
        let suffix = disposition[markerRange.upperBound...]
        guard let endIndex = suffix.firstIndex(of: "\"") else {
            return nil
        }
        return String(suffix[..<endIndex])
    }

    private func uniqueNonEmpty(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            return seen.insert(trimmed).inserted
        }
    }
}
