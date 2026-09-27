import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AdminFeedbackStore {
    private let api: FeedbackAPI
    private let token: String?
    private let cacheKey: String

    var messages: [FeedbackMessage] = []
    var isLoading = false
    var isSaving = false
    var errorMessage: String?
    var notice: String?

    init(token: String?, cacheID: String?) {
        api = FeedbackAPI(config: AppConfig())
        self.token = token
        cacheKey = AppOfflineSnapshotStore.scopedKey("admin-feedback", userID: cacheID)
        messages = AppOfflineSnapshotStore.load([FeedbackMessage].self, key: cacheKey)?.value ?? []
    }

    func load(showsNetworkBanner: Bool = false) async {
        guard !isLoading, let token, !token.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            messages = try await api.fetchMessages(token: token, admin: true)
            persist()
            errorMessage = nil
        } catch {
            errorMessage = appUserFacingErrorMessage(error, showsNetworkBanner: showsNetworkBanner)
        }
    }

    func update(
        _ message: FeedbackMessage,
        status: FeedbackStatus,
        priority: FeedbackPriority,
        note: String
    ) async -> Bool {
        guard let token, !token.isEmpty else { return false }
        isSaving = true
        errorMessage = nil
        notice = nil
        defer { isSaving = false }
        do {
            replace(try await api.updateAdmin(
                id: message.id,
                status: status,
                priority: priority,
                note: note,
                token: token
            ))
            let successMessage = "Изменения сохранены."
            notice = successMessage
            AppBannerCenter.shared.show(successMessage, style: .success)
            return true
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
            if let errorMessage {
                AppBannerCenter.shared.show(errorMessage, style: .error)
            }
            return false
        }
    }

    func retryEmail(_ message: FeedbackMessage) async -> Bool {
        guard let token, !token.isEmpty else { return false }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await api.retryAdminEmail(id: message.id, token: token)
            let successMessage = "Письмо снова поставлено в очередь."
            notice = successMessage
            AppBannerCenter.shared.show(successMessage, style: .success)
            await load(showsNetworkBanner: true)
            return true
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
            if let errorMessage {
                AppBannerCenter.shared.show(errorMessage, style: .error)
            }
            return false
        }
    }

    func imageData(reportID: String, attachmentID: String) async -> Data? {
        guard let token, !token.isEmpty else { return nil }
        return try? await api.attachmentData(
            reportID: reportID,
            attachmentID: attachmentID,
            token: token,
            admin: true
        )
    }

    private func replace(_ message: FeedbackMessage) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.insert(message, at: 0)
        }
        persist()
    }

    private func persist() {
        AppOfflineSnapshotStore.save(messages, key: cacheKey)
    }
}

private enum AdminFeedbackStatusFilter: String, CaseIterable, Identifiable {
    case all
    case new
    case inProgress
    case resolved
    case closed

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "Все"
        case .new: "Новые"
        case .inProgress: "В работе"
        case .resolved: "Решено"
        case .closed: "Закрыто"
        }
    }

    func includes(_ status: FeedbackStatus) -> Bool {
        switch self {
        case .all: true
        case .new: status == .new
        case .inProgress: status == .inProgress
        case .resolved: status == .resolved
        case .closed: status == .closed
        }
    }
}

struct AdminFeedbackPanel: View {
    @State private var store: AdminFeedbackStore
    @State private var searchText = ""
    @State private var statusFilter: AdminFeedbackStatusFilter = .all
    @State private var kindFilter: FeedbackKind?

    let permissions: Set<AdminPermission>

    init(
        token: String?,
        cacheID: String?,
        permissions: Set<AdminPermission>
    ) {
        _store = State(initialValue: AdminFeedbackStore(token: token, cacheID: cacheID))
        self.permissions = permissions
    }

