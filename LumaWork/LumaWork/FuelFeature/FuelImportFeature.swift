import Foundation
import SwiftUI

struct FuelImportUpload: Encodable {
    let fileName: String
    let dataBase64: String
}

struct FuelImportEntry: Decodable, Hashable, Identifiable {
    let row: Int
    let date: String?
    let fuelType: String?
    let liters: Double?
    let cost: Double?

    var id: Int { row }

    var isIncomplete: Bool {
        date == nil || fuelType == nil || liters == nil || cost == nil
    }
}

struct FuelImportTypeTotal: Decodable, Hashable, Identifiable {
    let fuelType: String
    let liters: Double
    let cost: Double

    var id: String { fuelType }
}

struct FuelImportPreviewItem: Decodable, Hashable, Identifiable {
    enum Status: String, Decodable {
        case ready
        case warning
        case duplicate
        case conflict
        case replaceable
        case error
    }

    let id: String
    let fileName: String
    let fileHash: String
    let status: Status
    let period: String?
    let entries: [FuelImportEntry]
    let totalsByFuelType: [FuelImportTypeTotal]
    let totalLiters: Double
    let totalCost: Double
    let mileage: Double?
    let carModel: String?
    let fuelNorm: Double?
    let worksheets: [String]
    let reportFormatVersion: Int
    let importerVersion: String
    let warnings: [String]
    let errors: [String]
    let existingImportId: String?
}

struct FuelImportEntryCorrection: Hashable {
    let row: Int
    var date: String
    var fuelType: String
    var liters: String
    var cost: String

    nonisolated init(entry: FuelImportEntry) {
        row = entry.row
        date = entry.date ?? ""
        fuelType = entry.fuelType ?? ""
        liters = entry.liters.map { String($0) } ?? ""
        cost = entry.cost.map { String($0) } ?? ""
    }

    var dictionary: [String: Any] {
        var result: [String: Any] = ["row": row]
        let normalizedDate = date.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedDate.isEmpty { result["date"] = normalizedDate }
        let normalizedFuelType = fuelType.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedFuelType.isEmpty { result["fuelType"] = normalizedFuelType }
        if let value = parseNumber(liters) { result["liters"] = value }
        if let value = parseNumber(cost) { result["cost"] = value }
        return result
    }

    private func parseNumber(_ value: String) -> Double? {
        Double(value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
    }
}

struct FuelImportCorrection: Hashable {
    let fileHash: String
    var period: String?
    var entries: [FuelImportEntryCorrection]

    nonisolated init(item: FuelImportPreviewItem) {
        fileHash = item.fileHash
        period = item.period
        entries = item.entries.map(FuelImportEntryCorrection.init)
    }

    var dictionary: [String: Any] {
        var result: [String: Any] = [
            "fileHash": fileHash,
            "entries": entries.map(\.dictionary)
        ]
        if let period { result["period"] = period }
        return result
    }
}

struct FuelImportCommitResponse: Decodable {
    struct Result: Decodable, Identifiable {
        let fileName: String
        let period: String?
        let status: String
        let message: String
        let refuelCount: Int

        var id: String { "\(fileName)|\(period ?? "")|\(status)" }
    }

    let importedMonths: Int
    let skippedMonths: Int
    let importedRefuels: Int
    let totalLiters: Double
    let totalCost: Double
    let results: [Result]
}

struct FuelImportAPI {
    private struct PreviewResponse: Decodable {
        let items: [FuelImportPreviewItem]
    }

    private let baseURL: URL?
    private let authToken: String?
    private let client = HTTPClient()

