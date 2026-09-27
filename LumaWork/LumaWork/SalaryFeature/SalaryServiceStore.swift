import Foundation
import Observation

struct SalaryService {
    private let config: AppConfig
    private let authToken: String?
    private let client = HTTPClient()

    init(config: AppConfig, authToken: String? = nil) {
        self.config = config
        self.authToken = authToken
    }

    func fetchMonths() async throws -> [SalaryMonth] {
        guard let authToken, let url = v2URL(path: "/api/v2/salary") else {
            throw AppServiceError.message("Требуется авторизация.")
        }
        let response = try await client.request(url, authToken: authToken)
        guard let rawRecords = salaryRecords(from: response.json) else {
            throw AppServiceError.message("Сервер временно вернул некорректный ответ по зарплате.")
        }
        return groupEntries(rawRecords.map { normalizeEntry($0) })
    }

    func fetchDocuments() async throws -> [SalaryDocument] {
        guard let authToken, let url = v2URL(path: "/api/v2/salary/documents") else {
            throw AppServiceError.message("Требуется авторизация.")
        }
        let response = try await client.request(url, authToken: authToken)
        let rawDocuments = dictionaryValue(response.json)?["documents"] as? [Any] ?? []
        return rawDocuments.compactMap(Self.salaryDocument)
    }

    func uploadDocument(
        month: String,
        sourceURL: URL,
        progress: @MainActor (Double) -> Void
    ) async throws -> SalaryDocument {
        let upload = try SalaryDocumentUpload(sourceURL: sourceURL)
        let chunkSize = 512 * 1024
        let chunks = stride(from: 0, to: upload.data.count, by: chunkSize).map { offset in
            upload.data.subdata(in: offset ..< min(offset + chunkSize, upload.data.count))
        }
        let uploadID = UUID().uuidString
        var uploadedDocument: SalaryDocument?
        for (index, chunk) in chunks.enumerated() {
            guard let authToken, let url = v2URL(path: "/api/v2/salary/documents/\(month)/chunk") else {
                throw AppServiceError.message("Требуется авторизация.")
            }
            let response = try await client.request(
                url,
                method: "POST",
                body: [
                    "uploadId": uploadID,
                    "fileName": upload.fileName,
                    "mimeType": upload.mimeType,
                    "chunkIndex": index,
                    "totalChunks": chunks.count,
                    "chunkBase64": chunk.base64EncodedString()
                ],
                authToken: authToken
            )
            if let raw = dictionaryValue(response.json)?["document"] {
                uploadedDocument = Self.salaryDocument(raw)
            }
            progress(Double(index + 1) / Double(chunks.count))
        }
        guard let uploadedDocument else {
            throw AppServiceError.message("Сервер не подтвердил загрузку расчётного листка.")
        }
        return uploadedDocument
    }

    func documentData(month: String) async throws -> Data {
        guard let authToken, let url = v2URL(path: "/api/v2/salary/documents/\(month)") else {
            throw AppServiceError.message("Требуется авторизация.")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200 ..< 300).contains(response.statusCode) else {
            throw AppServiceError.message("Не удалось загрузить расчётный листок.")
        }
        return data
    }

    func deleteDocument(month: String) async throws {
        guard let authToken, let url = v2URL(path: "/api/v2/salary/documents/\(month)") else {
            throw AppServiceError.message("Требуется авторизация.")
        }
        _ = try await client.request(url, method: "DELETE", authToken: authToken)
    }

    func create(_ input: SalaryEntryInput) async throws -> SalaryEntry {
        let normalizedEntry = normalizeInput(input)
        try validate(normalizedEntry)
        let entryForCreate = SalaryEntry(
            id: UUID().uuidString,
            date: normalizedEntry.date,
            baseSalary: normalizedEntry.baseSalary,
            weekendPay: normalizedEntry.weekendPay,
            periodMonth: normalizedEntry.periodMonth,
            amount: normalizedEntry.amount,
            kind: normalizedEntry.kind,
            comment: normalizedEntry.comment
        )

        guard let authToken, let url = v2URL(path: "/api/v2/salary") else {
            throw AppServiceError.message("Требуется авторизация.")
        }
        let response = try await client.request(url, method: "POST", body: requestPayload(for: entryForCreate), authToken: authToken)
        if let dictionary = dictionaryValue(response.json), dictionary["date"] != nil {
            return normalizeEntry(dictionary)
        }
        return entryForCreate
    }

