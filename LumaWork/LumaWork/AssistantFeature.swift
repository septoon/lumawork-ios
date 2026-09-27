import PhotosUI
import MarkdownUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

enum AssistantWorkspaceSection: String, CaseIterable, Identifiable {
    case assistant
    case wiki

    var id: String { rawValue }

    var title: String {
        switch self {
        case .assistant:
            "Чат"
        case .wiki:
            "Вики"
        }
    }
}

private enum AssistantChatHistoryAction {
    case openConversation(UUID)
    case startNewConversation
}

struct AssistantWorkspaceScreen: View {
    @Bindable var wikiStore: WikiStore
    @Bindable var assistantStore: AssistantStore
    @State private var selectedSection: AssistantWorkspaceSection = .assistant
    @State private var isChatHistoryPresented = false
    @State private var pendingChatHistoryAction: AssistantChatHistoryAction?
    @State private var keyboardDismissRequest = 0

    var body: some View {
        Group {
            switch selectedSection {
            case .assistant:
                AssistantScreen(store: assistantStore, keyboardDismissRequest: keyboardDismissRequest)
            case .wiki:
                WikiScreen(store: wikiStore)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                AssistantWorkspacePicker(selection: $selectedSection)
                    .opacity(selectedSection == .wiki || !assistantStore.hasActiveConversation ? 1 : 0)
                    .allowsHitTesting(selectedSection == .wiki || !assistantStore.hasActiveConversation)
                    .accessibilityHidden(selectedSection == .assistant && assistantStore.hasActiveConversation)
            }

            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: assistantStore.hasActiveConversation ? 18 : 0) {
                    Button {
                        AppHaptics.trigger(.expandCollapse)
                        Task { @MainActor in
                            await Task.yield()
                            assistantStore.startNewConversation()
                        }
                    } label: {
                        Label("Новый чат", systemImage: "square.and.pencil")
                            .labelStyle(.iconOnly)
                    }
                    .frame(width: assistantStore.hasActiveConversation ? 28 : 0)
                    .opacity(assistantStore.hasActiveConversation ? 1 : 0)
                    .clipped()
                    .allowsHitTesting(assistantStore.hasActiveConversation)
                    .accessibilityHidden(!assistantStore.hasActiveConversation)

                    Button {
                        AppHaptics.trigger(.expandCollapse)
                        keyboardDismissRequest += 1
                        dismissKeyboard()
                        Task { @MainActor in
                            await Task.yield()
                            isChatHistoryPresented = true
                        }
                    } label: {
                        Label("Предыдущие чаты", systemImage: "ellipsis")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel("Предыдущие чаты")
                }
                .opacity(selectedSection == .assistant ? 1 : 0)
                .allowsHitTesting(selectedSection == .assistant)
                .accessibilityHidden(selectedSection != .assistant)
            }
        }
        .sheet(isPresented: $isChatHistoryPresented, onDismiss: performPendingChatHistoryAction) {
            AssistantChatHistorySheet(
                store: assistantStore,
                onOpenConversation: { conversationID in
                    pendingChatHistoryAction = .openConversation(conversationID)
                    isChatHistoryPresented = false
                },
                onStartNewConversation: {
                    pendingChatHistoryAction = .startNewConversation
                    isChatHistoryPresented = false
                }
            )
        }
        .task {
#if DEBUG
            guard ProcessInfo.processInfo.arguments.contains("-assistant-history-preview") else { return }
            await Task.yield()
            isChatHistoryPresented = true
#endif
        }
        .animation(.snappy(duration: 0.24), value: selectedSection)
        .animation(.snappy(duration: 0.24), value: assistantStore.hasActiveConversation)
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private func performPendingChatHistoryAction() {
        guard let action = pendingChatHistoryAction else { return }
        pendingChatHistoryAction = nil
        Task { @MainActor in
            await Task.yield()
            switch action {
            case .openConversation(let conversationID):
                _ = await assistantStore.openConversation(conversationID)
            case .startNewConversation:
                assistantStore.startNewConversation()
            }
        }
    }
}

private struct AssistantChatHistorySheet: View {
    @Bindable var store: AssistantStore
    let onOpenConversation: (UUID) -> Void
    let onStartNewConversation: () -> Void
    @State private var renameTarget: AssistantAPIConversation?
    @State private var renameTitle = ""
    @State private var deleteTarget: AssistantAPIConversation?

