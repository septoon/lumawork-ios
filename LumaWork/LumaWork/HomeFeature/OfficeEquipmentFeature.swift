import Foundation
import Observation
import SwiftUI
import UIKit

nonisolated struct OfficeEquipmentField: Codable, Hashable, Identifiable, Sendable {
    let systemName: String
    let title: String
    let value: String

    var id: String { systemName + "|" + title }
}

nonisolated struct OfficeEquipmentSection: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let fields: [OfficeEquipmentField]
}

nonisolated struct OfficeEquipmentItem: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let serialNumber: String
    let vendor: String
    let type: String
    let model: String
    let number: String
    let location: String
    let owner: String
    let receivedAt: String
    let receivedAtDate: Date?
    let alternativeName: String
    let additionalInformation: String
    let description: String
    let detailSections: [OfficeEquipmentSection]

    var displayName: String {
        firstNonEmpty(alternativeName, name, [vendor, model].filter { !$0.isEmpty }.joined(separator: " "), model, "Оборудование")
    }

    var photoReferenceName: String {
        firstNonEmpty(alternativeName, [vendor, model].filter { !$0.isEmpty }.joined(separator: " "), model, name)
    }

    var photoCandidateNames: [String] {
        officeEquipmentUniqueStrings([
            alternativeName,
            name,
            [vendor, model].filter { !$0.isEmpty }.joined(separator: " "),
            model
        ])
    }
}

