import Foundation
import SwiftUI

struct WarehouseRequestsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let terminalID: String
    let simpleOneStore: SimpleOneRequestsStore

    @State private var records: [SimpleOneRequestRecord] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var reloadRequest = 0

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && records.isEmpty {
                    ProgressView("Ищу складскую заявку")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Не удалось загрузить", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Повторить") {
                            reloadRequest += 1
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else if records.isEmpty {
                    ContentUnavailableView(
                        "Складская заявка не найдена",
                        systemImage: "shippingbox",
                        description: Text("Для ID терминала \(terminalID) совпадений в SimpleOne нет.")
                    )
                } else {
                    List {
                        Section {
                            WarehouseRequestFieldRow(title: "ID терминала", value: terminalID, isLinkLike: true)
                        }

                        ForEach(records) { record in
                            Section {
                                ForEach(displayFields(for: record)) { field in
                                    WarehouseRequestFieldRow(title: field.title, value: field.value)
                                }
                            } header: {
                                Text(requestTitle(for: record))
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(AppTheme.background)
                }
            }
            .navigationTitle("Складские")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task(id: reloadRequest) {
            await loadRecords()
        }
    }

    private func loadRecords() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let fetchedRecords = try await simpleOneStore.fetchRequests(
                terminalID: terminalID,
                includeDetails: true
            )
            guard !Task.isCancelled else { return }

            let targetID = normalizedTerminalID(terminalID)
            records = uniqueSimpleOneRecords(fetchedRecords)
                .filter(isWarehouseRequest)
                .filter { record in
                    normalizedTerminalID(for: record) == targetID
                }
                .sorted { lhs, rhs in
                    (lhs.registeredDate ?? .distantPast) > (rhs.registeredDate ?? .distantPast)
                }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = appUserFacingErrorMessage(error, showsNetworkBanner: false)
                ?? "Не удалось загрузить складские заявки."
        }
    }

    private func normalizedTerminalID(for record: SimpleOneRequestRecord) -> String {
        normalizedTerminalID(firstNonEmpty([
            record.terminalID,
            value(
                for: ["ID терминал", "ID терминала"],
                in: warehouseInformationFields(record)
            )
        ]))
    }

    private func normalizedTerminalID(_ raw: String) -> String {
        raw
            .filter { $0.isLetter || $0.isNumber }
            .uppercased()
    }

    private func requestTitle(for record: SimpleOneRequestRecord) -> String {
        firstNonEmpty([
            record.incomingNumber,
            record.number,
            "Складская заявка"
        ])
    }

    private func displayFields(for record: SimpleOneRequestRecord) -> [WarehouseRequestDisplayField] {
        var fields: [WarehouseRequestDisplayField] = []
        var seenKeys = Set<String>()

        func append(_ title: String, _ value: String?) {
            let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmedValue.isEmpty,
                  normalizedEquipmentLabel(trimmedValue) != "информация отсутствует" else {
                return
            }
            let key = normalizedEquipmentLabel(title)
            guard seenKeys.insert(key).inserted else { return }
            fields.append(WarehouseRequestDisplayField(title: title, value: trimmedValue))
        }

        append("Номер заявки", firstNonEmpty([record.incomingNumber, record.number]))
        append("Статус", record.state)
        append("Зарегистрирована", formattedRegistrationDate(for: record))
        append("Исполнитель", record.assignedUser)
        append("Группа", record.assignmentGroup)

        for field in parseWarehouseInformationFields([warehouseInformationBlock(record)]) {
            append(field.key, field.value)
        }

        return fields
    }

    private func formattedRegistrationDate(for record: SimpleOneRequestRecord) -> String {
        if let date = record.registeredDate {
            return date.formatted(
                Date.FormatStyle(date: .numeric, time: .shortened)
                    .locale(Locale(identifier: "ru_RU"))
            )
        }
        return record.registeredAt ?? ""
    }
}

private struct WarehouseRequestDisplayField: Identifiable {
    let title: String
    let value: String

    var id: String {
        normalizedEquipmentLabel(title)
    }
}

private struct WarehouseRequestFieldRow: View {
    let title: String
    let value: String
    var isLinkLike = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedTint)

            AppSelectableText(
                text: value,
                textStyle: .body,
                weight: .medium,
                color: isLinkLike ? AppTheme.primaryTint : AppTheme.ink
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }
}
