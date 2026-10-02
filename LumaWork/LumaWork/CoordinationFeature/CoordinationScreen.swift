import SwiftUI

struct CoordinationScreen: View {
    let simpleOneStore: SimpleOneRequestsStore
    let groupClosedRequestsStore: CoordinationGroupClosedRequestsStore
    let lumaWorkAuthToken: String?

    @State private var store: CoordinationStore
    @State private var selectedSection: CoordinationSection = .distribution
    @State private var selectedReturnEquipmentRequest: SimpleOneRequestRecord?
    @AppStorage("CoordinationScreen.selectedRegion")
    private var selectedRegionRawValue = CoordinationRegion.defaultRegion.rawValue

    init(
        simpleOneStore: SimpleOneRequestsStore,
        lumaWorkAuthToken: String? = nil,
        store: CoordinationStore,
        groupClosedRequestsStore: CoordinationGroupClosedRequestsStore
    ) {
        self.simpleOneStore = simpleOneStore
        self.groupClosedRequestsStore = groupClosedRequestsStore
        self.lumaWorkAuthToken = lumaWorkAuthToken
        _store = State(initialValue: store)
    }

    private var selectedRegion: CoordinationRegion {
        CoordinationRegion(rawValue: selectedRegionRawValue) ?? .defaultRegion
    }

    private var hasCurrentScope: Bool {
        simpleOneStore.isAuthorized
            && store.region == selectedRegion
            && store.sessionID == simpleOneSessionID
    }

    private var visibleEngineers: [CoordinationEngineer] {
        guard hasCurrentScope else { return [] }
        return store.engineers
    }

    private var visibleRequestCount: Int {
        visibleEngineers.reduce(0) { $0 + $1.requestCount }
    }

    private var visibleEngineerCount: Int {
        visibleEngineers.lazy.filter { !$0.isUnassigned }.count
    }

    private var hasCurrentReturnEquipmentScope: Bool {
        simpleOneStore.isAuthorized
            && store.returnEquipmentSessionID == simpleOneSessionID
    }

    private var visibleReturnEquipmentRequests: [SimpleOneRequestRecord] {
        guard hasCurrentReturnEquipmentScope else { return [] }
        return store.returnEquipmentRequests.sorted { lhs, rhs in
            let lhsDate = lhs.registeredDate ?? .distantPast
            let rhsDate = rhs.registeredDate ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return lhs.number.localizedStandardCompare(rhs.number) == .orderedDescending
        }
    }

    private var currentSimpleOneUserName: String {
        let displayName = simpleOneStore.currentUser?.displayName
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !displayName.isEmpty {
            return displayName
        }
        let username = simpleOneStore.username.trimmingCharacters(in: .whitespacesAndNewlines)
        return username.isEmpty ? "Текущий пользователь" : username
    }

    private var simpleOneSessionID: String {
        makeCoordinationSessionID(for: simpleOneStore)
    }

    private var refreshTaskID: String {
        guard simpleOneStore.isAuthorized else { return "signed-out" }
        switch selectedSection {
        case .distribution:
            return "distribution|\(selectedRegion.rawValue)|\(simpleOneSessionID)"
        case .returnEquipment:
            return "return-equipment|\(simpleOneSessionID)"
        }
    }

    private var returnEquipmentDetailIsPresented: Binding<Bool> {
        Binding(
            get: { selectedReturnEquipmentRequest != nil },
            set: { isPresented in
                if !isPresented {
                    selectedReturnEquipmentRequest = nil
                }
            }
        )
    }

