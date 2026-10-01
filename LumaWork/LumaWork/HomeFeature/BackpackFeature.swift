import Foundation
import Observation
import SwiftUI
import UIKit

nonisolated struct BackpackItem: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var serialNumber: String
    var responsible: String
    var receivedAt: String
    var receivedAtDate: Date?
    var quantity: Int
}

private struct BackpackItemGroup: Identifiable {
    let id: String
    let name: String
    let items: [BackpackItem]

    var quantity: Int { items.reduce(0) { $0 + max($1.quantity, 1) } }
    var representativeItem: BackpackItem { items[0] }
    var latestReceivedAtDate: Date? { items.compactMap(\.receivedAtDate).max() }
}

private enum BackpackItemLocation: String, CaseIterable, Identifiable {
    case warehouse
    case car
    case home
    case absent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .warehouse: "На складе"
        case .car: "В машине"
        case .home: "Дома"
        case .absent: "Отсутствует"
        }
    }

    var systemImage: String {
        switch self {
        case .warehouse: "shippingbox.fill"
        case .car: "car.fill"
        case .home: "house.fill"
        case .absent: "questionmark.circle.fill"
        }
    }

    static func storageIdentity(for item: BackpackItem) -> String {
        let serialNumber = item.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        return serialNumber.isEmpty || serialNumber == "(не задано)"
            ? item.id
            : serialNumber
    }

    static func legacyStorageKey(for item: BackpackItem) -> String {
        "backpack-terminal-location-v1.\(storageIdentity(for: item))"
    }
}

@MainActor
@Observable
private final class BackpackItemLocationStore {
    private static let storageKey = "backpack-terminal-location-overrides-v2"

    private let defaults: UserDefaults
    private var rawLocations: [String: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let locations = try? JSONDecoder().decode([String: String].self, from: data) {
            rawLocations = locations
        } else {
            rawLocations = [:]
        }
    }

    func location(
        for item: BackpackItem,
        isReturnEquipment: Bool
    ) -> BackpackItemLocation {
        let identity = BackpackItemLocation.storageIdentity(for: item)
        if let rawLocation = rawLocations[identity],
           let location = BackpackItemLocation(rawValue: rawLocation) {
            return location
        }
        if let legacyRawLocation = defaults.string(
            forKey: BackpackItemLocation.legacyStorageKey(for: item)
        ), let legacyLocation = BackpackItemLocation(rawValue: legacyRawLocation) {
            return legacyLocation
        }
        return isReturnEquipment ? .car : .warehouse
    }

