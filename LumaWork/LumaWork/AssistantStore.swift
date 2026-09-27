import Foundation
import Observation

@MainActor
@Observable
final class AssistantStore {
    enum Activity: Equatable {
        case compressingContext
        case thinking
        case loadingSources
    }

    private struct CachedState: Codable {
        var conversations: [AssistantAPIConversation]
        var conversationID: UUID
        var messages: [AssistantAPIMessage]
    }

    private struct RetryableRequest {
        let message: String
        let image: AssistantPreparedImagePayload?
        let document: AssistantPreparedDocumentPayload?
        let currentScreen: String
        let requestID: UUID
        let conversationID: UUID
    }

    private let api: AssistantAPI
    private let toolExecutor: AssistantLocalToolExecutor
    private let cacheKey: String
    @ObservationIgnored private var generationTask: Task<Void, Never>?

    private(set) var conversations: [AssistantAPIConversation] = []
    private(set) var conversationID = UUID()
    private(set) var messages: [AssistantAPIMessage] = []
    private(set) var isLoadingHistory = false
    private(set) var isLoadingMessages = false
    private(set) var isSending = false
    private(set) var activity: Activity?
    private(set) var errorMessage: String?
    private var activeRequestID: UUID?
    private var messageLoadGeneration = 0
    private var retryableRequest: RetryableRequest?

    var isConversationFull: Bool {
        currentConversation?.isFull == true
    }

    var hasActiveConversation: Bool {
        !messages.isEmpty || currentConversation != nil
    }

    var willCompressOnNextRun: Bool {
        currentConversation?.willCompressOnNextRun == true
    }

    var canRetryLastRequest: Bool {
        retryableRequest?.conversationID == conversationID && !isSending
    }

    func clearError() {
        errorMessage = nil
    }

    func presentError(_ error: Error, fallback: String) {
        guard !AppErrorPresentation.isCancellation(error) else { return }
        presentErrorMessage(Self.inlineErrorMessage(error) ?? fallback)
    }

    private var currentConversation: AssistantAPIConversation? {
        conversations.first { $0.id == conversationID }
    }

    init(
        api: AssistantAPI,
        userID: String?,
        toolExecutor: AssistantLocalToolExecutor
    ) {
        self.api = api
        self.toolExecutor = toolExecutor
        cacheKey = AppOfflineSnapshotStore.scopedKey("assistant-state-v1", userID: userID)
        if let snapshot = AppOfflineSnapshotStore.load(CachedState.self, key: cacheKey) {
            conversations = snapshot.value.conversations
            conversationID = snapshot.value.conversationID
            messages = snapshot.value.messages
        }
    }

    func loadConversations(force: Bool = false) async {
        guard !isLoadingHistory else { return }
        guard force || conversations.isEmpty else {
            Task { await refreshConversationsQuietly() }
            return
        }
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do {
            conversations = try await api.conversations().conversations
            saveCache()
        } catch is CancellationError {
        } catch {
            if conversations.isEmpty, let message = Self.inlineErrorMessage(error) {
                presentErrorMessage(message)
            }
        }
    }

    func loadCurrentMessages(force: Bool = false) async {
        let targetConversationID = conversationID
        guard conversations.contains(where: { $0.id == targetConversationID }) else { return }
        guard force || messages.isEmpty else { return }
        _ = await loadMessages(conversationID: targetConversationID)
    }

    func openConversation(_ id: UUID) async -> Bool {
        guard id != conversationID || messages.isEmpty else { return true }
        stopGeneration()
        retryableRequest = nil
        let previousConversationID = conversationID
        let previousMessages = messages
        conversationID = id
        messages = []
        errorMessage = nil
        let opened = await loadMessages(conversationID: id)
        guard opened else {
            conversationID = previousConversationID
            messages = previousMessages
            saveCache()
            return false
        }
        return true
    }

    func startNewConversation() {
        stopGeneration()
        retryableRequest = nil
        messageLoadGeneration += 1
        isLoadingMessages = false
        conversationID = UUID()
        messages = []
        errorMessage = nil
        saveCache()
    }

    func stopGeneration() {
        guard isSending else { return }
        activeRequestID = nil
        retryableRequest = nil
        generationTask?.cancel()
        generationTask = nil
        isSending = false
        activity = nil
        saveCache()
    }