    var body: some View {
        NavigationStack {
            Group {
                if store.conversations.isEmpty, store.isLoadingHistory {
                    ProgressView("Загружаем чаты")
                } else if store.conversations.isEmpty {
                    ContentUnavailableView(
                        "Пока нет чатов",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Новый диалог появится после первого сообщения.")
                    )
                } else {
                    List {
                        ForEach(store.conversations) { conversation in
                            Button {
                                onOpenConversation(conversation.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 8) {
                                        Text(conversation.title)
                                            .font(.headline)
                                            .foregroundStyle(AppTheme.ink)
                                            .lineLimit(1)
                                        if conversation.isFull == true {
                                            Text("Заполнен")
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(AppTheme.dangerTint)
                                                .padding(.horizontal, 7)
                                                .padding(.vertical, 3)
                                                .background(AppTheme.dangerTint.opacity(0.10), in: Capsule())
                                        }
                                    }
                                    if !conversation.preview.isEmpty {
                                        Text(conversation.preview)
                                            .font(.subheadline)
                                            .foregroundStyle(AppTheme.mutedTint)
                                            .lineLimit(2)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    renameTarget = conversation
                                    renameTitle = conversation.title
                                } label: {
                                    Label("Переименовать", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    deleteTarget = conversation
                                } label: {
                                    Label("Удалить", systemImage: "trash")
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    Task { await store.deleteConversation(conversation.id) }
                                } label: {
                                    Label("Удалить", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Предыдущие чаты")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onStartNewConversation()
                    } label: {
                        Label("Новый чат", systemImage: "square.and.pencil")
                    }
                }
            }
            .task {
                await store.loadConversations(force: true)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .alert(
            "Переименовать чат",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )
        ) {
            TextField("Название", text: $renameTitle)
            Button("Сохранить") {
                guard let target = renameTarget else { return }
                let title = renameTitle
                renameTarget = nil
                Task { _ = await store.renameConversation(target.id, title: title) }
            }
            Button("Отмена", role: .cancel) { renameTarget = nil }
        } message: {
            Text("Название будет видно только в вашей истории чатов.")
        }
        .confirmationDialog(
            "Удалить чат?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Удалить", role: .destructive) {
                guard let target = deleteTarget else { return }
                deleteTarget = nil
                Task { await store.deleteConversation(target.id) }
            }
            Button("Отмена", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("Вся переписка этого чата будет удалена без возможности восстановления.")
        }
    }
}

private struct AssistantWorkspacePicker: View {
    @Binding var selection: AssistantWorkspaceSection

    var body: some View {
        Picker("Раздел помощника", selection: $selection) {
            ForEach(AssistantWorkspaceSection.allCases) { section in
                Text(section.title).tag(section)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 176)
        .onChange(of: selection) { _, _ in
            AppHaptics.trigger(.expandCollapse)
        }
    }
}

private struct AssistantScreen: View {
    @Bindable var store: AssistantStore
    let keyboardDismissRequest: Int
    @State private var draft = ""
    @State private var attachment: AssistantDraftAttachment?
    @State private var isPhotoLibraryPresented = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isCameraPresented = false
    @State private var isFileImporterPresented = false
    @State private var selectableMessage: AssistantAPIMessage?
    @State private var speechRecognizer = AssistantSpeechRecognizer()
    @State private var isNearBottom = true
    @State private var scrollToBottomRequest = 0
    @State private var composerHeight: CGFloat = 64
    @FocusState private var isComposerFocused: Bool

    private let quickActions = [
        AssistantQuickAction(title: "Найти инструкцию", systemImage: "book.closed"),
        AssistantQuickAction(title: "Проверить пробег", systemImage: "gauge.medium"),
        AssistantQuickAction(title: "Расходы на топливо", systemImage: "fuelpump")
    ]

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                AppScreen(
                    bottomContentPadding: 16,
                    keyboardDismissMode: .interactively,
                    sizeChangeScrollAnchor: .bottom,
                    onBottomProximityChange: { isNearBottom = $0 }
                ) {
                    if store.messages.isEmpty, store.isLoadingMessages {
                        AssistantMessageLoadingPlaceholder()
                    } else if store.messages.isEmpty {
                        Spacer(minLength: max(geometry.size.height - 186, 180))

                        if !isComposerFocused {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(quickActions) { action in
                                    Button {
                                        AppHaptics.trigger()
                                        draft = action.title
                                        isComposerFocused = true
                                    } label: {
                                        HStack(spacing: 14) {
                                            Image(systemName: action.systemImage)
                                                .font(.body.weight(.medium))
                                                .foregroundStyle(AppTheme.primaryTint)
                                                .frame(width: 24)

                                            Text(action.title)
                                                .font(.body)
                                                .foregroundStyle(AppTheme.mutedTint.opacity(0.88))

                                            Spacer(minLength: 0)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 11)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(.opacity)
                        }
                    } else {
                        ForEach(Array(store.messages.enumerated()), id: \.element.id) { index, message in
                            if AssistantMessageDateFormatter.startsNewDay(
                                message: message,
                                previous: index > 0 ? store.messages[index - 1] : nil
                            ) {
                                AssistantMessageDateDivider(createdAt: message.createdAt)
                            }
                            AssistantMessageBubble(
                                message: message,
                                onEdit: message.role == "user" ? {
                                    editMessage(message)
                                } : nil,
                                onSelectText: {
                                    selectableMessage = message
                                },
                                onKnowledgeFeedback: { feedback in
                                    Task {
                                        await store.submitKnowledgeFeedback(for: message.id, feedback: feedback)
                                    }
                                }
                            )
                                .id(message.id)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }

                    if let activity = store.activity {
                        AssistantActivityRow(activity: activity)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("assistant-bottom")
                }
                .animation(.snappy(duration: 0.28), value: store.messages.count)
                .animation(.easeInOut(duration: 0.2), value: store.activity)
                .animation(.easeOut(duration: 0.16), value: isComposerFocused)
                .onChange(of: store.messages.count) { _, _ in
                    scrollToBottom(proxy, animated: true)
                }
                .onChange(of: store.messages.last?.content.count) { _, _ in
                    if store.isSending {
                        proxy.scrollTo("assistant-bottom", anchor: .bottom)
                    }
                }
                .onChange(of: store.activity) { _, _ in
                    scrollToBottom(proxy, animated: true)
                }
                .onChange(of: isComposerFocused) { _, isFocused in
                    guard isFocused, !store.messages.isEmpty else { return }
                    isNearBottom = true
                    scrollToBottom(proxy, animated: true)
                }
                .onChange(of: scrollToBottomRequest) { _, _ in
                    scrollToBottom(proxy, animated: true)
                }
                .onTapGesture {
                    dismissComposerKeyboard()
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AssistantComposer(
                draft: $draft,
                attachment: $attachment,
                isFocused: $isComposerFocused,
                isSending: store.isSending,
                isConversationFull: store.isConversationFull,
                speechRecognizer: speechRecognizer,
                onCamera: {
                    AppHaptics.trigger()
                    isCameraPresented = true
                },
                onPhotos: {
                    AppHaptics.trigger()
                    isPhotoLibraryPresented = true
                },
                onFiles: {
                    AppHaptics.trigger()
                    isFileImporterPresented = true
                },
                onStartDictation: startDictation,
                onStopDictation: stopDictation,
                onCancelDictation: cancelDictation,
                onSendDictation: submitDictation,
                onStopGeneration: stopGeneration,
                onSend: submitDraft
            )
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.height
            } action: { newHeight in
                composerHeight = newHeight
            }
        }
        .overlay(alignment: .bottom) {
            if showsScrollToBottomButton {
                AssistantScrollToBottomButton {
                    AppHaptics.trigger(.expandCollapse)
                    scrollToBottomRequest += 1
                }
                .padding(.bottom, composerHeight + 13)
                .transition(.scale(scale: 0.84).combined(with: .opacity))
                .zIndex(2)
            }
        }
        .animation(.snappy(duration: 0.28, extraBounce: 0.08), value: showsScrollToBottomButton)
        .photosPicker(
            isPresented: $isPhotoLibraryPresented,
            selection: $selectedPhoto,
            matching: .images
        )
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task {
                await loadPhoto(item)
            }
        }
        .fullScreenCover(isPresented: $isCameraPresented) {
            AssistantCameraPicker(isPresented: $isCameraPresented) { image in
                Task {
                    await prepareCameraImage(image)
                }
            }
            .ignoresSafeArea()
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.image] + AssistantDocumentPreparer.supportedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task {
                await loadFile(url)
            }
        }
        .sheet(item: $selectableMessage) { message in
            AssistantSelectableMessageSheet(message: message)
        }
        .onAppear {
            Task { @MainActor in
                await Task.yield()
                if !store.isConversationFull {
                    isComposerFocused = true
                }
            }
        }
        .onDisappear {
            speechRecognizer.reset()
        }
        .onChange(of: store.conversationID) { _, _ in
            guard !store.hasActiveConversation else { return }
            draft = ""
            attachment = nil
            isComposerFocused = true
        }
        .onChange(of: keyboardDismissRequest) { _, _ in
            dismissComposerKeyboard()
        }
        .onChange(of: speechRecognizer.errorMessage) { _, message in
            guard let message else { return }
            AppBannerCenter.shared.show(message, style: .error)
        }
        .task(id: store.isConversationFull) {
            guard store.isConversationFull else { return }
            AppBannerCenter.shared.show(
                "Лимит этого чата исчерпан.",
                style: .information,
                actionTitle: "Новый чат"
            ) {
                draft = ""
                attachment = nil
                store.startNewConversation()
                isComposerFocused = true
            }
        }
        .task {
            await store.loadConversations()
            await store.loadCurrentMessages()
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem) async {
        defer { selectedPhoto = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw AppServiceError.message("Не удалось загрузить выбранное фото.")
            }
            let prepared = try await AssistantImagePreparer.prepare(data: data)
            guard let image = UIImage(data: prepared.data) else {
                throw AppServiceError.message("Не удалось подготовить выбранное фото.")
            }

            attachment = AssistantDraftAttachment(
                title: "Фото",
                systemImage: "photo.fill",
                previewImage: image,
                preparedImage: prepared,
                preparedDocument: nil
            )
            store.clearError()
        } catch is CancellationError {
            return
        } catch {
            store.presentError(error, fallback: "Не удалось добавить фото.")
        }
    }

    private func prepareCameraImage(_ image: UIImage) async {
        do {
            guard let data = image.jpegData(compressionQuality: 0.95) else {
                throw AppServiceError.message("Не удалось прочитать фото с камеры.")
            }
            let prepared = try await AssistantImagePreparer.prepare(data: data)
            guard let preview = UIImage(data: prepared.data) else {
                throw AppServiceError.message("Не удалось подготовить фото с камеры.")
            }
            attachment = AssistantDraftAttachment(
                title: "Фото с камеры",
                systemImage: "camera.fill",
                previewImage: preview,
                preparedImage: prepared,
                preparedDocument: nil
            )
            store.clearError()
        } catch is CancellationError {
            return
        } catch {
            store.presentError(error, fallback: "Не удалось добавить фото.")
        }
    }

    private func loadFile(_ url: URL) async {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let data = try Data(contentsOf: url)
            if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
                let prepared = try await AssistantImagePreparer.prepare(data: data)
                guard let preview = UIImage(data: prepared.data) else { return }
                attachment = AssistantDraftAttachment(
                    title: url.lastPathComponent,
                    systemImage: "photo.fill",
                    previewImage: preview,
                    preparedImage: prepared,
                    preparedDocument: nil
                )
            } else {
                let prepared = try await AssistantDocumentPreparer.prepare(
                    data: data,
                    fileName: url.lastPathComponent
                )
                attachment = AssistantDraftAttachment(
                    title: prepared.payload.fileName,
                    systemImage: documentSystemImage(for: url.pathExtension),
                    previewImage: nil,
                    preparedImage: prepared.fallbackImage,
                    preparedDocument: prepared.payload
                )
            }
            store.clearError()
        } catch {
            store.presentError(error, fallback: "Не удалось добавить файл.")
        }
    }

    private func submitDraft() {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachment != nil else {
            return
        }

        AppHaptics.trigger()
        let submittedDraft = draft
        let submittedImage = attachment?.preparedImage
        let submittedDocument = attachment?.preparedDocument
        draft = ""
        attachment = nil
        dismissComposerKeyboard()
        Task {
            await store.send(
                message: submittedDraft,
                image: submittedImage,
                document: submittedDocument
            )
        }
    }

    private var showsScrollToBottomButton: Bool {
        !store.messages.isEmpty && !isNearBottom
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.24)) {
                proxy.scrollTo("assistant-bottom", anchor: .bottom)
            }
        } else {
            proxy.scrollTo("assistant-bottom", anchor: .bottom)
        }
    }

    private func stopGeneration() {
        AppHaptics.trigger(.expandCollapse)
        store.stopGeneration()
    }

    private func dismissComposerKeyboard() {
        guard isComposerFocused else { return }
        isComposerFocused = false
    }

    private func editMessage(_ message: AssistantAPIMessage) {
        AppHaptics.trigger(.expandCollapse)
        draft = message.content
        attachment = nil
        isComposerFocused = true
    }

    private func documentSystemImage(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "xls", "xlsx", "csv": "tablecells.fill"
        case "pdf": "doc.richtext.fill"
        default: "doc.text.fill"
        }
    }

    private func startDictation() {
        guard !store.isSending, !store.isConversationFull else { return }
        AppHaptics.trigger()
        isComposerFocused = false
        Task {
            await speechRecognizer.start(initialText: draft) { text in
                draft = text
            }
            if speechRecognizer.phase == .idle {
                isComposerFocused = true
            }
        }
    }

    private func stopDictation() {
        AppHaptics.trigger()
        speechRecognizer.finish()
        isComposerFocused = true
    }

    private func cancelDictation() {
        AppHaptics.trigger()
        speechRecognizer.cancel()
        isComposerFocused = true
    }

    private func submitDictation() {
        speechRecognizer.finishForSubmission()
        submitDraft()
    }
}

private struct AssistantMessageBubble: View {
    let message: AssistantAPIMessage
    let onEdit: (() -> Void)?
    let onSelectText: () -> Void
    let onKnowledgeFeedback: (AssistantKnowledgeFeedback) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isCopied = false

