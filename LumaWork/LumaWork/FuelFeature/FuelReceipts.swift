import CryptoKit
import Foundation
import Observation
import UniformTypeIdentifiers

nonisolated enum FuelReceiptKind: String, Codable, CaseIterable, Identifiable {
    case fiscal, bank
    var id: String { rawValue }
    var title: String { self == .fiscal ? "Фискальные" : "Банковские" }
    var attachmentTitle: String { self == .fiscal ? "Фискальный чек" : "Банковский чек" }
    var symbol: String { self == .fiscal ? "receipt" : "creditcard" }
}

nonisolated struct FuelReceipt: Codable, Identifiable, Hashable {
    let id: String
    let month: String
    let kind: FuelReceiptKind
    let fileName: String
    let mimeType: String
    let sizeBytes: Int
    let createdAt: String
    let updatedAt: String

    func validate() throws {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        guard UUID(uuidString: id) != nil,
              month.range(of: #"^[0-9]{4}-(0[1-9]|1[0-2])$"#, options: .regularExpression) != nil,
              !month.hasPrefix("0000"), !fileName.isEmpty, fileName.count <= 255,
              !fileName.contains("/"), !fileName.contains("\\"),
              (1...FuelReceiptUpload.maximumBytes).contains(sizeBytes),
              ["application/pdf", "image/jpeg", "image/png", "image/heic", "image/heif"].contains(mimeType),
              (fractional.date(from: createdAt) ?? plain.date(from: createdAt)) != nil,
              (fractional.date(from: updatedAt) ?? plain.date(from: updatedAt)) != nil else {
            throw AppServiceError.message("Сервер вернул некорректные данные чека.")
        }
    }

    static func monthsWithoutRecords(_ receipts: [FuelReceipt], records: [FuelRecord]) -> [String] {
        let recordedMonths = Set(records.map { record in
            if let month = record.monthKey, month.count == 7 { return month }
            return String(record.date.trimmingCharacters(in: .whitespacesAndNewlines).prefix(7))
        })
        return Set(receipts.map(\.month)).subtracting(recordedMonths).sorted(by: >)
    }

    static func validateList(_ receipts: [FuelReceipt]) throws -> [FuelReceipt] {
        var ids = Set<String>()
        for receipt in receipts {
            try receipt.validate()
            guard ids.insert(receipt.id.lowercased()).inserted else {
                throw AppServiceError.message("Сервер вернул повторяющиеся чеки.")
            }
        }
        return receipts
    }
}

nonisolated struct FuelReceiptUpload {
    static let maximumBytes = 20 * 1024 * 1024
    static let chunkBytes = 512 * 1024
    static let allowedContentTypes: [UTType] = [.pdf, .jpeg, .png, .heic, .heif]
    let data: Data
    let fileName: String
    let mimeType: String

    init(sourceURL: URL) throws {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile != false else { throw AppServiceError.message("Выберите файл чека.") }
        if let size = values.fileSize, size > Self.maximumBytes {
            throw AppServiceError.message("Чек не должен превышать 20 МБ.")
        }
        switch sourceURL.pathExtension.lowercased() {
        case "pdf": mimeType = "application/pdf"
        case "jpg", "jpeg": mimeType = "image/jpeg"
        case "png": mimeType = "image/png"
        case "heic": mimeType = "image/heic"
        case "heif": mimeType = "image/heif"
        default: throw AppServiceError.message("Поддерживаются PDF, JPEG, PNG и HEIC/HEIF.")
        }
        data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        try Self.validate(data, mimeType: mimeType)
        fileName = sourceURL.lastPathComponent
    }

    static func validate(_ data: Data, mimeType: String) throws {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw AppServiceError.message("Выберите непустой чек размером до 20 МБ.")
        }
        let bytes = Array(data.prefix(64))
        let valid: Bool
        switch mimeType {
        case "application/pdf": valid = data.starts(with: Data("%PDF-".utf8))
        case "image/jpeg": valid = bytes.starts(with: [0xff, 0xd8, 0xff])
        case "image/png": valid = bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
        case "image/heic", "image/heif":
            let brands = ["heic", "heix", "hevc", "hevx", "mif1", "msf1"]
            let boxSize = bytes.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            valid = bytes.count >= 16 && boxSize >= 16 && boxSize <= data.count
                && String(bytes: bytes[4..<8], encoding: .ascii) == "ftyp"
                && stride(from: 8, through: min(bytes.count, boxSize) - 4, by: 4).contains { offset in
                    offset != 12 && brands.contains(String(bytes: bytes[offset..<offset + 4], encoding: .ascii) ?? "")
                }
        default: valid = false
        }
        guard valid else { throw AppServiceError.message("Содержимое файла не соответствует формату чека.") }
    }
}

