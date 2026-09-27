import Observation
import SwiftUI

struct MaintenanceService {
    private let config: AppConfig
    private let authToken: String?
    private let client = HTTPClient()

    init(config: AppConfig, authToken: String? = nil) {
        self.config = config
        self.authToken = authToken
    }

    func fetchRecords() async throws -> [MaintenanceRecord] {
        guard let authToken, let url = v2URL(path: "/api/v2/maintenance") else {
            throw AppServiceError.message("Требуется авторизация.")
        }
        let response = try await client.request(url, authToken: authToken)
        guard let records = dictionaryValue(response.json)?["records"] as? [Any] else {
            throw AppServiceError.message("Ответ сервера должен содержать records.")
        }
        return records.map(normalizeRecord).sorted { $0.date > $1.date }
    }

    func createRecord(_ input: MaintenanceRecordInput) async throws -> MaintenanceRecord {
        let normalized = normalizeInput(input)
        let recordForCreate = MaintenanceRecord(
            id: UUID().uuidString,
            vehicleID: normalized.vehicleID,
            date: normalized.date,
            procedure: normalized.procedure,
            mileage: normalized.mileage,
            parts: normalized.parts,
            workCost: normalized.workCost,
            totalCost: normalized.totalCost
        )

        guard let authToken, let url = v2URL(path: "/api/v2/maintenance") else {
            throw AppServiceError.message("Требуется авторизация.")
        }
        let response = try await client.request(
            url,
            method: "POST",
            body: requestPayload(for: recordForCreate),
            authToken: authToken
        )
        guard let data = response.json else {
            return recordForCreate
        }
        return normalizeRecord(data)
    }

    func updateRecord(target: MaintenanceRecord, input: MaintenanceRecordInput) async throws -> MaintenanceRecord {
        guard let targetID = target.id, !targetID.isEmpty else {
            throw AppServiceError.message(
                "Нельзя обновить запись без id."
            )
        }

        let normalized = normalizeInput(input)
        let payload = requestPayload(for: MaintenanceRecord(
            id: targetID,
            vehicleID: normalized.vehicleID,
            date: normalized.date,
            procedure: normalized.procedure,
            mileage: normalized.mileage,
            parts: normalized.parts,
            workCost: normalized.workCost,
            totalCost: normalized.totalCost
        ))

        guard let authToken, let url = v2URL(path: "/api/v2/maintenance/\(targetID)") else {
            throw AppServiceError.message("Требуется авторизация.")
        }
        let response = try await client.request(
            url,
            method: "PUT",
            body: payload,
            authToken: authToken
        )
        guard let data = response.json else {
            return normalizeRecord(payload)
        }
        return normalizeRecord(data)
    }

    private func normalizeRecord(_ raw: Any) -> MaintenanceRecord {
        let rawDictionary = dictionaryValue(raw) ?? [:]
        let parts = resolveParts(rawDictionary)
        let workCost = doubleValue(rawDictionary["workCost"])
        let totalCost = doubleValue(rawDictionary["totalCost"]) ?? deriveTotal(parts: parts, workCost: workCost)

        return MaintenanceRecord(
            id: stringValue(rawDictionary["id"]).isEmpty ? stringValue(rawDictionary["_id"]).nilIfEmpty : stringValue(rawDictionary["id"]).nilIfEmpty,
            vehicleID: stringValue(rawDictionary["vehicleId"]).nilIfEmpty,
            date: stringValue(rawDictionary["date"]),
            procedure: stringValue(rawDictionary["procedure"]),
            mileage: intValue(rawDictionary["mileage"]) ?? 0,
            parts: parts,
            workCost: workCost,
            totalCost: totalCost
        )
    }

