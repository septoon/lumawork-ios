import Foundation
import Charts
import SwiftUI

struct FuelAnalyticsScreen: View {
    let records: [FuelRecord]

    @State private var selectedYear: String?

    private var projection: FuelProjection {
        FuelProjection(records: records)
    }

    private var months: [FuelSummaryMonth] {
        projection.months(for: selectedYear)
    }

    private var pricePoints: [FuelMonthlyPricePoint] {
        months
            .compactMap { month in
                guard month.totalLiters > 0, month.fuelCost > 0 else { return nil }
                return FuelMonthlyPricePoint(
                    id: month.key,
                    label: shortMonthTitle(month.key),
                    fullLabel: month.label,
                    liters: month.totalLiters,
                    cost: month.fuelCost,
                    pricePerLiter: month.fuelCost / month.totalLiters
                )
            }
            .sorted { $0.id < $1.id }
    }

    private var archiveCount: Int {
        records.count(where: FuelArchivePolicy.isArchived)
    }

    private var overallPricePerLiter: Double {
        let liters = pricePoints.reduce(0) { $0 + $1.liters }
        let cost = pricePoints.reduce(0) { $0 + $1.cost }
        return liters > 0 ? cost / liters : 0
    }

    var body: some View {
        ZStack {
            FuelUI.background.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    heroCard
                    periodPicker

                    if months.isEmpty {
                        AppEmptyState(
                            title: "Нет данных за период",
                            message: "Выберите другой год.",
                            systemName: "chart.bar.xaxis"
                        )
                    } else {
                        FuelAnalyticsSection(months: months)
                        monthlyPriceCard
                        monthlyCostCard
                        monthlyTableCard
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, 14)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("Аналитика топлива")
        .navigationBarTitleDisplayMode(.inline)
        .appSidebarBackButton()
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "fuelpump.fill")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Средняя цена литра")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.78))
                    Text(overallPricePerLiter > 0 ? AppFormatting.rubles(overallPricePerLiter, maximumFractionDigits: 2) : "—")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.75)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 8) {
                analyticsBadge("\(records.count) записей", systemName: "list.bullet")
                analyticsBadge("\(pricePoints.count) месяцев", systemName: "calendar")
                if archiveCount > 0 {
                    analyticsBadge("Архив: \(archiveCount)", systemName: "archivebox.fill")
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [FuelUI.accent, FuelUI.positive, Color.indigo.opacity(0.9)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.white.opacity(0.2), lineWidth: 1)
        }
        .shadow(color: FuelUI.accent.opacity(0.22), radius: 16, y: 8)
    }

    private var periodPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                periodButton(title: "Весь период", year: nil)
                ForEach(projection.years, id: \.self) { year in
                    periodButton(title: year, year: year)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func periodButton(title: String, year: String?) -> some View {
        let isSelected = selectedYear == year
        return Button {
            AppHaptics.trigger(.expandCollapse)
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedYear = year
            }
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? .white : FuelUI.accent)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    isSelected ? AnyShapeStyle(FuelUI.accent) : AnyShapeStyle(FuelUI.chipBackground),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    private var monthlyPriceCard: some View {
        FuelPanelCard {
            analyticsHeader(
                title: "Цена топлива по месяцам",
                caption: "Стоимость заправок месяца ÷ залитые литры",
                systemName: "chart.bar.fill"
            )

            if pricePoints.isEmpty {
                Text("Нет месяцев, где одновременно указаны литры и стоимость.")
                    .font(.subheadline)
                    .foregroundStyle(FuelUI.muted)
            } else {
                Chart(pricePoints) { point in
                    BarMark(
                        x: .value("Месяц", point.label),
                        y: .value("Цена литра", point.pricePerLiter)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [FuelUI.accent, FuelUI.positive],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .cornerRadius(6)

                    LineMark(
                        x: .value("Месяц", point.label),
                        y: .value("Цена литра", point.pricePerLiter)
                    )
                    .foregroundStyle(Color.orange)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

                    PointMark(
                        x: .value("Месяц", point.label),
                        y: .value("Цена литра", point.pricePerLiter)
                    )
                    .foregroundStyle(Color.orange)
                    .symbolSize(42)
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(FuelUI.border.opacity(0.65))
                        AxisValueLabel {
                            if let amount = value.as(Double.self) {
                                Text("\(Int(amount.rounded())) ₽")
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks { value in
                        AxisValueLabel()
                        AxisTick().foregroundStyle(FuelUI.border)
                    }
                }
                .frame(height: 250)
            }
        }
    }

    private var monthlyCostCard: some View {
        FuelPanelCard {
            analyticsHeader(
                title: "Распределение расходов",
                caption: "Доля каждого месяца в общей стоимости топлива",
                systemName: "chart.pie.fill"
            )

            if pricePoints.isEmpty {
                Text("Нет данных о стоимости топлива.")
                    .font(.subheadline)
                    .foregroundStyle(FuelUI.muted)
            } else {
                Chart(pricePoints) { point in
                    SectorMark(
                        angle: .value("Стоимость", point.cost),
                        innerRadius: .ratio(0.58),
                        angularInset: 2
                    )
                    .cornerRadius(5)
                    .foregroundStyle(by: .value("Месяц", point.fullLabel))
                }
                .chartLegend(position: .bottom, alignment: .leading, spacing: 10)
                .frame(height: 280)
            }
        }
    }

    private var monthlyTableCard: some View {
        FuelPanelCard {
            analyticsHeader(
                title: "Детализация",
                caption: "Полный расчёт цены, объёма и расхода",
                systemName: "tablecells.fill"
            )

            VStack(spacing: 0) {
                ForEach(Array(months.reversed()), id: \.key) { month in
                    let price = month.totalLiters > 0 ? month.fuelCost / month.totalLiters : 0
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(month.label.capitalized)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(FuelUI.text)
                            Spacer()
                            Text(price > 0 ? "\(AppFormatting.rubles(price, maximumFractionDigits: 2))/л" : "—")
                                .font(.subheadline.weight(.bold).monospacedDigit())
                                .foregroundStyle(FuelUI.accent)
                        }

                        HStack(spacing: 8) {
                            detailPill("\(AppFormatting.number(month.totalLiters)) л")
                            detailPill(AppFormatting.rubles(month.fuelCost, maximumFractionDigits: 0))
                            detailPill("\(AppFormatting.number(month.totalMileage, maximumFractionDigits: 0)) км")
                        }
                    }
                    .padding(.vertical, 13)

                    if month.key != months.first?.key {
                        Divider().overlay(FuelUI.divider)
                    }
                }
            }
        }
    }

    private func analyticsHeader(title: String, caption: String, systemName: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemName)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(FuelUI.accent)
                .frame(width: 34, height: 34)
                .background(FuelUI.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(FuelUI.text)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(FuelUI.muted)
            }
        }
    }

    private func analyticsBadge(_ title: String, systemName: String) -> some View {
        Label(title, systemImage: systemName)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(.white.opacity(0.13), in: Capsule())
    }

    private func detailPill(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(FuelUI.mutedStrong)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(FuelUI.chipBackground, in: Capsule())
    }

    private func shortMonthTitle(_ monthKey: String) -> String {
        let components = monthKey.split(separator: "-")
        guard components.count == 2,
              let monthNumber = Int(components[1]),
              (1 ... 12).contains(monthNumber) else {
            return monthKey
        }
        let formatter = DateFormatter()
        formatter.locale = AppLocale.russian
        let month = String(formatter.shortStandaloneMonthSymbols[monthNumber - 1].prefix(3)).capitalized
        let year = String(components[0].suffix(2))
        return selectedYear == nil && projection.years.count > 1 ? "\(month) \(year)" : month
    }
}

