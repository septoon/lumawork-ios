import Foundation
import SwiftUI

enum FuelUI {
    static let background = AppTheme.background
    static let navBarBackground = Color.clear
    static let panel = AppTheme.panelSurface
    static let subpanel = AppTheme.subpanelSurface
    static let chipBackground = AppTheme.primaryTint.opacity(0.10)
    static let text = AppTheme.ink
    static let muted = AppTheme.mutedTint
    static let mutedStrong = AppTheme.ink.opacity(0.76)
    static let accent = AppTheme.primaryTint
    static let accentBorder = AppTheme.primaryTint.opacity(0.35)
    static let positive = AppTheme.secondaryTint
    static let danger = AppTheme.dangerTint
    static let warning = AppTheme.secondaryTint
    static let warningBackground = AppTheme.secondaryTint.opacity(0.16)
    static let warningBorder = AppTheme.secondaryTint.opacity(0.30)
    static let border = AppTheme.border
    static let divider = AppTheme.border
    static let overlay = AppTheme.overlayScrim
}

struct FuelPanelCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FuelUI.panel, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(FuelUI.border, lineWidth: 1)
        )
    }
}

struct FuelInsetCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FuelUI.subpanel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(FuelUI.border, lineWidth: 1)
        )
    }
}

struct FuelNotice: View {
    let text: String
    let tint: Color
    let isCritical: Bool

    var body: some View {
        AppNoticeBanner(
            text: text,
            tint: tint,
            isCritical: isCritical,
            style: isCritical ? .error : .success
        )
    }
}

struct FuelIconButton: View {
    let systemName: String
    var tint: Color = FuelUI.accent
    let action: () -> Void

    private var title: String {
        switch systemName {
        case "pencil":
            "Редактировать"
        case "trash":
            "Удалить"
        default:
            "Действие"
        }
    }

    var body: some View {
        Button(title, systemImage: systemName) {
            AppHaptics.trigger()
            action()
        }
        .labelStyle(.iconOnly)
        .appNativeIconControl(.inline, tint: tint)
    }
}

struct FuelDraft: Hashable {
    var date = ""
    var fuelType = ""
    var mileage = ""
    var liters = ""
    var fuelCost = ""
    var monthKey = ""
    var amount = ""
    var carryoverDebtRub = ""
    var comment = ""
    var adjustmentKind: FuelRecord.AdjustmentKind = .compensationPayment

    init() {}

    nonisolated init(record: FuelRecord) {
        date = record.date
        fuelType = record.fuelType ?? ""
        mileage = record.mileage.map { String($0) } ?? ""
        liters = record.liters.map { String($0) } ?? ""
        fuelCost = record.fuelCost.map { String($0) } ?? ""
        monthKey = record.monthKey ?? String(record.date.prefix(7))
        amount = record.amount.map { String($0) } ?? ""
        carryoverDebtRub = record.carryoverDebtRub.map { String($0) } ?? ""
        comment = record.comment ?? ""
        adjustmentKind = record.adjustmentKind ?? .compensationPayment
    }

    static func adjustment(kind: FuelRecord.AdjustmentKind) -> FuelDraft {
        var draft = FuelDraft()
        draft.adjustmentKind = kind
        return draft
    }

    var mileageValue: Double? {
        parseNumber(mileage)
    }

    var litersValue: Double? {
        parseNumber(liters)
    }

    var fuelCostValue: Double? {
        parseNumber(fuelCost)
    }

    var amountValue: Double? {
        parseNumber(amount)
    }

    var carryoverDebtValue: Double? {
        parseNumber(carryoverDebtRub)
    }

    private func parseNumber(_ raw: String) -> Double? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        return normalized.isEmpty ? nil : Double(normalized)
    }
}

enum FuelEditorMode: String, Identifiable {
    case fuel
    case adjustment

    var id: String { rawValue }
}

struct FuelEditorView: View {
    @Binding var draft: FuelDraft
    let fuelTypes: [String]
    let isSubmitting: Bool
    let isEditing: Bool
    let serverError: String?
    let onClose: () -> Void
    let onSave: () async -> Void

    @State private var validationError: String?