    func update(target: SalaryEntry, input: SalaryEntryInput) async throws -> SalaryEntry {
        let updatedEntry = normalizeInput(input)
        try validate(updatedEntry)
        let entryForUpdate = SalaryEntry(
            id: target.id,
            date: updatedEntry.date,
            baseSalary: updatedEntry.baseSalary,
            weekendPay: updatedEntry.weekendPay,
            periodMonth: updatedEntry.periodMonth,
            amount: updatedEntry.amount,
            kind: updatedEntry.kind,
            comment: updatedEntry.comment
        )

        guard let targetID = target.id, !targetID.isEmpty else {
            throw AppServiceError.message("Запись зарплаты для обновления не найдена.")
        }
        guard let authToken, let url = v2URL(path: "/api/v2/salary/\(targetID)") else {
            throw AppServiceError.message("Требуется авторизация.")
        }
        let response = try await client.request(url, method: "PUT", body: requestPayload(for: entryForUpdate), authToken: authToken)
        if let dictionary = dictionaryValue(response.json) {
            return normalizeEntry(dictionary)
        }
        return entryForUpdate
    }

    func delete(_ target: SalaryEntry) async throws {
        guard let targetID = target.id, !targetID.isEmpty else {
            throw AppServiceError.message("Запись зарплаты для удаления не найдена.")
        }
        guard let authToken, let url = v2URL(path: "/api/v2/salary/\(targetID)") else {
            throw AppServiceError.message("Требуется авторизация.")
        }
        _ = try await client.request(url, method: "DELETE", authToken: authToken)
    }

    private func normalizeEntry(_ raw: Any, fallbackMonth: String? = nil) -> SalaryEntry {
        let dictionary = dictionaryValue(raw) ?? [:]
        let primaryID = stringValue(dictionary["id"]).nilIfEmpty
        let rawKind = stringValue(dictionary["kind"]).lowercased().nilIfEmpty
        let date = stringValue(dictionary["date"])
        let periodMonth = stringValue(dictionary["periodMonth"]).nilIfEmpty
            ?? Self.inferredPeriodMonth(for: date, fallbackMonth: fallbackMonth)
        return SalaryEntry(
            id: primaryID ?? stringValue(dictionary["_id"]).nilIfEmpty,
            date: date,
            baseSalary: doubleValue(dictionary["baseSalary"]) ?? 0,
            weekendPay: doubleValue(dictionary["weekendPay"]) ?? 0,
            periodMonth: periodMonth,
            amount: doubleValue(dictionary["amount"]),
            kind: rawKind.flatMap(SalaryPaymentKind.init(rawValue:)),
            comment: stringValue(dictionary["comment"]).nilIfEmpty
        )
    }

    private static func salaryDocument(_ raw: Any) -> SalaryDocument? {
        guard let dictionary = dictionaryValue(raw) else { return nil }
        let id = stringValue(dictionary["id"])
        let month = stringValue(dictionary["month"])
        let fileName = stringValue(dictionary["fileName"])
        guard !id.isEmpty, isValidMonthKey(month), !fileName.isEmpty else { return nil }
        return SalaryDocument(
            id: id,
            month: month,
            fileName: fileName,
            mimeType: stringValue(dictionary["mimeType"]),
            sizeBytes: intValue(dictionary["sizeBytes"]) ?? 0,
            createdAt: stringValue(dictionary["createdAt"]),
            updatedAt: stringValue(dictionary["updatedAt"])
        )
    }

    private func salaryRecords(from raw: Any?) -> [Any]? {
        guard let dictionary = dictionaryValue(raw) else { return nil }
        if let records = dictionary["records"] as? [Any] {
            return records
        }
        if let entries = dictionary["entries"] as? [Any] {
            return entries
        }
        if let data = dictionary["data"] as? [Any] {
            return data
        }
        if let items = dictionary["items"] as? [Any] {
            return items
        }
        return nil
    }

    private func normalizeInput(_ input: SalaryEntryInput) -> SalaryEntry {
        SalaryEntry(
            id: nil,
            date: input.date,
            baseSalary: input.baseSalary,
            weekendPay: input.weekendPay,
            periodMonth: input.periodMonth,
            amount: input.amount,
            kind: input.kind,
            comment: input.comment
        )
    }