    var body: some View {
        AppScreen {
            if !simpleOneStore.isAuthorized {
                AppEmptyState(
                    title: "SimpleOne не подключён",
                    message: "Войдите в SimpleOne на экране «Заявки», затем вернитесь в координацию.",
                    systemName: "person.crop.circle.badge.exclamationmark"
                )
            } else {
                switch selectedSection {
                case .distribution:
                    distributionContent
                case .returnEquipment:
                    returnEquipmentContent
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                CoordinationSectionPicker(selection: $selectedSection)
            }

            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    CoordinationGroupClosedRequestsScreen(
                        simpleOneStore: simpleOneStore,
                        store: groupClosedRequestsStore,
                        lumaWorkAuthToken: lumaWorkAuthToken
                    )
                } label: {
                    Image(systemName: "checklist.checked")
                }
                .disabled(!simpleOneStore.isAuthorized)
                .accessibilityLabel("Закрытые заявки группы")
            }
        }
        .refreshable {
            await refreshSelectedSection()
        }
        .task(id: refreshTaskID) {
            guard simpleOneStore.isAuthorized else {
                store.reset()
                return
            }
            await refreshSelectedSection()
        }
        .navigationDestination(isPresented: returnEquipmentDetailIsPresented) {
            if let selectedReturnEquipmentRequest {
                CoordinationRequestDetailScreen(
                    initialRecord: selectedReturnEquipmentRequest,
                    simpleOneStore: simpleOneStore,
                    lumaWorkAuthToken: lumaWorkAuthToken,
                    store: store
                )
            }
        }
    }

    @ViewBuilder
    private var distributionContent: some View {
        CoordinationRegionSummaryCard(
            region: selectedRegion,
            engineerCount: visibleEngineerCount,
            requestCount: visibleRequestCount,
            lastUpdatedAt: hasCurrentScope ? store.lastUpdatedAt : nil,
            isLoading: !hasCurrentScope || store.isLoading,
            onSelect: selectRegion
        )

        if hasCurrentScope, let errorMessage = store.errorMessage {
            AppNoticeBanner(
                text: errorMessage,
                tint: AppTheme.dangerTint,
                isCritical: true
            )
        }

        if !hasCurrentScope || (store.isLoading && !store.hasCurrentSnapshot) {
            CoordinationLoadingCard()
        } else if visibleEngineers.isEmpty, store.hasCurrentSnapshot {
            AppEmptyState(
                title: "Активных заявок нет",
                message: store.errorMessage == nil
                    ? "В выбранном регионе нет активных заявок."
                    : "В последних сохранённых данных нет активных заявок.",
                systemName: "person.2.slash"
            )
        } else if visibleEngineers.isEmpty {
            AppEmptyState(
                title: "Нет сохранённых данных",
                message: "Подключитесь к интернету и обновите координацию.",
                systemName: "wifi.slash"
            )
        } else {
            AppSectionHeader(
                title: "Распределение",
                caption: "По инженерам и без назначения"
            )

            CoordinationListSurface {
                ForEach(Array(visibleEngineers.enumerated()), id: \.element.id) { index, engineer in
                    NavigationLink {
                        CoordinationEngineerRequestsScreen(
                            engineerID: engineer.id,
                            engineerName: engineer.name,
                            isUnassigned: engineer.isUnassigned,
                            region: selectedRegion,
                            simpleOneStore: simpleOneStore,
                            lumaWorkAuthToken: lumaWorkAuthToken,
                            store: store
                        )
                    } label: {
                        CoordinationEngineerRow(engineer: engineer)
                    }
                    .buttonStyle(.plain)

                    if index < visibleEngineers.count - 1 {
                        Divider()
                            .padding(.leading, 54)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var returnEquipmentContent: some View {
        CoordinationReturnEquipmentSummary(
            userName: currentSimpleOneUserName,
            requestCount: visibleReturnEquipmentRequests.count,
            lastUpdatedAt: hasCurrentReturnEquipmentScope ? store.returnEquipmentUpdatedAt : nil,
            isLoading: !hasCurrentReturnEquipmentScope || store.isReturnEquipmentLoading
        )

        if hasCurrentReturnEquipmentScope,
           let errorMessage = store.returnEquipmentErrorMessage {
            AppNoticeBanner(
                text: errorMessage,
                tint: AppTheme.dangerTint,
                isCritical: true
            )
        }

        if !hasCurrentReturnEquipmentScope
            || (store.isReturnEquipmentLoading && !store.hasReturnEquipmentSnapshot) {
            CoordinationLoadingCard()
        } else if visibleReturnEquipmentRequests.isEmpty,
                  store.hasReturnEquipmentSnapshot {
            AppEmptyState(
                title: "Заявок «Возврат ТО» нет",
                message: store.returnEquipmentErrorMessage == nil
                    ? "У текущего пользователя нет активных заявок этого типа."
                    : "В последних сохранённых данных таких заявок нет.",
                systemName: "shippingbox"
            )
        } else if visibleReturnEquipmentRequests.isEmpty {
            AppEmptyState(
                title: "Нет сохранённых данных",
                message: "Подключитесь к интернету и обновите вкладку «Возврат ТО».",
                systemName: "wifi.slash"
            )
        } else {
            AppSectionHeader(
                title: "Мои возвраты",
                caption: "Активные заявки текущего пользователя"
            )

            CoordinationRequestListSurface {
                ForEach(visibleReturnEquipmentRequests) { request in
                    Button {
                        AppHaptics.trigger()
                        selectedReturnEquipmentRequest = request
                    } label: {
                        CoordinationRequestRow(
                            record: request,
                            showsRequestType: false,
                            usesMulticardStatus: false,
                            terminalSerialNumber: store.returnEquipmentSerialNumber(for: request)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func selectRegion(_ region: CoordinationRegion) {
        guard selectedRegion != region else { return }
        AppHaptics.trigger(.expandCollapse)
        selectedRegionRawValue = region.rawValue
    }

    private func refreshSelectedSection() async {
        guard simpleOneStore.isAuthorized else { return }
        switch selectedSection {
        case .distribution:
            await store.refresh(
                region: selectedRegion,
                sessionID: simpleOneSessionID,
                simpleOneStore: simpleOneStore
            )
        case .returnEquipment:
            await store.refreshReturnEquipment(
                sessionID: simpleOneSessionID,
                simpleOneStore: simpleOneStore
            )
        }
    }
}

private struct CoordinationSectionPicker: View {
    @Binding var selection: CoordinationSection

    var body: some View {
        Picker("Раздел координации", selection: $selection) {
            ForEach(CoordinationSection.allCases) { section in
                Text(section.title).tag(section)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 216)
        .onChange(of: selection) { _, _ in
            AppHaptics.trigger(.expandCollapse)
        }
    }
}

private struct CoordinationRegionSummaryCard: View {
    let region: CoordinationRegion
    let engineerCount: Int
    let requestCount: Int
    let lastUpdatedAt: Date?
    let isLoading: Bool
    let onSelect: (CoordinationRegion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "person.2.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryTint)
                    .frame(width: 40, height: 40)
                    .background(AppTheme.primaryTint.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text("Регион / город")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedTint)

                    Menu {
                        ForEach(CoordinationRegion.allCases) { option in
                            Button {
                                onSelect(option)
                            } label: {
                                if option == region {
                                    Label(option.title, systemImage: "checkmark")
                                } else {
                                    Text(option.title)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(region.title)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(AppTheme.ink)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(AppTheme.primaryTint)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Выбрать регион или город")
                    .accessibilityValue(region.title)

                    Text("Координация СО ТО Крым")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.mutedTint)
                }

                Spacer(minLength: 8)

                if isLoading {
                    CoordinationShimmerText(
                        text: "Обновляю",
                        font: .caption.weight(.semibold)
                    )
                }
            }

            Divider()

            HStack(spacing: 10) {
                CoordinationSummaryMetric(
                    value: "\(engineerCount)",
                    title: coordinationEngineerCountTitle(engineerCount)
                )
                CoordinationSummaryMetric(
                    value: "\(requestCount)",
                    title: coordinationRequestCountTitle(requestCount)
                )
            }

            if let lastUpdatedAt {
                Text("Обновлено \(lastUpdatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedTint)
            }
        }
        .padding(.horizontal, 2)
    }
}

private struct CoordinationReturnEquipmentSummary: View {
    let userName: String
    let requestCount: Int
    let lastUpdatedAt: Date?
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "shippingbox.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryTint)
                    .frame(width: 40, height: 40)
                    .background(AppTheme.primaryTint.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("Возврат оборудования")
                        .font(.headline)
                        .foregroundStyle(AppTheme.ink)
                    Text(userName)
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.mutedTint)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(requestCount, format: .number)
                    .font(.headline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.primaryTint)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(AppTheme.primaryTint.opacity(0.12), in: Capsule())

                if isLoading {
                    CoordinationShimmerText(
                        text: "Обновляю",
                        font: .caption.weight(.semibold)
                    )
                }
            }

            if let lastUpdatedAt {
                Text("Обновлено \(lastUpdatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedTint)
            }
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct CoordinationSummaryMetric: View {
    let value: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(AppTheme.ink)
            Text(title)
                .font(.caption)
                .foregroundStyle(AppTheme.mutedTint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.softFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct CoordinationListSurface<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AppTheme.cardSurface.opacity(0.82),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
    }
}

private struct CoordinationRequestListSurface<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 10) {
            content
        }
        .padding(.horizontal, 0)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CoordinationEngineerRow: View {
    let engineer: CoordinationEngineer

    private var tint: Color {
        engineer.isUnassigned ? .orange : AppTheme.primaryTint
    }

    private var initials: String {
        engineer.name
            .split(whereSeparator: \.isWhitespace)
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .uppercased(with: AppLocale.russian)
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.12))

                if engineer.isUnassigned {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.body.weight(.semibold))
                } else {
                    Text(initials.isEmpty ? "?" : initials)
                        .font(.caption.weight(.bold))
                }
            }
            .foregroundStyle(tint)
            .frame(width: 38, height: 38)

            Text(engineer.name)
                .font(.body.weight(.semibold))
                .foregroundStyle(AppTheme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(engineer.requestCount)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(tint.opacity(0.12), in: Capsule())

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.mutedTint)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(engineer.name), \(engineer.requestCount) \(coordinationRequestCountTitle(engineer.requestCount))"
        )
    }
}

private struct CoordinationEngineerRequestsScreen: View {
    let engineerID: String
    let engineerName: String
    let isUnassigned: Bool
    let region: CoordinationRegion
    let simpleOneStore: SimpleOneRequestsStore
    let lumaWorkAuthToken: String?

    @State private var store: CoordinationStore
    @State private var selectedRequest: SimpleOneRequestRecord?
    @State private var loadingStatusRequestIDs: Set<String> = []
    @State private var statusErrorMessage: String?
    @State private var statusLoadID: UUID?

    init(
        engineerID: String,
        engineerName: String,
        isUnassigned: Bool,
        region: CoordinationRegion,
        simpleOneStore: SimpleOneRequestsStore,
        lumaWorkAuthToken: String? = nil,
        store: CoordinationStore
    ) {
        self.engineerID = engineerID
        self.engineerName = engineerName
        self.isUnassigned = isUnassigned
        self.region = region
        self.simpleOneStore = simpleOneStore
        self.lumaWorkAuthToken = lumaWorkAuthToken
        _store = State(initialValue: store)
    }

    private var hasCurrentScope: Bool {
        simpleOneStore.isAuthorized
            && store.region == region
            && store.sessionID == coordinationSessionID
    }

    private var requests: [SimpleOneRequestRecord] {
        guard hasCurrentScope else { return [] }
        return store.requests(for: engineerID)
    }

    private var refreshTaskID: String {
        guard simpleOneStore.isAuthorized else { return "signed-out" }
        return "\(region.rawValue)|\(coordinationSessionID)"
    }

    private var detailIsPresented: Binding<Bool> {
        Binding(
            get: { selectedRequest != nil },
            set: { isPresented in
                if !isPresented {
                    selectedRequest = nil
                }
            }
        )
    }

    var body: some View {
        AppScreen {
            HStack(spacing: 12) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryTint)

                VStack(alignment: .leading, spacing: 3) {
                    Text(region.title)
                        .font(.headline)
                        .foregroundStyle(AppTheme.ink)
                    Text("\(requests.count) \(coordinationRequestCountTitle(requests.count))")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.mutedTint)
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 2)

            if hasCurrentScope, let errorMessage = store.errorMessage {
                AppNoticeBanner(
                    text: errorMessage,
                    tint: AppTheme.dangerTint,
                    isCritical: true
                )
            }

            if let statusErrorMessage {
                AppNoticeBanner(
                    text: statusErrorMessage,
                    tint: AppTheme.dangerTint,
                    isCritical: true
                )
            }

            if !simpleOneStore.isAuthorized {
                AppEmptyState(
                    title: "SimpleOne не подключён",
                    message: "Войдите в SimpleOne на экране «Заявки».",
                    systemName: "person.crop.circle.badge.exclamationmark"
                )
            } else if !hasCurrentScope || (store.isLoading && !store.hasCurrentSnapshot) {
                CoordinationLoadingCard()
            } else if requests.isEmpty, store.hasCurrentSnapshot {
                AppEmptyState(
                    title: "Активных заявок нет",
                    message: store.errorMessage == nil
                        ? (isUnassigned
                            ? "Все активные заявки региона уже назначены инженерам."
                            : "У инженера больше нет активных заявок в выбранном регионе.")
                        : "В последних сохранённых данных активных заявок нет.",
                    systemName: "checkmark.circle"
                )
            } else if requests.isEmpty {
                AppEmptyState(
                    title: "Нет сохранённых данных",
                    message: "Подключитесь к интернету и обновите координацию.",
                    systemName: "wifi.slash"
                )
            } else {
                CoordinationRequestListSurface {
                    ForEach(requests) { request in
                        Button {
                            openRequest(request)
                        } label: {
                            CoordinationRequestRow(
                                record: request,
                                isLoadingDetails: loadingStatusRequestIDs.contains(request.id)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle(engineerName)
        .navigationBarTitleDisplayMode(.inline)
        .appSidebarBackButton()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    AppHaptics.trigger()
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(store.isLoading || !simpleOneStore.isAuthorized)
                .accessibilityLabel(
                    isUnassigned ? "Обновить заявки без назначения" : "Обновить заявки инженера"
                )
            }
        }
        .refreshable {
            await refresh()
        }
        .task(id: refreshTaskID) {
            guard simpleOneStore.isAuthorized else {
                store.reset()
                return
            }
            if store.region != region || store.sessionID != coordinationSessionID {
                await refresh()
            } else {
                await loadStatuses()
            }
        }
        .navigationDestination(isPresented: detailIsPresented) {
            if let selectedRequest {
                CoordinationRequestDetailScreen(
                    initialRecord: selectedRequest,
                    simpleOneStore: simpleOneStore,
                    lumaWorkAuthToken: lumaWorkAuthToken,
                    store: store
                )
            }
        }
    }

    private func refresh() async {
        guard simpleOneStore.isAuthorized else { return }
        await store.refresh(
            region: region,
            sessionID: coordinationSessionID,
            simpleOneStore: simpleOneStore
        )
        await loadStatuses()
    }

    private func loadStatuses() async {
        guard simpleOneStore.isAuthorized, hasCurrentScope else { return }
        let recordsToLoad = simpleOneStore.coordinationRequestsRequiringDetails(requests)
        guard !recordsToLoad.isEmpty else { return }

        let loadID = UUID()
        let requestIDs = Set(recordsToLoad.map(\.id))
        statusLoadID = loadID
        loadingStatusRequestIDs = requestIDs
        statusErrorMessage = nil
        defer {
            if statusLoadID == loadID {
                statusLoadID = nil
                loadingStatusRequestIDs = []
            }
        }

        do {
            let detailedRecords = try await simpleOneStore.fetchCoordinationDetails(recordsToLoad)
            guard statusLoadID == loadID,
                  !Task.isCancelled,
                  hasCurrentScope else { return }
            store.replace(detailedRecords)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            statusErrorMessage = appUserFacingErrorMessage(error)
        }
    }

    private var coordinationSessionID: String {
        makeCoordinationSessionID(for: simpleOneStore)
    }

    private func openRequest(_ request: SimpleOneRequestRecord) {
        AppHaptics.trigger()
        selectedRequest = request
    }
}

private struct CoordinationRequestDetailScreen: View {
    @Environment(\.appIsOfflineMode) private var isOfflineMode

    let initialRecord: SimpleOneRequestRecord
    let simpleOneStore: SimpleOneRequestsStore
    let lumaWorkAuthToken: String?
    let store: CoordinationStore

    @State private var record: SimpleOneRequestRecord
    @State private var errorMessage: String?

    init(
        initialRecord: SimpleOneRequestRecord,
        simpleOneStore: SimpleOneRequestsStore,
        lumaWorkAuthToken: String? = nil,
        store: CoordinationStore
    ) {
        self.initialRecord = initialRecord
        self.simpleOneStore = simpleOneStore
        self.lumaWorkAuthToken = lumaWorkAuthToken
        self.store = store
        _record = State(initialValue: initialRecord)
    }

    var body: some View {
        ActiveSimpleOneRequestDetailScreen(
            record: record,
            simpleOneAuthKey: simpleOneStore.browserAuthKey,
            lumaWorkAuthToken: lumaWorkAuthToken
        )
        .background {
            if let errorMessage {
                AppNoticeBanner(
                    text: errorMessage,
                    tint: AppTheme.dangerTint,
                    isCritical: true,
                    style: .error
                )
            }
        }
        .task(id: initialRecord.id) {
            guard !isOfflineMode else { return }
            do {
                let detailedRecord = try await simpleOneStore.fetchDetailedRequest(
                    initialRecord,
                    updatesActiveRequests: false,
                    usesCache: true
                )
                guard !Task.isCancelled else { return }
                store.replace(detailedRecord)
                record = detailedRecord
            } catch is CancellationError {
                return
            } catch {
                errorMessage = appUserFacingErrorMessage(error)
            }
        }
    }

}

private struct CoordinationRequestRow: View {
    let record: SimpleOneRequestRecord
    var showsRequestType = true
    var usesMulticardStatus = true
    var terminalSerialNumber: String? = nil
    var isLoadingDetails = false
    private let informationFields: [ClosedRequestInfoField]

    init(
        record: SimpleOneRequestRecord,
        showsRequestType: Bool = true,
        usesMulticardStatus: Bool = true,
        terminalSerialNumber: String? = nil,
        isLoadingDetails: Bool = false
    ) {
        self.record = record
        self.showsRequestType = showsRequestType
        self.usesMulticardStatus = usesMulticardStatus
        self.terminalSerialNumber = terminalSerialNumber
        self.isLoadingDetails = isLoadingDetails
        informationFields = warehouseInformationFields(record)
    }

    private var primaryNumber: String {
        let incoming = trimmed(record.incomingNumber)
        if !incoming.isEmpty {
            return incoming
        }

        let description = trimmed(record.shortDescription)
        if looksLikeExternalRequestNumber(description) {
            return description
        }

        return trimmed(record.number)
    }

    private var secondaryNumber: String? {
        let value = trimmed(record.number)
        guard !value.isEmpty, normalizedIdentifier(value) != normalizedIdentifier(primaryNumber) else {
            return nil
        }
        return value
    }

    private var descriptionText: String? {
        let value = trimmed(record.shortDescription)
        guard !value.isEmpty else { return nil }

        let normalizedValue = normalizedIdentifier(value)
        let knownNumbers = [primaryNumber, record.number, record.incomingNumber]
            .map(normalizedIdentifier)
            .filter { !$0.isEmpty }
        guard !knownNumbers.contains(normalizedValue) else { return nil }
        return value
    }

    private var status: String? {
        if usesMulticardStatus {
            guard !isCoordinationExpertiseRequestType(record.requestType) else {
                return nil
            }
            let rawStatus = value(
                for: ["МК Статус", "МК статус", "Статус заявки Мультикарта"],
                in: informationFields
            )
            let localizedStatus = localizedMulticardStatus(rawStatus)
            return localizedStatus.isEmpty
                ? (isLoadingDetails ? "Загружаю статус" : "Статус недоступен")
                : localizedStatus
        } else {
            let state = record.state.trimmingCharacters(in: .whitespacesAndNewlines)
            return state.isEmpty ? nil : state
        }
    }

    private var statusTint: Color {
        let value = (status ?? "")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if value.contains("ожидан") || value.contains("waiting") || value.contains("pending") {
            return .orange
        }
        if value.contains("отказ") || value.contains("отмен") || value.contains("cancel") {
            return AppTheme.dangerTint
        }
        if value.contains("решен") || value.contains("выполн") || value.contains("закрыт") || value.contains("completed") {
            return .green
        }
        if value.contains("недоступ") {
            return AppTheme.mutedTint
        }
        return AppTheme.primaryTint
    }

    private var registeredAtText: String? {
        if let date = record.registeredDate {
            return date.formatted(date: .numeric, time: .shortened)
        }
        let raw = trimmed(record.registeredAt ?? "")
        return isPlaceholderDateText(raw) ? nil : raw
    }

    private var deadlineText: String? {
        if let date = record.deadlineDate {
            return date.formatted(date: .numeric, time: .shortened)
        }
        let raw = trimmed(record.deadline)
        return isPlaceholderDateText(raw) ? nil : raw
    }

    private var hasValidOverdueDeadline: Bool {
        guard let deadlineDate = record.deadlineDate else { return false }
        return record.source == .active && deadlineDate < Date()
    }

    private var requestTypeText: String {
        let raw = record.requestType.trimmingCharacters(in: .whitespacesAndNewlines)
        if isCoordinationReturnEquipmentRequestType(raw) {
            return "Возврат ТО"
        }
        let firstToken = raw.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? raw
        switch firstToken.lowercased() {
        case "install":
            return "Установка"
        case "servicestd":
            return "Сервис"
        case "replacement":
            return "Замена"
        case "dismounting":
            return "Демонтаж"
        default:
            return raw
        }
    }

    var body: some View {
        let fields = informationFields
        let terminalID = firstNonEmpty(
            trimmed(record.terminalID),
            value(for: ["ID терминал", "ID терминала"], in: fields)
        )
        let installedSerial = value(for: ["Оборудование POS"], in: fields)
        let dismantledSerial = firstNonEmpty(
            value(for: ["Серийный номер демонтируемого ТО"], in: fields),
            value(for: ["Номер принятого оборудования POS"], in: fields)
        )
        let address = record.address
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .normalizedAddressCommaSpacing()
        let terminalIDText = terminalID.isEmpty ? (isLoadingDetails ? "загрузка…" : "—") : terminalID
        let installedSerialText = installedSerial.isEmpty ? (isLoadingDetails ? "загрузка…" : "—") : installedSerial
        let dismantledSerialText = dismantledSerial.isEmpty
            ? terminalSerialNumber ?? (isLoadingDetails ? "загрузка…" : "—")
            : dismantledSerial

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(primaryNumber)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .layoutPriority(1)

                if let secondaryNumber {
                    Text("|")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AppTheme.mutedTint.opacity(0.65))
                    Text(secondaryNumber)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AppTheme.mutedTint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }

            if (showsRequestType && !requestTypeText.isEmpty) || status != nil {
                HStack(spacing: 8) {
                    if showsRequestType, !requestTypeText.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "wrench.and.screwdriver")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.mutedTint)
                                .frame(width: 17)
                            Text(requestTypeText)
                                .font(.subheadline)
                                .foregroundStyle(AppTheme.mutedTint)
                        }
                    }

                    Spacer(minLength: 6)

                    if let status {
                        CoordinationRequestStatusLabel(
                            text: status,
                            tint: statusTint,
                            isLoading: status == "Загружаю статус"
                        )
                    }
                }
                .padding(.top, 12)
            }

            Divider()
                .padding(.top, 10)

            HStack(alignment: .top, spacing: 10) {
                CoordinationRequestCompactField(
                    systemName: "number.square",
                    label: "ID терминала",
                    value: terminalIDText
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                compactVerticalDivider(height: 48)

                VStack(alignment: .leading, spacing: 4) {
                    CoordinationRequestCompactField(
                        systemName: "barcode",
                        label: "S/N установки",
                        value: installedSerialText
                    )
                    CoordinationRequestCompactField(
                        systemName: "barcode",
                        label: "S/N демонтажа",
                        value: dismantledSerialText
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 6)

            if registeredAtText != nil || deadlineText != nil {
                Divider()
                    .padding(.top, 6)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) {
                        requestTimingLabels
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        requestTimingLabels
                    }
                }
                .padding(.vertical, 10)
            }

            if !address.isEmpty {
                Divider()
                CoordinationRequestCompactField(
                    systemName: "mappin.and.ellipse",
                    label: "Адрес",
                    value: address,
                    lineLimit: 2
                )
                .padding(.top, 10)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            AppTheme.cardSurface.opacity(0.86),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func compactVerticalDivider(height: CGFloat) -> some View {
        Rectangle()
            .fill(AppTheme.border)
            .frame(width: 1, height: height)
    }

    @ViewBuilder
    private var requestTimingLabels: some View {
        if let registeredAtText {
            CoordinationRequestMetadataLabel(
                systemName: "calendar",
                text: registeredAtText
            )
        }

        if let deadlineText {
            CoordinationRequestMetadataLabel(
                systemName: "clock",
                text: "До \(deadlineText)",
                tint: hasValidOverdueDeadline ? AppTheme.dangerTint : AppTheme.mutedTint
            )
        }
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedIdentifier(_ value: String) -> String {
        trimmed(value)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber }
    }

    private func looksLikeExternalRequestNumber(_ value: String) -> Bool {
        let candidate = trimmed(value).uppercased()
        return !candidate.contains(where: \.isWhitespace)
            && candidate.hasPrefix("SUTS")
            && candidate.contains("-")
    }

    private func isPlaceholderDateText(_ value: String) -> Bool {
        guard !value.isEmpty else { return true }
        let normalized = value.lowercased()
        return normalized == "0"
            || normalized.contains("1970-01-01")
            || normalized.contains("01.01.1970")
    }
}

private struct CoordinationRequestStatusLabel: View {
    let text: String
    let tint: Color
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isLoading ? "arrow.trianglehead.2.clockwise.rotate.90" : "circle.fill")
                .font(isLoading ? .caption2.weight(.semibold) : .system(size: 7, weight: .semibold))
                .foregroundStyle(tint)
            if isLoading {
                CoordinationShimmerText(
                    text: text,
                    font: .caption.weight(.semibold),
                    tint: tint
                )
            } else {
                Text(text)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isLoading ? "Загружаю статус" : "Статус: \(text)")
    }
}

private struct CoordinationRequestCompactField: View {
    let systemName: String
    let label: String
    let value: String
    var lineLimit: Int? = 1

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedTint)
                .frame(width: 18)

            Text("\(label): \(value)")
                .foregroundStyle(AppTheme.ink)
                .font(.caption)
                .lineLimit(lineLimit)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CoordinationRequestMetadataLabel: View {
    let systemName: String
    let text: String
    var tint: Color = AppTheme.mutedTint

    var body: some View {
        Label {
            Text(text)
                .lineLimit(1)
        } icon: {
            Image(systemName: systemName)
        }
        .font(.caption)
        .foregroundStyle(tint)
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct CoordinationRequestInfoRow: View {
    let systemName: String
    let text: String
    var tint: Color = AppTheme.mutedTint
    var lineLimit: Int? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(text)
                .font(.caption)
                .foregroundStyle(tint)
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct CoordinationLoadingCard: View {
    var body: some View {
        AppCard {
            CoordinationShimmerText(
                text: "Обновляю",
                font: .headline.weight(.semibold)
            )
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .accessibilityLabel("Обновляю данные")
    }
}

struct CoordinationShimmerText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let text: String
    let font: Font
    var tint: Color = AppTheme.primaryTint

    @State private var startedAt = Date()

    var body: some View {
        label
            .foregroundStyle(tint.opacity(0.56))
            .overlay {
                TimelineView(
                    .animation(
                        minimumInterval: reduceMotion ? 1.0 / 30.0 : nil,
                        paused: false
                    )
                ) { timeline in
                    GeometryReader { geometry in
                        shimmerBand(
                            size: geometry.size,
                            progress: shimmerProgress(at: timeline.date)
                        )
                    }
                }
                .mask(label)
                .allowsHitTesting(false)
            }
            .onAppear {
                startedAt = Date()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .accessibilityValue("Обновление данных")
    }

    private var label: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
    }

    private func shimmerBand(size: CGSize, progress: CGFloat) -> some View {
        let bandWidth = max(size.width * 0.48, 24)
        let bandHeight = max(size.height * 3, 1)
        let overflow = size.height
        let travelDistance = size.width + bandWidth + overflow * 2

        return LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: AppTheme.ink.opacity(0.2), location: 0.3),
                .init(color: AppTheme.ink, location: 0.5),
                .init(color: AppTheme.ink.opacity(0.2), location: 0.7),
                .init(color: .clear, location: 1)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: bandWidth, height: bandHeight)
        .rotationEffect(.degrees(-45))
        .offset(
            x: -bandWidth - overflow + travelDistance * progress,
            y: (size.height - bandHeight) / 2
        )
    }

    private func shimmerProgress(at date: Date) -> CGFloat {
        let duration = reduceMotion ? 1.8 : 1.15
        let elapsed = max(date.timeIntervalSince(startedAt), 0)
        return CGFloat(elapsed.truncatingRemainder(dividingBy: duration) / duration)
    }
}

private func coordinationEngineerCountTitle(_ count: Int) -> String {
    russianPlural(count, one: "инженер", few: "инженера", many: "инженеров")
}

private func coordinationRequestCountTitle(_ count: Int) -> String {
    russianPlural(count, one: "активная заявка", few: "активные заявки", many: "активных заявок")
}

func makeCoordinationSessionID(for store: SimpleOneRequestsStore) -> String {
    let userID = store.currentUser?.sysID
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !userID.isEmpty {
        return "id:\(userID)"
    }

    let username = store.username
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    return username.isEmpty ? "authorized" : "username:\(username)"
}

private func russianPlural(_ count: Int, one: String, few: String, many: String) -> String {
    let value = abs(count) % 100
    if (11 ... 14).contains(value) {
        return many
    }

    switch value % 10 {
    case 1:
        return one
    case 2 ... 4:
        return few
    default:
        return many
    }
}
