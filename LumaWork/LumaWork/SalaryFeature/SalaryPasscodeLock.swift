import LocalAuthentication
import Observation
import SwiftUI

enum SalaryPasscodeSettings {
    static let storageKey = "salary-passcode-code"
    static let faceIDEnabledKey = "salary-face-id-enabled"
    static let length = 4

    static func isFaceIDAvailable(using context: LAContext = LAContext()) -> Bool {
        var authorizationError: NSError?
        return context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &authorizationError
        ) && context.biometryType == .faceID
    }
}

@MainActor
@Observable
private final class SalaryPasscodeRecoveryStore {
    enum Phase: Equatable {
        case passcode
        case codeEntry
        case newPasscode
    }

    private let api: LumaWorkAuthAPI

    let email: String
    var phase: Phase = .passcode
    var code = ""
    var isLoading = false
    var notice: String?
    var errorMessage: String?

    init(email: String, api: LumaWorkAuthAPI) {
        self.email = email
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self.api = api
    }

    func requestCode() async {
        guard !email.isEmpty else {
            errorMessage = "Не удалось определить почту пользователя. Войдите в приложение заново."
            return
        }

        isLoading = true
        errorMessage = nil
        notice = nil
        do {
            try await api.requestCode(email: email)
            code = ""
            phase = .codeEntry
            notice = "Разовый код отправлен на \(email)."
            AppHaptics.trigger(.success)
        } catch {
            errorMessage = appUserFacingErrorMessage(
                error,
                fallback: "Не удалось отправить разовый код."
            )
        }
        isLoading = false
    }

    func verifyCode() async {
        guard code.count == 6 else {
            errorMessage = "Введите 6-значный код."
            return
        }

        isLoading = true
        errorMessage = nil
        notice = nil
        do {
            _ = try await api.verifyCode(email: email, code: code)
            code = ""
            phase = .newPasscode
            notice = "Код подтверждён. Придумайте новый PIN."
            AppHaptics.trigger(.success)
        } catch {
            errorMessage = appUserFacingErrorMessage(
                error,
                fallback: "Не удалось подтвердить разовый код."
            )
            AppHaptics.trigger(.error)
        }
        isLoading = false
    }

    func returnToPasscode() {
        code = ""
        errorMessage = nil
        notice = nil
        phase = .passcode
    }
}

struct SalaryPasscodeLockView: View {
    let passcode: String
    let onCreate: (String) -> Void
    let onUnlock: () -> Void
    let onCancel: () -> Void

    @AppStorage(SalaryPasscodeSettings.faceIDEnabledKey) private var isFaceIDEnabled = true
    @State private var input = ""
    @State private var firstSetupInput: String?
    @State private var isError = false
    @State private var isFaceIDAvailable = false
    @State private var isAuthenticatingWithFaceID = false
    @State private var hasAttemptedAutomaticFaceID = false
    @State private var faceIDErrorMessage: String?
    @State private var lastSubmittedRecoveryCode = ""
    @State private var recoveryStore: SalaryPasscodeRecoveryStore

    init(
        passcode: String,
        recoveryEmail: String,
        config: AppConfig = AppConfig(),
        onCreate: @escaping (String) -> Void,
        onUnlock: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.passcode = passcode
        self.onCreate = onCreate
        self.onUnlock = onUnlock
        self.onCancel = onCancel
        _recoveryStore = State(
            initialValue: SalaryPasscodeRecoveryStore(
                email: recoveryEmail,
                api: LumaWorkAuthAPI(config: config)
            )
        )
    }

    private var isCreatingPasscode: Bool {
        passcode.isEmpty || recoveryStore.phase == .newPasscode
    }

    private var titleText: String {
        switch recoveryStore.phase {
        case .codeEntry:
            "Введите код"
        case .newPasscode:
            firstSetupInput == nil ? "Придумайте новый код" : "Повторите новый код"
        case .passcode:
            if passcode.isEmpty {
                firstSetupInput == nil ? "Придумайте код" : "Повторите код"
            } else {
                "Сведения о ЗП"
            }
        }
    }

