import Foundation
import SwiftUI

struct SalaryDraft: Hashable {
    var date = ""
    var baseSalary = ""
    var weekendPay = ""
    var periodMonth = ""
    var amount = ""
    var kind = SalaryPaymentKind.advance
    var comment = ""

    init() {}

    init(entry: SalaryEntry) {
        date = entry.date
        baseSalary = String(entry.baseSalary)
        weekendPay = entry.weekendPay == 0 ? "" : String(entry.weekendPay)
        periodMonth = entry.accrualMonthKey
        amount = String(entry.netPaymentAmount)
        kind = entry.paymentKind
        comment = entry.comment ?? ""
    }

    var usesNetPaymentMode: Bool {
        date >= SalaryEntry.netPaymentStartDate
    }

    var normalizedPeriodMonth: String {
        let trimmed = periodMonth.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count == 7 {
            return trimmed
        }
        return Self.defaultPeriodMonth(for: date)
    }

    var normalizedComment: String? {
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func defaultPeriodMonth(for date: String) -> String {
        let monthKey = String(date.prefix(7))
        let dayText = String(date.suffix(2))
        guard date >= SalaryEntry.netPaymentStartDate,
              let day = Int(dayText),
              day <= 10,
              let previousMonth = SalaryEntry.previousMonthKey(from: monthKey) else {
            return monthKey
        }
        return previousMonth
    }
}

struct SalaryEditorView: View {
    @Binding var draft: SalaryDraft
    let isSubmitting: Bool
    let isEditing: Bool
    let onClose: () -> Void
    let onSave: () async -> Void

    @State private var validationError: String?

    var body: some View {
        SalaryModalContainer(
            title: isEditing ? "Редактировать запись зарплаты" : "Добавить запись зарплаты",
            onClose: onClose
        ) {
            SalaryDateField(title: "Дата выплаты", text: $draft.date)

            if draft.usesNetPaymentMode {
                SalaryMonthField(title: "За месяц", text: $draft.periodMonth, paymentDate: draft.date)
            }

            SalaryPaymentKindPicker(selection: $draft.kind)

            if draft.usesNetPaymentMode {
                SalaryField(title: "Выплата на руки", text: $draft.amount, placeholder: "0.00", kind: .decimal)
            } else {
                SalaryField(title: "Оклад", text: $draft.baseSalary, placeholder: "0.00", kind: .decimal)
                SalaryField(title: "Оплата в выходной", text: $draft.weekendPay, placeholder: "0.00", kind: .decimal)
            }

            if draft.kind == .other {
                SalaryField(title: "Комментарий", text: $draft.comment, placeholder: "Например: премия, перерасчет")
            }

            if let validationError {
                Text(validationError)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.dangerTint)
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
            return "Укажите дату выплаты."
        }

        if draft.usesNetPaymentMode {
            if draft.amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Укажите сумму выплаты."
            }
            guard let amount = Double(draft.amount.replacingOccurrences(of: ",", with: ".")), amount >= 0 else {
                return "Выплата должна быть неотрицательным числом."
            }
            return nil
        }

        if draft.baseSalary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Заполните дату и оклад."
        }

        guard let salary = Double(draft.baseSalary.replacingOccurrences(of: ",", with: ".")), salary >= 0 else {
            return "Оклад должен быть неотрицательным числом."
        }
        _ = salary

        if !draft.weekendPay.isEmpty,
           let weekend = Double(draft.weekendPay.replacingOccurrences(of: ",", with: ".")),
           weekend < 0 {
            return "Оплата в выходной должна быть неотрицательной."
        } else if !draft.weekendPay.isEmpty,
                  Double(draft.weekendPay.replacingOccurrences(of: ",", with: ".")) == nil {
            return "Некорректное значение оплаты в выходной."
        }

        return nil
    }
}

struct SalaryInsetSummaryCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(14)
        .background(AppTheme.primaryTint.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
    }
}

