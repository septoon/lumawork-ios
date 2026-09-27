import SwiftUI

struct LocalArchiveCleanupRange: Identifiable {
    let id = UUID()
    let bounds: ClosedRange<Date>
}

enum LocalArchiveCleanupResult {
    case success
    case failure(String)
}

@MainActor
struct LocalArchivePeriodCleanupSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let itemCountTitle: String
    let availableRange: ClosedRange<Date>
    let additionalMessage: String?
    let itemCount: (Date, Date) -> Int
    let deleteAction: (Date, Date) async -> LocalArchiveCleanupResult

    @State private var startDate: Date
    @State private var endDate: Date
    @State private var isDeleting = false
    @State private var deletionErrorMessage: String?

    init(
        title: String,
        itemCountTitle: String,
        availableRange: ClosedRange<Date>,
        additionalMessage: String? = nil,
        itemCount: @escaping (Date, Date) -> Int,
        deleteAction: @escaping (Date, Date) async -> LocalArchiveCleanupResult
    ) {
        self.title = title
        self.itemCountTitle = itemCountTitle
        self.availableRange = availableRange
        self.additionalMessage = additionalMessage
        self.itemCount = itemCount
        self.deleteAction = deleteAction

        let initialRange = Self.initialSelection(in: availableRange)
        _startDate = State(initialValue: initialRange.lowerBound)
        _endDate = State(initialValue: initialRange.upperBound)
    }

    var body: some View {
        NavigationStack {
            AppScreen(bottomContentPadding: 20) {
                AppCard {
                    AppSectionHeader(
                        title: "Период удаления",
                        caption: "Доступно: \(formatted(availableRange.lowerBound)) — \(formatted(availableRange.upperBound))"
                    )

                    DatePicker(
                        "С",
                        selection: $startDate,
                        in: availableRange,
                        displayedComponents: [.date]
                    )
                    .environment(\.locale, AppLocale.russian)

                    Divider()

                    DatePicker(
                        "По",
                        selection: $endDate,
                        in: availableRange,
                        displayedComponents: [.date]
                    )
                    .environment(\.locale, AppLocale.russian)

                    Divider()

                    HStack {
                        Text(itemCountTitle)
                            .foregroundStyle(AppTheme.mutedTint)
                        Spacer(minLength: 16)
                        Text(selectedItemCount, format: .number)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                            .foregroundStyle(AppTheme.ink)
                    }
                    .font(.subheadline)
                }

                AppNoticeBanner(
                    text: archiveWarningText,
                    tint: AppTheme.secondaryTint,
                    style: .information
                )

                if let deletionErrorMessage {
                    AppNoticeBanner(
                        text: deletionErrorMessage,
                        tint: AppTheme.dangerTint,
                        isCritical: true
                    )
                }

                Button(role: .destructive) {
                    AppHaptics.trigger()
                    deletionErrorMessage = nil
                    isDeleting = true
                    Task { @MainActor in
                        let result = await deleteAction(startDate, endDate)
                        isDeleting = false
                        switch result {
                        case .success:
                            dismiss()
                        case .failure(let message):
                            deletionErrorMessage = message
                            AppHaptics.trigger(.error)
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        if isDeleting {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "trash")
                        }
                        Text(isDeleting ? "Удаление…" : "Удалить за период")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 16))
                .controlSize(.large)
                .tint(AppTheme.dangerTint)
                .disabled(selectedItemCount == 0 || isDeleting)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ModalCloseButton(action: dismiss.callAsFunction)
                        .disabled(isDeleting)
                }
            }
        }
        .interactiveDismissDisabled(isDeleting)
        .onChange(of: startDate) { _, newValue in
            if newValue > endDate {
                endDate = newValue
            }
        }
        .onChange(of: endDate) { _, newValue in
            if newValue < startDate {
                startDate = newValue
            }
        }
    }

    private var selectedItemCount: Int {
        itemCount(startDate, endDate)
    }

    private var archiveWarningText: String {
        let base = "Удаляется только локальный архив на устройстве. Данные в SimpleOne не изменятся и могут загрузиться снова при следующем обновлении."
        guard let additionalMessage, !additionalMessage.isEmpty else {
            return base
        }
        return "\(base) \(additionalMessage)"
    }

    private func formatted(_ date: Date) -> String {
        Self.dateFormatter.string(from: date)
    }

    private static func initialSelection(in availableRange: ClosedRange<Date>) -> ClosedRange<Date> {
        let calendar = Calendar.autoupdatingCurrent
        let latestDate = calendar.startOfDay(for: availableRange.upperBound)
        let monthComponents = calendar.dateComponents([.year, .month], from: latestDate)
        let monthStart = calendar.date(from: monthComponents) ?? availableRange.lowerBound
        return max(availableRange.lowerBound, monthStart)...availableRange.upperBound
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = AppLocale.russian
        formatter.dateFormat = "d MMMM yyyy"
        return formatter
    }()
}