    @discardableResult
    func deleteConversation(_ id: UUID) async -> Bool {
        do {
            try await api.deleteConversation(id)
            removeLocalConversation(id)
            AppBannerCenter.shared.show("Чат удалён.", style: .success)
            return true
        } catch is CancellationError {
            return false
        } catch {
            if Self.isNotFound(error) {
                removeLocalConversation(id)
                AppBannerCenter.shared.show("Чат удалён.", style: .success)
                return true
            }
            if let message = Self.inlineErrorMessage(error) {
                presentErrorMessage(message)
            }
            return false
        }
    }

    func renameConversation(_ id: UUID, title rawTitle: String) async -> Bool {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        do {
            try await api.renameConversation(id, title: String(title.prefix(80)))
            guard let index = conversations.firstIndex(where: { $0.id == id }) else { return true }
            let conversation = conversations[index]
            conversations[index] = conversation.updating(title: String(title.prefix(80)))
            saveCache()
            return true
        } catch is CancellationError {
            return false
        } catch {
            if let message = Self.inlineErrorMessage(error) {
                presentErrorMessage(message)
            }
            return false
        }
    }

    func send(
        message rawMessage: String,
        image: AssistantPreparedImagePayload?,
        document: AssistantPreparedDocumentPayload? = nil,
        currentScreen: String = "assistant"
    ) async {
        let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSending, !isConversationFull, !message.isEmpty || image != nil || document != nil else { return }

        let requestID = UUID()
        let submittedConversationID = conversationID
        let displayMessage = message.isEmpty
            ? document.map { "Документ: \($0.fileName)" } ?? "Изображение"
            : message
        let attachmentMetadata: AssistantJSONValue? = if let document {
            .object([
                "kind": .string("document"),
                "fileName": .string(document.fileName),
                "mimeType": .string(document.mimeType),
                "wasTruncated": .bool(document.wasTruncated)
            ])
        } else if image != nil {
            .object(["kind": .string("image")])
        } else {
            nil
        }
        messages.append(AssistantAPIMessage(
            id: "local-user-\(requestID.uuidString)",
            requestId: requestID.uuidString.lowercased(),
            role: "user",
            content: displayMessage,
            attachmentMeta: attachmentMetadata,
            createdAt: Self.nowString()
        ))
        updateLocalConversation(message: displayMessage)
        saveCache()

        isSending = true
        activity = willCompressOnNextRun ? .compressingContext : .thinking
        errorMessage = nil
        activeRequestID = requestID
        retryableRequest = nil

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performSend(
                message: message,
                image: image,
                document: document,
                currentScreen: currentScreen,
                requestID: requestID,
                conversationID: submittedConversationID
            )
        }
        generationTask = task
        await task.value
    }

    func retryLastFailedRequest() async {
        guard !isSending,
              let request = retryableRequest,
              request.conversationID == conversationID else { return }

        let requestKey = request.requestID.uuidString.lowercased()
        messages.removeAll {
            $0.role == "assistant" && $0.requestId?.lowercased() == requestKey
        }
        isSending = true
        activity = willCompressOnNextRun ? .compressingContext : .thinking
        errorMessage = nil
        activeRequestID = request.requestID
        retryableRequest = nil
        saveCache()

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performSend(
                message: request.message,
                image: request.image,
                document: request.document,
                currentScreen: request.currentScreen,
                requestID: request.requestID,
                conversationID: request.conversationID
            )
        }
        generationTask = task
        await task.value
    }

    private func performSend(
        message: String,
        image: AssistantPreparedImagePayload?,
        document: AssistantPreparedDocumentPayload?,
        currentScreen: String,
        requestID: UUID,
        conversationID submittedConversationID: UUID
    ) async {
        defer { finishGeneration(requestID: requestID) }

        var toolResults: [AssistantAPIToolResult]?
        do {
            for cycle in 0 ... 2 {
                let cycleImage = cycle == 0 ? image : nil
                let envelope: AssistantAPIRunEnvelope
                do {
                    envelope = try await api.runStreaming(
                        message: message,
                        conversationID: submittedConversationID,
                        requestID: requestID,
                        currentScreen: currentScreen,
                        image: cycleImage,
                        document: document,
                        toolResults: toolResults
                    ) { [weak self] delta in
                        guard self?.isActive(requestID, conversationID: submittedConversationID) == true else { return }
                        self?.appendAssistantDelta(delta, requestID: requestID)
                    }
                } catch {
                    guard isActive(requestID, conversationID: submittedConversationID) else { throw error }
                    envelope = try await api.run(
                        message: message,
                        conversationID: submittedConversationID,
                        requestID: requestID,
                        currentScreen: currentScreen,
                        image: cycleImage,
                        document: document,
                        toolResults: toolResults
                    )
                }
                guard isActive(requestID, conversationID: submittedConversationID) else { return }
                applyServerTimestamps(envelope.messageTimestamps, requestID: requestID)
                switch envelope.result {
                case .answer(let text, let truncated, let sources, let knowledge, _, let status):
                    applyStatus(status, conversationID: submittedConversationID)
                    upsertAssistantMessage(
                        text: truncated ? "\(text)\n\nОтвет сокращён до установленного лимита." : text,
                        requestID: requestID,
                        sources: sources,
                        knowledge: knowledge,
                        createdAt: envelope.messageTimestamps?.assistant
                    )
                    retryableRequest = nil
                    return
                case .blocked(let text, let status):
                    applyStatus(status, conversationID: submittedConversationID)
                    upsertAssistantMessage(
                        text: text,
                        requestID: requestID,
                        createdAt: envelope.messageTimestamps?.assistant
                    )
                    retryableRequest = nil
                    return
                case .toolRequest(let requests, _, let status):
                    applyStatus(status, conversationID: submittedConversationID)
                    guard cycle < 2, !requests.isEmpty else {
                        throw AppServiceError.message("Не удалось получить необходимые данные за два шага.")
                    }
                    activity = .loadingSources
                    toolResults = try await toolExecutor.execute(requests)
                    guard isActive(requestID, conversationID: submittedConversationID) else { return }
                    activity = .thinking
                case .conversationFull(_, let status):
                    messages.removeAll { $0.id == "local-user-\(requestID.uuidString)" }
                    messages.removeAll {
                        $0.requestId == requestID.uuidString.lowercased() && $0.role == "assistant"
                    }
                    applyStatus(status, conversationID: submittedConversationID)
                    retryableRequest = nil
                    saveCache()
                    return
                }
            }
        } catch is CancellationError {
            guard ownsActiveRequest(requestID, conversationID: submittedConversationID) else { return }
            let recovered = await Task { @MainActor [weak self] in
                await self?.recoverCompletedResponse(
                    requestID: requestID,
                    conversationID: submittedConversationID
                ) ?? false
            }.value
            if recovered {
                retryableRequest = nil
            } else if ownsActiveRequest(requestID, conversationID: submittedConversationID) {
                retryableRequest = RetryableRequest(
                    message: message,
                    image: image,
                    document: document,
                    currentScreen: currentScreen,
                    requestID: requestID,
                    conversationID: submittedConversationID
                )
                presentErrorMessage("Не удалось получить ответ. Повторите запрос.", offersRetry: true)
                saveCache()
            }
        } catch {
            guard isActive(requestID, conversationID: submittedConversationID) else { return }
            if await recoverCompletedResponse(requestID: requestID, conversationID: submittedConversationID) {
                retryableRequest = nil
                return
            }
            retryableRequest = RetryableRequest(
                message: message,
                image: image,
                document: document,
                currentScreen: currentScreen,
                requestID: requestID,
                conversationID: submittedConversationID
            )
            presentErrorMessage(
                Self.inlineErrorMessage(error) ?? "Не удалось получить ответ. Повторите запрос.",
                offersRetry: true
            )
            saveCache()
        }
    }

    private func recoverCompletedResponse(requestID: UUID, conversationID targetConversationID: UUID) async -> Bool {
        let requestKey = requestID.uuidString.lowercased()
        for delay in [250, 500, 750, 1_000] {
            try? await Task.sleep(for: .milliseconds(delay))
            guard isActive(requestID, conversationID: targetConversationID) else { return false }
            do {
                let page = try await api.messages(conversationID: targetConversationID)
                guard page.messages.contains(where: {
                    $0.role == "assistant" && $0.requestId?.lowercased() == requestKey
                }) else { continue }
                guard isActive(requestID, conversationID: targetConversationID) else { return false }
                messages = page.messages
                applyStatus(page.conversation, conversationID: targetConversationID)
                errorMessage = nil
                saveCache()
                return true
            } catch {
                continue
            }
        }
        return false
    }

    private func isActive(_ requestID: UUID, conversationID targetConversationID: UUID) -> Bool {
        ownsActiveRequest(requestID, conversationID: targetConversationID) && !Task.isCancelled
    }

    private func ownsActiveRequest(_ requestID: UUID, conversationID targetConversationID: UUID) -> Bool {
        activeRequestID == requestID && conversationID == targetConversationID
    }

    private func finishGeneration(requestID: UUID) {
        guard activeRequestID == requestID else { return }
        activeRequestID = nil
        generationTask = nil
        isSending = false
        activity = nil
    }

    private func appendAssistantDelta(_ delta: String, requestID: UUID) {
        guard !delta.isEmpty else { return }
        activity = nil
        let requestKey = requestID.uuidString.lowercased()
        if let index = messages.firstIndex(where: { $0.requestId == requestKey && $0.role == "assistant" }) {
            let existing = messages[index]
            messages[index] = AssistantAPIMessage(
                id: existing.id,
                requestId: existing.requestId,
                role: existing.role,
                content: existing.content + delta,
                attachmentMeta: existing.attachmentMeta,
                createdAt: existing.createdAt
            )
        } else {
            messages.append(AssistantAPIMessage(
                id: "local-assistant-\(requestID.uuidString)",
                requestId: requestKey,
                role: "assistant",
                content: delta,
                attachmentMeta: nil,
                createdAt: Self.nowString()
            ))
        }
    }

    private func upsertAssistantMessage(
        text: String,
        requestID: UUID,
        sources: [String] = [],
        knowledge: AssistantAPIKnowledgeReference? = nil,
        createdAt: String? = nil
    ) {
        var metadataValues: [String: AssistantJSONValue] = [:]
        if !sources.isEmpty {
            metadataValues["sources"] = .array(sources.map { .string($0) })
        }
        if let knowledge {
            metadataValues["knowledge"] = knowledge.jsonValue
        }
        let metadata: AssistantJSONValue? = metadataValues.isEmpty ? nil : .object(metadataValues)
        let requestKey = requestID.uuidString.lowercased()
        let message = AssistantAPIMessage(
            id: "local-assistant-\(requestID.uuidString)",
            requestId: requestKey,
            role: "assistant",
            content: text,
            attachmentMeta: metadata,
            createdAt: createdAt ?? Self.nowString()
        )
        if let index = messages.firstIndex(where: { $0.requestId == requestKey && $0.role == "assistant" }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
        updateLocalConversation(message: text)
        saveCache()
    }

    func submitKnowledgeFeedback(for messageID: String, feedback: AssistantKnowledgeFeedback) async {
        guard let index = messages.firstIndex(where: { $0.id == messageID }),
              let reference = Self.knowledgeReference(from: messages[index]),
              let claim = reference.primaryClaim else { return }
        do {
            try await api.submitKnowledgeFeedback(
                claimID: claim.id,
                answerTraceID: reference.answerTraceId,
                feedback: feedback,
                conversationID: conversationID
            )
            let existing = messages[index]
            var metadata: [String: AssistantJSONValue] = [:]
            if case .object(let values) = existing.attachmentMeta { metadata = values }
            metadata["knowledgeFeedback"] = .string(feedback.rawValue)
            messages[index] = AssistantAPIMessage(
                id: existing.id,
                requestId: existing.requestId,
                role: existing.role,
                content: existing.content,
                attachmentMeta: .object(metadata),
                createdAt: existing.createdAt
            )
            AppHaptics.trigger()
            saveCache()
        } catch is CancellationError {
        } catch {
            if let message = Self.inlineErrorMessage(error) {
                AppBannerCenter.shared.show(message, style: .error)
            }
        }
    }

    private static func knowledgeReference(from message: AssistantAPIMessage) -> AssistantAPIKnowledgeReference? {
        guard case .object(let metadata) = message.attachmentMeta,
              case .object(let knowledge) = metadata["knowledge"],
              case .string(let traceID) = knowledge["answerTraceId"],
              case .array(let claimValues) = knowledge["claims"] else { return nil }
        let claims = claimValues.compactMap { value -> AssistantAPIKnowledgeClaim? in
            guard case .object(let claim) = value,
                  case .string(let id) = claim["id"],
                  case .string(let state) = claim["state"],
                  case .string(let role) = claim["role"] else { return nil }
            return AssistantAPIKnowledgeClaim(id: id, state: state, role: role)
        }
        return AssistantAPIKnowledgeReference(answerTraceId: traceID, claims: claims)
    }

    private func applyServerTimestamps(_ timestamps: AssistantAPIMessageTimestamps?, requestID: UUID) {
        guard let timestamps else { return }
        let requestKey = requestID.uuidString.lowercased()
        for index in messages.indices where messages[index].requestId == requestKey {
            let existing = messages[index]
            let timestamp = existing.role == "user" ? timestamps.user : timestamps.assistant
            guard let timestamp else { continue }
            messages[index] = AssistantAPIMessage(
                id: existing.id,
                requestId: existing.requestId,
                role: existing.role,
                content: existing.content,
                attachmentMeta: existing.attachmentMeta,
                createdAt: timestamp
            )
        }
    }

    private func updateLocalConversation(message: String) {
        let compact = message.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Self.nowString()
        if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
            let existing = conversations.remove(at: index)
            conversations.insert(AssistantAPIConversation(
                id: existing.id,
                title: existing.title,
                preview: String(compact.prefix(140)),
                lastMessageAt: now,
                createdAt: existing.createdAt,
                usedTokens: existing.usedTokens,
                tokenLimit: existing.tokenLimit,
                isFull: existing.isFull,
                contextTokens: existing.contextTokens,
                compressionThreshold: existing.compressionThreshold,
                compactions: existing.compactions,
                willCompressOnNextRun: existing.willCompressOnNextRun
            ), at: 0)
        } else {
            conversations.insert(AssistantAPIConversation(
                id: conversationID,
                title: compact.isEmpty ? "Рабочий чат" : String(compact.prefix(80)),
                preview: String(compact.prefix(140)),
                lastMessageAt: now,
                createdAt: now
            ), at: 0)
        }
    }

    private func applyStatus(_ status: AssistantAPIConversationStatus?, conversationID: UUID) {
        guard let status, let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index] = conversations[index].updating(status: status)
    }

    private func refreshConversationsQuietly() async {
        guard !isLoadingHistory else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do {
            conversations = try await api.conversations().conversations
            saveCache()
        } catch {
            // Cache remains visible; background refresh errors are intentionally quiet.
        }
    }

    private func loadMessages(conversationID targetConversationID: UUID) async -> Bool {
        messageLoadGeneration += 1
        let generation = messageLoadGeneration
        isLoadingMessages = true
        defer {
            if messageLoadGeneration == generation {
                isLoadingMessages = false
            }
        }
        do {
            let page = try await api.messages(conversationID: targetConversationID)
            guard messageLoadGeneration == generation, conversationID == targetConversationID else { return false }
            messages = page.messages
            applyStatus(page.conversation, conversationID: targetConversationID)
            errorMessage = nil
            saveCache()
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard messageLoadGeneration == generation, conversationID == targetConversationID else { return false }
            let message = Self.isNotFound(error)
                ? "Этот чат больше недоступен. История обновлена."
                : Self.inlineErrorMessage(error)
            if Self.isNotFound(error) {
                conversations.removeAll { $0.id == targetConversationID }
            }
            if let message {
                presentErrorMessage(message)
            }
            return false
        }
    }

    private func removeLocalConversation(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        if conversationID == id {
            startNewConversation()
        } else {
            saveCache()
        }
    }

    private func presentErrorMessage(_ message: String, offersRetry: Bool = false) {
        errorMessage = message
        if offersRetry, retryableRequest?.conversationID == conversationID {
            AppBannerCenter.shared.show(
                message,
                style: .error,
                actionTitle: "Повторить"
            ) { [weak self] in
                Task { await self?.retryLastFailedRequest() }
            }
        } else {
            AppBannerCenter.shared.show(message, style: .error)
        }
    }

    private static func isNotFound(_ error: Error) -> Bool {
        guard case AppServiceError.http(let status, _) = error else { return false }
        return status == 404
    }

    private static func inlineErrorMessage(_ error: Error) -> String? {
        switch AppErrorPresentation.classification(for: error) {
        case .cancellation:
            return nil
        case .network(let kind):
            return kind.message
        case .domain:
            return appUserFacingErrorMessage(error, showsNetworkBanner: false)
        }
    }

    private func saveCache() {
        AppOfflineSnapshotStore.save(
            CachedState(
                conversations: Array(conversations.prefix(30)),
                conversationID: conversationID,
                messages: Array(messages.suffix(100))
            ),
            key: cacheKey
        )
    }

    nonisolated private static func nowString() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