struct FuelReceiptAPI {
    let config: AppConfig
    let authToken: String?
    private let session: URLSession

    init(config: AppConfig, authToken: String?, session: URLSession? = nil) {
        self.config = config
        self.authToken = authToken
        self.session = session ?? Self.safeSession
    }

    private static let safeSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: FuelReceiptRedirectGuard(), delegateQueue: nil)
    }()

    func list() async throws -> [FuelReceipt] {
        let response = try await request()
        guard let raw = dictionaryValue(response.json)?["receipts"] else {
            throw AppServiceError.message("Сервер не вернул список чеков.")
        }
        return try FuelReceipt.validateList(JSONDecoder().decode([FuelReceipt].self, from: JSONSerialization.data(withJSONObject: raw)))
    }

    func upload(_ upload: FuelReceiptUpload, month: String, id: String, kind: FuelReceiptKind,
                progress: @MainActor (Double) -> Void) async throws -> FuelReceipt {
        let total = (upload.data.count + FuelReceiptUpload.chunkBytes - 1) / FuelReceiptUpload.chunkBytes
        let uploadID = UUID().uuidString.lowercased()
        var receipt: FuelReceipt?
        for index in 0..<total {
            try Task.checkCancellation()
            let offset = index * FuelReceiptUpload.chunkBytes
            let chunk = upload.data.subdata(in: offset..<min(offset + FuelReceiptUpload.chunkBytes, upload.data.count))
            let response = try await request("\(month)/\(id)/chunk", method: "POST", body: [
                "uploadId": uploadID, "kind": kind.rawValue, "fileName": upload.fileName,
                "mimeType": upload.mimeType, "chunkIndex": index, "totalChunks": total,
                "chunkBase64": chunk.base64EncodedString()
            ])
            let root = dictionaryValue(response.json)
            if index == total - 1, root?["complete"] as? Bool == true, let raw = root?["receipt"] {
                receipt = try JSONDecoder().decode(FuelReceipt.self, from: JSONSerialization.data(withJSONObject: raw))
            } else if index != total - 1 {
                guard root?["complete"] as? Bool == false,
                      root?["received"] as? Int == index + 1, root?["totalChunks"] as? Int == total else {
                    throw AppServiceError.message("Сервер не подтвердил часть чека. Повторите загрузку.")
                }
            }
            await progress(Double(index + 1) / Double(total))
        }
        guard let receipt, receipt.id == id, receipt.month == month, receipt.kind == kind,
              receipt.sizeBytes == upload.data.count, receipt.mimeType == upload.mimeType else {
            throw AppServiceError.message("Сервер не подтвердил сохранение чека.")
        }
        try receipt.validate()
        return receipt
    }

    func data(for receipt: FuelReceipt) async throws -> Data {
        var request = URLRequest(url: try url(receipt.id))
        request.setValue("Bearer \(authToken ?? "")", forHTTPHeaderField: "Authorization")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.timeoutInterval = 40
        AppBuildIdentity.apply(to: &request)
        let (temporaryURL, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard let http = response as? HTTPURLResponse else { throw AppServiceError.message("Не удалось открыть чек.") }
        guard (200..<300).contains(http.statusCode) else {
            throw AppServiceError.http(status: http.statusCode, fallback: "Не удалось открыть чек")
        }
        let size = try temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size == receipt.sizeBytes, (1...FuelReceiptUpload.maximumBytes).contains(size) else {
            throw AppServiceError.message("Чек загружен не полностью или превышает 20 МБ.")
        }
        let data = try Data(contentsOf: temporaryURL, options: .mappedIfSafe)
        try FuelReceiptUpload.validate(data, mimeType: receipt.mimeType)
        guard data.count == receipt.sizeBytes else { throw AppServiceError.message("Чек загружен не полностью.") }
        return data
    }

    func delete(_ receipt: FuelReceipt) async throws {
        _ = try await request(receipt.id, method: "DELETE")
    }

    private func request(_ suffix: String = "", method: String = "GET", body: [String: Any]? = nil) async throws -> HTTPResponse {
        var request = URLRequest(url: try url(suffix))
        request.httpMethod = method
        request.timeoutInterval = 40
        request.setValue("Bearer \(authToken ?? "")", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        AppBuildIdentity.apply(to: &request)
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppServiceError.message("Неизвестный ответ сервера.") }
        let json = data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data)
        guard (200..<300).contains(http.statusCode) else {
            let message = dictionaryValue(json)?["message"] as? String
            throw AppServiceError.http(status: http.statusCode, fallback: message ?? "Не удалось выполнить действие с чеком")
        }
        return HTTPResponse(statusCode: http.statusCode, json: json)
    }

    private func url(_ suffix: String = "") throws -> URL {
        guard let authToken, !authToken.isEmpty,
              let origin = config.lumaWorkAPIOrigin, let base = URL(string: origin) else {
            throw AppServiceError.message("Требуется авторизация.")
        }
        return base.appendingPathComponent("api/v2/fuel/receipts").appendingPathComponent(suffix)
    }
}