struct SalaryDocumentActionButton: View {
    let title: String
    let systemName: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            Label(title, systemImage: systemName)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct SalaryModalContainer<Content: View, Footer: View>: View {
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
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                ModalCloseButton(action: onClose)
            }

            ToolbarItem(placement: .confirmationAction) {
                footer
            }
        }
    }
}

struct SalaryField: View {
    enum Kind {
        case text
        case integer
        case decimal

        var keyboardType: UIKeyboardType {
            switch self {
            case .text:
                return .default
            case .integer:
                return .numberPad
            case .decimal:
                return .decimalPad
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
                .foregroundStyle(AppTheme.ink)
            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(kind.keyboardType)
                .foregroundStyle(AppTheme.ink)
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .background(AppTheme.softFill.opacity(0.66), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(AppTheme.border, lineWidth: 1)
                )
        }
    }
}

struct SalaryPaymentKindPicker: View {
    @Binding var selection: SalaryPaymentKind

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Тип выплаты")
                .font(.headline.weight(.medium))
                .foregroundStyle(AppTheme.ink)

            Menu {
                ForEach(SalaryPaymentKind.allCases, id: \.self) { kind in
                    Button(kind.title) {
                        selection = kind
                    }
                }
            } label: {
                HStack {
                    Text(selection.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedTint)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .background(AppTheme.softFill.opacity(0.66), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(AppTheme.border, lineWidth: 1)
                )
            }
        }
    }
}

struct SalaryMonthField: View {
    let title: String
    @Binding var text: String
    let paymentDate: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline.weight(.medium))
                .foregroundStyle(AppTheme.ink)

            Menu {
                ForEach(monthOptions, id: \.self) { month in
                    Button(AppFormatting.monthLabel(month)) {
                        text = month
                    }
                }
            } label: {
                HStack {
                    Text(AppFormatting.monthLabel(resolvedMonth))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedTint)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .background(AppTheme.softFill.opacity(0.66), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(AppTheme.border, lineWidth: 1)
                )
            }
        }
        .onAppear(perform: ensureDefaultMonth)
        .onChange(of: paymentDate) { oldValue, newValue in
            let oldDefault = SalaryDraft.defaultPeriodMonth(for: oldValue)
            if text.isEmpty || text == oldDefault {
                text = SalaryDraft.defaultPeriodMonth(for: newValue)
            }
        }
    }

    private var resolvedMonth: String {
        text.isEmpty ? SalaryDraft.defaultPeriodMonth(for: paymentDate) : text
    }

    private var monthOptions: [String] {
        var options = Self.monthKeys(around: paymentDate)
        if !options.contains(resolvedMonth) {
            options.insert(resolvedMonth, at: 0)
        }
        return options
    }

    private func ensureDefaultMonth() {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = SalaryDraft.defaultPeriodMonth(for: paymentDate)
        }
    }

    private static func monthKeys(around date: String) -> [String] {
        let baseMonth = String(date.prefix(7))
        guard baseMonth.count == 7 else {
            return []
        }

        return (-4 ... 4).compactMap { offset in
            offsetMonth(baseMonth, by: offset)
        }
    }

    private static func offsetMonth(_ monthKey: String, by offset: Int) -> String? {
        let parts = monthKey.split(separator: "-")
        guard parts.count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              (1 ... 12).contains(month) else {
            return nil
        }

        let rawMonth = (year * 12) + (month - 1) + offset
        let resolvedYear = rawMonth / 12
        let resolvedMonth = (rawMonth % 12) + 1
        return String(format: "%04d-%02d", resolvedYear, resolvedMonth)
    }
}

struct SalaryDateField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline.weight(.medium))
                .foregroundStyle(AppTheme.ink)

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
                .tint(AppTheme.primaryTint)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(AppTheme.softFill.opacity(0.66), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
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

struct SalaryGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(AppTheme.ghostFill.opacity(configuration.isPressed ? 1.25 : 1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
