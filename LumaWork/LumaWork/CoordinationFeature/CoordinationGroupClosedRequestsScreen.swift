import Foundation
import SwiftUI

private struct GroupClosedRequestsFilterID: Hashable {
    let revision: UInt64
    let query: String
    let excludedTypes: Data
    let day: Date
}

struct CoordinationGroupClosedRequestsScreen: View {
    let simpleOneStore: SimpleOneRequestsStore
    let store: CoordinationGroupClosedRequestsStore
    let lumaWorkAuthToken: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("CoordinationGroupClosedRequests.excludedTypes") private var excludedTypesData = Data()
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var list = GroupClosedRequestsList()
    @State private var referenceDate = Date()
    @State private var visibleDayID: String?
    @State private var selectedRequest: SimpleOneRequestRecord?
    @State private var loadingRequestID: String?

    private var excludedTypes: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: excludedTypesData)) ?? []
    }

    private var filterID: GroupClosedRequestsFilterID {
        GroupClosedRequestsFilterID(
            revision: store.itemsRevision,
            query: searchText,
            excludedTypes: excludedTypesData,
            day: Calendar.autoupdatingCurrent.startOfDay(for: referenceDate)
        )
    }

    private var visibleDay: GroupClosedRequestDay? {
        list.days.first { $0.id == visibleDayID } ?? list.days.first
    }

    private var selectedRequestIsPresented: Binding<Bool> {
        Binding(
            get: { selectedRequest != nil },
            set: { if !$0 { selectedRequest = nil } }
        )
    }

    var body: some View {
        AppScreen(fixedTopContent: {
            if simpleOneStore.isAuthorized, !list.days.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(list.count) из \(store.totalCount ?? store.items.count)")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.mutedTint)
                        Spacer(minLength: 4)
                        Label("Сегодня и вчера", systemImage: "calendar")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.primaryTint)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(AppTheme.primaryTint.opacity(0.10), in: Capsule())
                    }
                    if let visibleDay {
                        ClosedRequestDayHeader(title: visibleDay.title, caption: visibleDay.caption)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }) {
            if !simpleOneStore.isAuthorized {
                AppEmptyState(
                    title: "SimpleOne не подключён",
                    message: "Войдите в SimpleOne на экране «Заявки».",
                    systemName: "person.crop.circle.badge.exclamationmark"
                )
            } else if let errorMessage = errorMessage ?? store.errorMessage {
                AppNoticeBanner(text: errorMessage, tint: AppTheme.dangerTint, isCritical: true)
            }
            if simpleOneStore.isAuthorized, store.isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Загружено \(store.loadedCount) из \(store.totalCount.map(String.init) ?? "…")")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.mutedTint)
                }
            }
            if !simpleOneStore.isAuthorized {
                EmptyView()
            } else if store.items.isEmpty, store.isLoading {
                AppLoadingView(title: "Загружаю закрытые заявки группы")
            } else if list.days.isEmpty {
                AppEmptyState(
                    title: "Заявок нет",
                    message: store.items.isEmpty
                        ? "SimpleOne не вернул закрытые заявки группы."
                        : "За сегодня и вчера нет заявок с выбранными типами.",
                    systemName: "checklist"
                )
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(list.days) { day in
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(Array(day.items.enumerated()), id: \.element.id) { index, item in
                                requestCard(item)
                                    .depthStackPrimary(
                                        reduceMotion: reduceMotion,
                                        stage: day.startIndex + index
                                    )
                            }
                        }
                        .background(alignment: .top) {
                            ClosedRequestDayMarker(dayKey: day.id)
                        }
                    }
                }
                .onPreferenceChange(ClosedRequestDayPositionKey.self) { positions in
                    let next = ClosedRequestDayTracking.visibleKey(
                        orderedKeys: list.days.map(\.id), positions: positions
                    )
                    if visibleDayID != next {
                        visibleDayID = next
                    }
                }
            }
        }
        .navigationTitle("Закрытые заявки группы")
        .navigationBarTitleDisplayMode(.inline)
        .appNativeSearch(text: $searchText, prompt: "Поиск", isEnabled: simpleOneStore.isAuthorized)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Показать все") {
                        excludedTypesData = Data()
                    }
                    ForEach(list.availableTypes, id: \.key) { type in
                        Button {
                            toggleType(type.key)
                        } label: {
                            Label(
                                type.title,
                                systemImage: excludedTypes.contains(type.key) ? "square" : "checkmark.square.fill"
                            )
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                }
                .accessibilityLabel("Фильтр по типам заявок")
            }
        }
        .refreshable { await store.refresh(simpleOneStore: simpleOneStore) }
        .task(id: filterID) { await rebuildList() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            referenceDate = Date()
        }
        .task(id: "\(simpleOneStore.isAuthorized)|\(makeCoordinationSessionID(for: simpleOneStore))") {
            if simpleOneStore.isAuthorized {
                await store.refresh(simpleOneStore: simpleOneStore)
            } else {
                store.synchronizeSession(simpleOneStore: simpleOneStore)
                list = GroupClosedRequestsList()
            }
        }
        .navigationDestination(isPresented: selectedRequestIsPresented) {
            if let selectedRequest {
                ActiveSimpleOneRequestDetailScreen(
                    record: selectedRequest,
                    lumaWorkAuthToken: lumaWorkAuthToken
                )
            }
        }
    }

    private func toggleType(_ key: String) {
        var excluded = excludedTypes
        if !excluded.insert(key).inserted { excluded.remove(key) }
        excludedTypesData = (try? JSONEncoder().encode(excluded)) ?? Data()
    }

    private func requestCard(_ item: GroupClosedRequestItem) -> some View {
        let record = item.source
        let display = item.display
        let statusText = localizedClosedRequestStatus(record.state)
        return ClosedRequestsScreen.SimpleOneActiveRequestCardContainer(
            statusText: statusText,
            statusStyle: .closedStatus(statusText)
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Text(record.incomingNumber.isEmpty ? record.number : record.incomingNumber)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ClosedRequestsScreen.RequestChip(
                        text: display.requestType,
                        style: .requestType(display.requestType)
                    )
                }
                infoRow(title: display.timeTitle, value: display.closedAtText)
                infoRow(
                    title: "Исполнитель",
                    value: record.assignedUser.isEmpty ? "Не назначен" : record.assignedUser
                )
                if !record.customer.isEmpty, item.typeKey != "returnequip" {
                    infoRow(title: "Заказчик", value: record.customer)
                }
                if !record.address.isEmpty, item.typeKey != "returnequip" {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Адрес").foregroundStyle(AppTheme.mutedTint)
                        Text(display.normalizedAddress).foregroundStyle(AppTheme.ink)
                    }
                    .font(.subheadline.weight(.semibold))
                }
                if !record.terminalID.isEmpty {
                    HStack(alignment: .top, spacing: 12) {
                        Text("ID терминала").foregroundStyle(AppTheme.mutedTint)
                        Spacer(minLength: 12)
                        AppSelectableText(
                            text: record.terminalID,
                            textStyle: .subheadline,
                            weight: .semibold,
                            color: AppTheme.primaryTint,
                            textAlignment: .right,
                            isUnderlined: true,
                            onTap: { AppClipboard.copyTerminalID(record.terminalID) }
                        )
                    }
                    .font(.subheadline.weight(.semibold))
                }
                if loadingRequestID == record.id {
                    AppLoadingView(title: "Загружаю детали")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { open(record) }
        }
    }

    private func infoRow(title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title).foregroundStyle(AppTheme.mutedTint)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(AppTheme.ink)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.subheadline.weight(.semibold))
    }

    private func open(_ record: SimpleOneRequestRecord) {
        guard loadingRequestID == nil else { return }
        AppHaptics.trigger()
        loadingRequestID = record.id
        Task {
            defer { loadingRequestID = nil }
            do {
                selectedRequest = try await simpleOneStore.fetchDetailedRequest(record)
            } catch {
                errorMessage = appUserFacingErrorMessage(error)
            }
        }
    }

    private func rebuildList() async {
        let snapshot = store.items
        let query = searchText
        let excluded = excludedTypes
        let now = referenceDate
        let rebuilt = await Task.detached(priority: .userInitiated) {
            GroupClosedRequestsList.build(items: snapshot, query: query, excludedTypes: excluded, now: now)
        }.value
        guard !Task.isCancelled, list != rebuilt else { return }
        list = rebuilt
    }

}
