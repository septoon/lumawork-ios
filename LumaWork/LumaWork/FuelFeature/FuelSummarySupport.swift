import Foundation

enum FuelSummaryCalculator {
    static let fuelConsumptionRate = 9.4
    static let fuelConsumptionRateIncrease = 0.07
    static let approximateFuelPrice = 76.0
    static let rateIncreaseDates = Set(["2025-12-31", "2026-01-31", "2026-02-28", "2026-03-31"])

    static func build(records: [FuelRecord]) -> FuelSummary {
        let fuelOnlyRecords = records.filter { $0.recordType == .fuel }
        let adjustmentRecords = records.filter { $0.recordType == .adjustment }

        guard !records.isEmpty else {
            return FuelSummary(explanation: "", hasData: false)
        }

        var monthlyMap: [String: (label: String, mileage: Double, liters: Double, norm: Double, cost: Double)] = [:]

        for item in fuelOnlyRecords.sorted(by: { $0.date < $1.date }) {
            let month = monthInfo(for: item.date)
            let monthKey = month?.key ?? "unknown"
            let label = month?.label ?? "Без даты"
            let rate = item.fuelConsumptionRate ?? fuelRate(for: item.date)
            let fuelNorm = (item.mileage ?? 0) > 0 ? ((item.mileage ?? 0) * rate) / 100 : 0
            let existing = monthlyMap[monthKey] ?? (label, 0, 0, 0, 0)
            monthlyMap[monthKey] = (
                label,
                existing.mileage + (item.mileage ?? 0),
                existing.liters + (item.liters ?? 0),
                existing.norm + fuelNorm,
                existing.cost + (item.fuelCost ?? 0)
            )
        }

        for item in adjustmentRecords {
            let key = recordMonthKey(for: item)
            if monthlyMap[key] == nil {
                monthlyMap[key] = (AppFormatting.monthLabel(key), 0, 0, 0, 0)
            }
        }

        let sortedKeys = monthlyMap.keys.sorted()
        let monthly = sortedKeys.map { key -> FuelSummaryMonth in
            let month = monthlyMap[key] ?? ("Без даты", 0, 0, 0, 0)
            let monthAdjustments = adjustmentRecords.filter { recordMonthKey(for: $0) == key }
            let previousMonthCarryover = previousCalendarMonthKey(for: key)
                .flatMap { previousKey in
                    adjustmentRecords
                        .filter { recordMonthKey(for: $0) == previousKey && $0.adjustmentKind == .debtDeduction }
                        .compactMap(\.carryoverDebtRub)
                        .last
                } ?? 0

            let paidCompensation = monthAdjustments
                .filter { $0.adjustmentKind == .compensationPayment }
                .reduce(0) { $0 + ($1.amount ?? 0) }
            let debtAdjustments = monthAdjustments.filter { $0.adjustmentKind == .debtDeduction }
            let debtDeductionAmount = debtAdjustments.reduce(0) { $0 + ($1.amount ?? 0) }
            let debtDeductionLiters = debtAdjustments.reduce(0) { $0 + ($1.liters ?? 0) }
            let effectiveDebtDeductionAmount = debtAdjustments.reduce(0) { $0 + debtDeductionAmountValue(for: $1) }
            let effectiveDebtDeductionLiters = debtAdjustments.reduce(0) { $0 + debtDeductionLitersValue(for: $1) }
            let monthCarryover = debtAdjustments.compactMap(\.carryoverDebtRub).last ?? 0
            let fuelDiff = month.norm - month.liters
            let compensation = month.mileage * 5
            let effectiveAppliedCompensation = paidCompensation + effectiveDebtDeductionAmount
            let projectedDebtDeductionFromCarryover = effectiveDebtDeductionAmount > 0
                ? effectiveDebtDeductionAmount
                : min(max(compensation - paidCompensation, 0), previousMonthCarryover)
            let projectedPayout = compensation - paidCompensation - projectedDebtDeductionFromCarryover

            let compensationStatus: String
            if effectiveAppliedCompensation >= compensation, compensation > 0 {
                compensationStatus = "Закрыто"
            } else if effectiveAppliedCompensation > 0 {
                compensationStatus = "Частично закрыто"
            } else if previousMonthCarryover > 0 {
                compensationStatus = "Удержание"
            } else {
                compensationStatus = "К выплате"
            }

            return FuelSummaryMonth(
                key: key,
                label: month.label,
                totalMileage: month.mileage,
                totalLiters: month.liters,
                fuelNorm: month.norm,
                fuelCost: month.cost,
                fuelDiff: fuelDiff,
                diffLabel: diffLabel(for: fuelDiff),
                approvedRate: month.mileage > 0 ? (month.norm / month.mileage) * 100 : 0,
                compensation: compensation,
                paidCompensation: paidCompensation,
                debtDeductionAmount: debtDeductionAmount,
                debtDeductionLiters: debtDeductionLiters,
                effectiveDebtDeductionAmount: effectiveDebtDeductionAmount,
                effectiveDebtDeductionLiters: effectiveDebtDeductionLiters,
                effectiveAppliedCompensation: effectiveAppliedCompensation,
                remainingCompensation: projectedPayout,
                incomingCarryoverDebtRub: previousMonthCarryover,
                incomingCarryoverDebtLiters: previousMonthCarryover / approximateFuelPrice,
                monthCarryoverDebtRub: monthCarryover,
                monthCarryoverDebtLiters: monthCarryover / approximateFuelPrice,
                projectedDebtDeductionFromCarryover: projectedDebtDeductionFromCarryover,
                projectedPayout: projectedPayout,
                isCompensationClosed: effectiveAppliedCompensation >= compensation && compensation > 0,
                compensationStatusLabel: compensationStatus,
                adjustments: monthAdjustments
            )
        }

        let orderedDebtAdjustments = adjustmentRecords
            .filter { $0.adjustmentKind == .debtDeduction }
            .sorted { lhs, rhs in
                let leftMonth = recordMonthKey(for: lhs)
                let rightMonth = recordMonthKey(for: rhs)
                if leftMonth != rightMonth {
                    return leftMonth < rightMonth
                }
                return lhs.date < rhs.date
            }
        let carryover = orderedDebtAdjustments.compactMap(\.carryoverDebtRub).last ?? 0
        let effectiveDebtDeductionAmount = adjustmentRecords
            .filter { $0.adjustmentKind == .debtDeduction }
            .reduce(0) { $0 + debtDeductionAmountValue(for: $1) }
        let effectiveDebtDeductionLiters = adjustmentRecords
            .filter { $0.adjustmentKind == .debtDeduction }
            .reduce(0) { $0 + debtDeductionLitersValue(for: $1) }
        let hasEstimatedDebtDeductionAmount = adjustmentRecords.contains {
            $0.adjustmentKind == .debtDeduction && $0.amount == nil && $0.liters != nil
        }
        let hasEstimatedDebtDeductionLiters = adjustmentRecords.contains {
            $0.adjustmentKind == .debtDeduction && $0.liters == nil && $0.amount != nil
        }
        let totalPaidCompensation = adjustmentRecords
            .filter { $0.adjustmentKind == .compensationPayment }
            .reduce(0) { $0 + ($1.amount ?? 0) }

        let fuelDiff = monthly.reduce(0) { $0 + $1.fuelNorm } - monthly.reduce(0) { $0 + $1.totalLiters }
        let adjustedFuelDiff = fuelDiff + effectiveDebtDeductionLiters

        var explanation = "Расход соответствует норме."
        if adjustedFuelDiff < 0 {
            explanation = "Перерасход топлива \(AppFormatting.number(abs(adjustedFuelDiff))) л (с учётом вычетов долга)."
        } else if adjustedFuelDiff > 0 {
            explanation = "Остаток по норме \(AppFormatting.number(abs(adjustedFuelDiff))) л (с учётом вычетов долга)."
        }

        return FuelSummary(
            monthly: monthly,
            totals: FuelSummaryTotals(
                totalMileage: monthly.reduce(0) { $0 + $1.totalMileage },
                totalLiters: monthly.reduce(0) { $0 + $1.totalLiters },
                fuelNorm: monthly.reduce(0) { $0 + $1.fuelNorm },
                totalFuelCost: monthly.reduce(0) { $0 + $1.fuelCost },
                totalCompensation: monthly.reduce(0) { $0 + $1.compensation },
                totalPaidCompensation: totalPaidCompensation,
                totalDebtDeductionAmount: adjustmentRecords.filter { $0.adjustmentKind == .debtDeduction }.reduce(0) { $0 + ($1.amount ?? 0) },
                totalDebtDeductionLiters: adjustmentRecords.filter { $0.adjustmentKind == .debtDeduction }.reduce(0) { $0 + ($1.liters ?? 0) },
                effectiveDebtDeductionAmount: effectiveDebtDeductionAmount,
                effectiveDebtDeductionLiters: effectiveDebtDeductionLiters,
                hasEstimatedDebtDeductionAmount: hasEstimatedDebtDeductionAmount,
                hasEstimatedDebtDeductionLiters: hasEstimatedDebtDeductionLiters,
                carryoverDebtRub: carryover,
                carryoverDebtLiters: carryover / approximateFuelPrice,
                netCompensation: monthly.reduce(0) { $0 + $1.compensation } - totalPaidCompensation - effectiveDebtDeductionAmount,
                fuelDiff: fuelDiff,
                diffLabel: diffLabel(for: fuelDiff),
                adjustedFuelDiff: adjustedFuelDiff,
                adjustedDiffLabel: diffLabel(for: adjustedFuelDiff)
            ),
            explanation: explanation,
            hasData: !monthly.isEmpty || !adjustmentRecords.isEmpty
        )
    }