    init(config: AppConfig, authToken: String?) {
        baseURL = config.lumaWorkAPIOrigin.flatMap {
            URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        self.authToken = authToken
    }

    func preview(_ uploads: [FuelImportUpload]) async throws -> [FuelImportPreviewItem] {
        let response = try await request(
            path: "/api/v2/fuel/imports/preview",
            body: ["files": uploads.map(\.dictionary)]
        )
        return try decode(PreviewResponse.self, json: response.json).items
    }

    func commit(
        _ uploads: [FuelImportUpload],
        replacing importIDs: Set<String>,
        corrections: [FuelImportCorrection]
    ) async throws -> FuelImportCommitResponse {
        let response = try await request(
            path: "/api/v2/fuel/imports/commit",
            body: [
                "files": uploads.map(\.dictionary),
                "replaceImportIds": Array(importIDs),
                "corrections": corrections.map(\.dictionary)
            ]
        )
        return try decode(FuelImportCommitResponse.self, json: response.json)
    }

    private func request(path: String, body: [String: Any]) async throws -> HTTPResponse {
        guard let authToken, !authToken.isEmpty, let baseURL else {
            throw AppServiceError.message("Требуется авторизация.")
        }
        return try await client.request(
            baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
            method: "POST",
            body: body,
            authToken: authToken
        )
    }

    private func decode<Value: Decodable>(_ type: Value.Type, json: Any?) throws -> Value {
        guard let json else { throw AppServiceError.message("Сервер вернул пустой ответ.") }
        return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: json))
    }
}

private extension FuelImportUpload {
    var dictionary: [String: Any] {
        ["fileName": fileName, "dataBase64": dataBase64]
    }
}

@MainActor
extension FuelStore {
    func previewFuelImports(urls: [URL]) async -> Bool {
        guard !isPreviewingImport, !urls.isEmpty else { return false }
        isPreviewingImport = true
        importErrorMessage = nil
        importPreviewItems = []
        pendingImportUploads = []
        defer { isPreviewingImport = false }

        do {
            var uploads: [FuelImportUpload] = []
            var totalBytes = 0
            for url in urls {
                guard url.pathExtension.lowercased() == "xlsx" else {
                    throw AppServiceError.message("Поддерживаются только файлы XLSX.")
                }
                let didStartAccess = url.startAccessingSecurityScopedResource()
                defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard !data.isEmpty, data.count <= 6 * 1024 * 1024 else {
                    throw AppServiceError.message("Размер каждого XLSX должен быть не больше 6 МБ.")
                }
                totalBytes += data.count
                guard totalBytes <= 7 * 1024 * 1024 else {
                    throw AppServiceError.message("Общий размер выбранных отчётов должен быть не больше 7 МБ.")
                }
                uploads.append(FuelImportUpload(fileName: url.lastPathComponent, dataBase64: data.base64EncodedString()))
            }
            let items = try await importAPI.preview(uploads)
            pendingImportUploads = uploads
            importPreviewItems = items
            return true
        } catch is CancellationError {
            return false
        } catch {
            importErrorMessage = appUserFacingErrorMessage(error, fallback: "Не удалось разобрать XLSX-отчёты.")
            return false
        }
    }

    func commitFuelImports(
        replacing importIDs: Set<String>,
        corrections: [FuelImportCorrection]
    ) async -> Bool {
        guard !isCommittingImport, !pendingImportUploads.isEmpty else { return false }
        isCommittingImport = true
        importErrorMessage = nil
        defer { isCommittingImport = false }

        do {
            let result = try await importAPI.commit(
                pendingImportUploads,
                replacing: importIDs,
                corrections: corrections
            )
            guard result.importedMonths > 0 else {
                importErrorMessage = result.results.first?.message ?? "Нет месяцев, готовых к импорту."
                return false
            }
            await load()
            let skipped = result.skippedMonths > 0 ? " Пропущено: \(result.skippedMonths)." : ""
            notice = "История топлива восстановлена. Импортировано месяцев: \(result.importedMonths), заправок: \(result.importedRefuels).\(skipped)"
            importPreviewItems = []
            pendingImportUploads = []
            return true
        } catch is CancellationError {
            return false
        } catch {
            importErrorMessage = appUserFacingErrorMessage(error, fallback: "Не удалось импортировать отчёты.")
            return false
        }
    }
}

