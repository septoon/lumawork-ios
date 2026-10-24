import SwiftUI

struct GsmDeliverySettings: Codable, Equatable {
    var autoEnabled: Bool
    var time: String
    var timeZone: String
    var recipientEmail: String?
    var effectiveEmail: String
}

struct GsmDeliverySettingsScreen: View {
    let sessionStore: AppSessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var autoEnabled = true
    @State private var selectedTime = Self.date(for: "22:00")
    @State private var email = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var hasLoaded = false
    @State private var errorMessage: String?

    private static let pickerTimeZone = TimeZone(secondsFromGMT: 0)!
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = pickerTimeZone
        return calendar
    }

    var body: some View {
        Form {
            Section {
                Toggle("Автоматическая отправка", isOn: $autoEnabled)
                DatePicker("Время отправки", selection: $selectedTime, displayedComponents: .hourAndMinute)
                    .environment(\.timeZone, Self.pickerTimeZone)
                    .disabled(!autoEnabled)
            } footer: {
                Text("Ежедневно по московскому времени (МСК), только если данные отчёта изменились. Приложение можно закрыть.")
            }
            Section {
                TextField("Электронная почта", text: $email)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Использовать почту аккаунта") {
                    email = sessionStore.currentEmail
                }
            } header: {
                Text("Получатель")
            } footer: {
                Text("Адрес применяется к автоматической и ручной отправке ГСМ-отчётов. Пустое поле — почта аккаунта. Почта для входа не изменится.")
            }
            if isLoading { ProgressView().frame(maxWidth: .infinity) }
            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(AppTheme.dangerTint)
                    if !hasLoaded { Button("Повторить") { Task { await load() } } }
                }
            }
        }
        .disabled(isLoading || isSaving)
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
        .navigationTitle("Отправка ГСМ отчета")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                ModalConfirmButton(action: { Task { await save() } }, isDisabled: !hasLoaded || isLoading,
                    isLoading: isSaving, accessibilityLabel: "Сохранить настройки отправки")
            }
        }
        .task(id: sessionStore.authToken) { await load() }
    }

    private func request(body: [String: Any]? = nil) async throws -> GsmDeliverySettings {
        guard let origin = AppConfig().lumaWorkAPIOrigin.flatMap(URL.init(string:)),
              let token = sessionStore.authToken else { throw AppServiceError.message("Требуется авторизация.") }
        let response = try await HTTPClient().request(origin.appendingPathComponent("api/v2/gsm/delivery-settings"),
            method: body == nil ? "GET" : "PUT", body: body, authToken: token)
        guard let root = response.json as? [String: Any], let settings = root["settings"] as? [String: Any] else {
            throw AppServiceError.message("Сервер не подтвердил настройки отправки.")
        }
        return try JSONDecoder().decode(GsmDeliverySettings.self, from: JSONSerialization.data(withJSONObject: settings))
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let settings = try await request()
            autoEnabled = settings.autoEnabled
            selectedTime = Self.date(for: settings.time)
            email = settings.effectiveEmail
            hasLoaded = true
        } catch is CancellationError { }
        catch { errorMessage = appUserFacingErrorMessage(error, fallback: "Не удалось загрузить настройки отправки.") }
    }

    private func save() async {
        guard hasLoaded, !isSaving else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = Self.calendar.dateComponents([.hour, .minute], from: selectedTime)
        let time = String(format: "%02d:%02d", parts.hour ?? 22, parts.minute ?? 0)
        do {
            _ = try await request(body: ["autoEnabled": autoEnabled, "time": time,
                "recipientEmail": address.isEmpty || address == sessionStore.currentEmail ? NSNull() : address as Any])
            AppHaptics.trigger()
            dismiss()
        } catch is CancellationError { }
        catch { errorMessage = appUserFacingErrorMessage(error, fallback: "Не удалось сохранить настройки отправки.") }
    }

    private static func date(for time: String) -> Date {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: parts.first ?? 22, minute: parts.last ?? 0)) ?? .distantPast
    }
}