    var body: some View {
        AppScreen {
            AdminFeedbackOverview(messages: store.messages)

            if let error = store.errorMessage {
                AppNoticeBanner(text: error, tint: AppTheme.dangerTint, isCritical: true)
            }
            if let notice = store.notice {
                AppNoticeBanner(text: notice, tint: AppTheme.primaryTint)
            }

            HStack(spacing: 10) {
                NavigationLink {
                    FeedbackSingleChoiceScreen(
                        navigationTitle: "Статус",
                        options: AdminFeedbackStatusFilter.allCases,
                        selection: $statusFilter,
                        optionTitle: { $0.title }
                    )
                } label: {
                    Label(statusFilter.title, systemImage: "line.3.horizontal.decrease.circle")
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)

                NavigationLink {
                    FeedbackSingleChoiceScreen(
                        navigationTitle: "Тема",
                        options: [nil] + FeedbackKind.allCases.map(Optional.some),
                        selection: $kindFilter,
                        optionTitle: { $0?.title ?? "Все темы" },
                        optionSystemImage: { $0?.systemImage }
                    )
                } label: {
                    Label(kindFilter?.title ?? "Все темы", systemImage: kindFilter?.systemImage ?? "tag")
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)

                Spacer(minLength: 0)
            }

            AppSectionHeader(
                title: "Обратная связь",
                caption: "Показано \(filteredMessages.count) из \(store.messages.count)"
            )

            if store.isLoading && store.messages.isEmpty {
                AppLoadingView(title: "Загружаю сообщения")
            } else if filteredMessages.isEmpty {
                AppEmptyState(
                    title: "Сообщений нет",
                    message: "Измените фильтр или поисковый запрос.",
                    systemName: "text.bubble"
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(filteredMessages.enumerated()), id: \.element.id) { index, message in
                        NavigationLink {
                            AdminFeedbackDetailScreen(
                                messageID: message.id,
                                store: store,
                                canManage: permissions.contains(.manageFeedback)
                            )
                        } label: {
                            AdminFeedbackRow(message: message)
                        }
                        .buttonStyle(.plain)
                        if index < filteredMessages.count - 1 {
                            Divider().padding(.leading, 62)
                        }
                    }
                }
                .background(AppTheme.cardSurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
            }
        }
        .navigationTitle("Обратная связь")
        .navigationBarTitleDisplayMode(.inline)
        .appNativeSearch(text: $searchText, prompt: "Номер, заголовок, имя или почта")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await store.load(showsNetworkBanner: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(store.isLoading)
                .accessibilityLabel("Обновить обратную связь")
            }
        }
        .refreshable { await store.load(showsNetworkBanner: true) }
        .task { await store.load() }
    }

    private var filteredMessages: [FeedbackMessage] {
        let query = searchText
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: AppLocale.russian)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return store.messages.filter { message in
            guard statusFilter.includes(message.status) else { return false }
            if let kindFilter, message.kind != kindFilter { return false }
            guard !query.isEmpty else { return true }
            return [message.number, message.title, message.message, message.reporterName ?? "", message.reporterEmail]
                .map {
                    $0.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: AppLocale.russian)
                        .lowercased()
                }
                .contains { $0.contains(query) }
        }
    }
}

private struct AdminFeedbackOverview: View {
    let messages: [FeedbackMessage]