    func setLocation(_ location: BackpackItemLocation, for item: BackpackItem) {
        var updatedLocations = rawLocations
        updatedLocations[BackpackItemLocation.storageIdentity(for: item)] = location.rawValue
        rawLocations = updatedLocations
        defaults.removeObject(forKey: BackpackItemLocation.legacyStorageKey(for: item))

        guard let data = try? JSONEncoder().encode(updatedLocations) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

@MainActor
@Observable
final class BackpackStore {
    private let service = BackpackService()
    private let cacheKey: String

    var items: [BackpackItem] = []
    var isLoading = false
    var loadingDetailIDs: Set<String> = []
    var listRevision: UInt64 = 0
    var photoRevision: UInt64 = 0
    var errorMessage: String?
    var lastUpdatedAt: Date?

    init(cacheID: String? = nil) {
        cacheKey = AppOfflineSnapshotStore.scopedKey("backpack", userID: cacheID)
        if let snapshot = AppOfflineSnapshotStore.load([BackpackItem].self, key: cacheKey) {
            items = snapshot.value
            lastUpdatedAt = snapshot.updatedAt
        }
    }

    func loadIfNeeded() async {
        guard items.isEmpty, !isLoading else { return }
        await refresh()
    }

    func refresh() async {
        guard !isLoading else { return }

        guard let authKey = SimpleOneSessionKeychain.readAuthKey() else {
            errorMessage = "Войдите в SimpleOne, чтобы загрузить рюкзак."
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let listedItems = try await service.fetchItems(authKey: authKey)
            try Task.checkCancellation()
            let cachedByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
            items = listedItems.map { item in
                guard let cached = cachedByID[item.id],
                      item.receivedAtDate == nil,
                      item.name == cached.name,
                      item.serialNumber == cached.serialNumber,
                      item.responsible == cached.responsible,
                      item.quantity == cached.quantity else { return item }
                var item = item
                item.receivedAt = cached.receivedAt
                item.receivedAtDate = cached.receivedAtDate
                return item
            }
            lastUpdatedAt = Date()
            listRevision &+= 1
            photoRevision &+= 1
            AppOfflineSnapshotStore.save(items, key: cacheKey)

            loadingDetailIDs = Set(items.map(\.id))
            defer { loadingDetailIDs = [] }
            try await service.hydrateItems(listedItems, cachedItems: Array(cachedByID.values), authKey: authKey) { [weak self] detailed in
                guard let self else { return }
                if let index = self.items.firstIndex(where: { $0.id == detailed.id }) {
                    self.items[index] = detailed
                }
                self.loadingDetailIDs.remove(detailed.id)
            }
            try Task.checkCancellation()
            AppOfflineSnapshotStore.save(items, key: cacheKey)
            if zip(items, listedItems).contains(where: { $0.0.name != $0.1.name }) {
                photoRevision &+= 1
            }
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch SimpleOneServiceError.unauthorized {
            SimpleOneSessionKeychain.deleteAuthKey()
            errorMessage = SimpleOneServiceError.unauthorized.errorDescription
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
        }
    }
}

private struct BackpackService {
    private let simpleOneService = SimpleOneRequestsService()
    private var condition: String {
        guard let currentUserDynamicID = AppConfig.resolveFirst("SIMPLEONE_CURRENT_USER_DYNAMIC_ID"),
              let writeOffDynamicID = AppConfig.resolveFirst("SIMPLEONE_WRITE_OFF_DYNAMIC_ID") else {
            return "sys_idISEMPTY^sys_idISNOTEMPTY"
        }
        return "(quantity>0^(warehouse.responsible_for_write_offCONTAINS_DYNAMIC\(writeOffDynamicID)^ORactivity.service_managerDYNAMIC\(currentUserDynamicID)^ORactivity.balance_management_managersCONTAINS_DYNAMIC\(writeOffDynamicID)^ORactivity.project_managerDYNAMIC\(currentUserDynamicID)))"
    }

    func fetchItems(authKey: String) async throws -> [BackpackItem] {
        var page = 1
        let perPage = 100
        var items: [BackpackItem] = []
        var seenIDs = Set<String>()

        while true {
            let pageItems = try await fetchItemsPage(
                page: page,
                perPage: perPage,
                authKey: authKey
            )
            for item in pageItems {
                guard seenIDs.insert(item.id).inserted else { continue }
                items.append(item)
            }

            guard pageItems.count == perPage else { break }
            page += 1
        }

        return items.sorted { lhs, rhs in
            switch (lhs.receivedAtDate, rhs.receivedAtDate) {
            case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
                return lhsDate > rhsDate
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                break
            }

            let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return lhs.serialNumber.localizedStandardCompare(rhs.serialNumber) == .orderedAscending
        }
    }

    private func fetchItemsPage(
        page: Int,
        perPage: Int,
        authKey: String
    ) async throws -> [BackpackItem] {
        guard var components = URLComponents(
            url: simpleOneService.baseURL.appendingPathComponent("list/itsm_tchnsrv_balances_in_warehouses"),
            resolvingAgainstBaseURL: false
        ) else {
            throw SimpleOneServiceError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "condition", value: condition),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: String(perPage))
        ]
        guard let url = components.url else {
            throw SimpleOneServiceError.invalidURL
        }

        let response = try await simpleOneService.request(url: url, authKey: authKey)
        guard let records = simpleOneService.listItems(from: response) else {
            throw simpleOneService.serverError(from: response) ?? SimpleOneServiceError.invalidResponse
        }

        return records
            .map(makeItem(from:))
            .filter { !$0.name.isEmpty || !$0.serialNumber.isEmpty }
    }

    private func makeItem(from raw: [String: Any]) -> BackpackItem {
        let sysID = fieldString(raw, "sys_id", "id")
        let searchCode = fieldString(raw, "Код поиска ЗИП", "search_code", "code", "name")
        let name = firstNonEmpty(
            fieldDisplayString(raw, "ЗИП.Наименование"),
            fieldDisplayString(raw, "zip.name", "zip_id.name", "spare_part.name", "spare.name"),
            fieldString(raw, "zip.name", "zip_id.name", "spare_part.name", "spare.name", "item.name")
        )
        let serialNumber = firstNonEmpty(
            fieldString(raw, "ЗИП.S/N"),
            fieldString(raw, "zip.s_n", "zip_id.s_n", "spare_part.s_n"),
            fieldString(raw, "zip.serial_number", "zip_id.serial_number", "spare_part.serial_number"),
            fieldString(raw, "serial_number", "sn", "s/n", "s_n", "serial")
        )
        let responsible = firstNonEmpty(
            fieldDisplayString(raw, "Склад.Ответственные за списание"),
            fieldDisplayString(raw, "warehouse.responsible_for_write_off"),
            fieldString(raw, "warehouse.responsible_for_write_off", "responsible_for_write_off")
        )
        let receivedAt = backpackReceivedAt(from: raw)
        let quantity = backpackQuantity(from: raw)
        let id = firstNonEmpty(sysID, searchCode, [name, serialNumber, responsible].joined(separator: "|"))

        return BackpackItem(
            id: id,
            name: normalizedBackpackValue(name),
            serialNumber: normalizedBackpackValue(serialNumber),
            responsible: normalizedBackpackValue(responsible),
            receivedAt: normalizedBackpackValue(receivedAt.text),
            receivedAtDate: receivedAt.date,
            quantity: quantity
        )
    }

    func hydrateItems(
        _ items: [BackpackItem],
        cachedItems: [BackpackItem],
        authKey: String,
        onItem: @MainActor @Sendable (BackpackItem) -> Void
    ) async throws {
        let cachedByID = Dictionary(cachedItems.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        let pending = items.filter { item in
            guard let cached = cachedByID[item.id],
                  let version = item.receivedAtDate,
                  version == cached.receivedAtDate,
                  item.name == cached.name,
                  item.serialNumber == cached.serialNumber,
                  item.responsible == cached.responsible,
                  item.quantity == cached.quantity else { return true }
            onItem(cached)
            return false
        }
        try await withThrowingTaskGroup(of: BackpackItem.self) { group in
            var iterator = pending.makeIterator()
            func enqueue(_ item: BackpackItem) {
                group.addTask {
                    try Task.checkCancellation()
                    guard !item.id.isEmpty else {
                        return item
                    }

                    do {
                        return try await fetchDetailedItem(item, authKey: authKey)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as URLError where error.code == .cancelled {
                        throw CancellationError()
                    } catch SimpleOneServiceError.unauthorized {
                        throw SimpleOneServiceError.unauthorized
                    } catch {
                        if let cached = cachedByID[item.id],
                           item.name == cached.name,
                           item.serialNumber == cached.serialNumber,
                           item.responsible == cached.responsible,
                           item.quantity == cached.quantity {
                            return cached
                        }
                        return item
                    }
                }
            }

            for _ in 0..<min(4, pending.count) {
                if let item = iterator.next() { enqueue(item) }
            }
            while let item = try await group.next() {
                onItem(item)
                if let nextItem = iterator.next() { enqueue(nextItem) }
            }
        }
    }

    private func fetchDetailedItem(_ item: BackpackItem, authKey: String) async throws -> BackpackItem {
        let response = try await simpleOneService.request(
            path: "/record/itsm_tchnsrv_balances_in_warehouses/\(item.id)",
            authKey: authKey
        )
        guard let record = simpleOneService.recordItem(from: response) else {
            throw SimpleOneServiceError.invalidResponse
        }
        let flattened = flattenedRecordItem(from: record)
        let detailItem = makeItem(from: flattened)

        return BackpackItem(
            id: item.id,
            name: detailItem.name == "(не задано)" ? item.name : detailItem.name,
            serialNumber: detailItem.serialNumber == "(не задано)" ? item.serialNumber : detailItem.serialNumber,
            responsible: detailItem.responsible == "(не задано)" ? item.responsible : detailItem.responsible,
            receivedAt: detailItem.receivedAt == "(не задано)" ? item.receivedAt : detailItem.receivedAt,
            receivedAtDate: detailItem.receivedAtDate ?? item.receivedAtDate,
            quantity: detailItem.quantity > 0 ? detailItem.quantity : item.quantity
        )
    }

    private func flattenedRecordItem(from item: [String: Any]) -> [String: Any] {
        guard let sections = item["sections"] as? [[String: Any]] else {
            return item
        }

        var flattened = item
        for section in sections {
            guard let elements = section["elements"] as? [[String: Any]] else { continue }
            for element in elements {
                guard let value = element["value"] else { continue }

                for keyName in ["sys_column_name", "system_name", "name"] {
                    guard let key = element[keyName] as? String, !key.isEmpty else { continue }
                    if fieldString(flattened, key).isEmpty {
                        setFieldValue(value, for: key, in: &flattened)
                    }
                }
            }
        }
        return flattened
    }
}

struct BackpackScreen: View {
    let simpleOneStore: SimpleOneRequestsStore
    let coordinationStore: CoordinationStore
    let equipmentStore: OfficeEquipmentStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var store: BackpackStore
    @State private var photoStore = BackpackPhotoStore()
    @State private var locationStore = BackpackItemLocationStore()
    @State private var selectedGroup: BackpackItemGroup?
    @State private var selectedLocationFilter: BackpackItemLocation?
    @State private var refreshTask: Task<Void, Never>?
    @State private var loadedPhotoRevision: UInt64?
    @State private var userInitiatedReturnRevision: UInt64?
    @State private var showsEquipment = false

    init(
        store: BackpackStore,
        simpleOneStore: SimpleOneRequestsStore,
        coordinationStore: CoordinationStore,
        equipmentStore: OfficeEquipmentStore
    ) {
        self.simpleOneStore = simpleOneStore
        self.coordinationStore = coordinationStore
        self.equipmentStore = equipmentStore
        _store = State(initialValue: store)
    }

    private let columns = [
        GridItem(.adaptive(minimum: 154, maximum: 240), spacing: 12, alignment: .top)
    ]

    private var visibleItems: [BackpackItem] {
        guard let selectedLocationFilter else { return store.items }
        return store.items.filter { item in
            locationStore.location(
                for: item,
                isReturnEquipment: isReturnEquipment(item)
            ) == selectedLocationFilter
        }
    }

    private var groups: [BackpackItemGroup] {
        let groupedItems = Dictionary(grouping: visibleItems) { item in
            let normalizedName = normalizedBackpackSearchText(item.name)
            return normalizedName == normalizedBackpackSearchText("(не задано)")
                ? "item:\(item.id)"
                : "model:\(normalizedName)"
        }

        return groupedItems.map { key, items in
            let sortedItems = items.sorted(by: backpackItemIsNewer)
            return BackpackItemGroup(
                id: key,
                name: sortedItems[0].name,
                items: sortedItems
            )
        }
        .sorted(by: backpackGroupIsNewer)
    }

    private var totalQuantity: Int {
        visibleItems.reduce(0) { $0 + max($1.quantity, 1) }
    }

    private var isInitialLoading: Bool {
        store.items.isEmpty && store.lastUpdatedAt == nil && store.errorMessage == nil
    }

    private var isPhotoLoading: Bool {
        !store.items.isEmpty && loadedPhotoRevision != store.photoRevision
    }

    var body: some View {
        AppScreen(bottomContentPadding: 0) {
            VStack(alignment: .leading, spacing: 18) {
                if !simpleOneStore.isAuthorized {
                    AppEmptyState(
                        title: "SimpleOne не подключён",
                        message: "Войдите в SimpleOne на экране «Заявки», затем вернитесь в рюкзак.",
                        systemName: "person.crop.circle.badge.exclamationmark"
                    )
                } else {
                    if isInitialLoading {
                        BackpackInventoryHeaderSkeleton()
                            .depthStackPrimary(reduceMotion: reduceMotion)
                    } else {
                        BackpackInventoryHeader(
                            itemCount: totalQuantity,
                            modelCount: groups.count,
                            selectedLocation: $selectedLocationFilter,
                            lastUpdatedAt: store.lastUpdatedAt,
                            isRefreshing: store.isLoading || coordinationStore.isReturnEquipmentLoading,
                            onOpenEquipment: {
                                AppHaptics.trigger()
                                showsEquipment = true
                            }
                        )
                        .depthStackPrimary(reduceMotion: reduceMotion)
                    }

                    if let errorMessage = store.errorMessage {
                        AppNoticeBanner(text: errorMessage, tint: AppTheme.dangerTint, isCritical: true)
                            .depthStackSecondary()
                    }

                    if isInitialLoading {
                        BackpackInventorySkeleton(columns: columns)
                            .depthStackSecondary()
                    }

                    if !store.isLoading && store.items.isEmpty && store.lastUpdatedAt != nil {
                        AppCard {
                            ContentUnavailableView(
                                "Рюкзак пуст",
                                systemImage: "backpack",
                                description: Text("Оборудование по текущему фильтру пока не найдено. Обновите список, чтобы проверить снова.")
                            )
                        }
                        .depthStackSecondary()
                    }

                    if !store.isLoading,
                       !store.items.isEmpty,
                       groups.isEmpty,
                       let selectedLocationFilter {
                        AppCard {
                            ContentUnavailableView(
                                "Нет оборудования",
                                systemImage: selectedLocationFilter.systemImage,
                                description: Text("Для фильтра «\(selectedLocationFilter.title)» ничего не найдено.")
                            )
                        }
                        .depthStackSecondary()
                    }

                    if !groups.isEmpty {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                            ForEach(groups) { group in
                                BackpackInventoryTile(
                                    group: group,
                                    image: photoStore.image(for: group.representativeItem),
                                    isPhotoLoading: isPhotoLoading,
                                    isLoadingDetails: group.items.contains { store.loadingDetailIDs.contains($0.id) }
                                ) {
                                    AppHaptics.trigger()
                                    selectedGroup = group
                                }
                            }
                        }
                        .depthStackSecondary()
                    }
                }
            }
        }
        .navigationTitle("Рюкзак")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: startRefresh) {
                    Group {
                        if isRefreshInProgress {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .frame(width: 22, height: 22)
                }
                .disabled(isRefreshInProgress || !simpleOneStore.isAuthorized)
                .accessibilityLabel("Обновить рюкзак")
            }
        }
        .refreshable {
            if simpleOneStore.isAuthorized, refreshTask == nil, !store.isLoading {
                await refresh()
            }
        }
        .task(id: simpleOneDataScopeID) {
            guard simpleOneStore.isAuthorized else { return }
            await store.loadIfNeeded()
        }
        .task(id: store.listRevision) {
            guard simpleOneStore.isAuthorized, !store.items.isEmpty else { return }
            await coordinationStore.refreshReturnEquipment(
                sessionID: makeCoordinationSessionID(for: simpleOneStore),
                simpleOneStore: simpleOneStore,
                showsNetworkBanner: userInitiatedReturnRevision == store.listRevision
            )
        }
        .task(id: store.photoRevision) {
            guard simpleOneStore.isAuthorized, !store.items.isEmpty else { return }
            let revision = store.photoRevision
            await photoStore.load(for: store.items)
            guard !Task.isCancelled else { return }
            loadedPhotoRevision = revision
        }
        .onDisappear {
            refreshTask?.cancel()
        }
        .sheet(item: $selectedGroup) { group in
            let currentGroup = groups.first(where: { current in
                current.items.contains { $0.id == group.representativeItem.id }
            }) ?? group
            BackpackItemGroupDetailSheet(
                group: currentGroup,
                image: photoStore.image(for: currentGroup.representativeItem),
                isPhotoLoading: isPhotoLoading,
                loadingDetailIDs: store.loadingDetailIDs,
                coordinationStore: coordinationStore,
                locationStore: locationStore
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .navigationDestination(isPresented: $showsEquipment) {
            OfficeEquipmentScreen(store: equipmentStore, simpleOneStore: simpleOneStore)
        }
    }

    private func refresh() async {
        guard simpleOneStore.isAuthorized else { return }
        userInitiatedReturnRevision = store.listRevision &+ 1
        await store.refresh()
    }

    private func startRefresh() {
        guard refreshTask == nil, !store.isLoading else { return }

        AppHaptics.trigger()
        refreshTask = Task { @MainActor in
            defer { refreshTask = nil }
            await refresh()
        }
    }

    private var isRefreshInProgress: Bool {
        refreshTask != nil || store.isLoading || coordinationStore.isReturnEquipmentLoading
    }

    private var simpleOneDataScopeID: String {
        "\(simpleOneStore.isAuthorized)|\(makeCoordinationSessionID(for: simpleOneStore))"
    }

    private func isReturnEquipment(_ item: BackpackItem) -> Bool {
        coordinationStore.returnEquipmentSerialNumbers.contains(
            CoordinationStore.normalizedSerialNumber(item.serialNumber)
        )
    }
}

private struct BackpackInventoryHeader: View {
    let itemCount: Int
    let modelCount: Int
    @Binding var selectedLocation: BackpackItemLocation?
    let lastUpdatedAt: Date?
    let isRefreshing: Bool
    let onOpenEquipment: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(AppTheme.primaryTint.opacity(0.14))

                    Image(systemName: "shippingbox.and.arrow.backward.fill")
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundStyle(AppTheme.primaryTint)
                }
                .frame(width: 58, height: 58)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Мой рюкзак")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(AppTheme.ink)

                    BackpackLocationFilterMenu(selection: $selectedLocation)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 0) {
                BackpackInventoryMetric(value: itemCount, title: "единиц")

                Divider()
                    .frame(height: 34)
                    .padding(.horizontal, 20)

                BackpackInventoryMetric(value: modelCount, title: "моделей")
            }

            Button(action: onOpenEquipment) {
                HStack(spacing: 13) {
                    Image(systemName: "desktopcomputer.and.macbook")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 13, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Моё оборудование")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                        Text("Техника, закреплённая в SimpleOne")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.76))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.78))
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.accentGradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.white.opacity(0.18), lineWidth: 1)
                }
                .shadow(color: AppTheme.primaryTint.opacity(0.22), radius: 10, y: 5)
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Открывает оборудование, закреплённое за вами в SimpleOne")

            if isRefreshing {
                SkeletonPlaceholder(cornerRadius: 5)
                    .frame(width: 138, height: 12)
                    .accessibilityLabel("Обновляется рюкзак")
            } else if let lastUpdatedAt {
                Text(updatedText(for: lastUpdatedAt))
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedTint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(updatedAccessibilityText(for: lastUpdatedAt))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
    }

    private func updatedText(for date: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        let time = Self.timeFormatter.string(from: date)

        if calendar.isDateInToday(date) {
            return "Обновлено сегодня в \(time)"
        }
        if calendar.isDateInYesterday(date) {
            return "Обновлено вчера в \(time)"
        }
        return "Обновлено \(Self.dateFormatter.string(from: date)) в \(time)"
    }

    private func updatedAccessibilityText(for date: Date) -> String {
        updatedText(for: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = AppLocale.russian
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = AppLocale.russian
        formatter.dateFormat = "dd.MM.yyyy"
        return formatter
    }()
}

private struct BackpackInventoryHeaderSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                SkeletonPlaceholder(cornerRadius: 18)
                    .frame(width: 58, height: 58)
                VStack(alignment: .leading, spacing: 8) {
                    SkeletonPlaceholder(cornerRadius: 7)
                        .frame(width: 150, height: 24)
                    SkeletonPlaceholder(cornerRadius: 15)
                        .frame(width: 82, height: 30)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 20) {
                SkeletonPlaceholder(cornerRadius: 7)
                    .frame(width: 94, height: 26)
                SkeletonPlaceholder(cornerRadius: 7)
                    .frame(width: 105, height: 26)
            }

            SkeletonPlaceholder(cornerRadius: 18)
                .frame(maxWidth: .infinity)
                .frame(height: 62)
            SkeletonPlaceholder(cornerRadius: 5)
                .frame(width: 138, height: 12)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Загружается рюкзак")
    }
}

