//
//  LumaWorkApp.swift
//  LumaWork
//
//  LumaWork application entry point.
//

import SwiftUI
import UIKit

@MainActor
final class LumaWorkSceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let shortcutItem = connectionOptions.shortcutItem else { return }
        _ = handle(shortcutItem)
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(handle(shortcutItem))
    }

    private func handle(_ shortcutItem: UIApplicationShortcutItem) -> Bool {
        guard let route = AppRoute(quickActionType: shortcutItem.type) else { return false }
        AppNavigationRouter.shared.open(route)
        return true
    }
}

final class LumaWorkAppDelegate: NSObject, UIApplicationDelegate {
    private var ftpBackgroundEventsCompletionHandler: (() -> Void)?

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = LumaWorkSceneDelegate.self
        return configuration
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == FTPBackgroundDownloadManager.sessionIdentifier else {
            completionHandler()
            return
        }
        ftpBackgroundEventsCompletionHandler = completionHandler
        FTPBackgroundDownloadManager.shared.reconnectBackgroundSession()
    }

    @discardableResult
    func finishFTPBackgroundEvents() -> Bool {
        guard let completionHandler = ftpBackgroundEventsCompletionHandler else {
            return false
        }
        ftpBackgroundEventsCompletionHandler = nil
        completionHandler()
        return true
    }
}

@main
struct LumaWorkApp: App {
    @UIApplicationDelegateAdaptor(LumaWorkAppDelegate.self) private var appDelegate
    @AppStorage(AppAppearanceMode.storageKey) private var appearanceModeRawValue = AppAppearanceMode.system.rawValue

    init() {
        UserDefaults.standard.set(["ru"], forKey: "AppleLanguages")
        UserDefaults.standard.set("ru_RU", forKey: "AppleLocale")
        AppTheme.configureNavigationBarAppearance()
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(\.locale, AppLocale.russian)
                .preferredColorScheme(AppAppearanceMode(rawValue: appearanceModeRawValue)?.colorScheme)
        }
        .backgroundTask(.appRefresh(RequestNotificationsBackgroundRefresh.taskIdentifier)) {
            await RequestNotificationsBackgroundRefresh.perform()
        }
    }

}
