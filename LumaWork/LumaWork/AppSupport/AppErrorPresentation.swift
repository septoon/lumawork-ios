import Foundation
import Observation
import SwiftUI

enum AppNetworkBannerKind: String, Hashable, Sendable {
    case networkUnavailable
    case connectionLost
    case serverUnavailable
    case cannotConnectToServer

    var message: String {
        switch self {
        case .networkUnavailable:
            return "Нет подключения к интернету"
        case .connectionLost:
            return "Соединение прервано"
        case .serverUnavailable:
            return "Сервер не отвечает"
        case .cannotConnectToServer:
            return "Не удалось подключиться к серверу"
        }
    }
}

enum AppGlobalBannerStyle: String, Hashable, Sendable {
    case success
    case information
    case error

    var systemImage: String {
        switch self {
        case .success:
            "checkmark.circle.fill"
        case .information:
            "info.circle.fill"
        case .error:
            "exclamationmark.triangle.fill"
        }
    }
}

struct AppGlobalBanner: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let style: AppGlobalBannerStyle
    let actionTitle: String?
}

@MainActor
@Observable
final class AppBannerCenter {
    static let shared = AppBannerCenter()

    private(set) var banner: AppGlobalBanner?
    private(set) var isVisible = false

    private var lastShownAt: [String: Date] = [:]
    private var lifecycleTask: Task<Void, Never>?
    @ObservationIgnored private var bannerAction: (() -> Void)?
    private let duplicateCooldown: TimeInterval = 3

    func show(_ kind: AppNetworkBannerKind) {
        show(kind.message, style: .error)
    }

    func show(
        _ message: String,
        style: AppGlobalBannerStyle,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMessage.isEmpty else { return }
        let trimmedActionTitle = actionTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedActionTitle = trimmedActionTitle?.isEmpty == false ? trimmedActionTitle : nil

        let duplicateKey = "\(style.rawValue)|\(normalizedMessage)|\(normalizedActionTitle ?? "")"
        let now = Date()
        if banner?.message == normalizedMessage,
           banner?.style == style,
           banner?.actionTitle == normalizedActionTitle {
            return
        }
        if let lastShown = lastShownAt[duplicateKey], now.timeIntervalSince(lastShown) < duplicateCooldown {
            return
        }

        lastShownAt[duplicateKey] = now
        let nextBanner = AppGlobalBanner(
            message: normalizedMessage,
            style: style,
            actionTitle: normalizedActionTitle
        )
        lifecycleTask?.cancel()
        bannerAction = normalizedActionTitle == nil ? nil : action
        banner = nextBanner
        isVisible = false

        lifecycleTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await Task.yield()
            guard !Task.isCancelled, banner?.id == nextBanner.id else { return }

            isVisible = true
            switch style {
            case .success:
                AppHaptics.trigger(.success)
            case .information:
                AppHaptics.trigger()
            case .error:
                AppHaptics.trigger(.error)
            }

            do {
                try await Task.sleep(for: .milliseconds(normalizedActionTitle == nil ? 2_200 : 5_000))
            } catch {
                return
            }
            guard !Task.isCancelled, banner?.id == nextBanner.id else { return }

            isVisible = false
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            guard !Task.isCancelled, banner?.id == nextBanner.id else { return }
            banner = nil
            bannerAction = nil
        }
    }

    func performAction() {
        guard let action = bannerAction else { return }
        lifecycleTask?.cancel()
        bannerAction = nil
        isVisible = false
        banner = nil
        AppHaptics.trigger()
        action()
    }
}

enum AppErrorPresentation {
    enum Classification {
        case cancellation
        case network(AppNetworkBannerKind)
        case domain
    }

    nonisolated static func classification(for error: Error) -> Classification {
        if error is CancellationError {
            return .cancellation
        }

        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSUserCancelledError {
            return .cancellation
        }
        if nsError.domain == NSURLErrorDomain {
            return classification(forURLCode: URLError.Code(rawValue: nsError.code))
        }

        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            let underlyingClassification = classification(for: underlyingError)
            if case .domain = underlyingClassification {
                // Keep checking the outer error.
            } else {
                return underlyingClassification
            }
        }