    private func normalizeInput(_ input: MaintenanceRecordInput) -> MaintenanceRecord {
        let parts = input.parts.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.cost >= 0 }
        let workCost = input.workCost
        return MaintenanceRecord(
            id: nil,
            vehicleID: input.vehicleID,
            date: input.date,
            procedure: input.procedure,
            mileage: input.mileage,
            parts: parts,
            workCost: workCost,
            totalCost: deriveTotal(parts: parts, workCost: workCost)
        )
    }

    private func resolveParts(_ raw: [String: Any]) -> [MaintenancePart] {
        let directParts = arrayValue(raw["parts"]).compactMap { item -> MaintenancePart? in
            guard let item = dictionaryValue(item) else { return nil }
            let name = stringValue(item["name"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let cost = doubleValue(item["cost"]), !name.isEmpty, cost >= 0 else { return nil }
            return MaintenancePart(name: name, cost: cost)
        }

        if !directParts.isEmpty {
            return directParts
        }

        if let partsCost = doubleValue(raw["partsCost"]), partsCost >= 0 {
            return [MaintenancePart(name: "Запчасти", cost: partsCost)]
        }

        return []
    }

    private func deriveTotal(parts: [MaintenancePart], workCost: Double?) -> Double? {
        if parts.isEmpty, workCost == nil {
            return nil
        }
        return parts.reduce(0) { $0 + $1.cost } + (workCost ?? 0)
    }

    private func requestPayload(for record: MaintenanceRecord) -> [String: Any] {
        let partsCost = record.parts.reduce(0) { $0 + $1.cost }

        let payload: [String: Any?] = [
            "id": record.id,
            "vehicleId": record.vehicleID,
            "date": record.date,
            "procedure": record.procedure,
            "mileage": record.mileage,
            "parts": record.parts.map { ["name": $0.name, "cost": $0.cost] },
            "partsCost": record.parts.isEmpty ? nil : partsCost,
            "workCost": record.workCost
        ]

        return payload.compactMapValues { value in
            if let optional = value as? OptionalProtocol, optional.isNil {
                return nil
            }
            return value
        }
    }

    private func mapError(_ error: Error, fallback: String) -> Error {
        if let error = error as? AppServiceError {
            return error
        }
        return AppServiceError.message(fallback + ".")
    }

    private func v2URL(path: String) -> URL? {
        guard let origin = config.lumaWorkAPIOrigin?.trimmingCharacters(in: .whitespacesAndNewlines), !origin.isEmpty else {
            return nil
        }
        return URL(string: origin)?.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
}

@MainActor
@Observable
final class MaintenanceStore {
    private let service: MaintenanceService
    private let cacheKey: String

    var records: [MaintenanceRecord] = []
    var lastUpdatedAt: Date?
    var isLoading = false
    var isSubmitting = false
    var errorMessage: String?
    var notice: String?
    private var hasLoaded = false

    init(service: MaintenanceService, cacheID: String? = nil) {
        self.service = service
        cacheKey = AppOfflineSnapshotStore.scopedKey("maintenance", userID: cacheID)
        if let snapshot = AppOfflineSnapshotStore.load([MaintenanceRecord].self, key: cacheKey) {
            records = snapshot.value
            lastUpdatedAt = snapshot.updatedAt
        }
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await load(showsNetworkBanner: records.isEmpty)
    }

    func load(showsNetworkBanner: Bool = true) async {
        do {
            isLoading = true
            errorMessage = nil
            records = try await service.fetchRecords()
            lastUpdatedAt = Date()
            AppOfflineSnapshotStore.save(records, key: cacheKey)
            hasLoaded = true
        } catch {
            errorMessage = appUserFacingErrorMessage(
                error,
                showsNetworkBanner: showsNetworkBanner
            )
            if !records.isEmpty {
                hasLoaded = true
            }
        }
        isLoading = false
    }

    func save(editing target: MaintenanceRecord?, input: MaintenanceRecordInput) async -> Bool {
        do {
            isSubmitting = true
            errorMessage = nil
            if let target {
                _ = try await service.updateRecord(target: target, input: input)
                notice = "Запись обслуживания обновлена."
            } else {
                _ = try await service.createRecord(input)
                notice = "Запись обслуживания добавлена."
            }
            await load()
            isSubmitting = false
            return true
        } catch {
            isSubmitting = false
            errorMessage = appUserFacingErrorMessage(error)
            return false
        }
    }
}

struct MaintenanceScreen: View {
    private enum VehicleFlow: Identifiable {
        case add
        case edit(Vehicle)

        var id: String {
            switch self {
            case .add: "add"
            case let .edit(vehicle): "edit-\(vehicle.id)"
            }
        }

        var editingVehicle: Vehicle? {
            if case let .edit(vehicle) = self { vehicle } else { nil }
        }
    }

    let store: MaintenanceStore
    @Bindable var vehicleStore: VehicleStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft = MaintenanceDraft()
    @State private var editingRecord: MaintenanceRecord?
    @State private var isEditorPresented = false
    @State private var vehicleFlow: VehicleFlow?

    var body: some View {
        ZStack(alignment: .top) {
            AutoScreenBackdrop()

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    VehicleCarousel(store: vehicleStore) {
                        vehicleFlow = .add
                    } editAction: { vehicle in
                        vehicleFlow = .edit(vehicle)
                    }
                    .padding(.horizontal, -16)
                    .depthStackPrimary(reduceMotion: reduceMotion, pinY: -17)

                    AppCard {
                        VStack(alignment: .leading, spacing: 18) {
                            if let errorMessage = vehicleStore.errorMessage {
                                AppNoticeBanner(text: errorMessage, tint: AppTheme.dangerTint, isCritical: true)
                            }

                            maintenanceOverview

                            if let errorMessage = store.errorMessage {
                                AppNoticeBanner(text: errorMessage, tint: AppTheme.dangerTint, isCritical: true)
                            }

                            if !store.isLoading, selectedRecords.isEmpty, vehicleStore.selectedVehicle != nil {
                                AppEmptyState(
                                    title: "Записей пока нет",
                                    message: "Добавьте первое обслуживание выбранного автомобиля.",
                                    systemName: "wrench.and.screwdriver"
                                )
                            }

                            if !selectedRecords.isEmpty {
                                Label("ИСТОРИЯ", systemImage: "clock.arrow.circlepath")
                                    .font(.caption.weight(.bold))
                                    .tracking(0.8)
                                    .foregroundStyle(AppTheme.mutedTint)
                                    .padding(.top, 2)
                            }

                            ForEach(Array(selectedRecords.enumerated()), id: \.element.stableID) { index, record in
                                Button {
                                    editingRecord = record
                                    draft = MaintenanceDraft(record: record, fallbackVehicleID: vehicleStore.selectedVehicleID)
                                    isEditorPresented = true
                                } label: {
                                    MaintenanceTimelineRow(
                                        record: record,
                                        isLast: index == selectedRecords.count - 1
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .depthStackSecondary()
                }
                .padding(.horizontal, 16)
                .padding(.top, -17)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("Авто")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .appLoadingOverlay(
            isPresented: (vehicleStore.isLoading && vehicleStore.vehicles.isEmpty)
                || (store.isLoading && store.records.isEmpty),
            title: vehicleStore.vehicles.isEmpty
                ? "Загружаем автомобили"
                : "Загружаем записи обслуживания"
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    AppHaptics.trigger()
                    editingRecord = nil
                    draft = MaintenanceDraft(vehicleID: vehicleStore.selectedVehicleID)
                    isEditorPresented = true
                } label: {
                    Label("Добавить", systemImage: "plus")
                }
                .disabled(vehicleStore.selectedVehicle == nil)
            }
        }
        .task {
            async let vehicles: Void = vehicleStore.load(
                showsNetworkBanner: vehicleStore.vehicles.isEmpty
            )
            async let maintenance: Void = store.loadIfNeeded()
            _ = await (vehicles, maintenance)
        }
        .refreshable {
            await store.load()
        }
        .background {
            if let notice = store.notice {
                AppNoticeBanner(
                    text: notice,
                    tint: AppTheme.primaryTint,
                    style: .success
                )
            }
        }
        .task(id: store.notice) {
            await appDismissTransientMessage(store.notice) { value in
                if store.notice == value {
                    store.notice = nil
                }
            }
        }
        .task(id: store.errorMessage) {
            await appDismissTransientMessage(store.errorMessage) { value in
                if store.errorMessage == value {
                    store.errorMessage = nil
                }
            }
        }
        .sheet(isPresented: $isEditorPresented) {
            NavigationStack {
                MaintenanceEditorView(
                    draft: $draft,
                    vehicles: vehicleStore.vehicles,
                    isSubmitting: store.isSubmitting,
                    onSave: {
                        let input = MaintenanceRecordInput(
                            vehicleID: draft.vehicleID,
                            date: draft.date,
                            procedure: draft.procedure.trimmingCharacters(in: .whitespacesAndNewlines),
                            mileage: Int(draft.mileage) ?? 0,
                            parts: draft.parts.compactMap { part in
                                let name = part.name.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard let cost = Double(part.cost.replacingOccurrences(of: ",", with: ".")), !name.isEmpty else {
                                    return nil
                                }
                                return MaintenancePart(name: name, cost: cost)
                            },
                            workCost: draft.workCostValue
                        )
                        if await store.save(editing: editingRecord, input: input) {
                            isEditorPresented = false
                        }
                    }
                )
            }
            .presentationDetents([.large])
        }
        .sheet(item: $vehicleFlow) { flow in
            AddVehicleFlow(store: vehicleStore, editingVehicle: flow.editingVehicle)
                .presentationDetents([.large])
        }
    }

    private var selectedRecords: [MaintenanceRecord] {
        guard let vehicleID = vehicleStore.selectedVehicleID else { return [] }
        return store.records.filter { $0.vehicleID == vehicleID || ($0.vehicleID == nil && vehicleStore.vehicles.count == 1) }
    }

    private var maintenanceOverview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("ОБСЛУЖИВАНИЕ", systemImage: "wrench.and.screwdriver")
                .font(.caption.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(AppTheme.mutedTint)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 18, alignment: .topLeading),
                    GridItem(.flexible(), spacing: 18, alignment: .topLeading)
                ],
                alignment: .leading,
                spacing: 0
            ) {
                maintenanceMetric("Записей", "\(selectedRecords.count)")
                maintenanceMetric("Расходы", AppFormatting.rubles(totalMaintenanceCost))
                maintenanceMetric("Последнее ТО", selectedRecords.first.map { AppFormatting.shortDate($0.date) } ?? "Нет данных")
                maintenanceMetric(
                    "Пробег",
                    selectedRecords.first.map { "\(AppFormatting.number(Double($0.mileage), maximumFractionDigits: 0)) км" } ?? "Нет данных"
                )
            }

            if let latestRecord = selectedRecords.first {
                HStack(spacing: 12) {
                    Image(systemName: "wrench.adjustable")
                        .font(.headline)
                        .foregroundStyle(AppTheme.primaryTint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Последняя работа")
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedTint)
                        Text(latestRecord.procedure)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(AppTheme.ink)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private var totalMaintenanceCost: Double {
        selectedRecords.compactMap(\.totalCost).reduce(0, +)
    }

    private func maintenanceMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Rectangle()
                .fill(AppTheme.border)
                .frame(height: 1)
            Text(label)
                .font(.caption)
                .foregroundStyle(AppTheme.mutedTint)
            Text(value)
                .font(.body.weight(.semibold))
                .foregroundStyle(AppTheme.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
    }
}

private struct MaintenanceTimelineRow: View {
    let record: MaintenanceRecord
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Circle()
                    .fill(AppTheme.primaryTint)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(AppTheme.backgroundColor, lineWidth: 3))
                    .padding(.top, 5)

                if !isLast {
                    Rectangle()
                        .fill(AppTheme.border)
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                        .padding(.top, 5)
                }
            }
            .frame(width: 14)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(record.procedure)
                        .font(.headline)
                        .foregroundStyle(AppTheme.ink)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    if let totalCost = record.totalCost {
                        Text(AppFormatting.rubles(totalCost))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.secondaryTint)
                    }
                }

                HStack(spacing: 14) {
                    Label(AppFormatting.shortDate(record.date), systemImage: "calendar")
                    Label(
                        "\(AppFormatting.number(Double(record.mileage), maximumFractionDigits: 0)) км",
                        systemImage: "gauge.with.dots.needle.50percent"
                    )
                }
                .font(.caption)
                .foregroundStyle(AppTheme.mutedTint)

                if !record.parts.isEmpty {
                    Text(record.parts.map { "\($0.name) — \(AppFormatting.rubles($0.cost))" }.joined(separator: " • "))
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.ink.opacity(0.82))
                        .multilineTextAlignment(.leading)
                }

                if let workCost = record.workCost {
                    Text("Работа: \(AppFormatting.rubles(workCost))")
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedTint)
                }
            }
            .padding(.bottom, isLast ? 4 : 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }
}