    private func validate(_ entry: SalaryEntry) throws {
        guard !entry.date.isEmpty else {
            throw AppServiceError.message("Укажите дату выплаты.")
        }
        guard entry.baseSalary >= 0 else {
            throw AppServiceError.message("Некорректное значение оклада.")
        }
        guard entry.weekendPay >= 0 else {
            throw AppServiceError.message("Некорректное значение оплаты за выходной.")
        }
        if let amount = entry.amount, amount < 0 {
            throw AppServiceError.message("Некорректное значение выплаты.")
        }
        if let periodMonth = entry.periodMonth, !Self.isValidMonthKey(periodMonth) {
            throw AppServiceError.message("Некорректный месяц начисления.")
        }
    }

    private func requestPayload(for entry: SalaryEntry) -> [String: Any] {
        [
            "id": entry.id as Any,
            "date": entry.date,
            "baseSalary": entry.baseSalary,
            "weekendPay": entry.weekendPay,
            "periodMonth": entry.periodMonth as Any,
            "amount": entry.amount as Any,
            "kind": entry.kind?.rawValue as Any,
            "comment": entry.comment as Any
        ].compactMapValues { value in
            if let optional = value as? OptionalProtocol, optional.isNil {
                return nil
            }
            return value
        }
    }

    private func groupEntries(_ entries: [SalaryEntry]) -> [SalaryMonth] {
        Dictionary(grouping: entries, by: \.accrualMonthKey)
            .map { month, entries in
                SalaryMonth(month: month, entries: entries.sorted { $0.date < $1.date })
            }
            .sorted { $0.month < $1.month }
    }

    private static func isValidMonthKey(_ value: String) -> Bool {
        let parts = value.split(separator: "-")
        guard parts.count == 2,
              parts[0].count == 4,
              parts[1].count == 2,
              let month = Int(parts[1]),
              (1 ... 12).contains(month) else {
            return false
        }
        return true
    }

    private static func inferredPeriodMonth(for date: String, fallbackMonth: String?) -> String? {
        let monthKey = String(date.prefix(7))
        guard isValidMonthKey(monthKey), date >= SalaryEntry.netPaymentStartDate else {
            return fallbackMonth ?? (isValidMonthKey(monthKey) ? monthKey : nil)
        }

        let dayText = String(date.suffix(2))
        guard let day = Int(dayText), day <= 10 else {
            return monthKey
        }

        return SalaryEntry.previousMonthKey(from: monthKey) ?? monthKey
    }

    private func v2URL(path: String) -> URL? {
        guard let origin = config.lumaWorkAPIOrigin?.trimmingCharacters(in: .whitespacesAndNewlines), !origin.isEmpty else {
            return nil
        }
        return URL(string: origin)?.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
}

@MainActor
@Observable
final class SalaryStore {
    private let service: SalaryService
    private let cacheKey: String
    private let documentCacheKey: String

    var months: [SalaryMonth] = []
    var salaryDocuments: [SalaryDocument] = []
    var lastUpdatedAt: Date?
    var isLoading = false
    var isSubmitting = false
    var salaryDocumentBusyMonth: String?
    var salaryDocumentUploadProgress: Double?
    var errorMessage: String?
    var notice: String?
    private(set) var hasLoadedSalaryDocuments = false
    private var hasLoaded = false

    init(service: SalaryService, cacheID: String? = nil) {
        self.service = service
        cacheKey = AppOfflineSnapshotStore.scopedKey("salary", userID: cacheID)
        documentCacheKey = AppOfflineSnapshotStore.scopedKey("salary-documents", userID: cacheID)
        if let snapshot = AppOfflineSnapshotStore.load([SalaryMonth].self, key: cacheKey) {
            months = snapshot.value
            lastUpdatedAt = snapshot.updatedAt
        }
        if let snapshot = AppOfflineSnapshotStore.load([SalaryDocument].self, key: documentCacheKey) {
            salaryDocuments = snapshot.value
        }
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await load(showsNetworkBanner: months.isEmpty)
    }

