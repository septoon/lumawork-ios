import Foundation
import SwiftUI

struct HomeCalendarScreen: View {
    @Binding var selectedDate: Date

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            DatePicker(
                "Дата",
                selection: Binding(
                    get: { selectedDate },
                    set: { newValue in
                        selectedDate = newValue
                        AppHaptics.trigger()
                        dismiss()
                    }
                ),
                displayedComponents: [.date]
            )
            .datePickerStyle(.graphical)
            .environment(\.locale, AppLocale.russian)
            .padding(.horizontal, 16)
        }
        .padding(.top, 16)
        .navigationTitle("Календарь")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ModalCloseButton(action: dismiss.callAsFunction)
            }

            ToolbarItem(placement: .topBarTrailing) {
                ModalConfirmButton(
                    action: {
                        AppHaptics.trigger()
                        dismiss()
                    },
                    accessibilityLabel: "Готово"
                )
            }
        }
    }
}

private struct HomeFuelEntryDraft {
    var selectedDate = Date()
    var fuelType = ""
    var liters = ""
    var fuelCostRub = ""

    var storageDate: String {
        Self.storageFormatter.string(from: selectedDate)
    }

    var displayDate: String {
        Self.displayFormatter.string(from: selectedDate)
    }

    var litersValue: Double? {
        parseNumber(liters)
    }

    var fuelCostValue: Double? {
        parseNumber(fuelCostRub)
    }

    private func parseNumber(_ raw: String) -> Double? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        return normalized.isEmpty ? nil : Double(normalized)
    }

    private static let storageFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = AppLocale.russian
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = AppLocale.russian
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "dd.MM.yyyy"
        return formatter
    }()
}

struct HomeFuelEntryScreen: View {
    let store: FuelStore

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appIsOfflineMode) private var isOfflineMode
    @State private var draft = HomeFuelEntryDraft()
    @State private var validationError: String?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                AppCard {
                    AppSectionHeader(
                        title: "Заправка",
                        caption: "Для листа Отчет по ТК"
                    )

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Дата заправки")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(AppTheme.mutedTint)

                        Text(draft.displayDate)
                            .font(.headline)
                            .foregroundStyle(AppTheme.ink)

                        DatePicker(
                            "Дата заправки",
                            selection: $draft.selectedDate,
                            displayedComponents: [.date]
                        )
                        .labelsHidden()
                        .datePickerStyle(.graphical)
                        .environment(\.locale, AppLocale.russian)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Тип топлива")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(AppTheme.mutedTint)
                        Picker("Тип топлива", selection: $draft.fuelType) {
                            if store.availableFuelTypes.isEmpty {
                                Text("Сначала выберите типы в ГСМ профиле").tag("")
                            } else {
                                ForEach(store.availableFuelTypes, id: \.self) { fuelType in
                                    Text(fuelType).tag(fuelType)
                                }
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Литры")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(AppTheme.mutedTint)
                        TextField("0.00", text: $draft.liters)
                            .keyboardType(.decimalPad)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(AppTheme.secondaryTint.opacity(0.3), lineWidth: 1)
                            )
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Сумма в рублях")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(AppTheme.mutedTint)
                        TextField("0.00", text: $draft.fuelCostRub)
                            .keyboardType(.decimalPad)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(AppTheme.secondaryTint.opacity(0.3), lineWidth: 1)
                            )
                    }

                    if let validationError {
                        Text(validationError)
                            .font(.footnote)
                            .foregroundStyle(AppTheme.dangerTint)
                    }

                    if let errorMessage = store.errorMessage,
                       !errorMessage.isEmpty,
                       AppOfflineWarningPolicy.shouldDisplay(
                           errorMessage,
                           isOfflineMode: isOfflineMode
                       ) {
                        AppNoticeBanner(
                            text: errorMessage,
                            tint: AppTheme.dangerTint,
                            isCritical: true,
                            style: .error
                        )
                    }

                }
            }
            .padding(.bottom, 24)
        }
        .padding(.top, 8)
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle("Новая заправка")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ModalCloseButton(action: dismiss.callAsFunction)
            }

            ToolbarItem(placement: .topBarTrailing) {
                ModalConfirmButton(
                    action: saveFuelEntry,
                    isDisabled: store.isSubmitting,
                    isLoading: store.isSubmitting,
                    accessibilityLabel: "Сохранить заправку"
                )
            }
        }
        .task {
            await store.loadIfNeeded()
            if draft.fuelType.isEmpty {
                draft.fuelType = store.availableFuelTypes.first ?? ""
            }
        }
    }

    private func saveFuelEntry() {
        AppHaptics.trigger()
        validationError = validate()
        guard validationError == nil else { return }

        Task {
            let input = FuelRecordInput(
                recordType: .fuel,
                adjustmentKind: nil,
                monthKey: nil,
                amount: nil,
                carryoverDebtRub: nil,
                comment: nil,
                date: draft.storageDate,
                mileage: nil,
                liters: draft.litersValue,
                fuelCost: draft.fuelCostValue,
                fuelType: draft.fuelType
            )

            if await store.save(editing: nil, input: input) {
                dismiss()
            }
        }
    }

    private func validate() -> String? {
        guard !draft.fuelType.isEmpty else {
            return "Выберите тип топлива в ГСМ профиле."
        }
        guard let liters = draft.litersValue, liters >= 0 else {
            return "Укажите корректное количество литров."
        }
        guard let fuelCost = draft.fuelCostValue, fuelCost >= 0 else {
            return "Укажите корректную сумму заправки."
        }
        if liters == 0, fuelCost == 0 {
            return "Заполните литры и сумму заправки."
        }
        return nil
    }
}