    private var isUser: Bool { message.role == "user" }
    private var hasPrimaryKnowledgeClaim: Bool {
        guard case .object(let metadata) = message.attachmentMeta,
              case .object(let knowledge) = metadata["knowledge"],
              case .array(let claims) = knowledge["claims"] else { return false }
        return claims.filter { claim in
            guard case .object(let values) = claim else { return false }
            return values["role"] == .string("primary")
        }.count == 1
    }
    private var knowledgeFeedback: AssistantKnowledgeFeedback? {
        guard case .object(let metadata) = message.attachmentMeta,
              case .string(let rawValue) = metadata["knowledgeFeedback"] else { return nil }
        return AssistantKnowledgeFeedback(rawValue: rawValue)
    }
    private var sources: [AssistantSourceDisplay] {
        guard case .object(let metadata) = message.attachmentMeta,
              case .array(let values) = metadata["sources"] else { return [] }
        return values.compactMap { value in
            guard case .string(let key) = value else { return nil }
            return AssistantSourceDisplay(key: key)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if isUser { Spacer(minLength: 48) }

            VStack(alignment: .leading, spacing: 9) {
                if case .object(let metadata) = message.attachmentMeta {
                    if metadata["kind"] == .string("image") {
                        Label("Изображение", systemImage: "photo.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.primaryTint)
                    } else if metadata["kind"] == .string("document") {
                        Label(documentName(from: metadata), systemImage: "doc.text.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.primaryTint)
                    }
                }
                if isUser {
                    Text(message.content)
                        .font(.body)
                        .foregroundStyle(AppTheme.ink)
                        .textSelection(.enabled)
                } else {
                    Markdown(safeMarkdown)
                        .markdownTextStyle {
                            FontSize(17)
                            ForegroundColor(AppTheme.ink)
                        }
                        .textSelection(.enabled)
                }

                if !isUser, !sources.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ForEach(sources) { source in
                                Label(source.title, systemImage: source.systemImage)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(AppTheme.mutedTint)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(AppTheme.mutedTint.opacity(0.08), in: Capsule())
                            }
                        }
                    }
                }

                if !isUser {
                    HStack(spacing: 4) {
                        assistantActionButton(
                            isCopied ? "Скопировано" : "Копировать ответ",
                            systemImage: isCopied ? "checkmark" : "doc.on.doc",
                            isSelected: isCopied,
                            action: copyMessage
                        )
                        assistantActionButton(
                            "Выбрать фрагмент",
                            systemImage: "selection.pin.in.out",
                            action: onSelectText
                        )
                        if hasPrimaryKnowledgeClaim {
                            knowledgeFeedbackButton(.support, systemImage: "hand.thumbsup")
                            knowledgeFeedbackButton(.contradict, systemImage: "hand.thumbsdown")
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .task(id: isCopied) {
                        guard isCopied else { return }
                        do {
                            try await Task.sleep(for: .seconds(1.4))
                        } catch {
                            return
                        }
                        withAnimation(messageActionAnimation) {
                            isCopied = false
                        }
                    }
                }

                Text(AssistantMessageDateFormatter.time(message.createdAt))
                    .font(.caption2)
                    .foregroundStyle(
                        isUser
                            ? AppTheme.ink.opacity(0.68)
                            : AppTheme.mutedTint.opacity(0.72)
                    )
                    .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
            }
            .padding(.horizontal, isUser ? 16 : 0)
            .padding(.vertical, isUser ? 11 : 4)
            .background(
                isUser ? Color(uiColor: .systemBlue).opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 22, style: .continuous))
            .contextMenu {
                Button {
                    AppClipboard.copy(message.content)
                } label: {
                    Label("Копировать", systemImage: "doc.on.doc")
                }

                if let onEdit {
                    Button(action: onEdit) {
                        Label("Редактировать", systemImage: "pencil")
                    }
                }

                Button(action: onSelectText) {
                    Label("Выбрать текст", systemImage: "selection.pin.in.out")
                }
            } preview: {
                AssistantMessageContextPreview(message: message)
            }

            if !isUser { Spacer(minLength: 12) }
        }
        .frame(maxWidth: .infinity)
    }