@MainActor
final class AssistantLocalToolExecutor {
    private let simpleOneStore: SimpleOneRequestsStore
    private let backpackStore: BackpackStore
    private let closedRequestsStore = ClosedSimpleOneRequestsStore()

    init(simpleOneStore: SimpleOneRequestsStore, backpackStore: BackpackStore) {
        self.simpleOneStore = simpleOneStore
        self.backpackStore = backpackStore
    }

    func execute(_ requests: [AssistantAPIToolRequest]) async throws -> [AssistantAPIToolResult] {
        var results: [AssistantAPIToolResult] = []
        for request in requests.prefix(4) {
            let payload: AssistantJSONValue
            switch request.name {
            case "active_requests":
                payload = activeRequestsPayload(arguments: request.arguments)
            case "closed_requests":
                payload = await closedRequestsPayload(arguments: request.arguments)
            case "request_details":
                payload = try await requestDetailsPayload(arguments: request.arguments)
            case "backpack":
                payload = await backpackPayload(arguments: request.arguments)
            default:
                throw AppServiceError.message("Помощник запросил недоступный источник данных.")
            }
            results.append(AssistantAPIToolResult(name: request.name, payload: payload))
        }
        return results
    }

    private func activeRequestsPayload(arguments: [String: AssistantJSONValue]) -> AssistantJSONValue {
        let limit = arguments.limit
        let records = selectedRecords(simpleOneStore.activeRequests, arguments: arguments, limit: limit)
        return .object([
            "count": .number(Double(simpleOneStore.activeRequests.count)),
            "updatedAt": simpleOneStore.lastUpdatedAt.map { .string(Self.dateString($0)) } ?? .null,
            "requests": .array(records.map { requestSummary($0, closed: false) })
        ])
    }