    var body: some View {
        FuelModalContainer(
            title: isEditing ? "Редактировать запись" : "Добавить запись топлива",
            onClose: onClose
        ) {
            FuelDateField(title: "Дата", text: $draft.date)
            if !fuelTypes.isEmpty {
                Picker("Тип топлива", selection: $draft.fuelType) {
                    ForEach(fuelTypes, id: \.self) { fuelType in
                        Text(fuelType).tag(fuelType)
                    }
                }
                .pickerStyle(.menu)
            }
            FuelFormField(title: "Пробег (км)", text: $draft.mileage, placeholder: "0", kind: .integer)

            if let validationError {
                Text(validationError)
                    .font(.footnote)
                    .foregroundStyle(FuelUI.danger)
            }

            if let serverError, !serverError.isEmpty {
                FuelNotice(text: serverError, tint: FuelUI.danger, isCritical: true)
            }
        } footer: {
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
                accessibilityLabel: isEditing ? "Сохранить запись" : "Добавить запись"
            )
        }
    }

    private func validate() -> String? {
        if draft.date.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Укажите дату."
        }
        if (draft.litersValue != nil || draft.fuelCostValue != nil), draft.fuelType.isEmpty {
            return "Выберите тип топлива."
        }
        let mileageText = draft.mileage.trimmingCharacters(in: .whitespacesAndNewlines)
        if mileageText.isEmpty {
            if isEditing, draft.litersValue != nil || draft.fuelCostValue != nil {
                return nil
            }
            return "Укажите пробег."
        }
        guard let mileage = draft.mileageValue else {
            return "Укажите корректный пробег."
        }
        if mileage < 0 {
            return "Пробег должен быть неотрицательным."
        }
        return nil
    }
}

struct FuelAdjustmentEditorView: View {
    @Binding var draft: FuelDraft
    let isSubmitting: Bool
    let isEditing: Bool
    let serverError: String?
    let onClose: () -> Void
    let onSave: () async -> Void

    @State private var validationError: String?

    var body: some View {
        FuelModalContainer(
            title: isEditing ? "Редактировать корректировку" : "Добавить корректировку",
            onClose: onClose
        ) {
            HStack(spacing: 10) {
                adjustmentKindButton(title: "Выплата", kind: .compensationPayment)
                adjustmentKindButton(title: "Вычет долга", kind: .debtDeduction)
            }

            FuelFormField(title: "Месяц", text: $draft.monthKey, placeholder: "YYYY-MM", kind: .month)
            FuelFormField(title: "Сумма", text: $draft.amount, placeholder: "0.00", kind: .decimal)
            FuelFormField(title: "Литры", text: $draft.liters, placeholder: "0.00", kind: .decimal)

            if draft.adjustmentKind == .debtDeduction {
                FuelFormField(title: "Остаток долга", text: $draft.carryoverDebtRub, placeholder: "0.00", kind: .decimal)
            }

            FuelFormField(title: "Комментарий", text: $draft.comment, placeholder: "Комментарий", kind: .text)

            if let validationError {
                Text(validationError)
                    .font(.footnote)
                    .foregroundStyle(FuelUI.danger)
            }

            if let serverError, !serverError.isEmpty {
                FuelNotice(text: serverError, tint: FuelUI.danger, isCritical: true)
            }
        } footer: {
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
                accessibilityLabel: isEditing ? "Сохранить корректировку" : "Добавить корректировку"
            )
        }
    }

    private func adjustmentKindButton(title: String, kind: FuelRecord.AdjustmentKind) -> some View {
        let isSelected = draft.adjustmentKind == kind
        return Button {
            AppHaptics.trigger()
            draft.adjustmentKind = kind
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? .white : FuelUI.warning)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isSelected ? FuelUI.accent : FuelUI.warningBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(isSelected ? FuelUI.accentBorder : FuelUI.warningBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func validate() -> String? {
        if !draft.monthKey.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression).map({ _ in true }, default: false) {
            return "Укажите месяц корректировки в формате YYYY-MM."
        }
        if draft.adjustmentKind == .compensationPayment, draft.amountValue == nil {
            return "Для выплаты укажите сумму."
        }
        if draft.adjustmentKind == .debtDeduction, draft.amountValue == nil, draft.litersValue == nil {
            return "Для вычета долга укажите сумму или литры."
        }
        for value in [draft.amountValue, draft.litersValue, draft.carryoverDebtValue] {
            if let value, value < 0 {
                return "Все числовые значения должны быть неотрицательными."
            }
        }
        return nil
    }
}

struct FuelRecordEditSheet: View {
    @Environment(\.dismiss) private var dismiss

    let store: FuelStore
    let record: FuelRecord