    var body: some View {
        ZStack {
            passcodeBackground
                .ignoresSafeArea()

            Group {
                if recoveryStore.phase == .codeEntry {
                    recoveryCodeContent
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    passcodeContent
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
        }
        .animation(.snappy(duration: 0.34), value: recoveryStore.phase)
        .interactiveDismissDisabled()
        .background {
            if let notice = recoveryStore.notice {
                AppNoticeBanner(
                    text: notice,
                    tint: AppTheme.primaryTint,
                    style: .success
                )
            }
            if let errorMessage = recoveryStore.errorMessage {
                AppNoticeBanner(
                    text: errorMessage,
                    tint: AppTheme.dangerTint,
                    isCritical: true,
                    style: .error
                )
            }
            if let faceIDErrorMessage {
                AppNoticeBanner(
                    text: faceIDErrorMessage,
                    tint: AppTheme.dangerTint,
                    isCritical: true,
                    style: .error
                )
            }
        }
        .onChange(of: recoveryStore.code) { _, newValue in
            handleRecoveryCodeChange(newValue)
        }
        .onChange(of: recoveryStore.phase) { _, phase in
            if phase == .newPasscode {
                input = ""
                firstSetupInput = nil
                isError = false
            }
            if phase != .codeEntry {
                lastSubmittedRecoveryCode = ""
            }
        }
        .task(id: recoveryStore.notice) {
            await appDismissTransientMessage(recoveryStore.notice) { value in
                if recoveryStore.notice == value {
                    recoveryStore.notice = nil
                }
            }
        }
        .task(id: recoveryStore.errorMessage) {
            await appDismissTransientMessage(recoveryStore.errorMessage) { value in
                if recoveryStore.errorMessage == value {
                    recoveryStore.errorMessage = nil
                }
            }
        }
        .task {
            await prepareFaceID()
        }
        .task(id: faceIDErrorMessage) {
            await appDismissTransientMessage(faceIDErrorMessage) { value in
                if faceIDErrorMessage == value {
                    faceIDErrorMessage = nil
                }
            }
        }
    }

    private var passcodeContent: some View {
        VStack(spacing: 0) {
            header

            Spacer(minLength: 14)

            passcodeDots

            Spacer()

            keypad
                .padding(.horizontal, 24)
                .padding(.bottom, 22)
        }
    }

    private var recoveryCodeContent: some View {
        VStack(spacing: 0) {
            header

            Spacer()

            VStack(spacing: 18) {
                Image(systemName: "envelope.badge.shield.half.filled")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(AppTheme.primaryTint)

                VStack(spacing: 6) {
                    Text("Введите 6 цифр из письма")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)

                    Text(recoveryStore.email)
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.mutedTint)
                        .multilineTextAlignment(.center)
                }

                AppOneTimeCodeInput(
                    code: $recoveryStore.code,
                    isLoading: recoveryStore.isLoading
                )
                .padding(.top, 6)

                Button("Отправить код повторно") {
                    AppHaptics.trigger()
                    lastSubmittedRecoveryCode = ""
                    Task { await recoveryStore.requestCode() }
                }
                .font(.subheadline.weight(.medium))
                .disabled(recoveryStore.isLoading)

                if recoveryStore.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 24)

            Spacer()
        }
    }

    private var header: some View {
        ZStack(alignment: .top) {
            Text(titleText)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.ink)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 78)
                .padding(.top, 26)

