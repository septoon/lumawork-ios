import Foundation
import SwiftUI

enum ActiveRequestChatQuestions {
    static var dionURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "DION_CHAT_URL") as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return URL(string: trimmed)
    }
    static var telegramAppURL: URL? {
        AppConfig().telegramAppURL.flatMap(URL.init(string:))
    }

    static var telegramWebURL: URL? {
        AppConfig().telegramWebURL.flatMap(URL.init(string:))
    }
}

extension ActiveSimpleOneRequestData {
    var isFiscalPOS: Bool {
        normalizedTerminalType == "fiscal_pos"
    }

    var isUniversalPOS: Bool {
        normalizedTerminalType == "universal_pos"
    }

    var shouldShowChatQuestions: Bool {
        isFiscalPOS || isUniversalPOS
    }

    private var normalizedTerminalType: String {
        let rawType = fields(for: .install)
            .first { field in
                field.title?.trimmingCharacters(in: .whitespacesAndNewlines) == "Тип терминала:"
            }?
            .value
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return rawType.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "ru_RU")
        )
    }

    var kaAndPinMessage: String {
        let clientFields = fields(for: .client)
        let installFields = fields(for: .install)
        let dismantleFields = fields(for: .dismantle)

        let requestLines = [
            trimmed(requestNumber),
            labeledChatValue("Тид", firstNonEmptyChatValue(
                terminalID,
                chatValue(for: "Терминал:", in: clientFields)
            )),
            labeledChatValue("ИНН", chatValue(for: "ИНН ТСП:", in: clientFields)),
            unlabelledOrEmptyChatValue("Адрес", chatValue(for: "Адрес:", in: clientFields)),
            labeledChatValue("S/N", firstNonEmptyChatValue(
                chatValue(for: "S/N терминала:", in: installFields),
                chatValue(for: "S/N терминала:", in: dismantleFields)
            ))
        ]

        return (["Здравствуйте!", ""] + requestLines + ["", "Прошу выслать новый КА и пин"])
            .joined(separator: "\n")
    }

    var ofdActivationMessage: String {
        let clientFields = fields(for: .client)
        let installFields = fields(for: .install)
        let dismantleFields = fields(for: .dismantle)
        let serialNumber = firstNonEmptyChatValue(
            chatValue(for: "S/N терминала:", in: installFields),
            chatValue(for: "S/N терминала:", in: dismantleFields)
        )

        let requestLines = [
            trimmed(requestNumber),
            labeledChatValue("Тид", terminalID),
            labeledChatValue("ИНН", chatValue(for: "ИНН ТСП:", in: clientFields)),
            labeledChatValue("S/N", serialNumber),
            "РНМ:",
            "КА:"
        ]

        return (["Здравствуйте!", ""] + requestLines + ["", "Прошу активировать тариф ОФД"])
            .joined(separator: "\n")
    }

    var autoregMessage: String {
        let clientFields = fields(for: .client)
        let additionalInfo = additionalInfoKeyValues()
        let taxSystem = firstNonEmptyChatValue(
            nestedAdditionalInfoValue("СНО", in: additionalInfo[normalizedChatKey("ОКВЭД")] ?? ""),
            additionalInfo[normalizedChatKey("СНО")] ?? ""
        )

        let requestLines = [
            trimmed(requestNumber),
            labeledChatValue("ИНН", chatValue(for: "ИНН ТСП:", in: clientFields)),
            labeledChatValue("ТИД", terminalID),
            labeledChatValue("СНО", taxSystem),
            labeledChatValue("ФН", additionalInfo[normalizedChatKey("ФН")] ?? ""),
            labeledChatValue("Адрес", chatValue(for: "Адрес:", in: clientFields)),
            labeledChatValue("Услуги", additionalInfo[normalizedChatKey("Услуги")] ?? ""),
            labeledChatValue("ТМТ", additionalInfo[normalizedChatKey("ТМТ")] ?? "")
        ]

        return (requestLines + ["", "Прошу новый код автореги"])
            .joined(separator: "\n")
    }

    var managerQuestionMessage: String {
        let clientFields = fields(for: .client)
        let requestLines = [
            trimmed(requestNumber),
            unlabelledOrEmptyChatValue("Наименование юр. лица (ИП или ООО)", legalName),
            labeledChatValue("ИНН", chatValue(for: "ИНН ТСП:", in: clientFields)),
            labeledChatValue("ТИД", terminalID),
            labeledChatValue("Адрес", chatValue(for: "Адрес:", in: clientFields))
        ]

        return requestLines.joined(separator: "\n")
    }

    private func chatValue(for title: String, in fields: [ActiveSimpleOneField]) -> String {
        fields.first { field in
            field.title?.trimmingCharacters(in: .whitespacesAndNewlines) == title
        }?.value ?? ""
    }

    private func labeledChatValue(_ label: String, _ value: String) -> String {
        let value = trimmed(value)
        return value.isEmpty ? "\(label):" : "\(label): \(value)"
    }

    private func unlabelledOrEmptyChatValue(_ label: String, _ value: String) -> String {
        let value = trimmed(value)
        return value.isEmpty ? "\(label):" : value
    }

    private func firstNonEmptyChatValue(_ values: String...) -> String {
        values.first { !trimmed($0).isEmpty } ?? ""
    }

    private func additionalInfoKeyValues() -> [String: String] {
        let raw = chatValue(for: "Доп. инфо:", in: fields(for: .task))
        return raw
            .split(separator: ";", omittingEmptySubsequences: true)
            .reduce(into: [:]) { result, segment in
                let text = String(segment).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let separator = text.firstIndex(of: ":") else { return }

                let key = String(text[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(text[text.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { return }
                result[normalizedChatKey(key)] = value
            }
    }

    private func nestedAdditionalInfoValue(_ key: String, in rawValue: String) -> String {
        guard let separator = rawValue.firstIndex(of: ":") else { return "" }
        let nestedKey = String(rawValue[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedChatKey(nestedKey) == normalizedChatKey(key) else { return "" }
        return String(rawValue[rawValue.index(after: separator)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedChatKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ru_RU"))
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ActiveRequestChatQuestionsBlock: View {
    let kaAndPinAction: () -> Void
    let ofdActivationAction: () -> Void
    let autoregAction: () -> Void

    var body: some View {
        AppCard {
            AppSectionHeader(
                title: "Вопросы в чат",
                caption: "Текст заявки скопируется автоматически"
            )

            chatActionButton(
                title: "КА и пин",
                subtitle: "Скопировать текст и открыть чат Dion",
                systemName: "bubble.left.and.bubble.right.fill",
                action: kaAndPinAction
            )

            chatActionButton(
                title: "Активация ОФД",
                subtitle: "Скопировать текст и открыть чат Dion",
                systemName: "checkmark.shield.fill",
                action: ofdActivationAction
            )

            chatActionButton(
                title: "Код автореги",
                subtitle: "Скопировать текст и открыть Telegram",
                systemName: "paperplane.fill",
                action: autoregAction
            )

            Text("После перехода в чат нажмите «Вставить» в поле сообщения и отправьте текст.")
                .font(.footnote)
                .foregroundStyle(AppTheme.mutedTint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chatActionButton(
        title: String,
        subtitle: String,
        systemName: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryTint)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)

                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.mutedTint)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 8)

                Image(systemName: "arrow.up.right")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppTheme.primaryTint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(AppActionButtonStyle())
    }
}

struct ActiveRequestManagerQuestionBlock: View {
    let action: () -> Void

    var body: some View {
        AppCard {
            AppSectionHeader(
                title: "Вопрос Менеджеру",
                caption: "Текст заявки скопируется автоматически"
            )

            Button(action: action) {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(AppTheme.primaryTint)
                        .frame(width: 32)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Вопрос Менеджеру")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(AppTheme.ink)

                        Text("Скопировать текст для отправки менеджеру")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.mutedTint)
                            .multilineTextAlignment(.leading)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "doc.on.doc")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AppTheme.primaryTint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(AppActionButtonStyle())
        }
    }
}