    private var safeMarkdown: String {
        message.content.replacingOccurrences(
            of: #"!\[([^\]]*)\]\(([^\)]+)\)"#,
            with: "[$1]($2)",
            options: .regularExpression
        )
    }

    private func documentName(from metadata: [String: AssistantJSONValue]) -> String {
        guard case .string(let name) = metadata["fileName"], !name.isEmpty else { return "Документ" }
        return name
    }

    private func knowledgeFeedbackButton(
        _ feedback: AssistantKnowledgeFeedback,
        systemImage: String
    ) -> some View {
        let isSelected = knowledgeFeedback == feedback
        return Button {
            onKnowledgeFeedback(feedback)
        } label: {
            Image(systemName: isSelected ? "\(systemImage).fill" : systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSelected ? AppTheme.primaryTint : AppTheme.mutedTint.opacity(0.76))
                .frame(width: 32, height: 28)
                .background(
                    isSelected ? AppTheme.primaryTint.opacity(0.10) : Color.clear,
                    in: Capsule()
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(knowledgeFeedback != nil)
        .accessibilityLabel(feedback == .support ? "Полезный ответ" : "Ответ требует исправления")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func assistantActionButton(
        _ title: String,
        systemImage: String,
        isSelected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSelected ? AppTheme.primaryTint : AppTheme.mutedTint.opacity(0.76))
                .frame(width: 32, height: 28)
                .background(
                    isSelected ? AppTheme.primaryTint.opacity(0.10) : Color.clear,
                    in: Capsule()
                )
                .contentShape(Capsule())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func copyMessage() {
        AppClipboard.copy(message.content)
        withAnimation(messageActionAnimation) {
            isCopied = true
        }
    }

    private var messageActionAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .snappy(duration: 0.28, extraBounce: 0.08)
    }
}

private struct AssistantMessageContextPreview: View {
    let message: AssistantAPIMessage

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        Text(message.content)
            .font(.body)
            .foregroundStyle(AppTheme.ink)
            .lineLimit(12)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 340, alignment: .leading)
            .background(
                isUser
                    ? AnyShapeStyle(Color(uiColor: .systemBlue).opacity(0.12))
                    : AppTheme.cardSurface,
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
    }
}

private struct AssistantSelectableMessageSheet: View {
    let message: AssistantAPIMessage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    if message.role == "user" {
                        Text(message.content)
                            .font(.body)
                            .foregroundStyle(AppTheme.ink)
                    } else {
                        Markdown(safeMarkdown)
                            .markdownTextStyle {
                                FontSize(17)
                                ForegroundColor(AppTheme.ink)
                            }
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .navigationTitle("Выбор текста")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var safeMarkdown: String {
        message.content.replacingOccurrences(
            of: #"!\[([^\]]*)\]\(([^\)]+)\)"#,
            with: "[$1]($2)",
            options: .regularExpression
        )
    }
}

private struct AssistantMessageDateDivider: View {
    let createdAt: String

