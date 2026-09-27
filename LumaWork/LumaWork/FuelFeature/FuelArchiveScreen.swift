import Foundation
import SwiftUI

struct FuelArchiveScreen: View {
    let store: FuelStore

    @State private var editingSelection: FuelRecordEditSelection?
    @State private var recordToDelete: FuelRecord?

    private var records: [FuelRecord] {
        store.records.filter(FuelArchivePolicy.isArchived)
    }

    private var projection: FuelProjection {
        FuelProjection(records: records)
    }

    private var sortedRecords: [FuelRecord] {
        records.sorted { lhs, rhs in
            if lhs.date != rhs.date {
                return lhs.date > rhs.date
            }
            return lhs.stableID > rhs.stableID
        }
    }

    private var groupedRecords: [(key: String, records: [FuelRecord])] {
        Dictionary(grouping: sortedRecords, by: monthKey(for:))
            .map { (key: $0.key, records: $0.value) }
            .sorted { $0.key > $1.key }
    }

    var body: some View {
        ZStack {
            FuelUI.background
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let errorMessage = store.errorMessage {
                        FuelNotice(text: errorMessage, tint: FuelUI.danger, isCritical: true)
                    } else if let notice = store.notice {
                        FuelNotice(text: notice, tint: FuelUI.positive, isCritical: false)
                    }

                    summaryCard

                    if records.isEmpty {
                        FuelPanelCard {
                            Text("Архивных записей пока нет.")
                                .font(.subheadline)
                                .foregroundStyle(FuelUI.muted)
                        }
                    } else {
                        ForEach(groupedRecords, id: \.key) { group in
                            archiveMonthSection(monthKey: group.key, records: group.records)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("Архив топлива")
        .navigationBarTitleDisplayMode(.inline)
        .appSidebarBackButton()
        .sheet(item: $editingSelection) { selection in
            NavigationStack {
                FuelRecordEditSheet(store: store, record: selection.record)
            }
            .appEditorSheetStyle()
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
    }

    private var summaryCard: some View {
        FuelPanelCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(FuelArchivePolicy.archivedRecordsTitle)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(FuelUI.text)

                Text("На основном экране остаются записи с 13 мая 2026.")
                    .font(.subheadline)
                    .foregroundStyle(FuelUI.muted)

                if projection.summary.hasData {
                    metricRow(
                        title: "Пробег:",
                        value: "\(AppFormatting.number(projection.summary.totals.totalMileage, maximumFractionDigits: 0)) км"
                    )
                    metricRow(
                        title: "Заправлено:",
                        value: "\(AppFormatting.number(projection.summary.totals.totalLiters)) л"
                    )
                    metricRow(
                        title: "Сумма:",
                        value: AppFormatting.rubles(projection.summary.totals.totalFuelCost, maximumFractionDigits: 2)
                    )
                }
            }
        }
    }

    private func archiveMonthSection(monthKey: String, records: [FuelRecord]) -> some View {
        FuelPanelCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(AppFormatting.monthLabel(monthKey))
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(FuelUI.text)

                ForEach(Array(records.enumerated()), id: \.element.stableID) { index, record in
                    archivedRecordRow(record)

                    if index < records.count - 1 {
                        Divider()
                            .overlay(FuelUI.divider)
                    }
                }
            }
        }
    }

    private func archivedRecordRow(_ record: FuelRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(recordTitle(record))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FuelUI.text)
                    Text(AppFormatting.shortDate(record.date))
                        .font(.caption)
                        .foregroundStyle(FuelUI.muted)
                }

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    Text(recordAmount(record))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(record.recordType == .adjustment ? FuelUI.warning : FuelUI.text)
                        .multilineTextAlignment(.trailing)

                    HStack(spacing: 6) {
                        FuelIconButton(systemName: "pencil") {
                            editingSelection = FuelRecordEditSelection(record: record)
                        }
                        .accessibilityLabel("Редактировать \(recordTitle(record).lowercased()) за \(AppFormatting.shortDate(record.date))")

                        FuelIconButton(systemName: "trash", tint: FuelUI.danger) {
                            recordToDelete = record
                        }
                        .accessibilityLabel("Удалить \(recordTitle(record).lowercased()) за \(AppFormatting.shortDate(record.date))")
                    }
                }
            }

            if record.recordType == .fuel {
                HStack(spacing: 10) {
                    if let mileage = record.mileage {
                        archiveChip("\(AppFormatting.number(mileage, maximumFractionDigits: 0)) км")
                    }
                    if let liters = record.liters {
                        archiveChip("\(AppFormatting.number(liters)) л")
                    }
                    if let fuelCost = record.fuelCost {
                        archiveChip(AppFormatting.rubles(fuelCost, maximumFractionDigits: 2))
                    }
                }
            }

            if let comment = record.comment, !comment.isEmpty {
                Text(comment)
                    .font(.footnote)
                    .foregroundStyle(FuelUI.muted)
            }
        }
    }

    private func archiveChip(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(FuelUI.mutedStrong)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(FuelUI.chipBackground, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(FuelUI.border, lineWidth: 1)
            )
    }

    private func metricRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(FuelUI.muted)

            Spacer(minLength: 12)

            Text(value)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(FuelUI.text)
                .multilineTextAlignment(.trailing)
        }
    }

    private func recordTitle(_ record: FuelRecord) -> String {
        switch record.recordType {
        case .fuel:
            return "Заправка"
        case .adjustment:
            return record.adjustmentKind == .debtDeduction ? "Вычет долга" : "Выплата компенсации"
        }
    }

    private func recordAmount(_ record: FuelRecord) -> String {
        switch record.recordType {
        case .fuel:
            if let liters = record.liters {
                return "\(AppFormatting.number(liters)) л"
            }
            if let fuelCost = record.fuelCost {
                return AppFormatting.rubles(fuelCost, maximumFractionDigits: 2)
            }
            return "—"
        case .adjustment:
            if let amount = record.amount {
                return AppFormatting.rubles(amount, maximumFractionDigits: 2)
            }
            if let liters = record.liters {
                return "\(AppFormatting.number(liters, maximumFractionDigits: 2)) л"
            }
            return "—"
        }
    }

    private func monthKey(for record: FuelRecord) -> String {
        if let monthKey = record.monthKey, monthKey.count == 7 {
            return monthKey
        }
        let trimmedDate = record.date.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmedDate.prefix(7))
    }
}

private struct FuelRecordEditSelection: Identifiable {
    let record: FuelRecord

    var id: String { record.stableID }
}

extension FuelScreen {
    static func year(for recordType: FuelRecord.RecordType, date: String, monthKey: String) -> String? {
        let source = recordType == .adjustment ? monthKey : date
        let year = String(source.prefix(4))
        return year.count == 4 ? year : nil
    }
}
