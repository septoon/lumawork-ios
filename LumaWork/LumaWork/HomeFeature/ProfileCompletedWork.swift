import Foundation
import SwiftUI

nonisolated enum ProfileWorkCategory: String, CaseIterable, Identifiable, Sendable {
    case portable, stationary, integration, fiscal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .portable: "Переносные"
        case .stationary: "Стационарные"
        case .integration: "Интеграции"
        case .fiscal: "Кассы"
        }
    }

    init?(terminalType: String) {
        switch terminalType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "portable_pos", "universal_pos": self = .portable
        case "stat_pos": self = .stationary
        case "intel_pin": self = .integration
        case "fiscal_pos": self = .fiscal
        default: return nil
        }
    }
}

nonisolated enum ProfileWorkOperation: String, CaseIterable, Identifiable, Sendable {
    case install, replacement, serviceStd, dismounting

    var id: String { rawValue }

    var title: String {
        switch self {
        case .install: "Установки"
        case .replacement: "Замены"
        case .serviceStd: "Сервис"
        case .dismounting: "Демонтаж"
        }
    }
}

struct ProfileCompletedWorkStatistics {
    struct CategorySummary: Identifiable {
        let category: ProfileWorkCategory
        var counts: [ProfileWorkOperation: Int] = [:]
        var id: ProfileWorkCategory { category }
        var total: Int { counts.values.reduce(0, +) }

        var operations: [ProfileWorkOperation] {
            ProfileWorkOperation.allCases.filter {
                $0 != .dismounting || counts[$0, default: 0] > 0
            }
        }
    }

    let categories: [CategorySummary]

    init(records: [ClosedRequestRecord]) {
        var counts: [ProfileWorkCategory: [ProfileWorkOperation: Int]] = [:]
        var seen = Set<String>()
        for record in records {
            guard record.isCompletedWithVisit,
                  let operation = ProfileWorkOperation(rawValue: record.requestType.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let category = Self.category(for: record, operation: operation) else { continue }
            let requestNumber = record.requestNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !requestNumber.isEmpty, seen.insert(requestNumber).inserted else { continue }
            counts[category, default: [:]][operation, default: 0] += 1
        }
        categories = ProfileWorkCategory.allCases.map {
            CategorySummary(category: $0, counts: counts[$0] ?? [:])
        }
    }

    private static func category(for record: ClosedRequestRecord, operation: ProfileWorkOperation) -> ProfileWorkCategory? {
        let labels = operation == .dismounting
            ? ["Тип демонтируемого ТО", "Тип устанавливаемого ТО", "Тип терминала"]
            : ["Тип устанавливаемого ТО", "Тип терминала"]
        for label in labels {
            if let value = record.infoFields.first(where: {
                $0.key.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ":")))
                    .caseInsensitiveCompare(label) == .orderedSame
            })?.value, let category = ProfileWorkCategory(terminalType: value) {
                return category
            }
        }
        return nil
    }
}

struct ProfileCompletedWorkSection: View {
    let statistics: ProfileCompletedWorkStatistics
    let isLoading: Bool
    let hasArchive: Bool
    let onCategoryTap: (ProfileWorkCategory) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Выполненные работы")
                    .font(.headline)
                    .foregroundStyle(AppTheme.ink)
                Text("Только успешно закрытые заявки")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedTint)
            }

            if isLoading {
                ProgressView("Загружаем статистику")
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 260 : 140), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(statistics.categories) { summary in
                        Button {
                            onCategoryTap(summary.category)
                        } label: {
                            categoryCard(summary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(summary.category.title)
                        .accessibilityValue((["Всего \(summary.total)"] + summary.operations.map {
                            "\($0.title): \(summary.counts[$0, default: 0])"
                        }).joined(separator: ", "))
                    }
                }

                if !hasArchive {
                    Text("Загрузите закрытые заявки в разделе «Заявки».")
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedTint)
                }
            }
        }
    }

    private func categoryCard(_ summary: ProfileCompletedWorkStatistics.CategorySummary) -> some View {
        let category = summary.category
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: category.systemImage)
                    .foregroundStyle(category.tint)
                Text(category.title)
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .font(.caption.weight(.semibold))

            Text(summary.total, format: .number)
                .font(.title2.weight(.bold))
                .foregroundStyle(category.tint)
                .monospacedDigit()

            VStack(spacing: 3) {
                ForEach(summary.operations) { operation in
                    HStack(spacing: 4) {
                        Text(operation.title)
                        Spacer(minLength: 2)
                        Text(summary.counts[operation, default: 0], format: .number)
                            .monospacedDigit()
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(AppTheme.mutedTint)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(category.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(category.tint.opacity(0.16), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}

private extension ProfileWorkCategory {
    var systemImage: String {
        switch self {
        case .portable: "iphone.gen3"
        case .stationary: "desktopcomputer"
        case .integration: "link"
        case .fiscal: "cashregister"
        }
    }

    var tint: Color {
        switch self {
        case .portable: .blue
        case .stationary: .purple
        case .integration: .green
        case .fiscal: .orange
        }
    }
}