    var body: some View {
        Text(AssistantMessageDateFormatter.day(createdAt))
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppTheme.mutedTint.opacity(0.78))
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

private enum AssistantMessageDateFormatter {
    private static let preciseISO = ISO8601DateFormatter().configured(withFractionalSeconds: true)
    private static let fallbackISO = ISO8601DateFormatter().configured(withFractionalSeconds: false)

    static func startsNewDay(message: AssistantAPIMessage, previous: AssistantAPIMessage?) -> Bool {
        guard let currentDate = date(message.createdAt) else { return previous == nil }
        guard let previous, let previousDate = date(previous.createdAt) else { return true }
        return !Calendar.current.isDate(currentDate, inSameDayAs: previousDate)
    }

    static func time(_ raw: String) -> String {
        guard let value = date(raw) else { return "" }
        return value.formatted(date: .omitted, time: .shortened)
    }

    static func day(_ raw: String) -> String {
        guard let value = date(raw) else { return "" }
        if Calendar.current.isDateInToday(value) { return "Сегодня" }
        if Calendar.current.isDateInYesterday(value) { return "Вчера" }
        return value.formatted(
            Date.FormatStyle()
                .day(.twoDigits)
                .month(.wide)
                .year(.defaultDigits)
                .locale(Locale(identifier: "ru_RU"))
        )
    }