private struct FuelMonthlyPricePoint: Identifiable {
    let id: String
    let label: String
    let fullLabel: String
    let liters: Double
    let cost: Double
    let pricePerLiter: Double
}

struct FuelAnalyticsSection: View {
    let months: [FuelSummaryMonth]

    private var totals: FuelAnalyticsTotals {
        FuelAnalyticsTotals(months: months)
    }

    var body: some View {
        VStack(spacing: 18) {
            overviewCard
            monthlyConsumptionCard
        }
    }

    private var overviewCard: some View {
        FuelPanelCard {
            VStack(alignment: .leading, spacing: 4) {
                Text("Аналитика")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(FuelUI.text)
                Text("Итоги за выбранный период")
                    .font(.subheadline)
                    .foregroundStyle(FuelUI.muted)
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 18, alignment: .topLeading),
                    GridItem(.flexible(), spacing: 18, alignment: .topLeading)
                ],
                spacing: 18
            ) {
                metric(
                    title: "Пройдено",
                    value: "\(AppFormatting.number(totals.mileage, maximumFractionDigits: 0)) км",
                    systemImage: "road.lanes",
                    tint: FuelUI.accent
                )
                metric(
                    title: "Залито",
                    value: "\(AppFormatting.number(totals.liters)) л",
                    systemImage: "fuelpump.fill",
                    tint: FuelUI.accent
                )
                metric(
                    title: "Средний расход",
                    value: "\(AppFormatting.number(totals.consumption, maximumFractionDigits: 1)) л/100 км",
                    systemImage: "gauge.with.dots.needle.50percent",
                    tint: consumptionTint
                )
                metric(
                    title: "Стоимость топлива",
                    value: AppFormatting.rubles(totals.fuelCost, maximumFractionDigits: 0),
                    systemImage: "rublesign.circle.fill",
                    tint: FuelUI.warning
                )
                metric(
                    title: "Начислено",
                    value: AppFormatting.rubles(totals.compensation, maximumFractionDigits: 0),
                    systemImage: "plus.circle.fill",
                    tint: FuelUI.accent
                )
                metric(
                    title: "Выплачено",
                    value: AppFormatting.rubles(totals.paid, maximumFractionDigits: 0),
                    systemImage: "banknote.fill",
                    tint: FuelUI.positive
                )
                metric(
                    title: "Вычтено",
                    value: AppFormatting.rubles(totals.deducted, maximumFractionDigits: 0),
                    systemImage: "minus.circle.fill",
                    tint: FuelUI.warning
                )
                metric(
                    title: "Осталось к выплате",
                    value: AppFormatting.rubles(totals.remaining, maximumFractionDigits: 0),
                    systemImage: "equal.circle.fill",
                    tint: totals.remaining < 0 ? FuelUI.danger : FuelUI.positive
                )
            }
        }
    }

    private var monthlyConsumptionCard: some View {
        FuelPanelCard {
            VStack(alignment: .leading, spacing: 4) {
                Text("Расход по месяцам")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(FuelUI.text)
                Text("Фактический расход и норма, литров на 100 км")
                    .font(.subheadline)
                    .foregroundStyle(FuelUI.muted)
            }

            VStack(spacing: 16) {
                ForEach(Array(months.reversed()), id: \.key) { month in
                    monthlyRow(month)
                }
            }

            HStack(spacing: 16) {
                legend(title: "Фактически", color: FuelUI.accent)
                legend(title: "Норма", color: FuelUI.muted.opacity(0.55))
            }
        }
    }

    private func metric(title: String, value: String, systemImage: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            Text(title)
                .font(.caption)
                .foregroundStyle(FuelUI.muted)

            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(FuelUI.text)
                .lineLimit(2)
                .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private func monthlyRow(_ month: FuelSummaryMonth) -> some View {
        let actual = month.totalMileage > 0 ? month.totalLiters / month.totalMileage * 100 : 0
        let scale = maximumConsumptionScale
        let actualTint = actual > month.approvedRate && month.approvedRate > 0 ? FuelUI.danger : FuelUI.accent

        return HStack(alignment: .center, spacing: 12) {
            Text(shortMonthTitle(month.key))
                .font(.caption.weight(.semibold))
                .foregroundStyle(FuelUI.mutedStrong)
                .frame(width: 42, alignment: .leading)

            VStack(spacing: 6) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(FuelUI.border.opacity(0.55))
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(actualTint)
                                .frame(width: barWidth(value: actual, scale: scale, available: proxy.size.width))
                        }
                }
                .frame(height: 9)

                GeometryReader { proxy in
                    Capsule()
                        .fill(FuelUI.border.opacity(0.32))
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(FuelUI.muted.opacity(0.55))
                                .frame(width: barWidth(value: month.approvedRate, scale: scale, available: proxy.size.width))
                        }
                }
                .frame(height: 5)
            }

            VStack(alignment: .trailing, spacing: 2) {
                Text(month.totalMileage > 0 ? AppFormatting.number(actual, maximumFractionDigits: 1) : "—")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(month.totalMileage > 0 ? actualTint : FuelUI.muted)
                Text(AppFormatting.number(month.approvedRate, maximumFractionDigits: 1))
                    .font(.caption2)
                    .foregroundStyle(FuelUI.muted)
            }
            .frame(width: 36, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(month.label): фактический расход \(AppFormatting.number(actual, maximumFractionDigits: 1)) литров на 100 километров, норма \(AppFormatting.number(month.approvedRate, maximumFractionDigits: 1))"
        )
    }

    private func legend(title: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Capsule()
                .fill(color)
                .frame(width: 18, height: 5)
            Text(title)
                .font(.caption)
                .foregroundStyle(FuelUI.muted)
        }
    }

    private var maximumConsumptionScale: Double {
        let values = months.flatMap { month -> [Double] in
            let actual = month.totalMileage > 0 ? month.totalLiters / month.totalMileage * 100 : 0
            return [actual, month.approvedRate]
        }
        return max((values.max() ?? 0) * 1.12, 1)
    }

    private var consumptionTint: Color {
        let averageNorm = months.reduce(0) { $0 + $1.approvedRate } / Double(max(months.count, 1))
        return totals.consumption > averageNorm && averageNorm > 0 ? FuelUI.danger : FuelUI.positive
    }

    private func barWidth(value: Double, scale: Double, available: CGFloat) -> CGFloat {
        guard value > 0, scale > 0 else { return 0 }
        return max(4, available * CGFloat(min(value / scale, 1)))
    }

    private func shortMonthTitle(_ monthKey: String) -> String {
        let components = monthKey.split(separator: "-")
        guard components.count == 2,
              let monthNumber = Int(components[1]),
              (1 ... 12).contains(monthNumber) else {
            return monthKey
        }

        let formatter = DateFormatter()
        formatter.locale = AppLocale.russian
        return String(formatter.shortStandaloneMonthSymbols[monthNumber - 1].prefix(3)).capitalized
    }
}

private struct FuelAnalyticsTotals {
    let mileage: Double
    let liters: Double
    let fuelCost: Double
    let compensation: Double
    let paid: Double
    let deducted: Double

    init(months: [FuelSummaryMonth]) {
        mileage = months.reduce(0) { $0 + $1.totalMileage }
        liters = months.reduce(0) { $0 + $1.totalLiters }
        fuelCost = months.reduce(0) { $0 + $1.fuelCost }
        compensation = months.reduce(0) { $0 + $1.compensation }
        paid = months.reduce(0) { $0 + $1.paidCompensation }
        deducted = months.reduce(0) { $0 + $1.effectiveDebtDeductionAmount }
    }

    var consumption: Double {
        mileage > 0 ? liters / mileage * 100 : 0
    }

    var remaining: Double {
        compensation - paid - deducted
    }
}