private struct BackpackInventorySkeleton: View {
    let columns: [GridItem]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(0..<4, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 12) {
                    SkeletonPlaceholder(cornerRadius: 18)
                        .frame(height: 150)
                    SkeletonPlaceholder(cornerRadius: 6)
                        .frame(maxWidth: .infinity)
                        .frame(height: 18)
                    SkeletonPlaceholder(cornerRadius: 6)
                        .frame(width: 98, height: 18)
                    SkeletonPlaceholder(cornerRadius: 15)
                        .frame(width: 104, height: 30)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.cardSurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(AppTheme.border, lineWidth: 1)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Загружаются карточки терминалов")
    }
}

private struct BackpackLocationFilterMenu: View {
    @Binding var selection: BackpackItemLocation?

    private var title: String {
        selection?.title ?? "Все"
    }

    private var systemImage: String {
        selection?.systemImage ?? "square.grid.2x2.fill"
    }

    var body: some View {
        Menu {
            Button {
                select(nil)
            } label: {
                Label(
                    "Все",
                    systemImage: selection == nil ? "checkmark.circle.fill" : "square.grid.2x2.fill"
                )
            }

            ForEach(BackpackItemLocation.allCases) { location in
                Button {
                    select(location)
                } label: {
                    Label(
                        location.title,
                        systemImage: selection == location ? "checkmark.circle.fill" : location.systemImage
                    )
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(title)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(0.72)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppTheme.primaryTint)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(AppTheme.primaryTint.opacity(0.11), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(AppTheme.primaryTint.opacity(0.2), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Фильтр местоположения: \(title)")
        .accessibilityHint("Открывает выбор местоположения")
    }

    private func select(_ location: BackpackItemLocation?) {
        guard selection != location else { return }
        selection = location
        AppHaptics.trigger(.expandCollapse)
    }
}

private struct BackpackInventoryMetric: View {
    let value: Int
    let title: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(value, format: .number)
                .font(.title2.weight(.bold))
                .foregroundStyle(AppTheme.ink)

            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedTint)
        }
    }
}

private struct BackpackInventoryTile: View {
    let group: BackpackItemGroup
    let image: UIImage?
    let isPhotoLoading: Bool
    let isLoadingDetails: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                if isPhotoLoading && image == nil {
                    SkeletonPlaceholder(cornerRadius: 18)
                        .frame(height: 150)
                } else {
                    BackpackTerminalImage(image: image)
                        .frame(height: 150)
                }

