import AppIntents
import SwiftUI

struct EngineerSiriSettingsScreen: View {
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
                ShortcutsLink()
                Text("Действия доступны в приложении «Команды». Можно создать свою команду с удобным названием и запускать её голосом без названия приложения.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Быстрые команды")
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
                Text("Пробег — учтённые данные Инженера. Долг в рублях и перерасход топлива считаются отдельно. Если использован кеш, Siri сообщит время обновления.")
                Text("Маршрут берётся с сервера. Изменения, которые ещё не отправлены из приложения, могут отсутствовать в ответе.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
        .navigationTitle("Siri и команды")
        .navigationBarTitleDisplayMode(.inline)
    }
}
