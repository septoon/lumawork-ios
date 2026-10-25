import SwiftUI

struct TerminalRequestHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    let terminalID: String
    let currentRequestID: String
    let simpleOneStore: SimpleOneRequestsStore

    @State private var store = SimpleOneTerminalHistoryStore()
    @State private var reloadRequest = 0
    @AppStorage("TerminalRequestHistory.showsReturnEquipment") private var showsReturnEquipment = true
    @AppStorage("TerminalRequestHistory.showsExpertise") private var showsExpertise = true

    private var sessionID: String {
        makeCoordinationSessionID(for: simpleOneStore)
    }

    private var records: [SimpleOneRequestRecord] {
        guard hasCurrentSnapshot else { return [] }
        return SimpleOneTerminalHistory.records(
            store.records, terminalID: terminalID, excludingRequestID: currentRequestID,
            showsReturnEquipment: showsReturnEquipment, showsExpertise: showsExpertise
        )
    }

    private var hasCurrentSnapshot: Bool {
        store.hasSnapshot && store.isCurrentScope(terminalID: terminalID, sessionID: sessionID)
    }

    private var isLoading: Bool {
        simpleOneStore.isAuthorized && (store.isLoading || !store.isCurrentScope(terminalID: terminalID, sessionID: sessionID))
    }

    var body: some View {
        NavigationStack {
            Group {
                if !simpleOneStore.isAuthorized {
                    ContentUnavailableView("SimpleOne не подключён", systemImage: "person.crop.circle.badge.exclamationmark")
                } else if let error = store.errorMessage, !hasCurrentSnapshot, !isLoading {
                    ContentUnavailableView {
                        Label("Не удалось загрузить историю", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Повторить") { reloadRequest += 1 }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        Section {
                            historyField("ID терминала", value: terminalID)
                            if let error = store.errorMessage {
                                Text(error).font(.footnote).foregroundStyle(AppTheme.dangerTint)
                                Button("Повторить") { reloadRequest += 1 }
                            }
                        }

                        if records.isEmpty && !isLoading {
                            ContentUnavailableView(
                                "История не найдена", systemImage: "clock.arrow.circlepath",
                                description: Text(showsReturnEquipment && showsExpertise
                                    ? "Предыдущих закрытых заявок с этим ID терминала нет."
                                    : "С выбранными фильтрами заявок нет.")
                            )
                            .listRowBackground(Color.clear)
                        } else {
                            ForEach(records) { record in
                                historyRow(record)
                                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(AppTheme.background)
                    .refreshable { await load() }
                }
            }
            .navigationTitle("История выездов")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    if isLoading {
                        CoordinationShimmerText(text: "История выездов", font: .headline, tint: AppTheme.ink)
                    } else {
                        Text("История выездов").font(.headline)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Закрыть историю")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Показать все") {
                            showsReturnEquipment = true
                            showsExpertise = true
                        }
                        Toggle("Возврат ТО", isOn: $showsReturnEquipment)
                        Toggle("Экспертиза", isOn: $showsExpertise)
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease")
                    }
                    .accessibilityLabel("Фильтр истории")
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task(id: "\(sessionID)|\(simpleOneStore.isAuthorized)|\(terminalID)|\(currentRequestID)|\(reloadRequest)") { await load() }
    }

    private func historyRow(_ record: SimpleOneRequestRecord) -> some View {
        let detail = ActiveSimpleOneRequestData(record: record)
        let status = SimpleOneTerminalHistory.completionStatus(for: record)?.title ?? "Нет данных"
        let type = SimpleOneTerminalHistory.requestTypeTitle(for: record)
        return ClosedRequestsScreen.SimpleOneActiveRequestCardContainer(
            statusText: status, statusStyle: .closedStatus(status)
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Text(detail.requestNumber)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ClosedRequestsScreen.RequestChip(text: type, style: .requestType(type))
                }
                historyField("Дата", value: SimpleOneTerminalHistory.date(for: record)?.formatted(
                    .dateTime.day().month(.twoDigits).year().hour().minute().locale(Locale(identifier: "ru_RU"))
                ) ?? "Не указана")
                historyField("Исполнитель", value: record.assignedUser.isEmpty ? "Не указан" : record.assignedUser)
            }
        }
        .textSelection(.enabled)
    }

    private func historyField(_ title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(AppTheme.mutedTint)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.ink)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity)
    }

    private func load() async {
        guard simpleOneStore.isAuthorized else { return }
        await store.load(terminalID: terminalID, sessionID: sessionID) {
            try await simpleOneStore.fetchTerminalHistory(terminalID: terminalID)
        }
    }
}