            HStack {
                if recoveryStore.phase == .codeEntry {
                    Button("Назад", systemImage: "chevron.left") {
                        AppHaptics.trigger()
                        recoveryStore.returnToPasscode()
                    }
                    .labelStyle(.iconOnly)
                    .appNativeIconControl(.floating, tint: AppTheme.ink.opacity(0.72))
                }

                Spacer()

                Button("Закрыть ввод кода", systemImage: "xmark") {
                    AppHaptics.trigger()
                    onCancel()
                }
                .labelStyle(.iconOnly)
                .appNativeIconControl(.floating, tint: AppTheme.ink.opacity(0.72))
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
        }
        .frame(height: 72)
    }

    private var passcodeBackground: LinearGradient {
        LinearGradient(
            colors: [
                Color(uiColor: UIColor { traits in
                    traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.07, green: 0.08, blue: 0.09, alpha: 1)
                    : UIColor(red: 0.98, green: 0.97, blue: 0.93, alpha: 1)
                }),
                Color(uiColor: UIColor { traits in
                    traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.13, green: 0.15, blue: 0.16, alpha: 1)
                    : UIColor(red: 0.91, green: 0.94, blue: 0.89, alpha: 1)
                })
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var passcodeDots: some View {
        HStack(spacing: 14) {
            ForEach(0..<SalaryPasscodeSettings.length, id: \.self) { index in
                Circle()
                    .fill(dotColor(for: index))
                    .frame(width: 11, height: 11)
                    .scaleEffect(index < input.count ? 1.16 : 1)
            }
        }
        .offset(y: -12)
        .animation(.snappy(duration: 0.22), value: input)
        .animation(.easeInOut(duration: 0.18), value: isError)
    }

    private var keypad: some View {
        VStack(spacing: 14) {
            ForEach([[1, 2, 3], [4, 5, 6], [7, 8, 9]], id: \.self) { row in
                HStack {
                    ForEach(row, id: \.self) { digit in
                        keypadDigit(digit)
                    }
                }
            }

            HStack {
                Button {
                    if isCreatingPasscode {
                        AppHaptics.trigger()
                        resetPasscodeInput()
                    } else {
                        AppHaptics.trigger(.expandCollapse)
                        Task { await recoveryStore.requestCode() }
                    }
                } label: {
                    Group {
                        if recoveryStore.isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(isCreatingPasscode ? "Сбросить" : "Не помню\nкод")
                                .multilineTextAlignment(.center)
                        }
                    }
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.mutedTint)
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                }
                .buttonStyle(SalaryKeypadActionButtonStyle())
                .disabled(recoveryStore.isLoading)

                keypadDigit(0)

                Button {
                    AppHaptics.trigger()
                    if showsFaceIDKey {
                        Task { await authenticateWithFaceID() }
                    } else if !input.isEmpty {
                        input.removeLast()
                        isError = false
                    }
                } label: {
                    Group {
                        if showsFaceIDKey {
                            if isAuthenticatingWithFaceID {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "faceid")
                            }
                        } else {
                            Image(systemName: "delete.left")
                        }
                    }
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(AppTheme.mutedTint)
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(SalaryKeypadActionButtonStyle())
                .disabled(isAuthenticatingWithFaceID)
                .accessibilityLabel(showsFaceIDKey ? "Войти с Face ID" : "Удалить цифру")
                .accessibilityHint(showsFaceIDKey ? "Открывает раздел зарплаты после проверки Face ID" : "")
                .animation(.snappy(duration: 0.2), value: showsFaceIDKey)
            }
        }
    }

    private var canUseFaceID: Bool {
        isFaceIDEnabled
            && isFaceIDAvailable
            && !isCreatingPasscode
            && recoveryStore.phase == .passcode
    }

    private var showsFaceIDKey: Bool {
        canUseFaceID && input.isEmpty
    }

    private func keypadDigit(_ digit: Int) -> some View {
        Button {
            appendDigit(digit)
        } label: {
            Text("\(digit)")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 58)
        }
        .buttonStyle(SalaryKeypadDigitButtonStyle())
        .accessibilityLabel("Цифра \(digit)")
    }

    private func appendDigit(_ digit: Int) {
        guard input.count < SalaryPasscodeSettings.length else { return }
        AppHaptics.trigger()
        isError = false
        input.append(String(digit))

        guard input.count == SalaryPasscodeSettings.length else { return }
        if isCreatingPasscode {
            handleSetupInput()
            return
        }

        if input == passcode {
            onUnlock()
        } else {
            showError()
        }
    }

    private func prepareFaceID() async {
        guard isFaceIDEnabled, !passcode.isEmpty else {
            isFaceIDAvailable = false
            return
        }
        let context = LAContext()
        let isAvailable = SalaryPasscodeSettings.isFaceIDAvailable(using: context)

        isFaceIDAvailable = isAvailable
        guard isAvailable, !hasAttemptedAutomaticFaceID else { return }
        hasAttemptedAutomaticFaceID = true
        await authenticateWithFaceID()
    }

    private func authenticateWithFaceID() async {
        guard canUseFaceID, !isAuthenticatingWithFaceID else { return }
        isAuthenticatingWithFaceID = true
        faceIDErrorMessage = nil
        defer { isAuthenticatingWithFaceID = false }

        let context = LAContext()
        context.localizedFallbackTitle = "Ввести PIN"
        context.localizedCancelTitle = "Отмена"

        do {
            let authenticated = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Открыть сведения о зарплате"
            )
            guard authenticated, !Task.isCancelled else { return }
            AppHaptics.trigger(.success)
            onUnlock()
        } catch let error as LAError {
            guard !Task.isCancelled else { return }
            switch error.code {
            case .userCancel, .systemCancel, .appCancel, .userFallback:
                break
            case .biometryLockout:
                faceIDErrorMessage = "Face ID временно заблокирован. Введите PIN."
            default:
                faceIDErrorMessage = "Не удалось подтвердить Face ID. Введите PIN или повторите."
                AppHaptics.trigger(.error)
            }
        } catch {
            guard !Task.isCancelled else { return }
            faceIDErrorMessage = "Не удалось подтвердить Face ID. Введите PIN или повторите."
            AppHaptics.trigger(.error)
        }
    }

    private func handleSetupInput() {
        if let firstSetupInput {
            if input == firstSetupInput {
                onCreate(input)
            } else {
                showError()
            }
        } else {
            firstSetupInput = input
            input = ""
            AppHaptics.trigger(.expandCollapse)
        }
    }

    private func resetPasscodeInput() {
        input = ""
        firstSetupInput = nil
        isError = false
    }

    private func handleRecoveryCodeChange(_ newValue: String) {
        let normalizedCode = String(newValue.filter(\.isNumber).prefix(6))
        if normalizedCode != newValue {
            recoveryStore.code = normalizedCode
            return
        }
        if normalizedCode.count < 6 {
            lastSubmittedRecoveryCode = ""
        }

        guard recoveryStore.phase == .codeEntry,
              normalizedCode.count == 6,
              normalizedCode != lastSubmittedRecoveryCode,
              !recoveryStore.isLoading else { return }

        lastSubmittedRecoveryCode = normalizedCode
        AppHaptics.trigger()
        Task { await recoveryStore.verifyCode() }
    }

    private func showError() {
        AppHaptics.trigger(.error)
        withAnimation(.easeInOut(duration: 0.16)) {
            isError = true
        }

        Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            input = ""
            withAnimation(.easeInOut(duration: 0.18)) {
                isError = false
            }
        }
    }

    private func dotColor(for index: Int) -> Color {
        if isError {
            return AppTheme.dangerTint
        }
        return index < input.count ? AppTheme.primaryTint : AppTheme.ink.opacity(0.12)
    }
}

private struct SalaryKeypadDigitButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                Circle()
                    .fill(
                        configuration.isPressed
                        ? AppTheme.primaryTint.opacity(0.24)
                        : AppTheme.ink.opacity(0.045)
                    )
                    .overlay {
                        Circle()
                            .stroke(
                                configuration.isPressed
                                ? AppTheme.primaryTint.opacity(0.62)
                                : AppTheme.ink.opacity(0.06),
                                lineWidth: 1
                            )
                    }
                    .frame(width: 58, height: 58)
            }
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.62), value: configuration.isPressed)
    }
}

private struct SalaryKeypadActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                Capsule(style: .continuous)
                    .fill(configuration.isPressed ? AppTheme.ink.opacity(0.09) : .clear)
                    .padding(.horizontal, 8)
            }
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.68), value: configuration.isPressed)
    }
}