    func load(showsNetworkBanner: Bool = true) async {
        isLoading = true
        errorMessage = nil
        async let fetchedMonths = service.fetchMonths()
        async let fetchedDocuments = service.fetchDocuments()

        do {
            months = try await fetchedMonths
            lastUpdatedAt = Date()
            AppOfflineSnapshotStore.save(months, key: cacheKey)
            hasLoaded = true
        } catch {
            errorMessage = appUserFacingErrorMessage(
                error,
                showsNetworkBanner: showsNetworkBanner
            )
            if !months.isEmpty {
                hasLoaded = true
            }
        }

        do {
            salaryDocuments = try await fetchedDocuments
            AppOfflineSnapshotStore.save(salaryDocuments, key: documentCacheKey)
            hasLoadedSalaryDocuments = true
        } catch {
            if errorMessage == nil,
               let message = appUserFacingErrorMessage(error, showsNetworkBanner: salaryDocuments.isEmpty) {
                AppBannerCenter.shared.show(message, style: .error)
            }
        }
        isLoading = false
    }

    func salaryDocument(for month: String) -> SalaryDocument? {
        salaryDocuments.first { $0.month == month }
    }

    func uploadSalaryDocument(
        from sourceURL: URL,
        to month: String,
        showsSuccessBanner: Bool = true
    ) async -> Bool {
        salaryDocumentBusyMonth = month
        salaryDocumentUploadProgress = 0
        defer {
            salaryDocumentBusyMonth = nil
            salaryDocumentUploadProgress = nil
        }
        do {
            let document = try await service.uploadDocument(month: month, sourceURL: sourceURL) { [weak self] progress in
                self?.salaryDocumentUploadProgress = progress
            }
            salaryDocuments.removeAll { $0.month == month }
            salaryDocuments.append(document)
            salaryDocuments.sort { $0.month > $1.month }
            AppOfflineSnapshotStore.save(salaryDocuments, key: documentCacheKey)
            if showsSuccessBanner {
                AppBannerCenter.shared.show("Расчётный листок сохранён на сервере.", style: .success)
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            if let message = appUserFacingErrorMessage(error, fallback: "Не удалось сохранить расчётный листок на сервере.") {
                AppBannerCenter.shared.show(message, style: .error)
            }
            return false
        }
    }

    func salaryDocumentFileURL(for month: String) async -> URL? {
        guard let document = salaryDocument(for: month) else { return nil }
        salaryDocumentBusyMonth = month
        defer { salaryDocumentBusyMonth = nil }
        do {
            let data = try await service.documentData(month: month)
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("LumaWorkSalaryDocuments", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileExtension = document.mimeType == "application/pdf" ? "pdf" : "html"
            let url = directory.appendingPathComponent("\(month)-\(document.id).\(fileExtension)")
            try data.write(to: url, options: .atomic)
            return url
        } catch is CancellationError {
            return nil
        } catch {
            if let message = appUserFacingErrorMessage(error, fallback: "Не удалось открыть расчётный листок.") {
                AppBannerCenter.shared.show(message, style: .error)
            }
            return nil
        }
    }

    func deleteSalaryDocument(for month: String) async -> Bool {
        salaryDocumentBusyMonth = month
        defer { salaryDocumentBusyMonth = nil }
        do {
            try await service.deleteDocument(month: month)
            salaryDocuments.removeAll { $0.month == month }
            AppOfflineSnapshotStore.save(salaryDocuments, key: documentCacheKey)
            AppBannerCenter.shared.show("Расчётный листок удалён с сервера.", style: .success)
            return true
        } catch is CancellationError {
            return false
        } catch {
            if let message = appUserFacingErrorMessage(error, fallback: "Не удалось удалить расчётный листок.") {
                AppBannerCenter.shared.show(message, style: .error)
            }
            return false
        }
    }

    func save(editing target: SalaryEntry?, input: SalaryEntryInput) async -> Bool {
        do {
            isSubmitting = true
            errorMessage = nil
            if let target {
                _ = try await service.update(target: target, input: input)
                notice = "Запись зарплаты обновлена."
            } else {
                _ = try await service.create(input)
                notice = "Запись зарплаты добавлена."
            }
            await load()
            isSubmitting = false
            return true
        } catch {
            isSubmitting = false
            errorMessage = appUserFacingErrorMessage(error)
            return false
        }
    }

    func delete(_ entry: SalaryEntry) async {
        do {
            errorMessage = nil
            try await service.delete(entry)
            notice = "Запись зарплаты удалена."
            await load()
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