nonisolated extension SimpleOneRequestsService {
    func fetchCurrentOfficeEquipment(authKey: String) async throws -> [OfficeEquipmentItem] {
        guard let currentUserDynamicID = AppConfig.resolveFirst("SIMPLEONE_CURRENT_USER_DYNAMIC_ID") else {
            return []
        }
        return try await fetchOfficeEquipment(
            condition: "(ownerDYNAMIC\(currentUserDynamicID))",
            authKey: authKey
        )
    }

    func fetchOfficeEquipment(login: String, authKey: String) async throws -> [OfficeEquipmentItem] {
        let employeeID = try await fetchEmployeeID(login: login, authKey: authKey)
        return try await fetchOfficeEquipment(condition: "(owner=\(employeeID))", authKey: authKey)
    }

    private func fetchEmployeeID(login: String, authKey: String) async throws -> String {
        let normalizedLogin = officeEquipmentConditionValue(login)
        guard !normalizedLogin.isEmpty,
              var components = URLComponents(
                  url: baseURL.appendingPathComponent("list/employee"),
                  resolvingAgainstBaseURL: false
              ) else {
            throw SimpleOneServiceError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "condition", value: "(username=\(normalizedLogin))"),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "per_page", value: "20")
        ]
        guard let url = components.url else { throw SimpleOneServiceError.invalidURL }
        let response = try await request(url: url, authKey: authKey)
        guard let records = listItems(from: response) else {
            throw serverError(from: response) ?? SimpleOneServiceError.invalidResponse
        }
        let exact = records.first { record in
            fieldString(record, "username").localizedCaseInsensitiveCompare(normalizedLogin) == .orderedSame
        }
        guard let employeeID = exact.map({ firstNonEmpty(fieldString($0, "sys_id"), stringValue($0["sys_id"])) }),
              !employeeID.isEmpty else {
            throw AppServiceError.message("Пользователь SimpleOne «\(normalizedLogin)» не найден.")
        }
        return employeeID
    }

    private func fetchOfficeEquipment(
        condition: String,
        authKey: String
    ) async throws -> [OfficeEquipmentItem] {
        var page = 1
        let perPage = 100
        var items: [OfficeEquipmentItem] = []
        var seenIDs = Set<String>()

        while true {
            guard var components = URLComponents(
                url: baseURL.appendingPathComponent("list/itsm_tchnsrv_office_equipment"),
                resolvingAgainstBaseURL: false
            ) else {
                throw SimpleOneServiceError.invalidURL
            }
            components.queryItems = [
                URLQueryItem(name: "condition", value: condition),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "per_page", value: String(perPage))
            ]
            guard let url = components.url else { throw SimpleOneServiceError.invalidURL }
            let response = try await request(url: url, authKey: authKey)
            guard let records = listItems(from: response) else {
                throw serverError(from: response) ?? SimpleOneServiceError.invalidResponse
            }
            for record in records {
                let item = officeEquipmentItem(from: record)
                guard !item.id.isEmpty, seenIDs.insert(item.id).inserted else { continue }
                items.append(item)
            }
            let hasMore = totalCount(from: response).map { page * perPage < $0 }
                ?? (records.count == perPage)
            guard hasMore else { break }
            page += 1
        }

        let detailed = try await officeEquipmentDetails(items, authKey: authKey)
        return detailed.sorted { lhs, rhs in
            switch (lhs.receivedAtDate, rhs.receivedAtDate) {
            case let (left?, right?) where left != right: return left > right
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
        }
    }

    private func officeEquipmentDetails(
        _ items: [OfficeEquipmentItem],
        authKey: String
    ) async throws -> [OfficeEquipmentItem] {
        try await withThrowingTaskGroup(of: (Int, OfficeEquipmentItem).self) { group in
            var iterator = items.enumerated().makeIterator()

            func enqueue(_ index: Int, _ item: OfficeEquipmentItem) {
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let response = try await request(
                            path: "/record/itsm_tchnsrv_office_equipment/\(item.id)",
                            authKey: authKey
                        )
                        guard let record = recordItem(from: response) else {
                            throw SimpleOneServiceError.invalidResponse
                        }
                        return (index, officeEquipmentItem(from: record, fallback: item))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as URLError where error.code == .cancelled {
                        throw CancellationError()
                    } catch SimpleOneServiceError.unauthorized {
                        throw SimpleOneServiceError.unauthorized
                    } catch {
                        return (index, item)
                    }
                }
            }

            for _ in 0..<min(4, items.count) {
                if let (index, item) = iterator.next() { enqueue(index, item) }
            }
            var result = items
            while let (index, item) = try await group.next() {
                result[index] = item
                if let (nextIndex, nextItem) = iterator.next() { enqueue(nextIndex, nextItem) }
            }
            return result
        }
    }

    private func officeEquipmentItem(
        from raw: [String: Any],
        fallback: OfficeEquipmentItem? = nil
    ) -> OfficeEquipmentItem {
        let flattened = flattenedRecordItem(from: raw)
        let receivedAt = firstNonEmpty(fieldString(flattened, "sys_updated_at"), fallback?.receivedAt ?? "")
        let details = officeEquipmentSections(from: raw)
        return OfficeEquipmentItem(
            id: firstNonEmpty(fieldString(flattened, "sys_id"), stringValue(flattened["record_id"]), fallback?.id ?? ""),
            name: firstNonEmpty(fieldString(flattened, "name"), fallback?.name ?? ""),
            serialNumber: firstNonEmpty(fieldString(flattened, "serial_number"), fallback?.serialNumber ?? ""),
            vendor: firstNonEmpty(fieldDisplayString(flattened, "c_vendor"), fallback?.vendor ?? ""),
            type: firstNonEmpty(fieldDisplayString(flattened, "ci_type"), fallback?.type ?? ""),
            model: firstNonEmpty(fieldString(flattened, "c_model"), fieldDisplayString(flattened, "cmdb_model_id"), fallback?.model ?? ""),
            number: firstNonEmpty(fieldString(flattened, "number"), fallback?.number ?? ""),
            location: firstNonEmpty(fieldDisplayString(flattened, "company_location"), fallback?.location ?? ""),
            owner: firstNonEmpty(fieldDisplayString(flattened, "owner"), fallback?.owner ?? ""),
            receivedAt: receivedAt,
            receivedAtDate: officeEquipmentDate(receivedAt) ?? fallback?.receivedAtDate,
            alternativeName: firstNonEmpty(fieldString(flattened, "c_alternative_name"), fallback?.alternativeName ?? ""),
            additionalInformation: firstNonEmpty(fieldString(flattened, "c_additional_info"), fallback?.additionalInformation ?? ""),
            description: firstNonEmpty(fieldString(flattened, "description"), fallback?.description ?? ""),
            detailSections: details.isEmpty ? (fallback?.detailSections ?? []) : details
        )
    }

    private func officeEquipmentSections(from item: [String: Any]) -> [OfficeEquipmentSection] {
        guard let sections = item["sections"] as? [[String: Any]] else { return [] }
        return sections.enumerated().compactMap { sectionIndex, section in
            guard let elements = section["elements"] as? [[String: Any]] else { return nil }
            let fields = elements.enumerated().compactMap { fieldIndex, element -> OfficeEquipmentField? in
                guard officeEquipmentBoolean(element["hidden"]) != true,
                      element["split"] == nil,
                      element["widget_instance_id"] == nil,
                      let rawValue = element["value"] else { return nil }
                let systemName = firstNonEmpty(
                    stringValue(element["sys_column_name"]),
                    stringValue(element["system_name"]),
                    "\(sectionIndex)-\(fieldIndex)"
                )
                var title = stringValue(element["name"])
                    .trimmingCharacters(in: CharacterSet(charactersIn: "* "))
                if systemName == "sys_updated_at" || title.localizedCaseInsensitiveCompare("Когда изменено") == .orderedSame {
                    title = "Получено"
                }
                guard !title.isEmpty else { return nil }
                let value: String
                if stringValue(element["column_type"]) == "boolean",
                   let boolean = officeEquipmentBoolean(rawValue) {
                    value = boolean ? "Да" : "Нет"
                } else {
                    value = officeEquipmentPlainText(fieldValueString(rawValue, preferDisplay: true))
                }
                guard !value.isEmpty else { return nil }
                return OfficeEquipmentField(
                    systemName: "\(systemName)|\(sectionIndex)-\(fieldIndex)",
                    title: title,
                    value: value
                )
            }
            guard !fields.isEmpty else { return nil }
            let title = firstNonEmpty(stringValue(section["name"]), "Информация")
                .trimmingCharacters(in: CharacterSet(charactersIn: "* "))
            return OfficeEquipmentSection(id: "\(sectionIndex)|\(title)", title: title, fields: fields)
        }
    }
}

