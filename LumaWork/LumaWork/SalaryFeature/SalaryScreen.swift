import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct SalaryScreen: View {
    let store: SalaryStore
    let userEmail: String
    var onLockCancel: () -> Void = {}

    private let legacySlipStore = LegacySalarySlipStore()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(SalaryPasscodeSettings.storageKey) private var savedPasscode = ""
    @AppStorage("salary-amount-hidden") private var isAmountHidden = false
    @State private var isPasscodePresented = false
    @State private var isSalaryUnlocked = false
    @State private var selectedYear: String?
    @State private var showAllTime = false
    @State private var selectedMonth: SalaryMonthSectionData?
    @State private var draft = SalaryDraft()
    @State private var editingEntry: SalaryEntry?
    @State private var isEditorPresented = false
    @State private var entryToDelete: SalaryEntry?
    @State private var projection = SalaryProjection()
    @State private var slipImportTargetMonth: String?
    @State private var isSlipImporterPresented = false
    @State private var previewedSlipURL: URL?

    var body: some View {
        AppScreen {
            VStack(alignment: .leading, spacing: 18) {
                if let errorMessage = store.errorMessage {
                    AppNoticeBanner(text: errorMessage, tint: AppTheme.dangerTint, isCritical: true)
                }
                if filteredMonths.isEmpty {
                    AppEmptyState(
                        title: "Нет записей по зарплате",
                        message: "Добавьте первую выплату, чтобы увидеть месячные сводки.",
                        systemName: "rublesign.circle"
                    )
                } else {
                    summarySection
                        .depthStackPrimary(reduceMotion: reduceMotion)

                    SalaryAnalyticsCard(
                        months: projection.monthsDescending,
                        isAmountHidden: isAmountHidden
                    )
                    .depthStackSecondary()

                    periodsSection
                        .depthStackSecondary()
                }
            }
        }
        .navigationTitle("Зарплата")
        .navigationBarTitleDisplayMode(.inline)
        .appLoadingOverlay(
            isPresented: store.isLoading && store.months.isEmpty,
            title: "Загружаем зарплату"
        )
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Добавить выплату", systemImage: "plus") {
                    editingEntry = nil
                    draft = SalaryDraft()
                    isEditorPresented = true
                }
            }
        }
        .task {
            updateProjection(for: store.months)
            await store.loadIfNeeded()
            await migrateLegacySalarySlips()
        }
        .onAppear {
            presentPasscodeIfNeeded()
        }
        .onChange(of: savedPasscode) { _, _ in
            presentPasscodeIfNeeded()
        }
        .onChange(of: store.months) { _, newValue in
            updateProjection(for: newValue)
        }
        .refreshable {
            await store.load()
            await migrateLegacySalarySlips()
        }
        .sheet(isPresented: $isEditorPresented, onDismiss: closeEditor) {
            NavigationStack {
                editorSheet
            }
            .presentationDetents([.large])
        }
        .sheet(item: $selectedMonth) { month in
            monthDetailSheet(month)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.modalSurface)
        }
        .fullScreenCover(isPresented: $isPasscodePresented) {
            SalaryPasscodeLockView(
                passcode: savedPasscode,
                recoveryEmail: userEmail,
                onCreate: { newCode in
                    AppHaptics.trigger(.expandCollapse)
                    savedPasscode = newCode
                    isSalaryUnlocked = true
                    isPasscodePresented = false
                },
                onUnlock: {
                    AppHaptics.trigger(.expandCollapse)
                    isSalaryUnlocked = true
                    isPasscodePresented = false
                },
                onCancel: {
                    isPasscodePresented = false
                    onLockCancel()
                }
            )
        }
        .confirmationDialog("Удалить запись по зарплате?", isPresented: .init(
            get: { entryToDelete != nil },
            set: { if !$0 { entryToDelete = nil } }
        )) {
            Button("Удалить", role: .destructive) {
                if let entryToDelete {
                    Task {
                        await store.delete(entryToDelete)
                        self.entryToDelete = nil
                    }
                }
            }
            Button("Отмена", role: .cancel) {
                entryToDelete = nil
            }
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
    }

    private func presentPasscodeIfNeeded() {
        guard !isSalaryUnlocked else { return }
        isPasscodePresented = true
    }

    @ViewBuilder
    private var summarySection: some View {
        if let summary = activeSummary {
            VStack(alignment: .leading, spacing: 14) {
                Text("Перечислено за \(summary.title)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.84))

                HStack(alignment: .center, spacing: 16) {
                    Text(displayAmount(summary.amount))
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Spacer()
                    Button {
                        AppHaptics.trigger()
                        isAmountHidden.toggle()
                    } label: {
                        Image(systemName: isAmountHidden ? "eye.slash" : "eye")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Color.white.opacity(0.16), in: Circle())
                    }
                    .buttonStyle(.plain)
                }

                Text("Период начисления \(summary.period)")
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.78))

                Button(showAllTime ? "За последний месяц" : "За все время") {
                    AppHaptics.trigger()
                    showAllTime.toggle()
                }
                .buttonStyle(SalaryGhostButtonStyle())
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.heroGradient, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: AppTheme.primaryTint.opacity(0.20), radius: 12, x: 0, y: 8)
        }
    }

    private var periodsSection: some View {
        AppCard {
            AppSectionHeader(title: "Все периоды")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(projection.years, id: \.self) { year in
                        yearButton(year)
                    }
                }
            }

            if filteredMonths.isEmpty, let selectedYear {
                Text("Нет данных за \(selectedYear).")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.mutedTint)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 145), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(filteredMonths) { month in
                        monthButton(month)
                    }
                }
            }
        }
    }

    private func yearButton(_ year: String) -> some View {
        Button {
            AppHaptics.trigger()
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedYear = year
            }
        } label: {
            Text(year)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selectedYear == year ? .white : AppTheme.primaryTint)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    selectedYear == year
                    ? AnyShapeStyle(AppTheme.accentGradient)
                    : AnyShapeStyle(AppTheme.primaryTint.opacity(0.10)),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    private func monthButton(_ month: SalaryMonthSectionData) -> some View {
        Button {
            AppHaptics.trigger(.expandCollapse)
            selectedMonth = month
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(monthTitle(for: month.month))
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppTheme.mutedTint)
                }

                Text(isAmountHidden ? "Сумма скрыта" : displayAmount(month.total))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppTheme.secondaryTint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Text(paymentCountTitle(month.entryCount))
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedTint)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            .background(AppTheme.subpanelSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(monthTitle(for: month.month)), \(isAmountHidden ? "сумма скрыта" : displayAmount(month.total)), \(paymentCountTitle(month.entryCount))"
        )
    }

    private func monthDetailSheet(_ month: SalaryMonthSectionData) -> some View {
        NavigationStack {
            AppScreen {
                monthSummary(month)

                VStack(spacing: 12) {
                    ForEach(month.entries.sorted(by: { $0.date < $1.date }), id: \.stableID) { entry in
                        salaryEntryView(entry)
                    }
                }

                salarySlipView(for: month.month)
            }
            .navigationTitle(monthTitle(for: month.month))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    ModalCloseButton {
                        selectedMonth = nil
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $isSlipImporterPresented,
            allowedContentTypes: SalarySlipDocument.allowedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            importSlip(from: result)
        }
        .sheet(isPresented: Binding(
            get: { previewedSlipURL != nil },
            set: { if !$0 { removePreviewedSlip() } }
        )) {
            if let previewedSlipURL {
                SalaryDocumentPreviewSheet(url: previewedSlipURL)
            }
        }
    }

    private func monthSummary(_ month: SalaryMonthSectionData) -> some View {
        let sortedEntries = month.entries.sorted { $0.date < $1.date }
        let legacyEntries = sortedEntries.filter(\.isLegacySalaryEntry)
        let totalBase = legacyEntries.reduce(0) { $0 + $1.baseSalary }
        let totalWeekend = legacyEntries.reduce(0) { $0 + $1.weekendPay }
        let totalTax = sortedEntries.reduce(0) { $0 + SalaryCalculations.tax(for: $1) }

        return AppCard {
            AppSectionHeader(title: "Итог за месяц", caption: paymentCountTitle(month.entryCount))
            if !legacyEntries.isEmpty {
                AppStatRow(
                    title: "Начислено",
                    value: displayAmount(totalBase + totalWeekend)
                )
                AppStatRow(
                    title: "Удержано",
                    value: isAmountHidden ? "••••••" : "- \(AppFormatting.rubles(totalTax, maximumFractionDigits: 0))",
                    accent: AppTheme.dangerTint
                )
                Divider()
            }
            AppStatRow(
                title: "Перечислено",
                value: displayAmount(month.total),
                accent: AppTheme.secondaryTint
            )
        }
    }

    private func salarySlipView(for month: String) -> some View {
        let hasSlip = store.salaryDocument(for: month) != nil
        let isBusy = store.salaryDocumentBusyMonth == month

        return SalaryInsetSummaryCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "doc.richtext")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(AppTheme.primaryTint)
                        .frame(width: 38, height: 38)
                        .background(AppTheme.primaryTint.opacity(0.10), in: Circle())

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Расчетный листок")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(AppTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(hasSlip ? "Документ прикреплен к месяцу" : "Документ не прикреплен")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.mutedTint)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }

                if hasSlip {
                    HStack(spacing: 10) {
                        SalaryDocumentActionButton(title: "Открыть", systemName: "eye", tint: AppTheme.secondaryTint) {
                            Task {
                                previewedSlipURL = await store.salaryDocumentFileURL(for: month)
                            }
                        }
                        .disabled(isBusy)
                        SalaryDocumentActionButton(title: "Удалить", systemName: "trash", tint: AppTheme.dangerTint) {
                            deleteSlip(for: month)
                        }
                        .disabled(isBusy)
                        SalaryDocumentActionButton(title: "Заменить", systemName: "arrow.triangle.2.circlepath", tint: AppTheme.primaryTint) {
                            slipImportTargetMonth = month
                            isSlipImporterPresented = true
                        }
                        .disabled(isBusy)
                    }
                } else {
                    SalaryDocumentActionButton(title: "Прикрепить документ", systemName: "paperclip", tint: AppTheme.primaryTint) {
                        slipImportTargetMonth = month
                        isSlipImporterPresented = true
                    }
                    .disabled(isBusy)
                }

                if isBusy {
                    if let progress = store.salaryDocumentUploadProgress {
                        ProgressView(value: progress)
                            .tint(AppTheme.primaryTint)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private func salaryEntryView(_ entry: SalaryEntry) -> some View {
        let weekendPart = entry.weekendPay / 2

        return SalaryInsetSummaryCard {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.paymentKind.title)
                        .font(.headline)
                        .foregroundStyle(AppTheme.ink)
                    Text("Получено \(AppFormatting.shortDate(entry.date))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedTint)
                    Text("Выплата: \(AppFormatting.rubles(SalaryCalculations.payout(for: entry), maximumFractionDigits: 2))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.secondaryTint)
                }

                Spacer()

                HStack(spacing: 8) {
                    AppInlineIconButton(systemName: "pencil", tint: AppTheme.primaryTint) {
                        openEditorFromMonth(for: entry)
                    }
                    AppInlineIconButton(systemName: "trash", tint: AppTheme.dangerTint) {
                        requestDeleteFromMonth(entry)
                    }
                }
            }

            if entry.isLegacySalaryEntry {
                AppStatRow(title: "Оклад", value: AppFormatting.rubles(entry.baseSalary, maximumFractionDigits: 2))
                if entry.weekendPay > 0 {
                    AppStatRow(title: "Оплата за выходной", value: AppFormatting.rubles(weekendPart, maximumFractionDigits: 2))
                    AppStatRow(title: "Доплата за выходной", value: AppFormatting.rubles(weekendPart, maximumFractionDigits: 2))
                }
                AppStatRow(
                    title: "Налог",
                    value: "- \(AppFormatting.rubles(SalaryCalculations.tax(for: entry), maximumFractionDigits: 0))",
                    accent: AppTheme.dangerTint
                )
                Divider()
            }
            if let comment = entry.comment, !comment.isEmpty {
                AppStatRow(title: "Комментарий", value: comment)
            }
            AppStatRow(
                title: "Выплата",
                value: AppFormatting.rubles(SalaryCalculations.payout(for: entry), maximumFractionDigits: 2),
                accent: AppTheme.secondaryTint
            )
        }
    }

    private var editorSheet: some View {
        SalaryEditorView(
            draft: $draft,
            isSubmitting: store.isSubmitting,
            isEditing: editingEntry != nil,
            onClose: closeEditor,
            onSave: {
                let isNetPayment = draft.usesNetPaymentMode
                let amount = Double(draft.amount.replacingOccurrences(of: ",", with: ".")) ?? 0
                let affectedYear = isNetPayment
                    ? Self.year(from: draft.normalizedPeriodMonth)
                    : Self.year(from: draft.date)
                let input = SalaryEntryInput(
                    date: draft.date,
                    baseSalary: isNetPayment ? amount : Double(draft.baseSalary.replacingOccurrences(of: ",", with: ".")) ?? 0,
                    weekendPay: isNetPayment ? 0 : Double(draft.weekendPay.replacingOccurrences(of: ",", with: ".")) ?? 0,
                    periodMonth: isNetPayment ? draft.normalizedPeriodMonth : nil,
                    amount: isNetPayment ? amount : nil,
                    kind: draft.kind,
                    comment: draft.kind == .other ? draft.normalizedComment : nil
                )
                if await store.save(editing: editingEntry, input: input) {
                    selectedYear = affectedYear ?? selectedYear
                    closeEditor()
                }
            }
        )
    }

    private func closeEditor() {
        isEditorPresented = false
        editingEntry = nil
    }

    private func openEditorFromMonth(for entry: SalaryEntry) {
        selectedMonth = nil
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            editingEntry = entry
            draft = SalaryDraft(entry: entry)
            isEditorPresented = true
        }
    }

    private func requestDeleteFromMonth(_ entry: SalaryEntry) {
        selectedMonth = nil
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            entryToDelete = entry
        }
    }

    private func importSlip(from result: Result<[URL], Error>) {
        guard let month = slipImportTargetMonth else { return }
        defer { slipImportTargetMonth = nil }

        do {
            guard let selectedURL = try result.get().first else { return }
            Task {
                _ = await store.uploadSalaryDocument(from: selectedURL, to: month)
            }
        } catch {
            if let message = appUserFacingErrorMessage(error, fallback: "Не удалось прикрепить расчётный листок.") {
                AppBannerCenter.shared.show(message, style: .error)
            }
        }
    }

    private func deleteSlip(for month: String) {
        Task {
            _ = await store.deleteSalaryDocument(for: month)
        }
    }

    private func migrateLegacySalarySlips() async {
        guard store.hasLoadedSalaryDocuments else { return }
        var migratedCount = 0
        for document in legacySlipStore.documents() {
            if store.salaryDocument(for: document.month) == nil {
                guard await store.uploadSalaryDocument(
                    from: document.url,
                    to: document.month,
                    showsSuccessBanner: false
                ) else {
                    continue
                }
                migratedCount += 1
            }
            try? legacySlipStore.deleteDocument(for: document.month)
        }
        if migratedCount > 0 {
            AppBannerCenter.shared.show("Локальные расчётные листки перенесены на сервер.", style: .success)
        }
    }

    private func removePreviewedSlip() {
        if let previewedSlipURL {
            try? FileManager.default.removeItem(at: previewedSlipURL)
        }
        previewedSlipURL = nil
    }

    private var filteredMonths: [SalaryMonthSectionData] {
        projection.months(for: selectedYear)
    }

    private var activeSummary: SalarySummaryData? {
        if showAllTime {
            return projection.allTimeSummary ?? projection.latestSummary
        }
        return projection.latestSummary
    }

    private func displayAmount(_ amount: Double) -> String {
        let raw = AppFormatting.rubles(amount, maximumFractionDigits: 2)
        return isAmountHidden ? raw.replacingOccurrences(of: #"\S"#, with: "*", options: .regularExpression) : raw
    }

    private func monthTitle(for month: String) -> String {
        let parts = month.split(separator: "-")
        guard parts.count == 2,
              let monthNumber = Int(parts[1]),
              (1 ... 12).contains(monthNumber) else {
            return month
        }

        let formatter = DateFormatter()
        formatter.locale = AppLocale.russian
        return formatter.standaloneMonthSymbols[monthNumber - 1].capitalized
    }

    private func paymentCountTitle(_ count: Int) -> String {
        let lastTwoDigits = count % 100
        let lastDigit = count % 10
        let noun: String
        if (11 ... 14).contains(lastTwoDigits) {
            noun = "выплат"
        } else if lastDigit == 1 {
            noun = "выплата"
        } else if (2 ... 4).contains(lastDigit) {
            noun = "выплаты"
        } else {
            noun = "выплат"
        }
        return "\(count) \(noun)"
    }

    private func updateProjection(for months: [SalaryMonth]) {
        projection = SalaryProjection(months: months)

        guard let selectedYear else {
            self.selectedYear = projection.years.first
            return
        }

        if !projection.years.contains(selectedYear) {
            self.selectedYear = projection.years.first
        }
    }

}

private extension SalaryScreen {
    static func year(from date: String) -> String? {
        let year = String(date.prefix(4))
        return year.count == 4 ? year : nil
    }
}

private extension SalaryCalculations {
    static func tax(for entry: SalaryEntry) -> Double {
        if entry.usesNetPaymentAmount {
            return 0
        }
        return floor((entry.baseSalary + entry.weekendPay) * taxRate)
    }
}
