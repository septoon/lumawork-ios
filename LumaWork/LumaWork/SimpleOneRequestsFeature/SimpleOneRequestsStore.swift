import Foundation
import Observation
import OSLog

nonisolated private struct SimpleOneActiveArchiveSnapshot: Codable, Hashable, Sendable {
    var currentUser: SimpleOneUser?
    var activeRequests: [SimpleOneRequestRecord]
    var updatedAt: Date?
}

nonisolated private struct SimpleOneDetailedRequestCacheEntry: Codable, Hashable, Sendable {
    var record: SimpleOneRequestRecord
    var cachedAt: Date
}

nonisolated private struct SimpleOneDetailedRequestCacheSnapshot: Codable, Hashable, Sendable {
    var entries: [String: SimpleOneDetailedRequestCacheEntry]
}

@MainActor
@Observable
final class SimpleOneRequestsStore {
    let service = SimpleOneRequestsService()
    private let usernameStorageKey = "simpleone-username"
    private let detailedRequestCacheLifetime: TimeInterval = 24 * 60 * 60
    private let notificationCoordinator: SimpleOneRequestNotificationCoordinator?

    var username: String
    var currentUser: SimpleOneUser?
    var activeRequests: [SimpleOneRequestRecord] = []
    var closedRequests: [SimpleOneRequestRecord] = []
    var isLoading = false
    var isSigningIn = false
    var errorMessage: String?
    var notice: String?
    var lastUpdatedAt: Date?
    private(set) var activeRequestsRevision: UInt64 = 0
    private(set) var refreshingDetailRequestIDs: Set<String> = []

    private var authKey: String?
    private var detailedRequestCache: [String: SimpleOneDetailedRequestCacheEntry] = [:]
    @ObservationIgnored private var refreshTask: Task<Void, Error>?
    @ObservationIgnored private var refreshTaskToken: UUID?
    @ObservationIgnored private var notificationTask: Task<Void, Never>?
    @ObservationIgnored private var detailedRequestTasks: [String: Task<SimpleOneRequestRecord, Error>] = [:]

    init(
        notificationCoordinator: SimpleOneRequestNotificationCoordinator? = nil,
        automaticallyRefresh: Bool = true
    ) {
        self.notificationCoordinator = notificationCoordinator
        username = UserDefaults.standard.string(forKey: usernameStorageKey) ?? ""
        loadArchive()
        loadDetailedRequestCache()
        authKey = SimpleOneSessionKeychain.readAuthKey()
        if automaticallyRefresh, authKey != nil {
            Task {
                await bootstrapStoredSession()
            }
        }
    }

    var isAuthorized: Bool {
        authKey != nil
    }

    var browserAuthKey: String? {
        authKey
    }

    var needsInitialSnapshot: Bool {
        isAuthorized && lastUpdatedAt == nil
    }

    func isRefreshingStatus(for record: SimpleOneRequestRecord) -> Bool {
        refreshingDetailRequestIDs.contains(record.id)
    }

    func signIn(password: String) async {
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty, !trimmedPassword.isEmpty else {
            errorMessage = "Укажите логин и пароль SimpleOne."
            return
        }

        isSigningIn = true
        isLoading = true
        errorMessage = nil
        notice = nil
        defer {
            isSigningIn = false
            isLoading = false
        }

        do {
            let authKey = try await service.login(username: trimmedUsername, password: trimmedPassword)
            try SimpleOneSessionKeychain.saveAuthKey(authKey)
            UserDefaults.standard.set(trimmedUsername, forKey: usernameStorageKey)
            self.authKey = authKey
            let previousUserID = currentUser?.sysID
            let fetchedUser = try await service.fetchCurrentUser(authKey: authKey)
            if let previousUserID, !previousUserID.isEmpty, previousUserID != fetchedUser.sysID {
                activeRequests = []
                activeRequestsRevision &+= 1
                lastUpdatedAt = nil
                detailedRequestCache = [:]
            }
            currentUser = fetchedUser
            try await refreshRequests(authKey: authKey)
            notice = "SimpleOne подключен."
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
            if case .domain = AppErrorPresentation.classification(for: error) {
                signOut(clearUsername: false)
            }
        }
    }