    private static func date(_ raw: String) -> Date? {
        preciseISO.date(from: raw) ?? fallbackISO.date(from: raw)
    }
}

private extension ISO8601DateFormatter {
    func configured(withFractionalSeconds: Bool) -> ISO8601DateFormatter {
        formatOptions = withFractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return self
    }
}

private struct AssistantSourceDisplay: Identifiable {
    let key: String
    var id: String { key }

    var title: String {
        switch key {
        case "wiki": "Wiki"
        case "routes": "Маршруты"
        case "fuel": "Топливо"
        case "vehicles": "Автомобиль"
        case "maintenance": "Обслуживание"
        case "active_requests", "closed_requests", "request_details": "SimpleOne"
        case "backpack": "Рюкзак"
        case "ftp": "FTP"
        case "vision": "Изображение"
        case "document": "Документ"
        default: "Данные приложения"
        }
    }

    var systemImage: String {
        switch key {
        case "wiki": "book.closed"
        case "routes": "map"
        case "fuel": "fuelpump"
        case "vehicles", "maintenance": "car"
        case "active_requests", "closed_requests", "request_details": "ticket"
        case "backpack": "backpack"
        case "ftp": "folder"
        case "vision": "photo"
        case "document": "doc.text"
        default: "tray.full"
        }
    }
}

private struct AssistantActivityRow: View {
    let activity: AssistantStore.Activity

    private var title: String {
        switch activity {
        case .compressingContext: "Сжатие контекста"
        case .thinking: "Думаю"
        case .loadingSources: "Получаю рабочие данные"
        }
    }