@MainActor
@Observable
final class FuelReceiptStore {
    private let api: FuelReceiptAPI
    private let cacheKey: String?
    private let cacheDirectory: URL?
    private(set) var receipts: [FuelReceipt] = []
    private(set) var isLoading = false
    private(set) var busyID: String?
    private(set) var uploadProgress: Double?
    private(set) var isShowingCachedData = false
    private(set) var authorizationFailed = false
    var errorMessage: String?
    var isBusy: Bool { isLoading || busyID != nil }

    init(api: FuelReceiptAPI, ownerID: String?) {
        self.api = api
        if let ownerID, !ownerID.isEmpty {
            let scope = Self.hash(ownerID)
            cacheKey = "fuel-receipts-\(scope)"
            cacheDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("FuelReceipts/\(scope)", isDirectory: true)
        } else {
            cacheKey = nil
            cacheDirectory = nil
        }
        if let cacheKey, let snapshot = AppOfflineSnapshotStore.load([FuelReceipt].self, key: cacheKey),
           let cached = try? FuelReceipt.validateList(snapshot.value) {
            receipts = cached
            isShowingCachedData = true
        }
    }

    func receipts(month: String, kind: FuelReceiptKind? = nil) -> [FuelReceipt] {
        receipts.filter { $0.month == month && (kind == nil || $0.kind == kind) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func load() async {
        guard !isBusy else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await api.list()
            try Task.checkCancellation()
            receipts = loaded
            authorizationFailed = false
            isShowingCachedData = false
            errorMessage = nil
            persist()
        } catch {
            isShowingCachedData = !receipts.isEmpty
            report(error)
        }
    }

    func upload(from source: URL, month: String, kind: FuelReceiptKind, replacing: FuelReceipt?) async {
        guard !isBusy, !authorizationFailed else { return }
        let id = replacing?.id.lowercased() ?? UUID().uuidString.lowercased()
        busyID = id
        uploadProgress = 0
        errorMessage = nil
        defer { busyID = nil; uploadProgress = nil }
        do {
            let preparation = Task.detached(priority: .userInitiated) { try FuelReceiptUpload(sourceURL: source) }
            let upload = try await preparation.value
            try Task.checkCancellation()
            let saved = try await api.upload(upload, month: month, id: id, kind: kind) { [weak self] in
                self?.uploadProgress = $0
            }
            try Task.checkCancellation()
            receipts.removeAll { $0.id == id }
            receipts.append(saved)
            persist()
            removeCachedFiles(for: saved)
            _ = try? cache(upload.data, receipt: saved)
        } catch { report(error) }
    }

    func fileURL(for receipt: FuelReceipt) async -> URL? {
        guard !isBusy, !authorizationFailed else { return nil }
        busyID = receipt.id
        errorMessage = nil
        defer { busyID = nil }
        do {
            if let url = cachedURL(for: receipt), FileManager.default.fileExists(atPath: url.path) {
                if cachedFileIsValid(url, receipt: receipt) { return url }
                try? FileManager.default.removeItem(at: url)
            }
            let data = try await api.data(for: receipt)
            try Task.checkCancellation()
            return try cache(data, receipt: receipt)
        } catch { report(error); return nil }
    }

    func delete(_ receipt: FuelReceipt) async {
        guard !isBusy, !authorizationFailed else { return }
        busyID = receipt.id
        errorMessage = nil
        defer { busyID = nil }
        do {
            try await api.delete(receipt)
            try Task.checkCancellation()
            receipts.removeAll { $0.id == receipt.id }
            removeCachedFiles(for: receipt)
            persist()
        } catch { report(error) }
    }

    private func report(_ error: Error) {
        guard !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
        if case AppServiceError.http(let status, _) = error, status == 401 || status == 403 {
            authorizationFailed = true
            receipts = []
            if let cacheKey { AppOfflineSnapshotStore.remove(key: cacheKey) }
            if let cacheDirectory { try? FileManager.default.removeItem(at: cacheDirectory) }
            errorMessage = status == 401
                ? "Сессия истекла. Войдите в аккаунт повторно, чтобы открыть чеки."
                : "Доступ к чекам запрещён. Проверьте аккаунт и повторите вход."
        } else {
            errorMessage = appUserFacingErrorMessage(error, showsNetworkBanner: false)
        }
    }

    private func persist() {
        if let cacheKey { AppOfflineSnapshotStore.save(receipts, key: cacheKey) }
    }

    private func cachedURL(for receipt: FuelReceipt) -> URL? {
        let ext = switch receipt.mimeType {
        case "application/pdf": "pdf"
        case "image/jpeg": "jpg"
        case "image/png": "png"
        case "image/heic": "heic"
        default: "heif"
        }
        return cacheDirectory?.appendingPathComponent(Self.hash(receipt.id), isDirectory: true)
            .appendingPathComponent("\(Self.hash(receipt.updatedAt)).\(ext)")
    }

    private func cachedFileIsValid(_ url: URL, receipt: FuelReceipt) -> Bool {
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size == receipt.sizeBytes, (1...FuelReceiptUpload.maximumBytes).contains(size) else { return false }
            try FuelReceiptUpload.validate(Data(contentsOf: url, options: .mappedIfSafe), mimeType: receipt.mimeType)
            return true
        } catch { return false }
    }

    private func cache(_ data: Data, receipt: FuelReceipt) throws -> URL {
        guard let url = cachedURL(for: receipt) else { throw AppServiceError.message("Требуется авторизация.") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var directory = url.deletingLastPathComponent()
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        return url
    }

    private func removeCachedFiles(for receipt: FuelReceipt) {
        if let directory = cachedURL(for: receipt)?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated private final class FuelReceiptRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