@MainActor
@Observable
final class OfficeEquipmentStore {
    private let service = SimpleOneRequestsService()
    private let cacheKey: String
    private var loadID = UUID()

    var items: [OfficeEquipmentItem] = []
    var isLoading = false
    var errorMessage: String?
    var lastUpdatedAt: Date?

    init(cacheID: String? = nil) {
        cacheKey = AppOfflineSnapshotStore.scopedKey("office-equipment", userID: cacheID)
        if let snapshot = AppOfflineSnapshotStore.load([OfficeEquipmentItem].self, key: cacheKey) {
            items = snapshot.value
            lastUpdatedAt = snapshot.updatedAt
        }
    }

    func loadIfNeeded() async {
        guard items.isEmpty else { return }
        await refresh()
    }

    func refresh() async {
        guard let authKey = SimpleOneSessionKeychain.readAuthKey() else {
            errorMessage = "Войдите в SimpleOne, чтобы загрузить оборудование."
            return
        }
        let requestID = UUID()
        loadID = requestID
        isLoading = true
        errorMessage = nil
        defer {
            if loadID == requestID { isLoading = false }
        }
        do {
            let loaded = try await service.fetchCurrentOfficeEquipment(authKey: authKey)
            try Task.checkCancellation()
            guard loadID == requestID else { return }
            items = loaded
            lastUpdatedAt = Date()
            AppOfflineSnapshotStore.save(items, key: cacheKey)
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch SimpleOneServiceError.unauthorized {
            SimpleOneSessionKeychain.deleteAuthKey()
            guard loadID == requestID else { return }
            errorMessage = SimpleOneServiceError.unauthorized.errorDescription
        } catch {
            guard loadID == requestID else { return }
            errorMessage = appUserFacingErrorMessage(error)
        }
    }
}

struct OfficeEquipmentScreen: View {
    let simpleOneStore: SimpleOneRequestsStore
    @State private var store: OfficeEquipmentStore
    @State private var photoStore = BackpackPhotoStore()
    @State private var photoRefreshDate = Date.distantPast
    @State private var selectedItem: OfficeEquipmentItem?
    @State private var searchText = ""

