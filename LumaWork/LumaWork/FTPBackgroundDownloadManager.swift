import Foundation
import Observation
import UIKit

enum FTPDownloadAction: String, Codable, Hashable, Sendable {
    case download
    case saveToFiles
    case share

    var title: String {
        switch self {
        case .download: "Скачать"
        case .saveToFiles: "Сохранить в Файлы"
        case .share: "Поделиться"
        }
    }
}

enum FTPDownloadState: String, Codable, Hashable, Sendable {
    case preparing
    case downloading
    case completed
    case failed
    case cancelled

    var title: String {
        switch self {
        case .preparing: "Подготовка"
        case .downloading: "Загрузка"
        case .completed: "Завершено"
        case .failed: "Ошибка"
        case .cancelled: "Отменено"
        }
    }

    var isActive: Bool {
        self == .preparing || self == .downloading
    }
}

struct FTPDownloadRecord: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let ownerID: String
    let taskIdentifier: Int
    let fileName: String
    let remotePath: String
    let sourceURL: String
    let action: FTPDownloadAction
    let createdAt: Date
    var bytesWritten: Int64
    var totalBytesExpected: Int64?
    var progress: Double
    var state: FTPDownloadState
    var errorMessage: String?
    var destinationBookmark: Data?
    var localFilePath: String?
    var isPresentationPending: Bool

    var progressPercent: Int? {
        guard let totalBytesExpected, totalBytesExpected > 0 else { return nil }
        return min(100, max(0, Int((Double(bytesWritten) / Double(totalBytesExpected) * 100).rounded())))
    }

    var canCancel: Bool {
        state.isActive && localFilePath == nil
    }

    var transferredSizeText: String {
        let written = FTPDownloadFormatters.bytes.string(fromByteCount: max(0, bytesWritten))
        guard let totalBytesExpected, totalBytesExpected > 0 else {
            return written
        }
        return "\(written) / \(FTPDownloadFormatters.bytes.string(fromByteCount: totalBytesExpected))"
    }
}

private enum FTPDownloadFormatters {
    static let bytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()
}

@MainActor
@Observable
final class FTPBackgroundDownloadManager: NSObject {
    static let sessionIdentifier = "septon.LumaWork.ftp-downloads.background"
    static let shared = FTPBackgroundDownloadManager()

    private static let persistenceKey = "ftp-background-downloads-v1"

    private(set) var records: [FTPDownloadRecord]

    @ObservationIgnored private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.httpCookieStorage = .shared
        configuration.httpShouldSetCookies = true
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true