                if isLoadingDetails && group.name == "(не задано)" {
                    VStack(alignment: .leading, spacing: 6) {
                        SkeletonPlaceholder(cornerRadius: 6).frame(height: 16)
                        SkeletonPlaceholder(cornerRadius: 6).frame(width: 90, height: 16)
                    }
                    .frame(minHeight: 38, alignment: .topLeading)
                } else {
                    Text(group.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, minHeight: 38, alignment: .topLeading)
                }

                HStack(spacing: 8) {
                    Label {
                        Text("Остаток: \(group.quantity)")
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                    } icon: {
                        Image(systemName: "shippingbox.fill")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryTint)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(AppTheme.primaryTint.opacity(0.11), in: Capsule())

                    if isLoadingDetails {
                        SkeletonPlaceholder(cornerRadius: 6)
                            .frame(width: 36, height: 12)
                            .accessibilityLabel("Загружаются сведения о терминалах")
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.cardSurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group.name), остаток \(group.quantity)")
        .accessibilityHint("Открывает сведения об оборудовании")
    }
}

struct BackpackTerminalImage: View {
    let image: UIImage?
    var placeholderSystemImage = "creditcard.and.123"

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    AppTheme.primaryTint.opacity(0.16),
                    AppTheme.secondaryTint.opacity(0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(10)
                    .transition(.opacity)
            } else {
                Image(systemName: placeholderSystemImage)
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(AppTheme.mutedTint.opacity(0.7))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct BackpackItemGroupDetailSheet: View {
    @Environment(\.dismiss) private var dismiss

    let group: BackpackItemGroup
    let image: UIImage?
    let isPhotoLoading: Bool
    let loadingDetailIDs: Set<String>
    let coordinationStore: CoordinationStore
    let locationStore: BackpackItemLocationStore

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.background
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        if isPhotoLoading && image == nil {
                            SkeletonPlaceholder(cornerRadius: 18)
                                .frame(height: 230)
                        } else {
                            BackpackTerminalImage(image: image)
                                .frame(height: 230)
                        }

                        Text(group.name)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(AppTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)

                        VStack(spacing: 0) {
                            BackpackDetailField(
                                title: "Количество",
                                value: "\(group.quantity) шт.",
                                systemImage: "shippingbox.fill"
                            )
                        }
                        .padding(.horizontal, 16)
                        .background(AppTheme.cardSurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .stroke(AppTheme.border, lineWidth: 1)
                        )

                        VStack(alignment: .leading, spacing: 0) {
                            Text("Экземпляры")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(AppTheme.ink)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)

                            ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                                if index > 0 {
                                    Divider().padding(.leading, 58)
                                }

                                BackpackItemInstanceRow(
                                    position: index + 1,
                                    item: item,
                                    isLoadingDetails: loadingDetailIDs.contains(item.id),
                                    isLoadingReturnEquipment: coordinationStore.isReturnEquipmentLoading && !coordinationStore.hasReturnEquipmentSnapshot,
                                    isReturnEquipment: coordinationStore.returnEquipmentSerialNumbers.contains(
                                        CoordinationStore.normalizedSerialNumber(item.serialNumber)
                                    ),
                                    locationStore: locationStore
                                )
                            }
                        }
                        .background(AppTheme.cardSurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .stroke(AppTheme.border, lineWidth: 1)
                        )
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Оборудование")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    ModalCloseButton {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct BackpackItemInstanceRow: View {
    let position: Int
    let item: BackpackItem
    let isLoadingDetails: Bool
    let isLoadingReturnEquipment: Bool
    let isReturnEquipment: Bool
    let locationStore: BackpackItemLocationStore

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(position, format: .number)
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.primaryTint)
                .frame(width: 30, height: 30)
                .background(AppTheme.primaryTint.opacity(0.11), in: Circle())

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    BackpackInstanceValue(
                        title: "Серийный номер",
                        value: item.serialNumber,
                        systemImage: "barcode"
                    )