    @State private var draft: FuelDraft

    init(store: FuelStore, record: FuelRecord) {
        self.store = store
        self.record = record
        _draft = State(initialValue: FuelDraft(record: record))
    }

    var body: some View {
        Group {
            if record.recordType == .fuel {
                FuelEditorView(
                    draft: $draft,
                    fuelTypes: store.availableFuelTypes,
                    isSubmitting: store.isSubmitting,
                    isEditing: true,
                    serverError: store.errorMessage,
                    onClose: { dismiss() },
                    onSave: saveFuel
                )
            } else {
                FuelAdjustmentEditorView(
                    draft: $draft,
                    isSubmitting: store.isSubmitting,
                    isEditing: true,
                    serverError: store.errorMessage,
                    onClose: { dismiss() },
                    onSave: saveAdjustment
                )
            }
        }
        .onAppear {
            store.errorMessage = nil
        }
    }

    private func saveFuel() async {
        let input = FuelRecordInput(
            recordType: .fuel,
            adjustmentKind: nil,
            monthKey: nil,
            amount: nil,
            carryoverDebtRub: nil,
            comment: record.comment,
            date: draft.date,
            mileage: draft.mileageValue,
            liters: record.liters,
            fuelCost: record.fuelCost,
            fuelType: draft.fuelType.nilIfEmpty ?? record.fuelType
        )
        if await store.save(editing: record, input: input) {
            dismiss()
        }
    }

    private func saveAdjustment() async {
        let input = FuelRecordInput(
            recordType: .adjustment,
            adjustmentKind: draft.adjustmentKind,
            monthKey: draft.monthKey,
            amount: draft.amountValue,
            carryoverDebtRub: draft.carryoverDebtValue,
            comment: draft.comment.nilIfEmpty,
            date: "\(draft.monthKey)-01",
            mileage: nil,
            liters: draft.litersValue,
            fuelCost: nil
        )
        if await store.save(editing: record, input: input) {
            dismiss()
        }
    }
}

struct FuelModalContainer<Content: View, Footer: View>: View {
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer
    let title: String
    let onClose: () -> Void

    init(
        title: String,
        onClose: @escaping () -> Void,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.onClose = onClose
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(FuelUI.background.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                ModalCloseButton(action: onClose, tint: FuelUI.accent)
            }

            ToolbarItem(placement: .confirmationAction) {
                footer
            }
        }
    }
}

struct FuelFormField: View {
    enum Kind {
        case text
        case integer
        case decimal
        case month

        var keyboardType: UIKeyboardType {
            switch self {
            case .text:
                return .default
            case .integer:
                return .numberPad
            case .decimal:
                return .decimalPad
            case .month:
                return .numbersAndPunctuation
            }
        }
    }

    let title: String
    @Binding var text: String
    let placeholder: String
    var kind: Kind = .text

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline.weight(.medium))
                .foregroundStyle(FuelUI.text)
            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(kind.keyboardType)
                .foregroundStyle(FuelUI.text)
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .background(FuelUI.subpanel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(FuelUI.border, lineWidth: 1)
                )
        }
    }
}

struct FuelDateField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline.weight(.medium))
                .foregroundStyle(FuelUI.text)

            HStack {
                DatePicker(
                    "",
                    selection: Binding(
                        get: { Self.parse(text) ?? Date() },
                        set: { text = Self.storageFormatter.string(from: $0) }
                    ),
                    displayedComponents: [.date]
                )
                .labelsHidden()
                .environment(\.locale, AppLocale.russian)
                .datePickerStyle(.compact)
                .tint(FuelUI.accent)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(FuelUI.subpanel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(FuelUI.border, lineWidth: 1)
            )
        }
        .onAppear {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text = Self.storageFormatter.string(from: Date())
            }
        }
    }

    private static let storageFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = AppLocale.russian
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func parse(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return storageFormatter.date(from: trimmed)
    }
}

struct FuelPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                LinearGradient(
                    colors: [
                        FuelUI.accent.opacity(configuration.isPressed ? 0.85 : 1),
                        FuelUI.accentBorder.opacity(configuration.isPressed ? 0.85 : 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .appTapHaptic()
    }
}

private extension Optional where Wrapped == Range<String.Index> {
    func map(_ predicate: (Wrapped) -> Bool, default defaultValue: Bool) -> Bool {
        switch self {
        case .some(let range):
            return predicate(range)
        case .none:
            return defaultValue
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