        return classification(forMessage: nsError.localizedDescription)
    }

    nonisolated static func classification(forMessage message: String) -> Classification {
        let normalized = normalizedMessage(message)
        guard !normalized.isEmpty else { return .domain }

        let cancellationFragments = [
            "отменено",
            "операция отменена",
            "cancelled",
            "canceled",
            "request was cancelled",
            "request was canceled",
            "nsurlerrorcancelled",
            "nsurlerrordomain code=-999",
            "код -999"
        ]
        if cancellationFragments.contains(where: normalized.contains) {
            return .cancellation
        }

        let timeoutFragments = [
            "timed out",
            "timeout",
            "превышено время ожидания",
            "не ответил вовремя",
            "сервер не отвечает",
            "http 408",
            "http 502",
            "http 503",
            "http 504",
            "(408)",
            "(502)",
            "(503)",
            "(504)"
        ]
        if timeoutFragments.contains(where: normalized.contains) {
            return .network(.serverUnavailable)
        }

        let lostConnectionFragments = [
            "network connection was lost",
            "соединение с интернетом прервано",
            "соединение прервано",
            "потеряно соединение"
        ]
        if lostConnectionFragments.contains(where: normalized.contains) {
            return .network(.connectionLost)
        }

        let noInternetFragments = [
            "internet connection appears to be offline",
            "not connected to the internet",
            "интернет-соединение отсутствует",
            "нет подключения к интернету",
            "сети нет"
        ]
        if noInternetFragments.contains(where: normalized.contains) {
            return .network(.networkUnavailable)
        }

        let cannotConnectFragments = [
            "cannot connect to host",
            "cannot find host",
            "dns lookup failed",
            "не удалось подключиться",
            "не удалось найти сервер",
            "сервер недоступен",
            "проблема с подключением",
            "ошибка сети"
        ]
        if cannotConnectFragments.contains(where: normalized.contains) {
            return .network(.cannotConnectToServer)
        }

        return .domain
    }

    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if case .cancellation = classification(for: error) {
            return true
        }
        return false
    }

    nonisolated static func isDomainMessage(_ message: String) -> Bool {
        if case .domain = classification(forMessage: message) {
            return true
        }
        return false
    }

    @MainActor
    static func userMessage(
        for error: Error,
        fallback: String? = nil,
        showsNetworkBanner: Bool = true
    ) -> String? {
        guard !Task.isCancelled else { return nil }
        switch classification(for: error) {
        case .cancellation:
            return nil
        case .network(let kind):
            if showsNetworkBanner {
                AppBannerCenter.shared.show(kind)
            }
            return nil
        case .domain:
            return fallback ?? sanitizedDomainMessage(error)
        }
    }

    @MainActor
    static func presentIfNeeded(
        message: String
    ) {
        if case .network(let kind) = classification(forMessage: message) {
            AppBannerCenter.shared.show(kind)
        }
    }

    private nonisolated static func classification(forURLCode code: URLError.Code) -> Classification {
        switch code {
        case .cancelled, .userCancelledAuthentication:
            return .cancellation
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            return .network(.networkUnavailable)
        case .networkConnectionLost, .backgroundSessionWasDisconnected:
            return .network(.connectionLost)
        case .timedOut,
             .badServerResponse,
             .cannotLoadFromNetwork,
             .httpTooManyRedirects,
             .redirectToNonExistentLocation,
             .zeroByteResource:
            return .network(.serverUnavailable)
        case .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .resourceUnavailable,
             .secureConnectionFailed,
             .serverCertificateHasBadDate,
             .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid:
            return .network(.cannotConnectToServer)
        default:
            return .domain
        }
    }

    private nonisolated static func normalizedMessage(_ message: String) -> String {
        message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ru_RU"))
            .lowercased()
    }

    private nonisolated static func sanitizedDomainMessage(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return "Не удалось выполнить сетевой запрос."
        }

        guard let localizedError = error as? LocalizedError,
              let message = localizedError.errorDescription else {
            return "Не удалось выполнить операцию."
        }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Не удалось выполнить операцию." }

        let normalized = trimmed.lowercased()
        if normalized.contains("nsurlerrordomain") || normalized.contains("error domain=") {
            return "Не удалось выполнить операцию."
        }
        return trimmed
    }
}

@MainActor
func appUserFacingErrorMessage(
    _ error: Error,
    fallback: String? = nil,
    showsNetworkBanner: Bool = true
) -> String? {
    AppErrorPresentation.userMessage(
        for: error,
        fallback: fallback,
        showsNetworkBanner: showsNetworkBanner
    )
}

struct AppGlobalBannerHost: View {
    @Bindable var center: AppBannerCenter

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let banner = center.banner {
                HStack(spacing: 10) {
                    Image(systemName: banner.style.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .accessibilityHidden(true)

                    Text(banner.message)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let actionTitle = banner.actionTitle {
                        Button(actionTitle) {
                            center.performAction()
                        }
                        .font(.subheadline.weight(.bold))
                        .buttonStyle(.plain)
                        .padding(.leading, 4)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(backgroundStyle(for: banner.style))
                }
                .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
                .offset(y: reduceMotion || center.isVisible ? 0 : 140)
                .opacity(center.isVisible ? 1 : 0)
                .animation(
                    center.isVisible ? presentationAnimation : dismissalAnimation,
                    value: center.isVisible
                )
                .accessibilityElement(children: .contain)
                .allowsHitTesting(banner.actionTitle != nil)
            }
        }
        .padding(.horizontal, 16)
        .safeAreaPadding(.bottom, 8)
        .allowsHitTesting(center.banner?.actionTitle != nil)
    }

    private var presentationAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.16)
            : .spring(duration: 0.30, bounce: 0.08)
    }

    private var dismissalAnimation: Animation {
        reduceMotion
            ? .easeIn(duration: 0.16)
            : .easeIn(duration: 0.25)
    }

    private func backgroundStyle(for style: AppGlobalBannerStyle) -> AnyShapeStyle {
        switch style {
        case .success:
            AnyShapeStyle(AppTheme.accentGradient)
        case .information:
            AnyShapeStyle(AppTheme.secondaryTint)
        case .error:
            AnyShapeStyle(AppTheme.dangerTint)
        }
    }

}