    private var systemImage: String {
        switch activity {
        case .compressingContext: "doc.text"
        case .thinking: "ellipsis.bubble"
        case .loadingSources: "tray.full"
        }
    }

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(AppTheme.mutedTint.opacity(0.72))
            .padding(.vertical, 4)
            .assistantShimmer()
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(title)
    }
}

private struct AssistantMessageLoadingPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach([0.72, 0.48, 0.82], id: \.self) { width in
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppTheme.mutedTint.opacity(0.10))
                    .frame(maxWidth: .infinity)
                    .frame(height: 16)
                    .scaleEffect(x: width, anchor: .leading)
            }
        }
        .padding(.top, 12)
        .assistantShimmer()
        .accessibilityLabel("Загрузка сообщений")
    }
}

private struct AssistantShimmerModifier: ViewModifier {
    @State private var isAnimating = false

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { proxy in
                    LinearGradient(
                        colors: [.clear, Color.primary.opacity(0.82), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: max(64, proxy.size.width * 0.46))
                    .offset(x: isAnimating ? proxy.size.width * 1.15 : -proxy.size.width * 0.65)
                }
                .mask(content)
                .allowsHitTesting(false)
            }
            .task {
                isAnimating = false
                await Task.yield()
                withAnimation(.linear(duration: 1.05).repeatForever(autoreverses: false)) {
                    isAnimating = true
                }
            }
    }
}

private extension View {
    func assistantShimmer() -> some View {
        modifier(AssistantShimmerModifier())
    }
}

private struct AssistantQuickAction: Identifiable {
    let title: String
    let systemImage: String

    var id: String { title }
}

private struct AssistantDraftAttachment: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
    let previewImage: UIImage?
    let preparedImage: AssistantPreparedImagePayload?
    let preparedDocument: AssistantPreparedDocumentPayload?
}

private struct AssistantScrollToBottomButton: View {
    let action: () -> Void

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                Button(action: action) {
                    label
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
            } else {
                Button(action: action) {
                    label
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.16), lineWidth: 0.75)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .shadow(color: Color.black.opacity(0.28), radius: 10, y: 4)
        .contentShape(Circle())
        .accessibilityLabel("Перейти к последнему сообщению")
    }

    private var label: some View {
        Image(systemName: "arrow.down")
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(AppTheme.ink)
            .frame(width: 40, height: 40)
    }
}

private struct AssistantComposer: View {
    @Binding var draft: String
    @Binding var attachment: AssistantDraftAttachment?
    @State private var isAttachmentDialogPresented = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var isFocused: FocusState<Bool>.Binding
    let isSending: Bool
    let isConversationFull: Bool
    let speechRecognizer: AssistantSpeechRecognizer
    let onCamera: () -> Void
    let onPhotos: () -> Void
    let onFiles: () -> Void
    let onStartDictation: () -> Void
    let onStopDictation: () -> Void
    let onCancelDictation: () -> Void
    let onSendDictation: () -> Void
    let onStopGeneration: () -> Void
    let onSend: () -> Void