private struct AutoScreenBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                AppTheme.background

                Image("AutoHeroBackground")
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: 540)
                    .clipped()
                    .overlay(colorScheme == .dark ? Color.black.opacity(0.06) : Color.white.opacity(0.02))
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: 0.70),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .ignoresSafeArea()
    }
}

struct MaintenanceDraft: Hashable {
    struct PartDraft: Hashable, Identifiable {
        var id = UUID()
        var name = ""
        var cost = ""
    }

    var vehicleID: String?
    var date = ""
    var procedure = ""
    var mileage = ""
    var parts: [PartDraft] = []
    var workCost = ""

    init(vehicleID: String? = nil) {
        self.vehicleID = vehicleID
    }

    init(record: MaintenanceRecord, fallbackVehicleID: String? = nil) {
        vehicleID = record.vehicleID ?? fallbackVehicleID
        date = record.date
        procedure = record.procedure
        mileage = String(record.mileage)
        parts = record.parts.map { PartDraft(name: $0.name, cost: String($0.cost)) }
        workCost = record.workCost.map { String($0) } ?? ""
    }

    var workCostValue: Double? {
        let normalized = workCost.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        return normalized.isEmpty ? nil : Double(normalized)
    }
}

private struct MaintenanceEditorView: View {
    @Binding var draft: MaintenanceDraft
    let vehicles: [Vehicle]
    let isSubmitting: Bool
    let onSave: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var validationError: String?

