import Foundation
import CoreLocation
import OSLog

enum RouteMoveDirection {
    case up
    case down
}

enum RouteDayServiceError: LocalizedError {
    case unauthorized
    case notFound
    case infrastructure(String)
    case http(status: Int, message: String?)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Требуется авторизация."
        case .notFound:
            return "Эндпоинт маршрутов не найден."
        case .infrastructure(let message):
            return message
        case .http(let status, let message):
            if let message, !message.isEmpty {
                return message
            }
            return "Запрос не выполнен: HTTP \(status)"
        case .invalidResponse(let message):
            return message
        }
    }

    var shouldQueue: Bool {
        switch self {
        case .infrastructure:
            return true
        case .http(let status, _):
            return [0, 502, 503, 504].contains(status)
        case .unauthorized, .notFound, .invalidResponse:
            return false
        }
    }
}

struct RouteDayService {
    private let config: AppConfig
    private let authToken: String?

    init(config: AppConfig, authToken: String? = nil) {
        self.config = config
        self.authToken = authToken
    }

    func sendDay(_ record: RouteDayRecord, date: String) async throws {
        guard let authToken, let url = v2RoutesURL() else {
            throw RouteDayServiceError.unauthorized
        }
        let payload = buildSendPayload(record: record, date: date)
        do {
            _ = try await requestJSON(
                url,
                method: "POST",
                body: payload,
                acceptedStatuses: Set(200 ..< 300).union([204]),
                authToken: authToken
            )
        } catch let submissionError as RouteDayServiceError where submissionError.shouldQueue {
            // The write may have succeeded even if its response was lost.
            guard let checkURL = v2RoutesURL(from: date, to: date, workType: record.workType) else {
                throw submissionError
            }
            do {
                let response = try await requestJSON(checkURL, authToken: authToken)
                guard let remote = extractDay(from: response.json, date: date, workType: record.workType),
                      submittedDayMatches(remote, payload: payload) else {
                    throw submissionError
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw submissionError
            }
        }
    }

    private func submittedDayMatches(_ remote: [String: Any], payload: [String: Any]) -> Bool {
        guard stringValue(remote["date"]) == stringValue(payload["date"]),
              remoteWorkType(remote).rawValue == stringValue(payload["workType"]),
              intValue(remote["distanceKm"]) == intValue(payload["distanceKm"]),
              intValue(remote["periodStartOdometer"]) == intValue(payload["periodStartOdometer"]),
              let remoteStops = remote["stops"] as? [[String: Any]],
              let submittedStops = payload["stops"] as? [[String: Any]],
              remoteStops.count == submittedStops.count else { return false }
        return zip(remoteStops, submittedStops).allSatisfy { remote, submitted in
            guard var actual = normalizeRemoteStop(remote),
                  let expected = normalizeRemoteStop(submitted) else { return false }
            // Server stop IDs differ from the local draft IDs.
            actual.id = expected.id
            return actual == expected
        }
    }

    func fetchDay(
        date: String,
        workType: RouteWorkType,
        settings: RouteSettings
    ) async throws -> RouteDayRecord? {
        guard let authToken, let url = v2RoutesURL(from: date, to: date, workType: workType) else {
            throw RouteDayServiceError.unauthorized
        }
        let response = try await requestJSON(
            url,
            acceptedStatuses: Set(200 ..< 300).union([304]),
            authToken: authToken
        )
        return normalizeRemoteDay(
            extractDay(from: response.json, date: date, workType: workType),
            date: date,
            fallbackWorkType: workType,
            settings: settings
        )
    }

    func fetchAllDays(settings: RouteSettings) async throws -> [RouteDayRecord] {
        guard let authToken, let url = v2RoutesURL() else {
            throw RouteDayServiceError.unauthorized
        }
        let response = try await requestJSON(
            url,
            acceptedStatuses: Set(200 ..< 300).union([304]),
            authToken: authToken
        )
        return normalizeRemoteDays(from: response.json, settings: settings)
            .sorted { $0.date < $1.date }
    }

    func fetchOfficeAddresses() async throws -> [String] {
        guard let authToken, let url = v2OfficesURL() else {
            throw RouteDayServiceError.unauthorized
        }
        let response = try await requestJSON(
            url,
            acceptedStatuses: Set(200 ..< 300).union([304]),
            authToken: authToken
        )
        guard let dictionary = response.json as? [String: Any],
              let offices = dictionary["offices"] as? [Any] else {
            throw RouteDayServiceError.invalidResponse("Сервер вернул неизвестный список отделений.")
        }
        return offices
            .compactMap { ($0 as? [String: Any])?["address"] as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .uniqued()
    }

    private func buildSendPayload(record: RouteDayRecord, date: String) -> [String: Any] {
        [
            "date": date,
            "workType": record.workType.rawValue,
            "distanceKm": record.distanceKm as Any,
            "periodStartOdometer": record.periodStartOdometer as Any,
            "sent": record.sent,
            "stops": record.stops.map { stop in
                [
                    "id": stop.id,
                    "address": stop.address.trimmingCharacters(in: .whitespacesAndNewlines),
                    "org": stop.org.trimmingCharacters(in: .whitespacesAndNewlines),
                    "tid": stop.tid.trimmingCharacters(in: .whitespacesAndNewlines),
                    "reason": stop.reason.trimmingCharacters(in: .whitespacesAndNewlines),
                    "status": statusLabel(for: stop.status),
                    "rejectReason": stop.declineReason.trimmingCharacters(in: .whitespacesAndNewlines),
                    "requestNumber": stop.requestNumber.trimmingCharacters(in: .whitespacesAndNewlines),
                    "coordinateOverride": stop.coordinateOverride.map {
                        ["latitude": $0.latitude, "longitude": $0.longitude] as Any
                    } ?? NSNull()
                ]
            }
        ]
    }

    private func statusLabel(for status: RouteStopStatus) -> String {
        switch status {
        case .done:
            return "Выполнена"
        case .declined:
            return "Отказ"
        case .pending:
            return "В процессе"
        }
    }

    private func extractDay(
        from payload: Any?,
        date: String,
        workType: RouteWorkType
    ) -> [String: Any]? {
        guard let payload else { return nil }

        if let array = payload as? [Any] {
            return array.compactMap { $0 as? [String: Any] }.first {
                ($0["date"] as? String) == date && remoteWorkType($0) == workType
            }
        }

        if let dictionary = payload as? [String: Any] {
            if let records = dictionary["records"] as? [Any] {
                return records.compactMap { $0 as? [String: Any] }.first {
                    ($0["date"] as? String) == date && remoteWorkType($0) == workType
                }
            }
            let storageKey = workType.storageKey(for: date)
            if let days = dictionary["days"] as? [String: Any], let day = days[storageKey] as? [String: Any] {
                return day
            }
            if let day = dictionary[storageKey] as? [String: Any] {
                return day
            }
        }

        return nil
    }

    private func normalizeRemoteDays(from payload: Any?, settings: RouteSettings) -> [RouteDayRecord] {
        guard let payload else { return [] }

        var normalizedByKey: [String: RouteDayRecord] = [:]

        if let array = payload as? [Any] {
            for item in array {
                guard let dictionary = item as? [String: Any] else { continue }
                let date = stringValue(dictionary["date"]).nilIfEmpty
                guard let date,
                      let day = normalizeRemoteDay(dictionary, date: date, fallbackWorkType: .pos, settings: settings) else { continue }
                normalizedByKey[day.workType.storageKey(for: date)] = day
            }
            return Array(normalizedByKey.values)
        }

        guard let dictionary = payload as? [String: Any] else {
            return []
        }

        if let records = dictionary["records"] as? [Any] {
            for item in records {
                guard let rawDay = item as? [String: Any],
                      let date = stringValue(rawDay["date"]).nilIfEmpty,
                      let day = normalizeRemoteDay(rawDay, date: date, fallbackWorkType: .pos, settings: settings) else { continue }
                normalizedByKey[day.workType.storageKey(for: date)] = day
            }
        }

        if let date = stringValue(dictionary["date"]).nilIfEmpty,
           let day = normalizeRemoteDay(dictionary, date: date, fallbackWorkType: .pos, settings: settings) {
            normalizedByKey[day.workType.storageKey(for: date)] = day
        }

        let source = (dictionary["days"] as? [String: Any]) ?? dictionary
        for (storageKey, value) in source {
            guard let rawDay = value as? [String: Any] else { continue }
            let date = stringValue(rawDay["date"]).nilIfEmpty ?? String(storageKey.prefix(10))
            let fallbackWorkType: RouteWorkType = storageKey.hasSuffix("|ARM") ? .arm : .pos
            guard let day = normalizeRemoteDay(
                rawDay,
                date: date,
                fallbackWorkType: fallbackWorkType,
                settings: settings
            ) else { continue }
            normalizedByKey[day.workType.storageKey(for: date)] = day
        }

        return Array(normalizedByKey.values)
    }

    private func normalizeRemoteDay(
        _ raw: [String: Any]?,
        date: String,
        fallbackWorkType: RouteWorkType,
        settings: RouteSettings
    ) -> RouteDayRecord? {
        guard let raw else { return nil }
        let workType = remoteWorkType(raw, fallback: fallbackWorkType)
        let base = RouteLocalStorage.defaultDay(for: date, workType: workType, settings: settings)
        let rawStops = (raw["stops"] as? [Any])?.compactMap(normalizeRemoteStop)
        return RouteDayRecord(
            date: date,
            workType: workType,
            stops: RouteLocalStorage.hydrateStops(raw: rawStops, base: base.stops),
            distanceKm: intValue(raw["distanceKm"]) ?? intValue(raw["distance_km"]),
            periodStartOdometer: intValue(raw["periodStartOdometer"]) ?? intValue(raw["period_start_odometer"]),
            reportedDistanceKm: doubleValue(raw["distanceKm"]) ?? doubleValue(raw["distance_km"]),
            routeSummary: stringValue(raw["routeSummary"]).nilIfEmpty ?? stringValue(raw["route"]).nilIfEmpty,
            requestNumbersSummary: stringValue(raw["requestNumbersSummary"]).nilIfEmpty ?? stringValue(raw["request_numbers"]).nilIfEmpty,
            reportedPeriodStartOdometer: intValue(raw["reportedPeriodStartOdometer"]) ?? intValue(raw["periodStartOdometer"]) ?? intValue(raw["period_start_odometer"]),
            fuelDate: stringValue(raw["fuelDate"]).nilIfEmpty ?? stringValue(raw["fuel_date"]).nilIfEmpty,
            fuelLiters: doubleValue(raw["fuelLiters"]) ?? doubleValue(raw["fuel_liters"]),
            fuelCostRub: doubleValue(raw["fuelCostRub"]) ?? doubleValue(raw["fuel_cost_rub"]),
            sent: (raw["sent"] as? Bool) ?? false
        )
    }

    private func normalizeRemoteStop(_ raw: Any) -> RouteStop? {
        guard let dictionary = raw as? [String: Any] else { return nil }
        return RouteStop(
            id: stringValue(dictionary["id"]).nilIfEmpty ?? UUID().uuidString,
            address: stringValue(dictionary["address"]),
            org: stringValue(dictionary["org"]),
            tid: stringValue(dictionary["tid"]),
            reason: stringValue(dictionary["reason"]),
            status: normalizeRemoteStatus(dictionary["status"]),
            declineReason: stringValue(dictionary["declineReason"]).nilIfEmpty
                ?? stringValue(dictionary["rejectReason"]),
            requestNumber: stringValue(dictionary["requestNumber"]),
            coordinateOverride: normalizedCoordinate(dictionary["coordinateOverride"] ?? (dictionary["payload"] as? [String: Any])?["coordinateOverride"])
        )
    }

    private func normalizedCoordinate(_ raw: Any?) -> AppleRouteCoordinate? {
        guard let value = raw as? [String: Any],
              let latitude = doubleValue(value["latitude"]), let longitude = doubleValue(value["longitude"]) else { return nil }
        let coordinate = AppleRouteCoordinate(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
        return coordinate.isValid ? coordinate : nil
    }

    private func normalizeRemoteStatus(_ raw: Any?) -> RouteStopStatus {
        let value = stringValue(raw).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.contains("decline") || value.contains("отказ") {
            return .declined
        }
        if value.contains("done") || value.contains("выполн") {
            return .done
        }
        if value == RouteStopStatus.done.rawValue {
            return .done
        }
        if value == RouteStopStatus.declined.rawValue {
            return .declined
        }
        return .pending
    }

    private func requestJSON(
        _ url: URL,
        method: String = "GET",
        body: Any? = nil,
        acceptedStatuses: Set<Int> = Set(200 ..< 300),
        authToken: String? = nil
    ) async throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let authToken, !authToken.isEmpty {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        NetworkDiagnostics.logRequest(request, body: body)

        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            NetworkDiagnostics.logError(url: url, method: method, error: error)
            if AppErrorPresentation.isCancellation(error) {
                throw CancellationError()
            }
            throw RouteDayServiceError.infrastructure(routeNetworkMessage(for: error))
        } catch {
            NetworkDiagnostics.logError(url: url, method: method, error: error)
            switch AppErrorPresentation.classification(for: error) {
            case .cancellation:
                throw CancellationError()
            case .network(let kind):
                throw RouteDayServiceError.infrastructure(kind.message)
            case .domain:
                throw RouteDayServiceError.infrastructure("Не удалось выполнить сетевой запрос.")
            }
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RouteDayServiceError.invalidResponse("Сервер вернул неизвестный ответ.")
        }

        NetworkDiagnostics.logResponse(url: url, statusCode: httpResponse.statusCode, data: data)

        guard acceptedStatuses.contains(httpResponse.statusCode) else {
            let message = responseMessage(from: data)
            switch httpResponse.statusCode {
            case 401, 403:
                throw RouteDayServiceError.unauthorized
            case 404:
                throw RouteDayServiceError.notFound
            case 502, 503, 504:
                throw RouteDayServiceError.infrastructure("Сервер временно недоступен.")
            default:
                throw RouteDayServiceError.http(status: httpResponse.statusCode, message: message)
            }
        }

        let json: Any?
        if data.isEmpty {
            json = nil
        } else {
            json = try? JSONSerialization.jsonObject(with: data)
        }

        return HTTPResponse(statusCode: httpResponse.statusCode, json: json)
    }

    private func v2RoutesURL(
        from: String? = nil,
        to: String? = nil,
        workType: RouteWorkType? = nil
    ) -> URL? {
        guard let origin = config.lumaWorkAPIOrigin?.trimmingCharacters(in: .whitespacesAndNewlines), !origin.isEmpty,
              var components = URLComponents(string: origin) else {
            return nil
        }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
            ? "/api/v2/routes"
            : components.path + "/api/v2/routes"
        var queryItems: [URLQueryItem] = []
        if let from {
            queryItems.append(URLQueryItem(name: "from", value: from))
        }
        if let to {
            queryItems.append(URLQueryItem(name: "to", value: to))
        }
        if let workType {
            queryItems.append(URLQueryItem(name: "workType", value: workType.rawValue))
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url
    }

    private func v2OfficesURL() -> URL? {
        guard let origin = config.lumaWorkAPIOrigin?.trimmingCharacters(in: .whitespacesAndNewlines), !origin.isEmpty,
              var components = URLComponents(string: origin) else {
            return nil
        }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
            ? "/api/v2/offices"
            : components.path + "/api/v2/offices"
        return components.url
    }

    private func responseMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let message = object["message"] as? String, !message.isEmpty {
                return message
            }
            if let message = object["error"] as? String, !message.isEmpty {
                return message
            }
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private func remoteWorkType(
        _ dictionary: [String: Any],
        fallback: RouteWorkType = .pos
    ) -> RouteWorkType {
        RouteWorkType(rawValue: stringValue(dictionary["workType"]).uppercased()) ?? fallback
    }

    private func routeNetworkMessage(for error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet:
            return AppNetworkBannerKind.networkUnavailable.message
        case .networkConnectionLost:
            return AppNetworkBannerKind.connectionLost.message
        case .timedOut:
            return AppNetworkBannerKind.serverUnavailable.message
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return AppNetworkBannerKind.cannotConnectToServer.message
        default:
            return "Не удалось выполнить сетевой запрос."
        }
    }

}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Array where Element == String {
    func uniqued() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