    private var canSend: Bool {
        !isSending && !isConversationFull
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachment != nil)
    }

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                glassComposer
            } else {
                fallbackComposer
            }
        }
        .confirmationDialog(
            "Добавить вложение",
            isPresented: $isAttachmentDialogPresented,
            titleVisibility: .visible
        ) {
            Button("Камера", systemImage: "camera.fill", action: onCamera)
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
            Button("Фото", systemImage: "photo.on.rectangle.angled", action: onPhotos)
            Button("Файлы", systemImage: "folder.fill", action: onFiles)
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Выберите источник изображения или документа.")
        }
    }

    @available(iOS 26.0, *)
    private var glassComposer: some View {
        composerContent
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 28))
    }

    private var fallbackComposer: some View {
        composerContent
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            )
    }

    private var composerContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if speechRecognizer.phase == .idle, let attachment {
                AssistantAttachmentChip(attachment: attachment) {
                    AppHaptics.trigger(.expandCollapse)
                    withAnimation(elementTransitionAnimation) {
                        self.attachment = nil
                    }
                }
                .transition(
                    .scale(scale: 0.94, anchor: .bottomLeading)
                        .combined(with: .opacity)
                )
            }

            if speechRecognizer.isActive {
                recordingRow
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                standardRow
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }

        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .animation(elementTransitionAnimation, value: speechRecognizer.phase)
        .animation(elementTransitionAnimation, value: attachment?.id)
    }

    private var elementTransitionAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.14)
            : .snappy(duration: 0.30, extraBounce: 0.08)
    }

    private var standardRow: some View {
        HStack(alignment: .center, spacing: 6) {
            Group {
                Button {
                    AppHaptics.trigger(.expandCollapse)
                    isAttachmentDialogPresented = true
                } label: {
                    Image(systemName: "plus")
                        .font(.title3.weight(.medium))
                        .frame(width: 36, height: 36)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.ink)
                .disabled(isSending || isConversationFull)
                .accessibilityLabel("Добавить вложение")

                TextField(
                    isConversationFull ? "Откройте новый чат" : "Спросить помощника",
                    text: $draft,
                    axis: .vertical
                )
                    .font(.body)
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(1 ... 4)
                    .focused(isFocused)
                    .submitLabel(.send)
                    .onSubmit {
                        if canSend {
                            onSend()
                        }
                    }
                    .disabled(isConversationFull)

                Button(action: onStartDictation) {
                    Image(systemName: "mic")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(AppTheme.ink)
                        .frame(width: 38, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(isSending || isConversationFull)
                .accessibilityLabel("Начать локальную диктовку")
            }
            Button(action: isSending ? onStopGeneration : onSend) {
                ZStack {
                    Circle()
                        .fill(
                            isSending || canSend
                                ? Color(uiColor: .systemBlue)
                                : AppTheme.mutedTint.opacity(0.14)
                        )

                    if isSending {
                        Image(systemName: "stop.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(canSend ? Color.white : AppTheme.mutedTint.opacity(0.72))
                    }
                }
                .frame(width: 36, height: 36)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!isSending && !canSend)
            .accessibilityLabel(isSending ? "Остановить ответ" : "Отправить")
        }
    }

    private var recordingRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: onCancelDictation) {
                Image(systemName: "xmark")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(AppTheme.ink)
                    .frame(width: 44, height: 44)
                    .background(AppTheme.mutedTint.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Отменить диктовку")

            Group {
                if speechRecognizer.phase == .preparing {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Подготовка диктовки")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.mutedTint)
                    }
                } else if speechRecognizer.phase == .finalizing {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Завершение диктовки")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.mutedTint)
                    }
                } else {
                    AssistantRecordingWaveform(level: speechRecognizer.audioLevel)
                }
            }
            .frame(maxWidth: .infinity)

            Button(action: onStopDictation) {
                Image(systemName: "stop.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppTheme.ink)
                    .frame(width: 44, height: 44)
                    .background(AppTheme.mutedTint.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(speechRecognizer.phase != .recording)
            .accessibilityLabel("Завершить диктовку")

            Button(action: onSendDictation) {
                Image(systemName: "arrow.up")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(AppTheme.primaryTint, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(
                speechRecognizer.phase != .recording
                    || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
            .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
            .accessibilityLabel("Отправить распознанный текст")
        }
    }
}

private struct AssistantRecordingWaveform: View {
    let level: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate * 7
            HStack(spacing: 4) {
                ForEach(0 ..< 18, id: \.self) { _ in
                    Circle()
                        .fill(AppTheme.mutedTint.opacity(0.28))
                        .frame(width: 4, height: 4)
                }

                ForEach(0 ..< 6, id: \.self) { index in
                    let movement = (sin(phase + Double(index) * 0.85) + 1) / 2
                    Capsule()
                        .fill(AppTheme.mutedTint.opacity(0.74))
                        .frame(
                            width: 4,
                            height: 5 + max(0.12, level) * (8 + CGFloat(movement) * 13)
                        )
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: 30)
        .accessibilityHidden(true)
    }
}

private struct AssistantAttachmentChip: View {
    let attachment: AssistantDraftAttachment
    let removeAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let image = attachment.previewImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: attachment.systemImage)
                        .font(.headline)
                        .foregroundStyle(AppTheme.primaryTint)
                }
            }
            .frame(width: 42, height: 42)
            .background(AppTheme.primaryTint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text(attachment.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.ink)
                .lineLimit(1)

            Spacer(minLength: 4)

            Button(action: removeAction) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(AppTheme.mutedTint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Удалить вложение")
        }
        .padding(8)
        .background(AppTheme.primaryTint.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct AssistantCameraPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onImagePicked: (UIImage) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let parent: AssistantCameraPicker

        init(parent: AssistantCameraPicker) {
            self.parent = parent
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.isPresented = false
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImagePicked(image)
            }
            parent.isPresented = false
        }
    }
}

#Preview("Помощник") {
    let simpleOneStore = SimpleOneRequestsStore(automaticallyRefresh: false)
    let backpackStore = BackpackStore()
    NavigationStack {
        AssistantWorkspaceScreen(
            wikiStore: WikiStore(service: WikiAPI(config: AppConfig())),
            assistantStore: AssistantStore(
                api: AssistantAPI(config: AppConfig(), authToken: nil),
                userID: nil,
                toolExecutor: AssistantLocalToolExecutor(
                    simpleOneStore: simpleOneStore,
                    backpackStore: backpackStore
                )
            )
        )
    }
    .tint(AppTheme.primaryTint)
}
