import Foundation
import SwiftUI

private struct GroupClosedRequestItem: Identifiable {
    let source: SimpleOneRequestRecord
    let display: ClosedRequestPreparedListItem

    var id: String { source.id }
    var typeKey: String {
        source.requestType.split(whereSeparator: \.isWhitespace).first
            .map(String.init)?.lowercased() ?? ""
    }
}

private struct GroupClosedRequestDay: Identifiable {
    let id: String
    let title: String
    let caption: String
    var items: [GroupClosedRequestItem]
}

struct CoordinationGroupClosedRequestsScreen: View {
    let simpleOneStore: SimpleOneRequestsStore
    let lumaWorkAuthToken: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("CoordinationGroupClosedRequests.excludedTypes") private var excludedTypesData = Data()
    @State private var items: [GroupClosedRequestItem] = []
    @State private var totalCount: Int?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var dayPositions: [String: CGFloat] = [:]
    @State private var selectedRequest: SimpleOneRequestRecord?
    @State private var loadingRequestID: String?

    private var excludedTypes: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: excludedTypesData)) ?? []
    }

    private var availableTypes: [(key: String, title: String)] {
        var titles: [String: String] = [:]
        for item in items {
            titles[item.typeKey] = item.display.requestType.isEmpty
                ? "Тип не указан" : item.display.requestType
        }
        return titles.map { ($0.key, $0.value) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private var visibleItems: [GroupClosedRequestItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let calendar = Calendar.autoupdatingCurrent
        let excluded = excludedTypes
        return items.filter { item in
            guard let date = item.display.date,
                  calendar.isDateInToday(date) || calendar.isDateInYesterday(date),
                  !excluded.contains(item.typeKey) else { return false }
            return query.isEmpty || item.display.searchText.contains(query)
        }
    }

    private var days: [GroupClosedRequestDay] {
        var groups: [GroupClosedRequestDay] = []
        for item in visibleItems {
            if let last = groups.indices.last, groups[last].id == item.display.dayKey {
                groups[last].items.append(item)
            } else {
                groups.append(GroupClosedRequestDay(
                    id: item.display.dayKey,
                    title: item.display.dayTitle,
                    caption: item.display.dayCaption,
                    items: [item]
                ))
            }
        }
        return groups
    }

    private var visibleDay: GroupClosedRequestDay? {
        let groups = days
        guard let key = ClosedRequestDayTracking.visibleKey(
            orderedKeys: groups.map(\.id), positions: dayPositions
        ) else { return nil }
        return groups.first { $0.id == key }
    }

    private var selectedRequestIsPresented: Binding<Bool> {
        Binding(
            get: { selectedRequest != nil },
            set: { if !$0 { selectedRequest = nil } }
        )
    }

    var body: some View {
        AppScreen(fixedTopContent: {
            if simpleOneStore.isAuthorized, !days.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        AppSectionHeader(
                            title: "Закрытые заявки группы",
                            caption: "\(visibleItems.count) из \(totalCount ?? items.count)"
                        )
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
                            .id(visibleDay.id)
                            .transition(.opacity)
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
            } else if let errorMessage {
                AppNoticeBanner(text: errorMessage, tint: AppTheme.dangerTint, isCritical: true)
            }
            if simpleOneStore.isAuthorized, isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Загружено \(items.count) из \(totalCount.map(String.init) ?? "…")")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.mutedTint)
                }
            }
            if !simpleOneStore.isAuthorized {
                EmptyView()
            } else if items.isEmpty, isLoading {
                AppLoadingView(title: "Загружаю закрытые заявки группы")
            } else if visibleItems.isEmpty {
                AppEmptyState(
                    title: "Заявок нет",
                    message: items.isEmpty
                        ? "SimpleOne не вернул закрытые заявки группы."
                        : "За сегодня и вчера нет заявок с выбранными типами.",
                    systemName: "checklist"
                )
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(days) { day in
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(Array(day.items.enumerated()), id: \.element.id) { _, item in
                                requestCard(item)
                                    .depthStackPrimary(
                                        reduceMotion: reduceMotion,
                                        stage: visibleItems.firstIndex(where: { $0.id == item.id }) ?? 0
                                    )
                            }
                        }
                        .background(alignment: .top) {
                            ClosedRequestDayMarker(dayKey: day.id)
                        }
                    }
                }
                .onPreferenceChange(ClosedRequestDayPositionKey.self) { positions in
                    let keys = days.map(\.id)
                    let previous = ClosedRequestDayTracking.visibleKey(
                        orderedKeys: keys, positions: dayPositions
                    )
                    let next = ClosedRequestDayTracking.visibleKey(
                        orderedKeys: keys, positions: positions
                    )
                    if previous == next {
                        dayPositions = positions
                    } else {
                        withAnimation(.easeInOut(duration: 0.2)) { dayPositions = positions }
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
                    ForEach(availableTypes, id: \.key) { type in
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
        .refreshable { await load() }
        .task(id: "\(simpleOneStore.isAuthorized)|\(makeCoordinationSessionID(for: simpleOneStore))") {
            if simpleOneStore.isAuthorized {
                await load()
            } else {
                items = []
                totalCount = nil
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

    private func load() async {
        guard simpleOneStore.isAuthorized, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        var page = 1
        var collected: [GroupClosedRequestItem] = []
        var seenIDs = Set<String>()
        do {
            while !Task.isCancelled {
                let result = try await simpleOneStore.fetchGroupClosedRequestsPage(
                    page: page, perPage: 100
                )
                guard !Task.isCancelled, simpleOneStore.isAuthorized else { return }
                totalCount = result.totalCount ?? totalCount
                let previousCount = collected.count
                let newRecords = result.records.filter { seenIDs.insert($0.id).inserted }
                collected.append(contentsOf: Self.prepare(newRecords))
                items = collected.sorted {
                    ($0.display.date ?? .distantPast) > ($1.display.date ?? .distantPast)
                }
                guard result.hasMore, collected.count > previousCount else { break }
                page += 1
            }
        } catch is CancellationError {
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
        }
    }

    private static func prepare(_ records: [SimpleOneRequestRecord]) -> [GroupClosedRequestItem] {
        let displayRecords = records.map(ClosedRequestsStore.closedRequestRecord(from:))
        let displays = ClosedRequestsIndexBuilder.build(records: displayRecords)
        return zip(records, displays).map { GroupClosedRequestItem(source: $0, display: $1.item) }
            .sorted { lhs, rhs in
                (lhs.display.date ?? .distantPast) > (rhs.display.date ?? .distantPast)
            }
    }
}