    static func years(from summary: FuelSummary) -> [String] {
        Array(Set(summary.monthly.map { String($0.key.prefix(4)) }))
            .sorted(by: >)
    }

    static func filteredMonths(from summary: FuelSummary, selectedYear: String?) -> [FuelSummaryMonth] {
        guard let selectedYear else {
            return Array(summary.monthly.reversed())
        }
        return Array(summary.monthly.filter { $0.key.hasPrefix(selectedYear) }.reversed())
    }

    private static func monthInfo(for date: String) -> (key: String, label: String)? {
        let normalized = normalizedDate(date)
        let parts = normalized.split(separator: "-")
        guard parts.count >= 2 else { return nil }
        let key = "\(parts[0])-\(parts[1])"
        return (key, AppFormatting.monthLabel(key))
    }

    private static func fuelRate(for date: String) -> Double {
        rateIncreaseDates.contains(normalizedDate(date)) ? fuelConsumptionRate * (1 + fuelConsumptionRateIncrease) : fuelConsumptionRate
    }

    private static func recordMonthKey(for record: FuelRecord) -> String {
        if let monthKey = record.monthKey, monthKey.count == 7 {
            return monthKey
        }
        return String(normalizedDate(record.date).prefix(7))
    }

    private static func previousCalendarMonthKey(for monthKey: String) -> String? {
        let parts = monthKey.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]), (1 ... 12).contains(month) else {
            return nil
        }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = 1
        let calendar = Calendar(identifier: .gregorian)
        guard let date = calendar.date(from: components),
              let previousMonth = calendar.date(byAdding: .month, value: -1, to: date) else {
            return nil
        }
        let previousComponents = calendar.dateComponents([.year, .month], from: previousMonth)
        guard let previousYear = previousComponents.year, let previousMonthNumber = previousComponents.month else {
            return nil
        }
        return String(format: "%04d-%02d", previousYear, previousMonthNumber)
    }

    private static func debtDeductionAmountValue(for record: FuelRecord) -> Double {
        guard record.adjustmentKind == .debtDeduction else { return 0 }
        if let amount = record.amount {
            return amount
        }
        return (record.liters ?? 0) * approximateFuelPrice
    }

    private static func debtDeductionLitersValue(for record: FuelRecord) -> Double {
        guard record.adjustmentKind == .debtDeduction else { return 0 }
        if let liters = record.liters {
            return liters
        }
        return (record.amount ?? 0) / approximateFuelPrice
    }

    private static func diffLabel(for value: Double) -> String {
        let sign = value > 0 ? "+" : value < 0 ? "-" : ""
        return "\(sign)\(AppFormatting.number(abs(value))) л"
    }

    private static func normalizedDate(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct FuelProjection: Equatable {
    let summary: FuelSummary
    let years: [String]
    let allRecords: [FuelRecord]

    init(records: [FuelRecord] = []) {
        summary = FuelSummaryCalculator.build(records: records)
        years = FuelSummaryCalculator.years(from: summary)
        allRecords = records.sorted { $0.date > $1.date }
    }

    static func current(records: [FuelRecord] = []) -> FuelProjection {
        FuelProjection(records: records.filter(FuelArchivePolicy.isCurrent))
    }

    func months(for selectedYear: String?) -> [FuelSummaryMonth] {
        FuelSummaryCalculator.filteredMonths(from: summary, selectedYear: selectedYear)
    }
}

enum FuelArchivePolicy {
    nonisolated static let currentRecordsStartDate = "2026-05-13"
    nonisolated static let archivedRecordsTitle = "Архив до 13 мая 2026"

    nonisolated static func isAvailable(for userEmail: String) -> Bool {
        guard let ownerEmail = AppConfig().fuelArchiveOwnerEmail?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !ownerEmail.isEmpty else {
            return false
        }
        return userEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == ownerEmail
    }

    nonisolated static func isCurrent(_ record: FuelRecord) -> Bool {
        normalizedDate(record.date) >= currentRecordsStartDate
    }

    nonisolated static func isArchived(_ record: FuelRecord) -> Bool {
        normalizedDate(record.date) < currentRecordsStartDate
    }

    nonisolated private static func normalizedDate(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
