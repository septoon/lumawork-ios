import AppIntents
import SwiftUI
import UIKit

struct EngineerSiriSettingsScreen: View {
    @State private var searchText = ""
    @State private var isPreparing = false
    @State private var share: EngineerShortcutShare?

    private let examples = [
        "Сколько бензина я должен в Инженере",
        "Какой пробег за прошлый месяц в Инженере",
        "Какой мой VIN в Инженере",
        "Сколько у меня заявок сегодня в Инженере",
        "Найди заявку в Инженере",
        "Куда ехать дальше в Инженере"
    ]

    var body: some View {
        List {
            Section {
                Button {
                    export(EngineerShortcutCatalog.commands)
                } label: {
                    Label("Передать все \(EngineerShortcutCatalog.commands.count) команд", systemImage: "square.and.arrow.up")
                }
                .disabled(isPreparing)
                Text("Выберите «Команды» в меню передачи и подтвердите добавление. Если iOS не предлагает добавить весь набор, добавляйте команды по одной из списка ниже.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Названия — готовые вопросы. Например: «Сири, сколько бензина я должен». Данные и период уже выбраны, подтверждения запуска в действиях нет.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Вопросы без названия приложения")
            } footer: {
                Text("Добавление контролирует iOS. Передача файлов не означает, что все команды уже установлены.")
            }

            ForEach(EngineerShortcutCatalog.sections, id: \.self) { section in
                let commands = visibleCommands.filter { $0.section == section }
                if !commands.isEmpty {
                    Section(section) {
                        ForEach(commands) { command in
                            Button {
                                export([command])
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(command.title)
                                        .foregroundStyle(.primary)
                                    if command.requiresInput {
                                        Text("Siri уточнит адрес, инструкцию или вопрос")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else if command.information == .salary {
                                        Text("С проверкой Face ID")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else if command.information == .adminOverview {
                                        Text("Требуется доступ к админке и проверка личности")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .disabled(isPreparing)
                        }
                    }
                }
            }

            Section {
                ShortcutsLink()
                Text("Автоматические команды доступны сразу с названием приложения. Ниже — примеры их вызова.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Автоматические команды Инженера")
            }

            Section("Примеры после «Привет, Siri»") {
                ForEach(examples, id: \.self) { example in
                    Text(example)
                        .font(.subheadline)
                        .textSelection(.enabled)
                }
            }

            Section("Произвольный вопрос") {
                Text("Скажите «Спроси Инженера», затем продиктуйте вопрос. Ответ подготовит помощник приложения. Требуется интернет.")
                Text("Например: «Сравни мой пробег за этот и прошлый месяц и скажи, сколько осталось долга за бензин».")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Доступ и актуальность") {
                Text("Siri может попросить разблокировать iPhone. Для зарплаты нужна отдельная проверка Face ID. При выключенном Face ID используйте раздел «Зарплата» в приложении.")
                Text("Пробег — учтённые данные Инженера. Долг за бензин — текущий топливный баланс с учётом вычетов, как в разделе «Топливо». Если использован кеш, Siri сообщит время обновления.")
                Text("Маршрут берётся с сервера. Изменения, которые ещё не отправлены из приложения, могут отсутствовать в ответе.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
        .navigationTitle("Siri и команды")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Найти вопрос")
        .sheet(item: $share) { item in
            EngineerShortcutShareSheet(urls: item.urls)
        }
        .appLoadingOverlay(isPresented: isPreparing, title: "Готовим команды")
    }

    private var visibleCommands: [EngineerShortcutDefinition] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return EngineerShortcutCatalog.commands }
        return EngineerShortcutCatalog.commands.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private func export(_ commands: [EngineerShortcutDefinition]) {
        guard !isPreparing else { return }
        isPreparing = true
        Task {
            defer { isPreparing = false }
            do {
                let urls = try await Task.detached(priority: .userInitiated) {
                    try EngineerShortcutFiles.prepare(commands)
                }.value
                share = EngineerShortcutShare(urls: urls)
            } catch {
                AppBannerCenter.shared.show(error.localizedDescription, style: .error)
            }
        }
    }
}

private struct EngineerShortcutShare: Identifiable {
    let id = UUID()
    let urls: [URL]
}

private struct EngineerShortcutShareSheet: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