struct FuelImportPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: FuelStore
    @State private var replacementImportIDs: Set<String> = []
    @State private var corrections: [String: FuelImportCorrection] = [:]
    @State private var correctionRoute: FuelImportCorrectionRoute?

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 14) {
                header

                if let error = store.importErrorMessage {
                    FuelNotice(text: error, tint: FuelUI.danger, isCritical: true)
                }

                ForEach(store.importPreviewItems) { item in
                    monthCard(item)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 16)
        }
        .background(FuelUI.background.ignoresSafeArea())
        .navigationTitle("Импорт отчётов")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("Закрыть")
            }
        }
        .safeAreaInset(edge: .bottom) {
            importFooter
        }
        .sheet(item: $correctionRoute) { route in
            NavigationStack {
                FuelImportCorrectionSheet(
                    item: route.item,
                    initialCorrection: correction(for: route.item)
                ) { correction in
                    corrections[route.item.id] = correction
                }
            }
            .appEditorSheetStyle()
        }
        .interactiveDismissDisabled(store.isCommittingImport)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Проверьте историю перед сохранением")
                .font(.title3.weight(.semibold))
                .foregroundStyle(FuelUI.text)
            Text("Каждая строка останется отдельной заправкой. Итоги рассчитаны по видам топлива и по месяцу.")
                .font(.subheadline)
                .foregroundStyle(FuelUI.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func monthCard(_ item: FuelImportPreviewItem) -> some View {
        FuelPanelCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: statusIcon(item.status))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(statusTint(item.status))
                    .frame(width: 34, height: 34)
                    .background(statusTint(item.status).opacity(0.13), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(monthTitle(effectivePeriod(for: item)))
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(FuelUI.text)
                    Text(statusTitle(item.status))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(statusTint(item.status))
                    Text(item.fileName)
                        .font(.caption2)
                        .foregroundStyle(FuelUI.muted)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Text("\(meaningfulEntryCount(item)) \(refuelWord(meaningfulEntryCount(item)))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FuelUI.mutedStrong)
            }

            if !item.entries.isEmpty {
                VStack(spacing: 0) {
                    ForEach(item.entries) { entry in
                        let corrected = correctedEntry(entry, in: item)
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(dayTitle(corrected.date.nilIfBlank ?? effectiveMonthEndDate(for: item) ?? "Дата не указана"))
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(FuelUI.text)
                                Text(corrected.fuelType.nilIfBlank ?? "Вид топлива не указан")
                                    .font(.caption)
                                    .foregroundStyle(FuelUI.accent)
                            }
                            Spacer(minLength: 8)
                            Text(displayNumber(corrected.liters).map { "\(AppFormatting.number($0)) л" } ?? "— л")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(FuelUI.mutedStrong)
                            Text(displayNumber(corrected.cost).map { AppFormatting.rubles($0, maximumFractionDigits: 0) } ?? "— ₽")
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(FuelUI.text)
                                .frame(minWidth: 74, alignment: .trailing)
                        }
                        .padding(.vertical, 10)

                        if entry.id != item.entries.last?.id {
                            Divider().overlay(FuelUI.divider)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .background(FuelUI.subpanel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                if item.totalsByFuelType.count > 1 {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("По видам топлива")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(FuelUI.muted)
                        ForEach(item.totalsByFuelType) { total in
                            HStack {
                                Text(total.fuelType)
                                Spacer()
                                Text("\(AppFormatting.number(total.liters)) л · \(AppFormatting.rubles(total.cost, maximumFractionDigits: 0))")
                            }
                            .font(.caption)
                            .foregroundStyle(FuelUI.mutedStrong)
                        }
                    }
                }

                HStack {
                    Text("Итого")
                        .font(.headline.weight(.semibold))
                    Spacer()
                    Text("\(AppFormatting.number(correctedTotalLiters(item))) л")
                    Text(AppFormatting.rubles(correctedTotalCost(item), maximumFractionDigits: 0))
                        .fontWeight(.semibold)
                }
                .font(.subheadline)
                .foregroundStyle(FuelUI.text)
            }

            if item.period == nil || item.entries.contains(where: \.isIncomplete) {
                Button {
                    correctionRoute = FuelImportCorrectionRoute(item: item)
                } label: {
                    Label(
                        item.period == nil ? "Выбрать месяц и год" : "Дополнить данные",
                        systemImage: item.period == nil ? "calendar" : "square.and.pencil"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(FuelUI.accent)
            }

            if let mileage = item.mileage {
                HStack(spacing: 8) {
                    Label("Пробег", systemImage: "road.lanes")
                    Spacer()
                    Text("\(AppFormatting.number(mileage, maximumFractionDigits: 0)) км")
                        .fontWeight(.semibold)
                }
                .font(.subheadline)
                .foregroundStyle(FuelUI.mutedStrong)
            }

            if let carModel = item.carModel, !carModel.isEmpty {
                HStack {
                    Label("Автомобиль", systemImage: "car.fill")
                    Spacer()
                    Text(carModel)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(FuelUI.mutedStrong)
            }

            if let norm = item.fuelNorm {
                HStack {
                    Text("Норма из отчёта")
                    Spacer()
                    Text("\(AppFormatting.number(norm)) л / 100 км")
                        .fontWeight(.semibold)
                }
                .font(.caption)
                .foregroundStyle(FuelUI.mutedStrong)
            }

            ForEach(item.errors, id: \.self) { message in
                issueRow(message, tint: FuelUI.danger, icon: "xmark.circle.fill")
            }
            ForEach(item.warnings, id: \.self) { message in
                issueRow(message, tint: FuelUI.warning, icon: "exclamationmark.triangle.fill")
            }

            if item.status == .replaceable, let importID = item.existingImportId {
                Toggle("Заменить предыдущий XLSX-импорт", isOn: replacementBinding(importID))
                    .font(.subheadline.weight(.medium))
                    .tint(FuelUI.accent)
            }
        }
    }

    private var importFooter: some View {
        VStack(spacing: 8) {
            Button {
                Task {
                    if await store.commitFuelImports(
                        replacing: replacementImportIDs,
                        corrections: store.importPreviewItems.map { correction(for: $0) }
                    ) {
                        AppHaptics.trigger()
                        dismiss()
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    if store.isCommittingImport { ProgressView().tint(.white) }
                    Text(store.isCommittingImport ? "Импортируем…" : "Импортировать \(importableMonthCount) \(monthWord(importableMonthCount))")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(FuelPrimaryButtonStyle())
            .disabled(importableMonthCount == 0 || store.isCommittingImport)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }

    private var importableMonthCount: Int {
        store.importPreviewItems.filter { item in
            effectivePeriod(for: item) != nil
                && (item.status == .ready
                || item.status == .warning
                || (item.status == .replaceable && item.existingImportId.map(replacementImportIDs.contains) == true))
        }.count
    }

    private func correction(for item: FuelImportPreviewItem) -> FuelImportCorrection {
        corrections[item.id] ?? FuelImportCorrection(item: item)
    }

    private func effectivePeriod(for item: FuelImportPreviewItem) -> String? {
        correction(for: item).period
    }

    private func effectiveMonthEndDate(for item: FuelImportPreviewItem) -> String? {
        guard let period = effectivePeriod(for: item),
              let date = FuelImportFormatting.monthParser.date(from: period),
              let range = Calendar(identifier: .gregorian).range(of: .day, in: .month, for: date) else {
            return nil
        }
        return "\(period)-\(String(format: "%02d", range.count))"
    }

    private func meaningfulEntryCount(_ item: FuelImportPreviewItem) -> Int {
        correction(for: item).entries.count
    }

    private func correctedEntry(_ entry: FuelImportEntry, in item: FuelImportPreviewItem) -> FuelImportEntryCorrection {
        correction(for: item).entries.first(where: { $0.row == entry.row }) ?? FuelImportEntryCorrection(entry: entry)
    }

    private func displayNumber(_ value: String) -> Double? {
        Double(value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
    }

    private func correctedTotalLiters(_ item: FuelImportPreviewItem) -> Double {
        correction(for: item).entries.reduce(0) { $0 + (displayNumber($1.liters) ?? 0) }
    }

    private func correctedTotalCost(_ item: FuelImportPreviewItem) -> Double {
        correction(for: item).entries.reduce(0) { $0 + (displayNumber($1.cost) ?? 0) }
    }

    private func replacementBinding(_ importID: String) -> Binding<Bool> {
        Binding(
            get: { replacementImportIDs.contains(importID) },
            set: { enabled in
                if enabled { replacementImportIDs.insert(importID) }
                else { replacementImportIDs.remove(importID) }
            }
        )
    }

    private func issueRow(_ message: String, tint: Color, icon: String) -> some View {
        Label(message, systemImage: icon)
            .font(.caption)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func statusIcon(_ status: FuelImportPreviewItem.Status) -> String {
        switch status {
        case .ready: "checkmark.circle.fill"
        case .warning, .replaceable: "exclamationmark.triangle.fill"
        case .duplicate: "checkmark.circle"
        case .conflict: "exclamationmark.octagon.fill"
        case .error: "xmark.circle.fill"
        }
    }

    private func statusTint(_ status: FuelImportPreviewItem.Status) -> Color {
        switch status {
        case .ready: FuelUI.positive
        case .warning, .replaceable: FuelUI.warning
        case .duplicate: FuelUI.mutedStrong
        case .conflict, .error: FuelUI.danger
        }
    }

    private func statusTitle(_ status: FuelImportPreviewItem.Status) -> String {
        switch status {
        case .ready: "Готов к импорту"
        case .warning: "Есть предупреждения"
        case .duplicate: "Уже импортирован"
        case .conflict: "Конфликт с историей"
        case .replaceable: "Можно заменить прошлый импорт"
        case .error: "Файл не удалось обработать"
        }
    }

    private func monthTitle(_ period: String?) -> String {
        guard let period,
              let date = FuelImportFormatting.monthParser.date(from: period) else { return "Месяц не определён" }
        return FuelImportFormatting.monthTitle.string(from: date).capitalized
    }

    private func dayTitle(_ value: String) -> String {
        guard let date = FuelImportFormatting.dayParser.date(from: value) else { return value }
        return FuelImportFormatting.dayTitle.string(from: date)
    }

    private func refuelWord(_ count: Int) -> String {
        count % 10 == 1 && count % 100 != 11 ? "заправка"
            : (2 ... 4).contains(count % 10) && !(12 ... 14).contains(count % 100) ? "заправки" : "заправок"
    }

    private func monthWord(_ count: Int) -> String {
        count % 10 == 1 && count % 100 != 11 ? "месяц"
            : (2 ... 4).contains(count % 10) && !(12 ... 14).contains(count % 100) ? "месяца" : "месяцев"
    }
}

private struct FuelImportCorrectionRoute: Identifiable {
    let item: FuelImportPreviewItem
    var id: String { item.id }
}

private struct FuelImportCorrectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: FuelImportPreviewItem
    let onSave: (FuelImportCorrection) -> Void
    @State private var correction: FuelImportCorrection
    @State private var selectedMonth: Date

    init(
        item: FuelImportPreviewItem,
        initialCorrection: FuelImportCorrection,
        onSave: @escaping (FuelImportCorrection) -> Void
    ) {
        self.item = item
        self.onSave = onSave
        _correction = State(initialValue: initialCorrection)
        _selectedMonth = State(initialValue:
            initialCorrection.period.flatMap(FuelImportFormatting.monthParser.date(from:)) ?? Date()
        )
    }

    var body: some View {
        Form {
            Section {
                DatePicker(
                    "Месяц и год",
                    selection: $selectedMonth,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)

                Text("День в календаре не учитывается. Месячная запись сохраняется на последний день выбранного месяца.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Период отчёта")
            }

            if !correction.entries.isEmpty {
                Section {
                    ForEach($correction.entries, id: \.row) { $entry in
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Строка \(entry.row)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            TextField("Дата YYYY-MM-DD", text: $entry.date)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.numbersAndPunctuation)
                            TextField("Вид топлива", text: $entry.fuelType)
                            HStack {
                                TextField("Литры", text: $entry.liters)
                                    .keyboardType(.decimalPad)
                                TextField("Сумма", text: $entry.cost)
                                    .keyboardType(.decimalPad)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Заправки")
                } footer: {
                    Text("Пустые поля не блокируют импорт. Вы сможете дополнить записи позже.")
                }
            }
        }
        .navigationTitle("Данные отчёта")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Отмена") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Готово") {
                    correction.period = FuelImportFormatting.monthKey.string(from: selectedMonth)
                    onSave(correction)
                    dismiss()
                }
            }
        }
    }
}

private enum FuelImportFormatting {
    static let monthParser: DateFormatter = formatter("yyyy-MM", locale: "en_US_POSIX")
    static let dayParser: DateFormatter = formatter("yyyy-MM-dd", locale: "en_US_POSIX")
    static let monthTitle: DateFormatter = formatter("LLLL yyyy", locale: "ru_RU")
    static let dayTitle: DateFormatter = formatter("d MMMM", locale: "ru_RU")
    static let monthKey: DateFormatter = formatter("yyyy-MM", locale: "en_US_POSIX")

    private static func formatter(_ format: String, locale: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: locale)
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