    private func closedRequestsPayload(arguments: [String: AssistantJSONValue]) async -> AssistantJSONValue {
        await closedRequestsStore.loadAndWait(using: simpleOneStore)
        let records = selectedRecords(closedRequestsStore.records, arguments: arguments, limit: arguments.limit)
        return .object([
            "count": .number(Double(closedRequestsStore.records.count)),
            "updatedAt": closedRequestsStore.lastUpdatedAt.map { .string(Self.dateString($0)) } ?? .null,
            "requests": .array(records.map { requestSummary($0, closed: true) })
        ])
    }

    private func requestDetailsPayload(arguments: [String: AssistantJSONValue]) async throws -> AssistantJSONValue {
        let id = arguments["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var records = simpleOneStore.activeRequests
        if !records.contains(where: { Self.matchesIdentifier($0, id: id) }) {
            await closedRequestsStore.loadAndWait(using: simpleOneStore)
            records.append(contentsOf: closedRequestsStore.records)
        }
        guard let record = Self.findRecord(records, id: id, query: arguments["query"]?.stringValue) else {
            return .object(["status": .string("not_found")])
        }
        let detailed = try await simpleOneStore.fetchDetailedRequest(
            record,
            updatesActiveRequests: record.source == .active
        )
        return requestDetails(detailed)
    }

    private func backpackPayload(arguments: [String: AssistantJSONValue]) async -> AssistantJSONValue {
        await backpackStore.loadIfNeeded()
        let query = arguments["query"]?.stringValue ?? ""
        let limit = arguments.limit
        let filtered = Self.filteredBackpackItems(backpackStore.items, query: query)
        let items = filtered.prefix(limit).map { item in
            AssistantJSONValue.object([
                "id": .string(item.id),
                "type": .string("оборудование"),
                "model": .string(item.name),
                "quantity": .number(Double(max(item.quantity, 0))),
                "updatedAt": .string(item.receivedAt)
            ])
        }
        return .object([
            "updatedAt": backpackStore.lastUpdatedAt.map { .string(Self.dateString($0)) } ?? .null,
            "totals": .object([
                "positions": .number(Double(backpackStore.items.count)),
                "quantity": .number(Double(backpackStore.items.reduce(0) { $0 + max($1.quantity, 0) }))
            ]),
            "items": .array(Array(items))
        ])
    }

    private func selectedRecords(
        _ records: [SimpleOneRequestRecord],
        arguments: [String: AssistantJSONValue],
        limit: Int
    ) -> [SimpleOneRequestRecord] {
        let query = arguments["query"]?.stringValue ?? ""
        return Self.filteredRecords(records, query: query).prefix(limit).map { $0 }
    }

    private func requestSummary(_ record: SimpleOneRequestRecord, closed: Bool) -> AssistantJSONValue {
        var value: [String: AssistantJSONValue] = [
            "id": .string(record.id),
            "number": .string(record.number),
            "equipmentType": .string(record.requestType),
            "equipmentModel": .string(record.terminalModel),
            "symptom": .string(record.shortDescription)
        ]
        if closed {
            value["closedAt"] = .string(record.primaryDate)
            value["resolutionCode"] = .string(record.closureCode ?? "")
            value["result"] = .string(record.resolution ?? record.engineerComment)
        } else {
            value["status"] = .string(record.state)
            value["dueAt"] = .string(record.deadline)
        }
        return .object(value)
    }

    private func requestDetails(_ record: SimpleOneRequestRecord) -> AssistantJSONValue {
        .object([
            "id": .string(record.id),
            "number": .string(record.number),
            "status": .string(record.state),
            "dueAt": .string(record.deadline),
            "project": .string(record.clientServiceParent ?? record.assignmentGroup),
            "equipmentType": .string(record.requestType),
            "equipmentModel": .string(record.terminalModel),
            "terminalId": .string(record.terminalID),
            "symptom": .string(record.informationText.isEmpty ? record.shortDescription : record.informationText),
            "errorCode": .string(record.waitingReason ?? ""),
            "performedActions": .string(record.engineerComment),
            "result": .string(record.resolution ?? ""),
            "updatedAt": .string(record.primaryDate)
        ])
    }

    private static func findRecord(
        _ records: [SimpleOneRequestRecord],
        id: String,
        query: String?
    ) -> SimpleOneRequestRecord? {
        if !id.isEmpty, let exact = records.first(where: { matchesIdentifier($0, id: id) }) {
            return exact
        }
        return filteredRecords(records, query: query ?? "").first
    }

    private static func matchesIdentifier(_ record: SimpleOneRequestRecord, id: String) -> Bool {
        guard !id.isEmpty else { return false }
        return [record.id, record.sysID, record.number, record.terminalID]
            .contains { $0.caseInsensitiveCompare(id) == .orderedSame }
    }

    private static func filteredRecords(
        _ records: [SimpleOneRequestRecord],
        query: String
    ) -> [SimpleOneRequestRecord] {
        let tokens = searchTokens(query)
        let sorted = records.sorted { $0.primaryDate.localizedStandardCompare($1.primaryDate) == .orderedDescending }
        guard !tokens.isEmpty else { return sorted }
        let scored = sorted.map { record in
            (record, tokens.reduce(0) { $0 + (record.searchText.contains($1) ? 1 : 0) })
        }
        let matches = scored.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.map(\.0)
        return matches.isEmpty ? sorted : matches
    }

    private static func filteredBackpackItems(_ items: [BackpackItem], query: String) -> [BackpackItem] {
        let tokens = searchTokens(query)
        guard !tokens.isEmpty else { return items }
        let matches = items.filter { item in
            let text = "\(item.name) \(item.serialNumber)".folding(
                options: [.diacriticInsensitive, .caseInsensitive],
                locale: .current
            )
            return tokens.contains(where: text.contains)
        }
        return matches.isEmpty ? items : matches
    }

    private static func searchTokens(_ value: String) -> [String] {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 }
    }

    nonisolated private static func dateString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

private extension Dictionary where Key == String, Value == AssistantJSONValue {
    var limit: Int {
        guard let value = self["limit"]?.numberValue else { return 10 }
        return Swift.min(Swift.max(Int(value), 1), 10)
    }
}

private extension AssistantJSONValue {
    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var numberValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }
}