    init(store: OfficeEquipmentStore, simpleOneStore: SimpleOneRequestsStore) {
        self.simpleOneStore = simpleOneStore
        _store = State(initialValue: store)
    }

    private let columns = [GridItem(.adaptive(minimum: 154, maximum: 240), spacing: 12, alignment: .top)]

    private var filteredItems: [OfficeEquipmentItem] {
        let query = officeEquipmentSearchText(searchText)
        guard !query.isEmpty else { return store.items }
        return store.items.filter { item in
            officeEquipmentSearchText([
                item.displayName,
                item.serialNumber,
                item.vendor,
                item.model,
                item.number,
                item.receivedAt
            ].joined(separator: " ")).contains(query)
        }
    }

    var body: some View {
        AppScreen(bottomContentPadding: 0) {
            if let errorMessage = store.errorMessage {
                AppNoticeBanner(text: errorMessage, tint: AppTheme.dangerTint, isCritical: true)
            }

            if !store.isLoading && store.items.isEmpty {
                AppEmptyState(
                    title: "Оборудование не найдено",
                    message: "В SimpleOne нет оборудования с фильтром текущего владельца.",
                    systemName: "desktopcomputer"
                )
            } else if !store.items.isEmpty && filteredItems.isEmpty {
                AppEmptyState(
                    title: "Ничего не найдено",
                    message: "Измените поисковый запрос.",
                    systemName: "magnifyingglass"
                )
            } else {
                HStack {
                    AppSectionHeader(
                        title: "Моё оборудование",
                        caption: "\(filteredItems.count) из \(store.items.count)"
                    )
                    Spacer()
                    if let lastUpdatedAt = store.lastUpdatedAt {
                        Text(lastUpdatedAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedTint)
                    }
                }

                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(filteredItems) { item in
                        OfficeEquipmentTile(item: item, image: photoStore.image(for: item)) {
                            AppHaptics.trigger()
                            selectedItem = item
                        }
                    }
                }
            }
        }
        .navigationTitle("Моё оборудование")
        .navigationBarTitleDisplayMode(.inline)
        .appNativeSearch(text: $searchText, prompt: "Название, модель, серийный номер")
        .appLoadingOverlay(
            isPresented: simpleOneStore.isAuthorized && store.isLoading && store.items.isEmpty,
            title: "Загружаем оборудование"
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await refresh() } } label: {
                    if store.isLoading { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(store.isLoading)
                .accessibilityLabel("Обновить оборудование")
            }
        }
        .refreshable { await refresh() }
        .task { await store.loadIfNeeded() }
        .task(id: [store.lastUpdatedAt, photoRefreshDate]) {
            guard !store.items.isEmpty else { return }
            await photoStore.load(for: store.items)
        }
        .sheet(item: $selectedItem) { item in
            OfficeEquipmentDetailSheet(item: item, image: photoStore.image(for: item))
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private func refresh() async {
        photoRefreshDate = Date()
        await store.refresh()
    }
}

private struct OfficeEquipmentTile: View {
    let item: OfficeEquipmentItem
    let image: UIImage?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                BackpackTerminalImage(image: image, placeholderSystemImage: "desktopcomputer")
                    .frame(height: 150)
                Text(item.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
                if !item.type.isEmpty {
                    Label(item.type, systemImage: "shippingbox.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.primaryTint)
                        .lineLimit(1)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.cardSurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.displayName)
        .accessibilityHint("Открывает полную информацию об оборудовании")
    }
}

private struct OfficeEquipmentDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: OfficeEquipmentItem
    let image: UIImage?

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.background.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        BackpackTerminalImage(image: image, placeholderSystemImage: "desktopcomputer")
                            .frame(height: 230)
                        Text(item.displayName)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(AppTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)

