import Foundation

struct AppConfig {
    let wikiAPIOrigin: String?
    let wikiAPIToken: String?
    let lumaWorkAPIOrigin: String?
    let simpleOneAPIOrigin: String?
    let simpleOneWebOrigin: String?
    let appSiteOrigin: String?
    let fuelArchiveOwnerEmail: String?
    let supportEmail: String?
    let telegramAppURL: String?
    let telegramWebURL: String?
    let mapsRouteURL: String?

    init(
        wikiAPIOrigin: String? = AppConfig.resolveWikiAPIOrigin(),
        wikiAPIToken: String? = AppConfig.resolveWikiAPIToken(),
        lumaWorkAPIOrigin: String? = AppConfig.resolveLumaWorkAPIOrigin(),
        simpleOneAPIOrigin: String? = AppConfig.resolveFirst("SIMPLEONE_API_URL", "SIMPLEONE_API_ORIGIN"),
        simpleOneWebOrigin: String? = AppConfig.resolveFirst("SIMPLEONE_WEB_URL", "SIMPLEONE_WEB_ORIGIN"),
        appSiteOrigin: String? = AppConfig.resolveFirst("APP_SITE_URL", "APP_SITE_ORIGIN"),
        fuelArchiveOwnerEmail: String? = AppConfig.resolveFirst("FUEL_ARCHIVE_OWNER_EMAIL"),
        supportEmail: String? = AppConfig.resolveFirst("SUPPORT_EMAIL"),
        telegramAppURL: String? = AppConfig.resolveFirst("TELEGRAM_APP_URL"),
        telegramWebURL: String? = AppConfig.resolveFirst("TELEGRAM_WEB_URL"),
        mapsRouteURL: String? = AppConfig.resolveFirst("MAPS_ROUTE_URL")
    ) {
        self.wikiAPIOrigin = wikiAPIOrigin
        self.wikiAPIToken = wikiAPIToken
        self.lumaWorkAPIOrigin = lumaWorkAPIOrigin
        self.simpleOneAPIOrigin = simpleOneAPIOrigin
        self.simpleOneWebOrigin = simpleOneWebOrigin
        self.appSiteOrigin = appSiteOrigin
        self.fuelArchiveOwnerEmail = fuelArchiveOwnerEmail
        self.supportEmail = supportEmail
        self.telegramAppURL = telegramAppURL
        self.telegramWebURL = telegramWebURL
        self.mapsRouteURL = mapsRouteURL
    }

    private static func resolveWikiAPIOrigin() -> String? {
        resolveFirst("WIKI_API_URL", "WIKI_API_ORIGIN")
    }

    private static func resolveWikiAPIToken() -> String? {
        resolveFirst("WIKI_API_TOKEN")
    }

    private static func resolveLumaWorkAPIOrigin() -> String? {
        resolveFirst("LUMAWORK_API_URL", "LUMAWORK_API_ORIGIN")
    }

    static func configuredURL(_ rawValue: String?) -> URL {
        guard let rawValue,
              let url = URL(string: rawValue),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            return URL(fileURLWithPath: "/")
        }
        return url
    }

    static func resolveFirst(_ keys: String...) -> String? {
        let environment = ProcessInfo.processInfo.environment
        let defaults = UserDefaults.standard

        let candidates = keys.flatMap { key in
            [
                environment[key],
                Bundle.main.object(forInfoDictionaryKey: key) as? String,
                defaults.string(forKey: key)
            ]
        }

        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty && !$0.hasPrefix("$(") })
    }
}