        let delegateQueue = OperationQueue()
        delegateQueue.name = "LumaWork.FTPBackgroundDownloadDelegate"
        delegateQueue.maxConcurrentOperationCount = 1
        return URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }()
    @ObservationIgnored private var pendingFinalizations = 0
    @ObservationIgnored private var backgroundEventsAreWaiting = false

    private override init() {
        records = Self.loadRecords()
        super.init()
        _ = session
        restoreTasks()
    }

    func start(
        request: URLRequest,
        fileName: String,
        remotePath: String,
        action: FTPDownloadAction,
        destinationDirectory: URL?,
        ownerID: String
    ) throws {
        guard !records.contains(where: {
            $0.ownerID == ownerID && $0.remotePath == remotePath && $0.state.isActive
        }) else {
            return
        }

        let bookmark: Data?
        if action == .saveToFiles {
            guard let destinationDirectory else {
                throw FTPBackgroundDownloadError.message("Не выбрана папка для сохранения.")
            }
            let hasAccess = destinationDirectory.startAccessingSecurityScopedResource()
            defer {
                if hasAccess { destinationDirectory.stopAccessingSecurityScopedResource() }
            }
            bookmark = try destinationDirectory.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } else {
            bookmark = nil
        }

        let recordID = UUID()
        let task = session.downloadTask(with: request)
        task.taskDescription = recordID.uuidString
        let record = FTPDownloadRecord(
            id: recordID,
            ownerID: ownerID,
            taskIdentifier: task.taskIdentifier,
            fileName: fileName,
            remotePath: remotePath,
            sourceURL: request.url?.absoluteString ?? remotePath,
            action: action,
            createdAt: Date(),
            bytesWritten: 0,
            totalBytesExpected: nil,
            progress: 0,
            state: .preparing,
            errorMessage: nil,
            destinationBookmark: bookmark,
            localFilePath: nil,
            isPresentationPending: false
        )
        records.insert(record, at: 0)
        persistRecords()
        task.resume()
    }

    func records(ownerID: String) -> [FTPDownloadRecord] {
        records
            .filter { $0.ownerID == ownerID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func record(remotePath: String, ownerID: String) -> FTPDownloadRecord? {
        records(ownerID: ownerID).first {
            $0.remotePath == remotePath && $0.state.isActive
        }
    }

    func completedRecord(remotePath: String, ownerID: String) -> FTPDownloadRecord? {
        records(ownerID: ownerID).first { record in
            guard record.remotePath == remotePath,
                  record.state == .completed,
                  let path = record.localFilePath else {
                return false
            }
            return FileManager.default.fileExists(atPath: path)
        }
    }

    func cancel(recordID: UUID) {
        guard let index = records.firstIndex(where: { $0.id == recordID }),
              records[index].canCancel else {
            return
        }
        let taskIdentifier = records[index].taskIdentifier
        records[index].state = .cancelled
        records[index].errorMessage = "Загрузка отменена пользователем."
        persistRecords()

        session.getAllTasks { tasks in
            tasks.first(where: { $0.taskIdentifier == taskIdentifier })?.cancel()
        }
    }

    func remove(recordID: UUID) {
        guard let index = records.firstIndex(where: { $0.id == recordID }),
              !records[index].state.isActive else {
            return
        }
        if records[index].action == .download,
           records[index].state == .completed,
           let localFilePath = records[index].localFilePath,
           FileManager.default.fileExists(atPath: localFilePath) {
            return
        }
        let record = records.remove(at: index)
        if let localFilePath = record.localFilePath {
            Self.removeManagedLocalFileIfNeeded(URL(fileURLWithPath: localFilePath))
        }
        persistRecords()
    }

    func deleteSavedDownload(recordID: UUID, ownerID: String) throws {
        guard let index = records.firstIndex(where: {
            $0.id == recordID && $0.ownerID == ownerID &&
                $0.action == .download && $0.state == .completed
        }), let localFilePath = records[index].localFilePath else {
            throw FTPBackgroundDownloadError.message("Скачанный файл не найден.")
        }

        let directory = try Self.userDownloadsDirectory().standardizedFileURL
        let fileURL = URL(fileURLWithPath: localFilePath).standardizedFileURL
        guard fileURL.deletingLastPathComponent() == directory,
              fileURL.resolvingSymlinksInPath().deletingLastPathComponent() == directory.resolvingSymlinksInPath() else {
            throw FTPBackgroundDownloadError.message("Нельзя удалить файл за пределами загрузок FTP.")
        }

        try FileManager.default.removeItem(at: fileURL)
        records.remove(at: index)
        persistRecords()
    }

    func consumePendingShare(ownerID: String) -> FTPDownloadedFile? {
        guard let index = records.firstIndex(where: {
            $0.ownerID == ownerID &&
                $0.action == .share &&
                $0.state == .completed &&
                $0.isPresentationPending &&
                $0.localFilePath != nil
        }), let localFilePath = records[index].localFilePath else {
            return nil
        }
        records[index].isPresentationPending = false
        persistRecords()
        return FTPDownloadedFile(recordID: records[index].id, url: URL(fileURLWithPath: localFilePath))
    }

    func downloadedFile(recordID: UUID) -> FTPDownloadedFile? {
        guard let record = records.first(where: { $0.id == recordID }),
              record.state == .completed,
              let localFilePath = record.localFilePath,
              FileManager.default.fileExists(atPath: localFilePath) else {
            return nil
        }
        return FTPDownloadedFile(recordID: record.id, url: URL(fileURLWithPath: localFilePath))
    }

    func downloadedFile(remotePath: String, ownerID: String) -> FTPDownloadedFile? {
        guard let record = completedRecord(remotePath: remotePath, ownerID: ownerID),
              let localFilePath = record.localFilePath else {
            return nil
        }
        return FTPDownloadedFile(recordID: record.id, url: URL(fileURLWithPath: localFilePath))
    }

    func filesDirectoryURL(recordID: UUID? = nil) -> URL? {
        if let recordID,
           let record = records.first(where: { $0.id == recordID }),
           record.action != .share,
           let localFilePath = record.localFilePath {
            return URL(fileURLWithPath: localFilePath).deletingLastPathComponent()
        }
        return try? Self.userDownloadsDirectory()
    }

    func reconnectBackgroundSession() {
        _ = session
        finishBackgroundEventsIfReady()
    }

    private func restoreTasks() {
        session.getAllTasks { tasks in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let activeIdentifiers = Set(tasks.map(\.taskIdentifier))

                for task in tasks {
                    guard let index = self.recordIndex(
                        taskIdentifier: task.taskIdentifier,
                        recordID: task.taskDescription
                    ) else {
                        task.cancel()
                        continue
                    }
                    let written = max(self.records[index].bytesWritten, task.countOfBytesReceived)
                    let expected = task.countOfBytesExpectedToReceive > 0
                        ? task.countOfBytesExpectedToReceive
                        : self.records[index].totalBytesExpected
                    self.records[index].bytesWritten = written
                    self.records[index].totalBytesExpected = expected
                    self.records[index].progress = Self.progress(written: written, expected: expected)
                    self.records[index].state = written > 0 ? .downloading : .preparing
                    self.records[index].errorMessage = nil
                }

                for index in self.records.indices where self.records[index].state.isActive {
                    guard !activeIdentifiers.contains(self.records[index].taskIdentifier) else { continue }
                    self.records[index].state = .failed
                    self.records[index].errorMessage = "Фоновая загрузка была прервана системой. Запустите её повторно."
                }
                self.persistRecords()
            }
        }
    }

    private func updateProgress(
        taskIdentifier: Int,
        recordID: String?,
        bytesWritten: Int64,
        totalBytesExpected: Int64
    ) {
        guard let index = recordIndex(taskIdentifier: taskIdentifier, recordID: recordID),
              records[index].state != .cancelled else {
            return
        }
        let previousBytes = records[index].bytesWritten
        let previousPercent = records[index].progressPercent
        let expected = totalBytesExpected > 0 ? totalBytesExpected : nil
        records[index].bytesWritten = bytesWritten
        records[index].totalBytesExpected = expected
        records[index].progress = Self.progress(written: bytesWritten, expected: expected)
        records[index].state = .downloading
        records[index].errorMessage = nil
        if records[index].progressPercent != previousPercent || bytesWritten - previousBytes >= 1_048_576 {
            persistRecords()
        }
    }

    private func finish(taskIdentifier: Int, recordID: String?, stagedURL: URL, response: URLResponse?) {
        guard let index = recordIndex(taskIdentifier: taskIdentifier, recordID: recordID) else {
            try? FileManager.default.removeItem(at: stagedURL.deletingLastPathComponent())
            return
        }
        guard records[index].state != .cancelled else {
            try? FileManager.default.removeItem(at: stagedURL.deletingLastPathComponent())
            return
        }

        if let httpResponse = response as? HTTPURLResponse,
           !(200 ..< 300).contains(httpResponse.statusCode) {
            records[index].state = .failed
            records[index].errorMessage = Self.httpErrorMessage(statusCode: httpResponse.statusCode, fileURL: stagedURL)
            persistRecords()
            try? FileManager.default.removeItem(at: stagedURL.deletingLastPathComponent())
            return
        }

        let record = records[index]
        records[index].state = .preparing
        records[index].localFilePath = stagedURL.path
        persistRecords()

        pendingFinalizations += 1
        let finalizationTask = Task.detached(priority: .utility) {
            Self.finalizeDownloadedFile(stagedURL: stagedURL, record: record)
        }
        Task { @MainActor [weak self] in
            let result = await finalizationTask.value
            self?.applyFinalization(result, recordID: record.id)
        }
    }

    private func applyFinalization(_ result: FTPFileFinalizationResult, recordID: UUID) {
        defer {
            pendingFinalizations = max(0, pendingFinalizations - 1)
            finishBackgroundEventsIfReady()
        }
        guard let index = records.firstIndex(where: { $0.id == recordID }),
              records[index].state != .cancelled else {
            if let path = result.localFilePath {
                Self.removeManagedLocalFileIfNeeded(URL(fileURLWithPath: path))
            }
            return
        }

        records[index].bytesWritten = max(records[index].bytesWritten, result.fileSize ?? 0)
        records[index].totalBytesExpected = records[index].totalBytesExpected ?? result.fileSize
        records[index].progress = result.errorMessage == nil ? 1 : records[index].progress
        records[index].localFilePath = result.localFilePath
        records[index].errorMessage = result.errorMessage
        records[index].state = result.errorMessage == nil ? .completed : .failed
        records[index].isPresentationPending = result.errorMessage == nil && records[index].action == .share
        persistRecords()
    }

    private func fail(taskIdentifier: Int, recordID: String?, error: Error) {
        guard let index = recordIndex(taskIdentifier: taskIdentifier, recordID: recordID),
              records[index].state != .completed else {
            return
        }
        if records[index].state == .cancelled || (error as? URLError)?.code == .cancelled {
            records[index].state = .cancelled
            records[index].errorMessage = "Загрузка отменена пользователем."
        } else {
            records[index].state = .failed
            records[index].errorMessage = Self.userFacingMessage(error)
        }
        persistRecords()
    }

    private func recordIndex(taskIdentifier: Int, recordID: String?) -> Int? {
        if let recordID, let id = UUID(uuidString: recordID),
           let index = records.firstIndex(where: { $0.id == id }) {
            return index
        }
        return records.firstIndex(where: { $0.taskIdentifier == taskIdentifier && $0.state.isActive })
    }

    private func finishBackgroundEvents() {
        backgroundEventsAreWaiting = true
        finishBackgroundEventsIfReady()
    }

    private func finishBackgroundEventsIfReady() {
        guard backgroundEventsAreWaiting, pendingFinalizations == 0 else { return }
        guard (UIApplication.shared.delegate as? LumaWorkAppDelegate)?.finishFTPBackgroundEvents() == true else {
            return
        }
        backgroundEventsAreWaiting = false
    }

    private func persistRecords() {
        let retained = records.filter { record in
            if record.state.isActive { return true }
            guard record.action == .download,
                  record.state == .completed,
                  let path = record.localFilePath else { return false }
            return FileManager.default.fileExists(atPath: path)
        }
        let retainedIDs = Set(retained.map(\.id))
        let history = records.filter { !retainedIDs.contains($0.id) }.prefix(50)
        records = retained + history
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: Self.persistenceKey)
    }

    private static func loadRecords() -> [FTPDownloadRecord] {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
              let records = try? JSONDecoder().decode([FTPDownloadRecord].self, from: data) else {
            return []
        }
        return records
    }

    private static func progress(written: Int64, expected: Int64?) -> Double {
        guard let expected, expected > 0 else { return 0 }
        return min(1, max(0, Double(written) / Double(expected)))
    }

    nonisolated private static func stageDownloadedFile(from temporaryURL: URL, recordID: String?) throws -> URL {
        let identifier = UUID(uuidString: recordID ?? "") ?? UUID()
        let directory = try downloadsDirectory().appendingPathComponent(identifier.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("payload.download")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    nonisolated private static func downloadsDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("FTPDownloads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(values)
        return directory
    }

    nonisolated private static func finalizeDownloadedFile(
        stagedURL: URL,
        record: FTPDownloadRecord
    ) -> FTPFileFinalizationResult {
        var localURL: URL?
        do {
            let namedURL = try moveToNamedLocalFile(stagedURL: stagedURL, fileName: record.fileName)
            localURL = namedURL
            let fileSize = (try? namedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)

            if record.action == .saveToFiles {
                guard let bookmark = record.destinationBookmark else {
                    throw FTPBackgroundDownloadError.message("Папка назначения недоступна.")
                }
                let destination = try copyToSelectedDirectory(
                    localURL: namedURL,
                    fileName: record.fileName,
                    bookmark: bookmark
                )
                try? FileManager.default.removeItem(at: namedURL.deletingLastPathComponent())
                return FTPFileFinalizationResult(
                    localFilePath: destination.path,
                    fileSize: fileSize,
                    errorMessage: nil
                )
            }

            if record.action == .download {
                let destination = try copyToAppDownloadsDirectory(
                    localURL: namedURL,
                    fileName: record.fileName
                )
                try? FileManager.default.removeItem(at: namedURL.deletingLastPathComponent())
                return FTPFileFinalizationResult(
                    localFilePath: destination.path,
                    fileSize: fileSize,
                    errorMessage: nil
                )
            }

            return FTPFileFinalizationResult(
                localFilePath: namedURL.path,
                fileSize: fileSize,
                errorMessage: nil
            )
        } catch {
            return FTPFileFinalizationResult(
                localFilePath: localURL?.path ?? stagedURL.path,
                fileSize: nil,
                errorMessage: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
    }

    nonisolated private static func moveToNamedLocalFile(stagedURL: URL, fileName: String) throws -> URL {
        let safeName = sanitizedFileName(fileName)
        let destination = stagedURL.deletingLastPathComponent().appendingPathComponent(safeName)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: stagedURL, to: destination)
        return destination
    }

    nonisolated private static func removeManagedLocalFileIfNeeded(_ fileURL: URL) {
        guard let root = try? downloadsDirectory().standardizedFileURL else { return }
        let parent = fileURL.deletingLastPathComponent().standardizedFileURL
        guard parent.path.hasPrefix(root.path + "/") else { return }
        try? FileManager.default.removeItem(at: parent)
    }

    nonisolated private static func copyToSelectedDirectory(localURL: URL, fileName: String, bookmark: Data) throws -> URL {
        var isStale = false
        let directory = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        guard !isStale else {
            throw FTPBackgroundDownloadError.message("Доступ к выбранной папке устарел. Выберите её снова.")
        }

        let hasAccess = directory.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { directory.stopAccessingSecurityScopedResource() }
        }

        let destination = availableDestination(in: directory, fileName: fileName)
        try FileManager.default.copyItem(at: localURL, to: destination)
        return destination
    }

    nonisolated private static func copyToAppDownloadsDirectory(localURL: URL, fileName: String) throws -> URL {
        let directory = try userDownloadsDirectory()
        let destination = availableDestination(in: directory, fileName: fileName)
        try FileManager.default.copyItem(at: localURL, to: destination)
        return destination
    }

    nonisolated private static func userDownloadsDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("Загрузки FTP", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    nonisolated private static func availableDestination(in directory: URL, fileName: String) -> URL {
        let safeName = sanitizedFileName(fileName)
        let original = directory.appendingPathComponent(safeName)
        guard FileManager.default.fileExists(atPath: original.path) else { return original }

        let source = URL(fileURLWithPath: safeName)
        let baseName = source.deletingPathExtension().lastPathComponent
        let pathExtension = source.pathExtension
        for index in 2 ... 999 {
            let candidateName = pathExtension.isEmpty
                ? "\(baseName) (\(index))"
                : "\(baseName) (\(index)).\(pathExtension)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return directory.appendingPathComponent("\(UUID().uuidString)-\(safeName)")
    }

    nonisolated private static func sanitizedFileName(_ value: String) -> String {
        let result = value
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "FTP-файл" : result
    }

    private static func httpErrorMessage(statusCode: Int, fileURL: URL) -> String {
        if statusCode == 401 || statusCode == 403 {
            return "Сессия приложения «Инженер» или Wing FTP истекла. Войдите заново и повторите загрузку. HTTP \(statusCode)"
        }
        if let data = try? Data(contentsOf: fileURL),
           let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = (payload["message"] as? String) ?? (payload["error"] as? String),
           !message.isEmpty {
            return "\(message) HTTP \(statusCode)"
        }
        return "FTP не удалось скачать файл. HTTP \(statusCode)"
    }

    private static func userFacingMessage(_ error: Error) -> String {
        if let error = error as? FTPBackgroundDownloadError {
            return error.localizedDescription
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                return "Нет подключения к интернету. Фоновая загрузка не выполнена."
            case .timedOut:
                return "FTP не ответил вовремя. Повторите загрузку."
            case .networkConnectionLost:
                return "Соединение прервано во время загрузки."
            default:
                break
            }
        }
        return appUserFacingErrorMessage(error, fallback: "Не удалось скачать файл.") ?? "Не удалось скачать файл."
    }
}

extension FTPBackgroundDownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        Task { @MainActor [weak self] in
            self?.updateProgress(
                taskIdentifier: downloadTask.taskIdentifier,
                recordID: downloadTask.taskDescription,
                bytesWritten: totalBytesWritten,
                totalBytesExpected: totalBytesExpectedToWrite
            )
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let result = Result {
            try Self.stageDownloadedFile(from: location, recordID: downloadTask.taskDescription)
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch result {
            case .success(let stagedURL):
                self.finish(
                    taskIdentifier: downloadTask.taskIdentifier,
                    recordID: downloadTask.taskDescription,
                    stagedURL: stagedURL,
                    response: downloadTask.response
                )
            case .failure(let error):
                self.fail(
                    taskIdentifier: downloadTask.taskIdentifier,
                    recordID: downloadTask.taskDescription,
                    error: error
                )
            }
        }
    }
}

extension FTPBackgroundDownloadManager: URLSessionDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        Task { @MainActor [weak self] in
            self?.fail(taskIdentifier: task.taskIdentifier, recordID: task.taskDescription, error: error)
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak self] in
            self?.finishBackgroundEvents()
        }
    }
}

private enum FTPBackgroundDownloadError: LocalizedError, Sendable {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): message
        }
    }
}

private struct FTPFileFinalizationResult: Sendable {
    let localFilePath: String?
    let fileSize: Int64?
    let errorMessage: String?
}
