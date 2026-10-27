import SwiftUI

enum AdminUserSupportAction {
    case email, loginCode, gsmReport, revokeSessions

    var title: String {
        switch self {
        case .email: "Изменить почту"
        case .loginCode: "Отправить код входа"
        case .gsmReport: "Отправить ГСМ-отчёт"
        case .revokeSessions: "Выйти со всех устройств"
        }
    }

    var endpoint: String {
        switch self {
        case .email: "email"
        case .loginCode: "login-code"
        case .gsmReport: "gsm-report"
        case .revokeSessions: "sessions/revoke"
        }
    }
}

struct AdminUserSupportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let user: AdminUserRecord
    let store: AdminUsersStore
    let action: AdminUserSupportAction

    @State private var email = ""
    @State private var repeatedEmail = ""
    @State private var month = Calendar.current.component(.month, from: Date())
    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private var normalizedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    private var canSubmit: Bool {
        guard !isSubmitting && !store.isLoading else { return false }
        if action != .email { return true }
        let parts = normalizedEmail.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".")
            && !normalizedEmail.contains(where: { $0.isWhitespace })
            && normalizedEmail != user.email.lowercased()
            && normalizedEmail == repeatedEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Пользователь") {
                    LabeledContent("Имя", value: user.displayName)
                    LabeledContent(action == .email ? "Текущая почта" : "Получатель", value: user.email)
                        .textSelection(.enabled)
                }

                if action == .email {
                    Section {
                        TextField("Новая почта", text: $email)
                        TextField("Повторите новую почту", text: $repeatedEmail)
                    } header: {
                        Text("Новая почта аккаунта")
                    } footer: {
                        Text("Сессии на всех устройствах, старые коды входа и подключения ChatGPT будут отозваны. Для входа потребуется код на новую почту. Рабочая почта в профиле сохраняется отдельно.")
                    }
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                }

                if action == .gsmReport {
                    Section("Период отчёта") {
                        Picker("Месяц", selection: $month) {
                            ForEach(1...12, id: \.self) { value in
                                Text(Calendar(identifier: .gregorian).standaloneMonthSymbols[value - 1].capitalized).tag(value)
                            }
                        }
                        Picker("Год", selection: $year) {
                            ForEach(2020...(Calendar.current.component(.year, from: Date()) + 1), id: \.self) { value in
                                Text(String(value)).tag(value)
                            }
                        }
                        Text("Отчёт будет сформирован заново по данным пользователя и отправлен на указанную почту. Профиль ГСМ должен быть заполнен.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                if action == .loginCode {
                    Section {
                        Text("Одноразовый код придёт на почту пользователя. Код доступен только получателю. Повторная отправка возможна через минуту.")
                    }
                }

                if action == .revokeSessions {
                    Section {
                        Text("Все сессии приложения, коды входа и подключения ChatGPT будут отозваны. Данные аккаунта сохранятся. Пользователь сможет войти снова по коду из письма.")
                    }
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(AppTheme.dangerTint) }
                }

                Section {
                    Button(role: action == .revokeSessions ? .destructive : nil) {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Text(isSubmitting ? "Выполняется…" : action.title)
                            Spacer()
                            if isSubmitting { ProgressView() }
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
            .navigationTitle(action.title)
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isSubmitting)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }.disabled(isSubmitting)
                }
            }
        }
    }

    private func submit() async {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        let success = await store.supportAction(
            user: user, action: action, email: normalizedEmail,
            month: String(format: "%04d-%02d", year, month)
        )
        if success { dismiss() } else { errorMessage = store.errorMessage ?? "Не удалось выполнить действие." }
    }
}