                        ForEach(displaySections) { section in
                            VStack(alignment: .leading, spacing: 0) {
                                Text(section.title)
                                    .font(.headline.weight(.semibold))
                                    .foregroundStyle(AppTheme.ink)
                                    .padding(.horizontal, 16)
                                    .padding(.top, 15)
                                    .padding(.bottom, 6)
                                ForEach(Array(section.fields.enumerated()), id: \.element.id) { index, field in
                                    if index > 0 { Divider().padding(.leading, 58) }
                                    BackpackDetailField(
                                        title: field.title,
                                        value: field.value,
                                        systemImage: officeEquipmentFieldIcon(field.systemName)
                                    )
                                    .padding(.horizontal, 16)
                                }
                            }
                            .background(AppTheme.cardSurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Оборудование")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    ModalCloseButton { dismiss() }
                }
            }
        }
    }

    private var displaySections: [OfficeEquipmentSection] {
        if !item.detailSections.isEmpty { return item.detailSections }
        let fields = [
            OfficeEquipmentField(systemName: "serial_number", title: "Серийный номер", value: item.serialNumber),
            OfficeEquipmentField(systemName: "c_vendor", title: "Вендор", value: item.vendor),
            OfficeEquipmentField(systemName: "c_model", title: "Модель", value: item.model),
            OfficeEquipmentField(systemName: "number", title: "Номер", value: item.number),
            OfficeEquipmentField(systemName: "company_location", title: "Месторасположение", value: item.location),
            OfficeEquipmentField(systemName: "owner", title: "Владелец", value: item.owner),
            OfficeEquipmentField(systemName: "sys_updated_at", title: "Получено", value: item.receivedAt),
            OfficeEquipmentField(systemName: "c_additional_info", title: "Дополнительная информация", value: item.additionalInformation),
            OfficeEquipmentField(systemName: "description", title: "Описание", value: item.description)
        ].filter { !$0.value.isEmpty }
        return [OfficeEquipmentSection(id: "main", title: "Информация", fields: fields)]
    }
}

nonisolated private func officeEquipmentConditionValue(_ raw: String) -> String {
    raw.replacingOccurrences(of: "^", with: " ")
        .replacingOccurrences(of: "(", with: " ")
        .replacingOccurrences(of: ")", with: " ")
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

nonisolated private func officeEquipmentUniqueStrings(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && seen.insert(officeEquipmentSearchText($0)).inserted }
}

nonisolated private func officeEquipmentSearchText(_ raw: String) -> String {
    raw.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: AppLocale.russian)
        .lowercased()
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

nonisolated private func officeEquipmentDate(_ raw: String) -> Date? {
    let formats = ["yyyy-MM-dd HH:mm:ss", "dd.MM.yyyy HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX", "yyyy-MM-dd'T'HH:mm:ssXXXXX"]
    for format in formats {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        if let date = formatter.date(from: raw) { return date }
    }
    return nil
}

nonisolated private func officeEquipmentBoolean(_ raw: Any?) -> Bool? {
    switch raw {
    case let value as Bool: value
    case let value as NSNumber: value.intValue != 0
    case let value as String:
        ["1", "true", "yes"].contains(value.lowercased()) ? true
            : (["0", "false", "no"].contains(value.lowercased()) ? false : nil)
    case let value as [String: Any]: officeEquipmentBoolean(value["value"] ?? value["database_value"])
    default: nil
    }
}

nonisolated private func officeEquipmentPlainText(_ raw: String) -> String {
    raw.replacingOccurrences(of: "<[^>]+>", with: "", options: [.regularExpression, .caseInsensitive])
        .replacingOccurrences(of: "&nbsp;", with: " ")
        .replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "_x000D_", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

nonisolated private func officeEquipmentFieldIcon(_ systemName: String) -> String {
    if systemName.contains("serial") || systemName.contains("inventory") { return "barcode" }
    if systemName.contains("date") || systemName.contains("_at") { return "calendar" }
    if systemName.contains("owner") { return "person.fill" }
    if systemName.contains("location") || systemName.contains("room") { return "mappin.and.ellipse" }
    if systemName.contains("vendor") || systemName.contains("model") { return "building.2.fill" }
    if systemName.contains("description") || systemName.contains("info") { return "text.alignleft" }
    return "info.circle.fill"
}
