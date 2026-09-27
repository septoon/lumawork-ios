import Charts
import SwiftUI

struct SalaryAnalyticsCard: View {
    let months: [SalaryMonthSectionData]
    let isAmountHidden: Bool

    @AppStorage("salary-analytics-excluded-payment-kinds")
    private var excludedPaymentKindsRawValue = ""

    var body: some View {
        AppCard {
            AppSectionHeader(
                title: "Аналитика",
                caption: "Структура выплат и средние значения за всё время"
            )

            metrics
            donut
            paymentKindFilters
        }
    }

    private var metrics: some View {
        HStack(spacing: 10) {
            metric(
                title: "В среднем выплат",
                value: averagePaymentCountText,
                systemName: "number.circle.fill",
                tint: AppTheme.primaryTint,
                accessibilityValue: "\(averagePaymentCountText) в месяц"
            )
            metric(
                title: "В среднем за месяц",
                value: displayAmount(averageMonthlyTotal),
                systemName: "rublesign.circle.fill",
                tint: AppTheme.secondaryTint,
                accessibilityValue: displayAmount(averageMonthlyTotal)
            )
        }
    }

    private func metric(
        title: String,
        value: String,
        systemName: String,
        tint: Color,
        accessibilityValue: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemName)
                .font(.headline)
                .foregroundStyle(tint)

            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AppTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Text(title)
                .font(.caption)
                .foregroundStyle(AppTheme.mutedTint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.subpanelSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
    }

    private var donut: some View {
        ZStack {
            Circle()
                .stroke(AppTheme.border.opacity(0.55), lineWidth: 34)
                .frame(width: 190, height: 190)

            Chart(paymentSlices) { slice in
                SectorMark(
                    angle: .value("Сумма", displayedAmount(for: slice)),
                    innerRadius: .ratio(0.64),
                    angularInset: 2.2
                )
                .cornerRadius(5)
                .foregroundStyle(slice.kind.analyticsColor)
                .opacity(isIncluded(slice.kind) ? 1 : 0)
            }
            .chartLegend(.hidden)
            .frame(width: 220, height: 220)

            VStack(spacing: 4) {
                Text("Выбрано")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedTint)

                Text(displayAmount(filteredTotal))
                    .font(.headline.weight(.bold))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .contentTransition(.numericText(value: filteredTotal))
            }
            .padding(.horizontal, 44)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
        .animation(.snappy(duration: 0.45, extraBounce: 0.08), value: excludedPaymentKindsRawValue)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Распределение выплат по типам")
        .accessibilityValue("Выбрано \(displayAmount(filteredTotal))")
    }

    private var paymentKindFilters: some View {
        VStack(spacing: 4) {
            ForEach(paymentSlices) { slice in
                paymentKindFilter(slice)
            }
        }
        .padding(10)
        .background(AppTheme.subpanelSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func paymentKindFilter(_ slice: PaymentSlice) -> some View {
        let included = isIncluded(slice.kind)

        return Button {
            withAnimation(.snappy(duration: 0.45, extraBounce: 0.08)) {
                setIncluded(!included, kind: slice.kind)
            }
            AppHaptics.trigger(.expandCollapse)
        } label: {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(included ? slice.kind.analyticsColor : Color.clear)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(slice.kind.analyticsColor.opacity(included ? 1 : 0.65), lineWidth: 1.5)

                    if included {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 17, height: 17)

                Text(slice.kind.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(included ? AppTheme.ink : AppTheme.mutedTint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 1) {
                    Text(displayAmount(slice.amount))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(included ? AppTheme.ink : AppTheme.mutedTint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)

                    Text(percentageText(for: slice))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(AppTheme.mutedTint)
                }
            }
            .padding(.horizontal, 4)
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(slice.kind.title)
        .accessibilityValue(included ? "Включено, \(displayAmount(slice.amount))" : "Исключено")
        .accessibilityHint(included ? "Дважды коснитесь, чтобы исключить из диаграммы" : "Дважды коснитесь, чтобы добавить в диаграмму")
    }

    private var paymentSlices: [PaymentSlice] {
        let entries = months.flatMap(\.entries)
        return SalaryPaymentKind.allCases.map { kind in
            PaymentSlice(
                kind: kind,
                amount: entries
                    .filter { $0.paymentKind == kind }
                    .reduce(0) { $0 + SalaryCalculations.payout(for: $1) }
            )
        }
    }

    private var averagePaymentCount: Double {
        guard !months.isEmpty else { return 0 }
        return Double(months.reduce(0) { $0 + $1.entryCount }) / Double(months.count)
    }

    private var averagePaymentCountText: String {
        averagePaymentCount.formatted(
            .number
                .locale(AppLocale.russian)
                .precision(.fractionLength(1))
        )
    }

    private var averageMonthlyTotal: Double {
        guard !months.isEmpty else { return 0 }
        return months.reduce(0) { $0 + $1.total } / Double(months.count)
    }

    private var filteredTotal: Double {
        paymentSlices.reduce(0) { result, slice in
            result + displayedAmount(for: slice)
        }
    }

    private var excludedPaymentKinds: Set<SalaryPaymentKind> {
        Set(
            excludedPaymentKindsRawValue
                .split(separator: ",")
                .compactMap { SalaryPaymentKind(rawValue: String($0)) }
        )
    }

    private func isIncluded(_ kind: SalaryPaymentKind) -> Bool {
        !excludedPaymentKinds.contains(kind)
    }

    private func setIncluded(_ isIncluded: Bool, kind: SalaryPaymentKind) {
        var excluded = excludedPaymentKinds
        if isIncluded {
            excluded.remove(kind)
        } else {
            excluded.insert(kind)
        }
        excludedPaymentKindsRawValue = excluded
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")
    }

    private func displayedAmount(for slice: PaymentSlice) -> Double {
        isIncluded(slice.kind) ? max(slice.amount, 0) : 0
    }

    private func percentageText(for slice: PaymentSlice) -> String {
        guard isIncluded(slice.kind), filteredTotal > 0 else { return "—" }
        return (slice.amount / filteredTotal).formatted(.percent.precision(.fractionLength(0)))
    }

    private func displayAmount(_ amount: Double) -> String {
        guard !isAmountHidden else { return "••••••" }
        return AppFormatting.rubles(amount, maximumFractionDigits: 0)
    }
}

private struct PaymentSlice: Identifiable {
    let kind: SalaryPaymentKind
    let amount: Double

    var id: SalaryPaymentKind {
        kind
    }
}

private extension SalaryPaymentKind {
    var analyticsColor: Color {
        switch self {
        case .advance:
            return AppTheme.secondaryTint
        case .salary:
            return AppTheme.primaryTint
        case .weekend:
            return .blue
        case .gsm:
            return .purple
        case .other:
            return .pink
        }
    }
}