                    Spacer(minLength: 8)

                    if isReturnEquipment {
                        Text("Возврат ТО")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(AppTheme.secondaryTint, in: Capsule())
                            .fixedSize()
                            .accessibilityLabel("Оборудование относится к возврату ТО")
                    }
                }

                HStack(alignment: .bottom, spacing: 8) {
                    if isLoadingDetails && item.receivedAt == "(не задано)" {
                        VStack(alignment: .leading, spacing: 5) {
                            SkeletonPlaceholder(cornerRadius: 4).frame(width: 78, height: 11)
                            SkeletonPlaceholder(cornerRadius: 5).frame(width: 112, height: 17)
                        }
                        .accessibilityLabel("Загружается дата выдачи")
                    } else {
                        BackpackInstanceValue(
                            title: "Дата выдачи",
                            value: item.receivedAt,
                            systemImage: "calendar"
                        )
                    }

                    Spacer(minLength: 8)

                    if isLoadingReturnEquipment {
                        SkeletonPlaceholder(cornerRadius: 14)
                            .frame(width: 86, height: 28)
                            .accessibilityLabel("Загружается местоположение")
                    } else {
                        BackpackItemLocationMenu(
                            item: item,
                            isReturnEquipment: isReturnEquipment,
                            store: locationStore
                        )
                    }
                }

                if item.quantity > 1 {
                    BackpackInstanceValue(
                        title: "Остаток",
                        value: "\(item.quantity) шт.",
                        systemImage: "shippingbox"
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

private struct BackpackItemLocationMenu: View {
    let item: BackpackItem
    let isReturnEquipment: Bool
    let store: BackpackItemLocationStore

    private var location: BackpackItemLocation {
        store.location(for: item, isReturnEquipment: isReturnEquipment)
    }

    var body: some View {
        Menu {
            ForEach(BackpackItemLocation.allCases) { option in
                Button {
                    store.setLocation(option, for: item)
                    AppHaptics.trigger(.expandCollapse)
                } label: {
                    Label(
                        option.title,
                        systemImage: location == option ? "checkmark.circle.fill" : option.systemImage
                    )
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: location.systemImage)

                Text(location.title)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.72)
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(AppTheme.primaryTint)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(AppTheme.primaryTint.opacity(0.11), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(AppTheme.primaryTint.opacity(0.2), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Местоположение терминала: \(location.title)")
        .accessibilityHint("Открывает выбор местоположения")
    }
}

private struct BackpackInstanceValue: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.primaryTint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.mutedTint)

                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct BackpackDetailField: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(AppTheme.primaryTint)
                .frame(width: 30, height: 30)
                .background(AppTheme.primaryTint.opacity(0.11), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedTint)

                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}


private func normalizedBackpackValue(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "(не задано)" : trimmed
}

private func normalizedBackpackSearchText(_ raw: String) -> String {
    raw
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
}

private func backpackQuantity(from raw: [String: Any]) -> Int {
    let value = firstNonEmpty(
        fieldString(raw, "Остаток", "Количество"),
        fieldString(raw, "quantity")
    )
    let normalized = value.replacingOccurrences(of: ",", with: ".")
    return Double(normalized).map { max(Int($0), 0) } ?? 0
}

private func backpackItemIsNewer(_ lhs: BackpackItem, _ rhs: BackpackItem) -> Bool {
    switch (lhs.receivedAtDate, rhs.receivedAtDate) {
    case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
        return lhsDate > rhsDate
    case (_?, nil):
        return true
    case (nil, _?):
        return false
    default:
        return lhs.serialNumber.localizedStandardCompare(rhs.serialNumber) == .orderedAscending
    }
}

private func backpackGroupIsNewer(_ lhs: BackpackItemGroup, _ rhs: BackpackItemGroup) -> Bool {
    switch (lhs.latestReceivedAtDate, rhs.latestReceivedAtDate) {
    case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
        return lhsDate > rhsDate
    case (_?, nil):
        return true
    case (nil, _?):
        return false
    default:
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

private func backpackReceivedAt(from raw: [String: Any]) -> (text: String, date: Date?) {
    let value = firstNonEmpty(
        fieldString(raw, "Когда изменено"),
        fieldString(raw, "sys_updated_at", "updated_at")
    )
    guard !value.isEmpty else {
        return ("", nil)
    }

    guard let date = BackpackDateFormatters.input.date(from: value) else {
        return (value, nil)
    }
    return (BackpackDateFormatters.output.string(from: date), date)
}

private enum BackpackDateFormatters {
    static let input: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = AppLocale.russian
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static let output: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = AppLocale.russian
        formatter.timeZone = .current
        formatter.dateFormat = "dd.MM.yyyy HH:mm:ss"
        return formatter
    }()
}