    var body: some View {
        Form {
            if vehicles.count > 1 {
                Section("Автомобиль") {
                    Picker("Применить к", selection: vehicleSelection) {
                        ForEach(vehicles) { vehicle in
                            Text(vehiclePickerTitle(vehicle)).tag(vehicle.id)
                        }
                    }
                    .pickerStyle(.menu)
                }
            } else if let vehicle = vehicles.first {
                Section("Автомобиль") {
                    LabeledContent("Применить к", value: vehicle.displayName)
                }
            }

            Section("Запись") {
                AppDateField(title: "Дата", text: $draft.date)
                TextField("Процедура", text: $draft.procedure)
                TextField("Пробег", text: $draft.mileage)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.numberPad)
                TextField("Работа", text: $draft.workCost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.decimalPad)
            }

            Section("Запчасти") {
                ForEach($draft.parts) { $part in
                    VStack {
                        TextField("Название", text: $part.name)
                        TextField("Стоимость", text: $part.cost)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.decimalPad)
                    }
                }
                .onDelete { offsets in
                    draft.parts.remove(atOffsets: offsets)
                }

                Button("Добавить запчасть") {
                    draft.parts.append(.init())
                }
            }

            if let validationError {
                Section {
                    Text(validationError)
                        .foregroundStyle(AppTheme.dangerTint)
                }
            }
        }
        .navigationTitle("Обслуживание")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ModalCloseButton(action: dismiss.callAsFunction)
            }
            ToolbarItem(placement: .topBarTrailing) {
                ModalConfirmButton(
                    action: {
                        AppHaptics.trigger()
                        validationError = validate()
                        guard validationError == nil else { return }
                        Task {
                            await onSave()
                        }
                    },
                    isDisabled: isSubmitting,
                    isLoading: isSubmitting,
                    accessibilityLabel: "Сохранить обслуживание"
                )
            }
        }
    }

    private func validate() -> String? {
        if vehicles.count > 1, draft.vehicleID == nil {
            return "Выберите автомобиль для записи."
        }

        if draft.date.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            draft.procedure.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            draft.mileage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Заполните дату, процедуру и пробег."
        }

        guard let mileage = Int(draft.mileage), mileage >= 0 else {
            return "Пробег должен быть неотрицательным числом."
        }
        _ = mileage

        if let workCost = draft.workCostValue, workCost < 0 {
            return "Стоимость работы должна быть неотрицательным числом."
        }

        for part in draft.parts {
            let isNameEmpty = part.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let costRaw = part.cost.trimmingCharacters(in: .whitespacesAndNewlines)

            if isNameEmpty, costRaw.isEmpty {
                continue
            }
            guard !isNameEmpty, let cost = Double(costRaw.replacingOccurrences(of: ",", with: ".")), cost >= 0 else {
                return "Для каждой запчасти укажите название и неотрицательную стоимость."
            }
        }

        return nil
    }

    private var vehicleSelection: Binding<String> {
        Binding(
            get: { draft.vehicleID ?? vehicles.first?.id ?? "" },
            set: { draft.vehicleID = $0 }
        )
    }

    private func vehiclePickerTitle(_ vehicle: Vehicle) -> String {
        let plate = vehicle.licensePlate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return plate.isEmpty ? vehicle.displayName : "\(vehicle.displayName) • \(plate)"
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
