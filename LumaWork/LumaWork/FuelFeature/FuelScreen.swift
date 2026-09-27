import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct FuelScreen: View {
    let store: FuelStore
    let userEmail: String

    @State private var selectedYear: String?
    @State private var draft = FuelDraft()
    @State private var editingRecord: FuelRecord?
    @State private var editorMode: FuelEditorMode?
    @State private var recordToDelete: FuelRecord?
    @State private var projection = FuelProjection()
    @State private var expandedMonthKey: String?
    @State private var refuelViewInRubByMonth: [String: Bool] = [:]
    @State private var isImportPickerPresented = false
    @State private var importSheetRoute: FuelImportSheetRoute?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            FuelUI.background
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    mainSection

                    if !store.records.isEmpty {
                        analyticsNavigationSection
                    }

                    if projection.summary.hasData, !filteredMonths.isEmpty {
                        monthlyDetailsSection
                    }

                    if FuelArchivePolicy.isAvailable(for: userEmail) {
                        archiveNavigationSection
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
            }

            if let notice = store.notice {
                AppNoticeBanner(
                    text: notice,
                    tint: FuelUI.positive,
                    style: .success
                )
            }

        }
        .navigationTitle("Топливо")
        .navigationBarTitleDisplayMode(.inline)
        .appLoadingOverlay(
            isPresented: store.isLoading && store.records.isEmpty,
            title: "Загружаем топливо"
        )
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button {
                        openAdjustmentEditor(kind: .compensationPayment)
                    } label: {
                        Label("Добавить выплату", systemImage: "banknote")
                    }

                    Button {
                        openAdjustmentEditor(kind: .debtDeduction)
                    } label: {
                        Label("Добавить вычет долга", systemImage: "minus.circle")
                    }

                    Divider()

                    Button {
                        AppHaptics.trigger()
                        isImportPickerPresented = true
                    } label: {
                        Label("Импортировать отчёты", systemImage: "tray.and.arrow.down")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Другие действия с топливом")

                Button("Добавить заправку", systemImage: "plus") {
                    openFuelEditor()
                }
            }
        }
        .task {
            updateProjection(for: store.records)
            await store.loadIfNeeded()
        }
        .onChange(of: store.records) { _, newValue in
            updateProjection(for: newValue)
        }
        .refreshable {
            await store.load()
        }
        .sheet(item: $editorMode, onDismiss: closeEditor) { mode in
            NavigationStack {
                editorSheet(mode: mode)
            }
            .appEditorSheetStyle()
        }
        .sheet(item: $importSheetRoute) { _ in
            NavigationStack {
                FuelImportPreviewSheet(store: store)
            }
            .presentationDetents([.large])
        }
        .fileImporter(
            isPresented: $isImportPickerPresented,
            allowedContentTypes: [UTType(filenameExtension: "xlsx") ?? .data],
            allowsMultipleSelection: true
        ) { result in
            do {
                let urls = try result.get()
                Task {
                    if await store.previewFuelImports(urls: urls) {
                        importSheetRoute = FuelImportSheetRoute()
                    }
                }
            } catch {
                store.errorMessage = appUserFacingErrorMessage(error, fallback: "Не удалось выбрать XLSX-отчёты.")
            }
        }
        .confirmationDialog("Удалить запись?", isPresented: .init(
            get: { recordToDelete != nil },
            set: { if !$0 { recordToDelete = nil } }
        )) {
            Button("Удалить", role: .destructive) {
                if let recordToDelete {
                    Task {
                        await store.delete(recordToDelete)
                        self.recordToDelete = nil
                    }
                }
            }
            Button("Отмена", role: .cancel) {
                recordToDelete = nil
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
        .appLoadingOverlay(
            isPresented: store.isPreviewingImport,
            title: "Разбираем отчёты"
        )
    }

    private var analyticsNavigationSection: some View {
        NavigationLink {
            FuelAnalyticsScreen(records: store.records)
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(.white.opacity(0.18))
                    Image(systemName: "chart.xyaxis.line")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Аналитика")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                    Text("Цена литра, расходы и динамика по месяцам")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(16)
            .background(
                LinearGradient(
                    colors: [FuelUI.accent, FuelUI.positive],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(.white.opacity(0.2), lineWidth: 1)
            }
            .shadow(color: FuelUI.accent.opacity(0.2), radius: 12, y: 6)
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture().onEnded { AppHaptics.trigger() })
        .accessibilityHint("Открывает подробную статистику по всем заправкам, включая архив")
    }

    private var archiveNavigationSection: some View {
        FuelPanelCard {
            NavigationLink {
                FuelArchiveScreen(store: store)
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "archivebox.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(FuelUI.warning)
                        .frame(width: 34, height: 34)
                        .background(FuelUI.warningBackground, in: Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        Text(FuelArchivePolicy.archivedRecordsTitle)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(FuelUI.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        Text("\(archiveRecords.count) записей")
                            .font(.subheadline)
                            .foregroundStyle(FuelUI.muted)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 12)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FuelUI.mutedStrong)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var mainSection: some View {
        FuelPanelCard {
            if let errorMessage = store.errorMessage {
                FuelNotice(text: errorMessage, tint: FuelUI.danger, isCritical: true)
            }

            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "fuelpump.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(FuelUI.accent)
                    .frame(width: 48, height: 48)
                    .background(FuelUI.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 15, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Топливный баланс")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(FuelUI.text)
                        .lineLimit(1)
                    Text("Расход, компенсации и задолженность")
                        .font(.subheadline)
                        .foregroundStyle(FuelUI.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }

            if !projection.summary.hasData {
                Text("Пока нет данных по заправкам и корректировкам.")
                    .font(.subheadline)
                    .foregroundStyle(FuelUI.muted)
                    .padding(.top, 4)
            } else if projection.summary.hasData {
                VStack(alignment: .leading, spacing: 7) {
                    Text(summaryHeadline)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(adjustedDiffTint(for: projection.summary.totals.adjustedFuelDiff))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    Text(projection.summary.explanation)
                        .font(.subheadline)
                        .foregroundStyle(FuelUI.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                yearSection
            }
        }
    }

    private var monthlyDetailsSection: some View {
        FuelPanelCard {
            VStack(alignment: .leading, spacing: 4) {
                Text("По месяцам")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(FuelUI.text)
                Text("Откройте месяц, чтобы увидеть расчёт и записи")
                    .font(.subheadline)
                    .foregroundStyle(FuelUI.muted)
            }

            VStack(spacing: 12) {
                ForEach(filteredMonths, id: \.key) { month in
                    monthSection(month)
                }
            }
        }
    }

    @ViewBuilder
    private var yearSection: some View {
        if !projection.years.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(projection.years, id: \.self) { year in
                        Button {
                            AppHaptics.trigger()
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedYear = year
                            }
                        } label: {
                            Text(year)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(selectedYear == year ? .white : FuelUI.mutedStrong)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(selectedYear == year ? FuelUI.accent : FuelUI.chipBackground)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(selectedYear == year ? FuelUI.accentBorder : FuelUI.border, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func monthSection(_ month: FuelSummaryMonth) -> some View {
        let isExpanded = expandedMonthKey == month.key
        let isRefuelInRub = refuelViewInRubByMonth[month.key] ?? false
        let fuelRecords = fuelRecords(for: month.key)

        return FuelInsetCard {
            Button {
                AppHaptics.trigger(.expandCollapse)
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedMonthKey = isExpanded ? nil : month.key
                }
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(monthOnlyTitle(for: month))
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(FuelUI.text)
                                .lineLimit(1)
                            statusBadge(for: month)
                        }

                        Text("\(AppFormatting.number(month.totalMileage, maximumFractionDigits: 0)) км · \(AppFormatting.number(month.totalLiters)) л · \(AppFormatting.rubles(month.fuelCost, maximumFractionDigits: 0))")
                            .font(.caption)
                            .foregroundStyle(FuelUI.muted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }

                    Spacer(minLength: 12)

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(month.diffLabel)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(monthDiffTint(for: month.fuelDiff))
                            .lineLimit(1)
                        Text(month.fuelDiff < 0 ? "перерасход" : month.fuelDiff > 0 ? "остаток" : "баланс")
                            .font(.caption2)
                            .foregroundStyle(FuelUI.muted)
                            .lineLimit(1)
                    }

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FuelUI.mutedStrong)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                    .overlay(FuelUI.divider)

                VStack(alignment: .leading, spacing: 12) {
                    metricRow(
                        title: "Пройдено км:",
                        value: "\(AppFormatting.number(month.totalMileage, maximumFractionDigits: 0)) км"
                    )
                    metricRow(title: "Норма топлива:", value: "\(AppFormatting.number(month.fuelNorm)) л")
                    toggleMetricRow(
                        title: "Заправлено:",
                        value: isRefuelInRub
                            ? "\(AppFormatting.number(month.fuelCost, maximumFractionDigits: 2)) ₽"
                            : "\(AppFormatting.number(month.totalLiters)) л",
                        accent: FuelUI.text
                    ) {
                        refuelViewInRubByMonth[month.key] = !isRefuelInRub
                    }
                    metricRow(
                        title: "Разница:",
                        value: month.diffLabel,
                        accent: monthDiffTint(for: month.fuelDiff)
                    )
                    metricRow(
                        title: "Компенсация ГСМ:",
                        value: AppFormatting.rubles(month.compensation, maximumFractionDigits: 0)
                    )

                    if month.paidCompensation > 0 {
                        metricRow(
                            title: "Выплачено:",
                            value: AppFormatting.rubles(month.paidCompensation, maximumFractionDigits: 2),
                            accent: FuelUI.text
                        )
                    }

                    if month.effectiveDebtDeductionAmount > 0 {
                        metricRow(
                            title: "Списано:",
                            value: "\(month.debtDeductionAmount <= 0 && month.debtDeductionLiters > 0 ? "≈ " : "")\(AppFormatting.number(month.effectiveDebtDeductionAmount, maximumFractionDigits: 2)) ₽",
                            accent: FuelUI.text
                        )
                    }

                    if month.incomingCarryoverDebtRub > 0 {
                        metricRow(
                            title: "Долг из прошлого месяца:",
                            value: AppFormatting.rubles(month.incomingCarryoverDebtRub, maximumFractionDigits: 2),
                            accent: FuelUI.danger
                        )
                    }

                    if month.monthCarryoverDebtRub > 0 {
                        metricRow(
                            title: "Перенос на след. месяц:",
                            value: AppFormatting.rubles(month.monthCarryoverDebtRub, maximumFractionDigits: 2),
                            accent: FuelUI.danger
                        )
                    }

                    if !fuelRecords.isEmpty {
                        monthFuelRecordsSection(fuelRecords)
                    }

                    if !month.adjustments.isEmpty {
                        monthAdjustmentsSection(month.adjustments)
                    }
                }
            }
        }
    }

    private func monthAdjustmentsSection(_ adjustments: [FuelRecord]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Корректировки месяца")
                .font(.caption.weight(.semibold))
                .foregroundStyle(FuelUI.muted)

            ForEach(Array(adjustments.enumerated()), id: \.element.stableID) { index, adjustment in
                adjustmentRow(adjustment)

                if index < adjustments.count - 1 {
                    Divider()
                        .overlay(FuelUI.divider)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
        .background(FuelUI.subpanel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(FuelUI.border, lineWidth: 1)
        )
    }

    private func monthFuelRecordsSection(_ records: [FuelRecord]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Записи топлива")
                .font(.caption.weight(.semibold))
                .foregroundStyle(FuelUI.muted)

            ForEach(Array(records.enumerated()), id: \.element.stableID) { index, record in
                fuelRecordRow(record)

                if index < records.count - 1 {
                    Divider()
                        .overlay(FuelUI.divider)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
        .background(FuelUI.subpanel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(FuelUI.border, lineWidth: 1)
        )
    }

    private func fuelRecordRow(_ record: FuelRecord) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                Text(AppFormatting.shortDate(record.date))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FuelUI.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                HStack(spacing: 6) {
                    if let fuelType = record.fuelType, !fuelType.isEmpty {
                        Text(fuelType)
                            .foregroundStyle(FuelUI.accent)
                    }
                    if record.source?.uppercased() == "XLSX_IMPORT" {
                        Text("XLSX")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(FuelUI.mutedStrong)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(FuelUI.chipBackground, in: Capsule())
                    }
                }
                .font(.caption)

                if let mileage = record.mileage {
                    Label(
                        "\(AppFormatting.number(mileage, maximumFractionDigits: 0)) км",
                        systemImage: "gauge.with.dots.needle.33percent"
                    )
                    .font(.caption)
                    .foregroundStyle(FuelUI.muted)
                    .lineLimit(1)
                }
            }
            .layoutPriority(2)

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 4) {
                if let liters = record.liters {
                    Text("\(AppFormatting.number(liters)) л")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FuelUI.text)
                        .lineLimit(1)
                }
                if let fuelCost = record.fuelCost {
                    Text(AppFormatting.rubles(fuelCost, maximumFractionDigits: 2))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(FuelUI.muted)
                        .lineLimit(1)
                }
            }
            .fixedSize(horizontal: true, vertical: false)

            HStack(spacing: 4) {
                FuelIconButton(systemName: "pencil") {
                    openFuelEditor(editing: record)
                }
                .accessibilityLabel("Редактировать запись топлива за \(AppFormatting.shortDate(record.date))")

                FuelIconButton(systemName: "trash", tint: FuelUI.danger) {
                    recordToDelete = record
                }
                .accessibilityLabel("Удалить запись топлива за \(AppFormatting.shortDate(record.date))")
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func adjustmentRow(_ adjustment: FuelRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(adjustment.adjustmentKind == .debtDeduction ? "Вычет долга" : "Выплата компенсации")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FuelUI.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(monthAdjustmentSubtitle(for: adjustment))
                        .font(.caption)
                        .foregroundStyle(FuelUI.muted)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    FuelIconButton(systemName: "pencil") {
                        openAdjustmentEditor(editing: adjustment)
                    }
                    FuelIconButton(systemName: "trash", tint: FuelUI.danger) {
                        recordToDelete = adjustment
                    }
                }
            }

            if let comment = adjustment.comment, !comment.isEmpty {
                Text(comment)
                    .font(.footnote)
                    .foregroundStyle(FuelUI.muted)
            }
        }
    }

    @ViewBuilder
    private func editorSheet(mode: FuelEditorMode) -> some View {
        if mode == .fuel {
            FuelEditorView(
                draft: $draft,
                fuelTypes: store.availableFuelTypes,
                isSubmitting: store.isSubmitting,
                isEditing: editingRecord != nil,
                serverError: store.errorMessage,
                onClose: closeEditor,
                onSave: {
                    let affectedYear = Self.year(
                        for: .fuel,
                        date: draft.date,
                        monthKey: draft.monthKey
                    )
                    let input = FuelRecordInput(
                        recordType: .fuel,
                        adjustmentKind: nil,
                        monthKey: nil,
                        amount: nil,
                        carryoverDebtRub: nil,
                        comment: editingRecord?.comment,
                        date: draft.date,
                        mileage: draft.mileageValue,
                        liters: editingRecord?.liters,
                        fuelCost: editingRecord?.fuelCost,
                        fuelType: draft.fuelType.nilIfEmpty ?? editingRecord?.fuelType
                    )
                    if await store.save(editing: editingRecord, input: input) {
                        selectedYear = affectedYear ?? selectedYear
                        closeEditor()
                    }
                }
            )
        } else {
            FuelAdjustmentEditorView(
                draft: $draft,
                isSubmitting: store.isSubmitting,
                isEditing: editingRecord != nil,
                serverError: store.errorMessage,
                onClose: closeEditor,
                onSave: {
                    let affectedYear = Self.year(
                        for: .adjustment,
                        date: draft.date,
                        monthKey: draft.monthKey
                    )
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
                    if await store.save(editing: editingRecord, input: input) {
                        selectedYear = affectedYear ?? selectedYear
                        closeEditor()
                    }
                }
            )
        }
    }

    private func openFuelEditor(editing: FuelRecord? = nil) {
        editingRecord = editing
        draft = editing.map(FuelDraft.init(record:)) ?? FuelDraft()
        if draft.fuelType.isEmpty {
            draft.fuelType = store.availableFuelTypes.first ?? ""
        }
        editorMode = .fuel
    }

    private func openAdjustmentEditor(kind: FuelRecord.AdjustmentKind? = nil, editing: FuelRecord? = nil) {
        editingRecord = editing
        if let editing {
            draft = FuelDraft(record: editing)
        } else if let kind {
            draft = FuelDraft.adjustment(kind: kind)
        }
        editorMode = .adjustment
    }

    private func closeEditor() {
        editorMode = nil
        editingRecord = nil
    }

    private var filteredMonths: [FuelSummaryMonth] {
        projection.months(for: selectedYear)
    }

    private func updateProjection(for records: [FuelRecord]) {
        projection = FuelProjection(records: records.filter(FuelArchivePolicy.isCurrent))

        guard let selectedYear else {
            self.selectedYear = projection.years.first
            return
        }

        if !projection.years.contains(selectedYear) {
            self.selectedYear = projection.years.first
        }

        if let expandedMonthKey, !projection.summary.monthly.contains(where: { $0.key == expandedMonthKey }) {
            self.expandedMonthKey = nil
        }
    }

    private var currentRecords: [FuelRecord] {
        store.records.filter(FuelArchivePolicy.isCurrent)
    }

    private var archiveRecords: [FuelRecord] {
        store.records.filter(FuelArchivePolicy.isArchived)
    }

    private func fuelRecords(for monthKey: String) -> [FuelRecord] {
        currentRecords
            .filter { record in
                record.recordType == .fuel && String(record.date.prefix(7)) == monthKey
            }
            .sorted { lhs, rhs in
                if lhs.date != rhs.date {
                    return lhs.date > rhs.date
                }
                return lhs.stableID > rhs.stableID
            }
    }

    private var summaryHeadline: String {
        let value = projection.summary.totals.adjustedFuelDiff
        if value < 0 {
            return "Перерасход \(AppFormatting.number(abs(value))) л"
        }
        if value > 0 {
            return "Остаток \(AppFormatting.number(value)) л"
        }
        return "Баланс соблюдён"
    }

    private func monthOnlyTitle(for month: FuelSummaryMonth) -> String {
        let parts = month.key.split(separator: "-")
        guard parts.count == 2,
              let monthNumber = Int(parts[1]),
              (1 ... 12).contains(monthNumber) else {
            return month.label
        }

        let formatter = DateFormatter()
        formatter.locale = AppLocale.russian
        return formatter.standaloneMonthSymbols[monthNumber - 1].capitalized
    }

    private func metricRow(title: String, value: String, accent: Color = FuelUI.text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(FuelUI.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 12)

            Text(value)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(accent)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private func toggleMetricRow(title: String, value: String, accent: Color, action: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(FuelUI.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 12)

            Button {
                AppHaptics.trigger()
                action()
            } label: {
                Text(value)
                    .font(.system(size: 16, weight: .semibold))
                    .underline(color: accent.opacity(0.7))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .buttonStyle(.plain)
        }
    }

    private func statusBadge(for month: FuelSummaryMonth) -> some View {
        Text(month.compensationStatusLabel)
            .font(.caption.weight(.semibold))
            .foregroundStyle(statusTint(for: month))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(statusBackground(for: month), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(statusTint(for: month).opacity(0.18), lineWidth: 1)
            )
    }

    private func statusTint(for month: FuelSummaryMonth) -> Color {
        if month.isCompensationClosed {
            return FuelUI.positive
        }
        if month.effectiveAppliedCompensation > 0 || month.incomingCarryoverDebtRub > 0 {
            return FuelUI.warning
        }
        return FuelUI.mutedStrong
    }

    private func statusBackground(for month: FuelSummaryMonth) -> Color {
        if month.isCompensationClosed {
            return FuelUI.positive.opacity(0.14)
        }
        if month.effectiveAppliedCompensation > 0 || month.incomingCarryoverDebtRub > 0 {
            return FuelUI.warning.opacity(0.14)
        }
        return FuelUI.chipBackground
    }

    private func monthDiffTint(for value: Double) -> Color {
        value < 0 ? FuelUI.danger : value > 0 ? FuelUI.positive : FuelUI.text
    }

    private func adjustedDiffTint(for value: Double) -> Color {
        value < 0 ? FuelUI.danger : value > 0 ? FuelUI.positive : FuelUI.text
    }

    private func monthAdjustmentSubtitle(for adjustment: FuelRecord) -> String {
        let amountText = adjustment.amount.map {
            "\(AppFormatting.number($0, maximumFractionDigits: 2)) ₽"
        } ?? "—"
        let litersText = adjustment.liters.map {
            "\(AppFormatting.number($0, maximumFractionDigits: 2)) л"
        } ?? "—"
        return "\(amountText) · \(litersText)"
    }
}

private struct FuelImportSheetRoute: Identifiable {
    let id = UUID()
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