    func refresh(showsNetworkBanner: Bool = true) async {
        guard let authKey else {
            errorMessage = SimpleOneServiceError.missingCredentials.errorDescription
            return
        }

        if let refreshTask {
            _ = try? await refreshTask.value
            return
        }

        isLoading = true
        errorMessage = nil
        notice = nil
        let token = UUID()
        refreshTaskToken = token
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            if currentUser == nil {
                currentUser = try await service.fetchCurrentUser(authKey: authKey)
            }
            try await refreshRequests(authKey: authKey)
        }
        refreshTask = task
        defer {
            if refreshTaskToken == token {
                refreshTask = nil
                refreshTaskToken = nil
                isLoading = false
            }
        }

        do {
            try await task.value
        } catch is CancellationError {
            notice = nil
        } catch SimpleOneServiceError.unauthorized {
            signOut(clearUsername: false)
            errorMessage = SimpleOneServiceError.unauthorized.errorDescription
        } catch {
            errorMessage = appUserFacingErrorMessage(
                error,
                showsNetworkBanner: showsNetworkBanner
            )
        }
    }

    func signOut(clearUsername: Bool = false) {
        refreshTask?.cancel()
        refreshTask = nil
        refreshTaskToken = nil
        notificationTask?.cancel()
        notificationTask = nil
        for task in detailedRequestTasks.values {
            task.cancel()
        }
        detailedRequestTasks = [:]
        if !refreshingDetailRequestIDs.isEmpty {
            refreshingDetailRequestIDs = []
            activeRequestsRevision &+= 1
        }
        isLoading = false
        SimpleOneSessionKeychain.deleteAuthKey()
        authKey = nil
        if clearUsername {
            username = ""
            UserDefaults.standard.removeObject(forKey: usernameStorageKey)
        }
    }

    func fetchRequest(terminalID: String) async throws -> SimpleOneRequestRecord? {
        let records = try await fetchRequests(terminalID: terminalID)
        let normalizedTerminalID = terminalID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return records.first { record in
            record.terminalID
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .contains(normalizedTerminalID)
        } ?? records.first
    }

    func fetchRequests(terminalID: String) async throws -> [SimpleOneRequestRecord] {
        try await fetchRequests(terminalID: terminalID, includeDetails: false)
    }

    func fetchRequests(terminalID: String, includeDetails: Bool) async throws -> [SimpleOneRequestRecord] {
        guard let authKey else {
            throw SimpleOneServiceError.missingCredentials
        }

        do {
            return try await service.fetchRequests(
                terminalID: terminalID,
                authKey: authKey,
                includeDetails: includeDetails
            )
        } catch SimpleOneServiceError.unauthorized {
            signOut(clearUsername: false)
            throw SimpleOneServiceError.unauthorized
        }
    }

    func fetchClosedRequestsForCurrentUser(
        onProgress: @escaping @Sendable (Int) -> Void = { _ in }
    ) async throws -> [SimpleOneRequestRecord] {
        guard let authKey else {
            throw SimpleOneServiceError.missingCredentials
        }

        do {
            if currentUser == nil {
                currentUser = try await service.fetchCurrentUser(authKey: authKey)
            }
            guard let currentUser, !currentUser.sysID.isEmpty else {
                throw SimpleOneServiceError.invalidResponse
            }
            return try await service.fetchClosedRequests(
                userID: currentUser.sysID,
                authKey: authKey,
                onProgress: onProgress
            )
        } catch SimpleOneServiceError.unauthorized {
            signOut(clearUsername: false)
            throw SimpleOneServiceError.unauthorized
        }
    }

    func fetchClosedRequestsPageForCurrentUser(
        page: Int,
        perPage: Int
    ) async throws -> SimpleOnePagedRequestRecords {
        guard let authKey else {
            throw SimpleOneServiceError.missingCredentials
        }

        do {
            if currentUser == nil {
                currentUser = try await service.fetchCurrentUser(authKey: authKey)
            }
            guard let currentUser, !currentUser.sysID.isEmpty else {
                throw SimpleOneServiceError.invalidResponse
            }
            return try await service.fetchClosedRequestsPage(
                userID: currentUser.sysID,
                authKey: authKey,
                page: page,
                perPage: perPage
            )
        } catch SimpleOneServiceError.unauthorized {
            signOut(clearUsername: false)
            throw SimpleOneServiceError.unauthorized
        }
    }

    func exportClosedRequestsXLSXForCurrentUser() async throws -> SimpleOneExportedFile {
        guard let authKey else {
            throw SimpleOneServiceError.missingCredentials
        }

        do {
            if currentUser == nil {
                currentUser = try await service.fetchCurrentUser(authKey: authKey)
            }
            guard let currentUser, !currentUser.sysID.isEmpty else {
                throw SimpleOneServiceError.invalidResponse
            }
            return try await service.exportClosedRequestsXLSX(
                userID: currentUser.sysID,
                authKey: authKey
            )
        } catch SimpleOneServiceError.unauthorized {
            signOut(clearUsername: false)
            throw SimpleOneServiceError.unauthorized
        }
    }

    func exportTimeReportXLSXForCurrentUser() async throws -> SimpleOneExportedFile {
        guard let authKey else {
            throw SimpleOneServiceError.missingCredentials
        }

        do {
            if currentUser == nil {
                currentUser = try await service.fetchCurrentUser(authKey: authKey)
            }
            guard let currentUser, !currentUser.sysID.isEmpty else {
                throw SimpleOneServiceError.invalidResponse
            }
            return try await service.exportTimeReportXLSX(
                userID: currentUser.sysID,
                authKey: authKey
            )
        } catch SimpleOneServiceError.unauthorized {
            signOut(clearUsername: false)
            throw SimpleOneServiceError.unauthorized
        }
    }

    func fetchTimeReportEntries(
        onProgress: @escaping @Sendable (Int) -> Void = { _ in }
    ) async throws -> [TimeReportEntry] {
        guard let authKey else {
            throw SimpleOneServiceError.missingCredentials
        }

        do {
            return try await service.fetchTimeReportEntries(
                authKey: authKey,
                onProgress: onProgress
            )
        } catch SimpleOneServiceError.unauthorized {
            signOut(clearUsername: false)
            throw SimpleOneServiceError.unauthorized
        }
    }

    func fetchCoordinationRequests(
        region: CoordinationRegion,
        includesDetails: Bool = true
    ) async throws -> [SimpleOneRequestRecord] {
        guard let authKey else {
            throw SimpleOneServiceError.missingCredentials
        }

        do {
            let listedRequests = try await service.fetchCoordinationRequests(
                region: region,
                authKey: authKey
            )
            guard includesDetails else {
                return listedRequests.map { record in
                    guard let cached = detailedRequestCache[record.id],
                          isDetailedRequestCacheEntryFresh(cached, comparedTo: record) else { return record }
                    return preservingAssignedUserID(in: cached.record, fallback: record)
                }
            }
            return try await hydrateRequestDetails(listedRequests, authKey: authKey, allowsPartialResults: true)
        } catch SimpleOneServiceError.unauthorized {
            signOut(clearUsername: false)
            throw SimpleOneServiceError.unauthorized
        }
    }

    func fetchGroupClosedRequestsPage(
        page: Int,
        perPage: Int,
        newestFirst: Bool = false
    ) async throws -> SimpleOnePagedRequestRecords {
        guard let authKey else { throw SimpleOneServiceError.missingCredentials }
        do {
            return try await service.fetchGroupClosedRequestsPage(
                authKey: authKey,
                page: page,
                perPage: perPage,
                newestFirst: newestFirst
            )
        } catch SimpleOneServiceError.unauthorized {
            signOut(clearUsername: false)
            throw SimpleOneServiceError.unauthorized
        }
    }

    func fetchCoordinationDetails(_ records: [SimpleOneRequestRecord]) async throws -> [SimpleOneRequestRecord] {
        guard let authKey else { throw SimpleOneServiceError.missingCredentials }
        return try await hydrateRequestDetails(records, authKey: authKey, allowsPartialResults: true)
    }

    func coordinationRequestsRequiringDetails(
        _ records: [SimpleOneRequestRecord]
    ) -> [SimpleOneRequestRecord] {
        pruneExpiredDetailedRequestCache()
        return records.filter { record in
            guard let cached = detailedRequestCache[record.id] else { return true }
            return !isDetailedRequestCacheEntryFresh(cached, comparedTo: record)
        }
    }

    func fetchReturnEquipmentRequestsForCurrentUser() async throws -> [SimpleOneRequestRecord] {
        guard let authKey else {
            throw SimpleOneServiceError.missingCredentials
        }

        do {
            if currentUser == nil {
                currentUser = try await service.fetchCurrentUser(authKey: authKey)
            }
            guard let currentUser, !currentUser.sysID.isEmpty else {
                throw SimpleOneServiceError.invalidResponse
            }
            let listedRequests = try await service.fetchReturnEquipmentRequests(
                userID: currentUser.sysID,
                authKey: authKey
            )
            return try await hydrateRequestDetails(listedRequests, authKey: authKey, allowsPartialResults: true)
        } catch SimpleOneServiceError.unauthorized {
            signOut(clearUsername: false)
            throw SimpleOneServiceError.unauthorized
        }
    }

    func fetchDetailedRequest(
        _ record: SimpleOneRequestRecord,
        updatesActiveRequests: Bool = true,
        usesCache: Bool = true,
        allowsCachedFallback: Bool = true,
        persistsCache: Bool = true
    ) async throws -> SimpleOneRequestRecord {
        guard let authKey else {
            throw SimpleOneServiceError.missingCredentials
        }

        let cached = usesCache ? detailedRequestCache[record.id] : nil
        if let cached, isDetailedRequestCacheEntryFresh(cached, comparedTo: record) {
            return preservingAssignedUserID(in: cached.record, fallback: record)
        }

        let taskKey = "\(record.id)|\(record.sysUpdatedAt ?? "")"
        if let existingTask = detailedRequestTasks[taskKey] {
            return try await existingTask.value
        }

        let detailTask = Task {
            try await service.fetchRequestDetails(record: record, authKey: authKey)
        }
        detailedRequestTasks[taskKey] = detailTask
        defer {
            detailedRequestTasks[taskKey] = nil
        }

        do {
            let detailedRecord = try await detailTask.value
            guard self.authKey == authKey else { throw CancellationError() }
            if updatesActiveRequests {
                activeRequests = activeRequests.map { existingRecord in
                    existingRecord.id == detailedRecord.id ? detailedRecord : existingRecord
                }
                activeRequestsRevision &+= 1
                saveArchive()
            }
            detailedRequestCache[record.id] = SimpleOneDetailedRequestCacheEntry(
                record: detailedRecord,
                cachedAt: Date()
            )
            if persistsCache { saveDetailedRequestCache() }
            return detailedRecord
        } catch SimpleOneServiceError.unauthorized {
            signOut(clearUsername: false)
            throw SimpleOneServiceError.unauthorized
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            if allowsCachedFallback, let cached {
                return preservingAssignedUserID(in: cached.record, fallback: record)
            }
            throw error
        }
    }

    func issueEquipment(_ record: SimpleOneRequestRecord) async throws -> SimpleOneRequestRecord {
        guard let authKey else {
            throw SimpleOneServiceError.missingCredentials
        }

        do {
            let updatedRecord = try await service.issueEquipment(record: record, authKey: authKey)
            activeRequests = activeRequests.map { existingRecord in
                existingRecord.id == updatedRecord.id ? updatedRecord : existingRecord
            }
            activeRequestsRevision &+= 1
            detailedRequestCache[updatedRecord.id] = SimpleOneDetailedRequestCacheEntry(
                record: updatedRecord,
                cachedAt: Date()
            )
            lastUpdatedAt = Date()
            saveArchive()
            saveDetailedRequestCache()
            return updatedRecord
        } catch SimpleOneServiceError.unauthorized {
            signOut(clearUsername: false)
            throw SimpleOneServiceError.unauthorized
        }
    }

    private func bootstrapStoredSession() async {
        await refresh()
    }

    private func refreshRequests(authKey: String) async throws {
        guard let currentUser, !currentUser.sysID.isEmpty else {
            throw SimpleOneServiceError.invalidResponse
        }
        let previousRequests = activeRequests
        let isInitialSnapshot = lastUpdatedAt == nil
        let listedRequests = try await service.fetchActiveRequests(
            userID: currentUser.sysID,
            authKey: authKey
        )
        pruneExpiredDetailedRequestCache()

        var initiallyVisibleRequests: [SimpleOneRequestRecord] = []
        var requestsRequiringDetails: [SimpleOneRequestRecord] = []
        initiallyVisibleRequests.reserveCapacity(listedRequests.count)
        requestsRequiringDetails.reserveCapacity(listedRequests.count)
        for record in listedRequests {
            if let cached = detailedRequestCache[record.id],
               isDetailedRequestCacheEntryFresh(cached, comparedTo: record) {
                initiallyVisibleRequests.append(
                    preservingAssignedUserID(in: cached.record, fallback: record)
                )
            } else {
                initiallyVisibleRequests.append(record)
                requestsRequiringDetails.append(record)
            }
        }

        activeRequests = initiallyVisibleRequests
        refreshingDetailRequestIDs = Set(requestsRequiringDetails.map(\.id))
        activeRequestsRevision &+= 1
        closedRequests = []
        lastUpdatedAt = Date()
        saveArchive()

        let refreshedRequests = try await hydrateActiveRequestDetailsProgressively(
            requestsRequiringDetails,
            authKey: authKey
        )
        saveArchive()
        RequestNotificationsBackgroundRefresh.schedule()
        scheduleNotificationProcessing(
            previousRequests: previousRequests,
            refreshedRequests: refreshedRequests,
            isInitialSnapshot: isInitialSnapshot,
            authKey: authKey
        )
    }

    private func hydrateActiveRequestDetailsProgressively(
        _ records: [SimpleOneRequestRecord],
        authKey: String
    ) async throws -> [SimpleOneRequestRecord] {
        guard !records.isEmpty else {
            refreshingDetailRequestIDs = []
            return activeRequests
        }

        defer {
            if !refreshingDetailRequestIDs.isEmpty {
                refreshingDetailRequestIDs = []
                activeRequestsRevision &+= 1
            }
        }

        try await withThrowingTaskGroup(of: SimpleOneRequestRecord.self) { group in
            var iterator = records.makeIterator()

            func enqueue(_ record: SimpleOneRequestRecord) {
                group.addTask { @MainActor in
                    try Task.checkCancellation()
                    do {
                        return try await self.fetchDetailedRequest(
                            record,
                            updatesActiveRequests: false,
                            allowsCachedFallback: false,
                            persistsCache: false
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch SimpleOneServiceError.unauthorized {
                        throw SimpleOneServiceError.unauthorized
                    } catch {
                        return record
                    }
                }
            }

            for _ in 0..<min(4, records.count) {
                if let record = iterator.next() {
                    enqueue(record)
                }
            }

            while let record = try await group.next() {
                guard self.authKey == authKey else { throw CancellationError() }
                try Task.checkCancellation()

                if let index = activeRequests.firstIndex(where: { $0.id == record.id }) {
                    activeRequests[index] = record
                }
                refreshingDetailRequestIDs.remove(record.id)
                activeRequestsRevision &+= 1

                if let next = iterator.next() {
                    enqueue(next)
                }
            }
        }

        saveDetailedRequestCache()
        return activeRequests
    }

    private func hydrateRequestDetails(
        _ listedRequests: [SimpleOneRequestRecord],
        authKey: String,
        allowsPartialResults: Bool = false
    ) async throws -> [SimpleOneRequestRecord] {
        pruneExpiredDetailedRequestCache()

        var recordsByID: [String: SimpleOneRequestRecord] = [:]
        var recordsRequiringDetails: [SimpleOneRequestRecord] = []
        recordsByID.reserveCapacity(listedRequests.count)
        recordsRequiringDetails.reserveCapacity(listedRequests.count)

        for record in listedRequests {
            if let cached = detailedRequestCache[record.id],
               isDetailedRequestCacheEntryFresh(cached, comparedTo: record) {
                recordsByID[record.id] = preservingAssignedUserID(
                    in: cached.record,
                    fallback: record
                )
            } else {
                recordsRequiringDetails.append(record)
            }
        }

        if !recordsRequiringDetails.isEmpty {
            let hydratedRecords = try await withThrowingTaskGroup(of: SimpleOneRequestRecord.self) { group in
                var iterator = recordsRequiringDetails.makeIterator()
                func enqueue(_ record: SimpleOneRequestRecord) {
                    group.addTask { @MainActor in
                        try Task.checkCancellation()
                        do {
                            return try await self.fetchDetailedRequest(
                                record,
                                updatesActiveRequests: false,
                                allowsCachedFallback: false,
                                persistsCache: false
                            )
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch SimpleOneServiceError.unauthorized {
                            throw SimpleOneServiceError.unauthorized
                        } catch {
                            guard allowsPartialResults else { throw error }
                            return record
                        }
                    }
                }
                for _ in 0..<min(4, recordsRequiringDetails.count) {
                    if let record = iterator.next() { enqueue(record) }
                }
                var result: [SimpleOneRequestRecord] = []
                while let record = try await group.next() {
                    result.append(record)
                    if let next = iterator.next() { enqueue(next) }
                }
                return result
            }
            guard self.authKey == authKey else { throw CancellationError() }
            try Task.checkCancellation()
            for record in hydratedRecords {
                recordsByID[record.id] = record
            }
            saveDetailedRequestCache()
        }

        return listedRequests.map { record in
            recordsByID[record.id] ?? record
        }
    }

    private func scheduleNotificationProcessing(
        previousRequests: [SimpleOneRequestRecord],
        refreshedRequests: [SimpleOneRequestRecord],
        isInitialSnapshot: Bool,
        authKey: String
    ) {
        guard notificationCoordinator != nil else { return }
        notificationTask?.cancel()
        notificationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var requestsForComparison = refreshedRequests

            if !previousRequests.isEmpty {
                let refreshedIDs = Set(refreshedRequests.map(\.id))
                let removedRequests = previousRequests.filter { !refreshedIDs.contains($0.id) }
                do {
                    let hydratedRemovedRequests = try await service.detailedRecords(
                        removedRequests,
                        authKey: authKey,
                        maximumConcurrentRequests: 4
                    )
                    try Task.checkCancellation()
                    requestsForComparison.append(contentsOf: hydratedRemovedRequests.filter { hydrated in
                        guard let previous = previousRequests.first(where: { $0.id == hydrated.id }) else {
                            return false
                        }
                        return previous.assignedUser.trimmingCharacters(in: .whitespacesAndNewlines)
                            != hydrated.assignedUser.trimmingCharacters(in: .whitespacesAndNewlines)
                    })
                } catch is CancellationError {
                    return
                } catch {
                    // The visible refresh is already complete; notification enrichment is best-effort.
                }
            }

            guard !Task.isCancelled else { return }
            await notificationCoordinator?.process(
                previous: previousRequests,
                current: requestsForComparison,
                isInitialSnapshot: isInitialSnapshot
            )
        }
    }

    private func loadArchive() {
        guard let data = try? Data(contentsOf: Self.archiveFileURL()),
              let snapshot = try? JSONDecoder().decode(SimpleOneActiveArchiveSnapshot.self, from: data) else {
            return
        }
        currentUser = snapshot.currentUser
        activeRequests = snapshot.activeRequests
        activeRequestsRevision &+= 1
        closedRequests = []
        lastUpdatedAt = snapshot.updatedAt
    }

    private func loadDetailedRequestCache() {
        guard let data = try? Data(contentsOf: Self.detailedRequestCacheFileURL()),
              let snapshot = try? JSONDecoder().decode(SimpleOneDetailedRequestCacheSnapshot.self, from: data) else {
            return
        }

        detailedRequestCache = snapshot.entries
    }

    private func saveDetailedRequestCache() {
        let snapshot = SimpleOneDetailedRequestCacheSnapshot(entries: detailedRequestCache)
        let url = Self.detailedRequestCacheFileURL()

        Task.detached(priority: .utility) {
            let logger = Logger(subsystem: "LumaWork", category: "SimpleOneRequestsStore")
            do {
                let data = try JSONEncoder().encode(snapshot)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: url, options: [.atomic])
            } catch {
                logger.error("SimpleOne details cache save failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func pruneExpiredDetailedRequestCache() {
        let now = Date()
        detailedRequestCache = detailedRequestCache.filter { _, entry in
            let version = entry.record.sysUpdatedAt?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !version.isEmpty
                || now.timeIntervalSince(entry.cachedAt) < detailedRequestCacheLifetime
        }
    }

    private func isDetailedRequestCacheEntryFresh(
        _ entry: SimpleOneDetailedRequestCacheEntry,
        comparedTo record: SimpleOneRequestRecord
    ) -> Bool {
        SimpleOneDetailedRequestCachePolicy.isFresh(
            cachedAt: entry.cachedAt,
            cachedVersion: entry.record.sysUpdatedAt ?? "",
            currentVersion: record.sysUpdatedAt ?? "",
            lifetime: detailedRequestCacheLifetime
        )
    }

    private func preservingAssignedUserID(
        in detailedRecord: SimpleOneRequestRecord,
        fallback: SimpleOneRequestRecord
    ) -> SimpleOneRequestRecord {
        let currentID = detailedRecord.assignedUserID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard currentID.isEmpty,
              let fallbackID = fallback.assignedUserID,
              !fallbackID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return detailedRecord
        }

        var record = detailedRecord
        record.assignedUserID = fallbackID
        return record
    }

    private func saveArchive() {
        let snapshot = SimpleOneArchiveSnapshot(
            currentUser: currentUser,
            activeRequests: activeRequests,
            closedRequests: [],
            updatedAt: lastUpdatedAt
        )
        let url = Self.archiveFileURL()

        Task.detached(priority: .utility) {
            let logger = Logger(subsystem: "LumaWork", category: "SimpleOneRequestsStore")
            do {
                let data = try JSONEncoder().encode(snapshot)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: url, options: [.atomic])
            } catch {
                logger.error("SimpleOne archive save failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    nonisolated private static func archiveFileURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("LumaWork", isDirectory: true)
            .appendingPathComponent("simpleone-archive.json", isDirectory: false)
    }

    nonisolated private static func detailedRequestCacheFileURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("LumaWork", isDirectory: true)
            .appendingPathComponent("simpleone-request-details-cache.json", isDirectory: false)
    }
}