    var body: some View {
        HStack(spacing: 0) {
            metric("Всего", messages.count, "text.bubble", AppTheme.primaryTint)
            Divider().frame(height: 46)
            metric("Новые", messages.filter { $0.status == .new }.count, "sparkles", AppTheme.secondaryTint)
            Divider().frame(height: 46)
            metric("В работе", messages.filter { $0.status == .inProgress }.count, "hammer.fill", .blue)
            Divider().frame(height: 46)
            metric("Критичные", messages.filter { $0.impact == .blocks }.count, "exclamationmark.octagon.fill", AppTheme.dangerTint)
        }
        .padding(.vertical, 10)
        .background(AppTheme.cardSurface.opacity(0.82), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
    }

    private func metric(_ title: String, _ value: Int, _ icon: String, _ tint: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.caption.weight(.bold)).foregroundStyle(tint)
            Text(value.formatted()).font(.headline.weight(.bold)).foregroundStyle(AppTheme.ink)
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(AppTheme.mutedTint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct AdminFeedbackRow: View {
    let message: FeedbackMessage

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: message.kind.systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(message.status.tint)
                .frame(width: 38, height: 38)
                .background(message.status.tint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(message.number)
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(AppTheme.mutedTint)
                    Text(message.status.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(message.status.tint)
                }
                Text(message.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(2)
                Text(message.reporterName ?? message.reporterEmail)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedTint)
                    .lineLimit(1)
                Text(feedbackFullDate(message.submittedAt ?? message.createdAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.forward")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 10)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

private struct AdminFeedbackDetailScreen: View {
    @Bindable var store: AdminFeedbackStore
    let messageID: String
    let canManage: Bool
    @State private var status: FeedbackStatus
    @State private var priority: FeedbackPriority
    @State private var note: String

    init(messageID: String, store: AdminFeedbackStore, canManage: Bool) {
        self.messageID = messageID
        self.store = store
        self.canManage = canManage
        let message = store.messages.first { $0.id == messageID }
        _status = State(initialValue: message?.status ?? .new)
        _priority = State(initialValue: message?.priority ?? .normal)
        _note = State(initialValue: message?.adminNote ?? "")
    }

    var body: some View {
        Group {
            if let message {
                AppScreen {
                    FeedbackReportHero(message: message)
                    AdminFeedbackReporterPanel(message: message)
                    FeedbackReportNarrative(message: message)

                    if !message.attachments.isEmpty {
                        FeedbackAttachmentGallery(
                            reportID: message.id,
                            attachments: message.attachments,
                            load: store.imageData
                        )
                    }

                    if !message.additions.isEmpty {
                        FeedbackAdditionsTimeline(
                            title: "Дополнения пользователя",
                            additions: message.additions
                        )
                    }

                    if canManage {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 12) {
                                Image(systemName: "slider.horizontal.3")
                                    .font(.headline.weight(.semibold))
                                    .foregroundStyle(AppTheme.primaryTint)
                                    .frame(width: 42, height: 42)
                                    .background(AppTheme.primaryTint.opacity(0.13), in: Circle())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Обработка")
                                        .font(.headline)
                                        .foregroundStyle(AppTheme.ink)
                                    Text("Статус, приоритет и внутренняя заметка")
                                        .font(.caption)
                                        .foregroundStyle(AppTheme.mutedTint)
                                }
                            }

                            NavigationLink {
                                FeedbackSingleChoiceScreen(
                                    navigationTitle: "Статус",
                                    options: FeedbackStatus.allCases.filter { $0 != .draft },
                                    selection: $status,
                                    optionTitle: { $0.title }
                                )
                            } label: {
                                AdminFeedbackProcessingRow(
                                    title: "Статус",
                                    value: status.title,
                                    systemImage: "circle.dotted",
                                    tint: status.tint
                                )
                            }
                            .buttonStyle(.plain)
                            NavigationLink {
                                FeedbackSingleChoiceScreen(
                                    navigationTitle: "Приоритет",
                                    options: FeedbackPriority.allCases,
                                    selection: $priority,
                                    optionTitle: { $0.title }
                                )
                            } label: {
                                AdminFeedbackProcessingRow(
                                    title: "Приоритет",
                                    value: priority.title,
                                    systemImage: "flag.fill",
                                    tint: priority == .critical ? AppTheme.dangerTint : AppTheme.secondaryTint
                                )
                            }
                            .buttonStyle(.plain)
                            TextField("Внутренняя заметка", text: $note, axis: .vertical)
                                .lineLimit(3 ... 8)
                                .padding(13)
                                .background(
                                    AppTheme.subpanelSurface,
                                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                                )
                            Button {
                                Task {
                                    _ = await store.update(
                                        message,
                                        status: status,
                                        priority: priority,
                                        note: note
                                    )
                                }
                            } label: {
                                HStack {
                                    Spacer()
                                    if store.isSaving { ProgressView().controlSize(.small) }
                                    Text(store.isSaving ? "Сохраняем" : "Сохранить")
                                    Spacer()
                                }
                            }
                            .buttonStyle(AppActionButtonStyle())
                            .disabled(store.isSaving)

                            if message.emailStatus == .failed {
                                Button {
                                    Task { _ = await store.retryEmail(message) }
                                } label: {
                                    Label("Повторить отправку письма", systemImage: "envelope.arrow.triangle.branch")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(AppActionButtonStyle())
                                .disabled(store.isSaving)
                            }
                        }
                        .padding(18)
                        .background(
                            AppTheme.cardSurface,
                            in: RoundedRectangle(cornerRadius: 26, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 26, style: .continuous)
                                .stroke(AppTheme.primaryTint.opacity(0.16), lineWidth: 1)
                        )
                    }
                }
                .navigationTitle(message.number)
                .navigationBarTitleDisplayMode(.inline)
            } else {
                ContentUnavailableView("Сообщение не найдено", systemImage: "text.bubble")
            }
        }
    }

    private var message: FeedbackMessage? {
        store.messages.first { $0.id == messageID }
    }
}

private struct AdminFeedbackProcessingRow: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 22)
            Text(title)
                .foregroundStyle(AppTheme.ink)
            Spacer(minLength: 10)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            Image(systemName: "chevron.forward")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(13)
        .background(AppTheme.subpanelSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct AdminFeedbackReporterPanel: View {
    let message: FeedbackMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.title2)
                    .foregroundStyle(AppTheme.primaryTint)
                    .frame(width: 46, height: 46)
                    .background(AppTheme.primaryTint.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(message.reporterName ?? "Пользователь")
                        .font(.headline)
                        .foregroundStyle(AppTheme.ink)
                    Text(message.reporterEmail)
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedTint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                spacing: 10
            ) {
                infoTile("Устройство", message.deviceInfo?.deviceModel ?? "—", "iphone")
                infoTile("ОС", message.deviceInfo?.osVersion ?? "—", "gearshape.2")
                infoTile("Приложение", message.deviceInfo?.appVersion ?? "—", "app.badge")
                infoTile("Письмо", message.emailStatus.title, "envelope")
            }
        }
        .padding(18)
        .background(AppTheme.cardSurface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(AppTheme.primaryTint.opacity(0.14), lineWidth: 1)
        )
    }

    private func infoTile(_ title: String, _ value: String, _ systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.primaryTint)
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
        .padding(12)
        .background(AppTheme.subpanelSurface, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }
}
