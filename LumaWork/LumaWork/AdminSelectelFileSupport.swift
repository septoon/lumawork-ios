import Foundation

nonisolated enum AdminSelectelManagedArea: String, CaseIterable, Codable, Identifiable, Sendable {
    case wikiSnapshots
    case wikiUploads
    case engineerReleases
    case publicationMetadata

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wikiSnapshots: "Снимки Wiki"
        case .wikiUploads: "Загрузки Wiki"
        case .engineerReleases: "Релизы приложения"
        case .publicationMetadata: "Публикация SideStore"
        }
    }

    var subtitle: String {
        switch self {
        case .wikiSnapshots: "Состояния базы знаний · только просмотр"
        case .wikiUploads: "Файлы, загруженные в Wiki"
        case .engineerReleases: "IPA-сборки приложения «Инженер»"
        case .publicationMetadata: "Каталог обновлений source.json"
        }
    }

    var systemImage: String {
        switch self {
        case .wikiSnapshots: "clock.arrow.circlepath"
        case .wikiUploads: "tray.and.arrow.up.fill"
        case .engineerReleases: "shippingbox.fill"
        case .publicationMetadata: "doc.badge.gearshape"
        }
    }

    func allows(fileName: String) -> Bool {
        guard Self.isSafeFileName(fileName) else { return false }
        switch self {
        case .wikiSnapshots, .wikiUploads:
            return true
        case .engineerReleases:
            return fileName.range(of: #"^LumaWork-[^/\\]+\.ipa$"#, options: [.regularExpression, .caseInsensitive]) != nil
        case .publicationMetadata:
            return fileName == "source.json"
        }
    }

    private static func isSafeFileName(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
            && !value.contains("\0")
            && value.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 }
    }
}

nonisolated struct AdminEngineerSource: Codable, Hashable, Sendable {
    var name: String
    var subtitle: String
    var description: String
    var iconURL: String
    var website: String
    var apps: [AdminEngineerSourceApp]
    var news: [AdminEngineerSourceNews]

    static let empty = AdminEngineerSource(
        name: "LumaWork",
        subtitle: "Обновления приложения Инженер",
        description: "Источник обновлений LumaWork для SideStore.",
        iconURL: "",
        website: "",
        apps: [.empty],
        news: []
    )

    var validationMessage: String? {
        if name.trimmed.isEmpty { return "Укажите название источника." }
        if !iconURL.isHTTPURL { return "Укажите корректный URL иконки источника." }
        if !website.isHTTPURL { return "Укажите корректный URL сайта." }
        if apps.isEmpty { return "Добавьте хотя бы одно приложение." }

        var bundleIdentifiers = Set<String>()
        for (appIndex, app) in apps.enumerated() {
            let number = appIndex + 1
            if app.name.trimmed.isEmpty { return "Укажите название приложения №\(number)." }
            if app.bundleIdentifier.trimmed.isEmpty { return "Укажите Bundle ID приложения №\(number)." }
            if !bundleIdentifiers.insert(app.bundleIdentifier.trimmed).inserted {
                return "Bundle ID приложений не должны повторяться."
            }
            if app.developerName.trimmed.isEmpty { return "Укажите разработчика приложения №\(number)." }
            if !app.iconURL.isHTTPURL { return "Укажите корректный URL иконки приложения №\(number)." }
            if app.tintColor.trimmed.isEmpty { return "Укажите цвет приложения №\(number)." }
            if app.category.trimmed.isEmpty { return "Укажите категорию приложения №\(number)." }

            var builds = Set<String>()
            for (versionIndex, version) in app.versions.enumerated() {
                let label = "версии №\(versionIndex + 1) приложения №\(number)"
                if version.version.trimmed.isEmpty { return "Укажите номер \(label)." }
                if version.buildVersion.trimmed.isEmpty { return "Укажите номер сборки \(label)." }
                if !builds.insert(version.buildVersion.trimmed).inserted {
                    return "Номера сборок приложения №\(number) не должны повторяться."
                }
                if version.date.trimmed.isEmpty { return "Укажите дату \(label)." }
                if !version.downloadURL.isHTTPURL { return "Укажите корректный URL IPA для \(label)." }
                if version.size < 0 { return "Размер IPA для \(label) не может быть отрицательным." }
                if version.minOSVersion.trimmed.isEmpty { return "Укажите минимальную iOS для \(label)." }
            }

            if app.appPermissions.privacy.contains(where: { $0.key.trimmed.isEmpty || $0.value.trimmed.isEmpty }) {
                return "Ключи и описания Privacy должны быть заполнены."
            }
            if app.appPermissions.entitlements.contains(where: { $0.trimmed.isEmpty }) {
                return "Entitlements не должны содержать пустые строки."
            }
        }

        var newsIdentifiers = Set<String>()
        for item in news {
            if item.title.trimmed.isEmpty { return "Укажите заголовок новости." }
            if item.identifier.trimmed.isEmpty { return "Укажите идентификатор новости." }
            if !newsIdentifiers.insert(item.identifier.trimmed).inserted {
                return "Идентификаторы новостей не должны повторяться."
            }
            if !item.imageURL.trimmed.isEmpty, !item.imageURL.isHTTPURL {
                return "Укажите корректный URL изображения новости."
            }
            if !item.url.trimmed.isEmpty, !item.url.isHTTPURL {
                return "Укажите корректную ссылку новости."
            }
        }
        return nil
    }
}

nonisolated struct AdminEngineerSourceApp: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var bundleIdentifier: String
    var developerName: String
    var subtitle: String
    var localizedDescription: String
    var iconURL: String
    var tintColor: String
    var category: String
    var versions: [AdminEngineerSourceVersion]
    var appPermissions: AdminEngineerSourcePermissions

    static let empty = AdminEngineerSourceApp(
        name: "Инженер",
        bundleIdentifier: "septon.LumaWork",
        developerName: "LumaWork",
        subtitle: "Рабочее приложение инженера",
        localizedDescription: "Рабочее приложение инженера LumaWork.",
        iconURL: "",
        tintColor: "#2474FF",
        category: "utilities",
        versions: [],
        appPermissions: .empty
    )

    private enum CodingKeys: String, CodingKey {
        case name, bundleIdentifier, developerName, subtitle, localizedDescription
        case iconURL, tintColor, category, versions, appPermissions
    }
}

nonisolated struct AdminEngineerSourceVersion: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var version: String
    var buildVersion: String
    var date: String
    var localizedDescription: String
    var downloadURL: String
    var size: Int64
    var minOSVersion: String

    static let empty = AdminEngineerSourceVersion(
        version: "",
        buildVersion: "",
        date: ISO8601DateFormatter().string(from: Date()),
        localizedDescription: "",
        downloadURL: "",
        size: 0,
        minOSVersion: "26.2"
    )

    private enum CodingKeys: String, CodingKey {
        case version, buildVersion, date, localizedDescription, downloadURL, size, minOSVersion
    }
}

nonisolated struct AdminEngineerSourcePermissions: Codable, Hashable, Sendable {
    var entitlements: [String]
    var privacy: [String: String]

    static let empty = AdminEngineerSourcePermissions(entitlements: [], privacy: [:])
}

nonisolated struct AdminEngineerSourceNews: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var title: String
    var identifier: String
    var caption: String
    var date: String
    var tintColor: String
    var imageURL: String
    var appID: String
    var notify: Bool
    var url: String

    static let empty = AdminEngineerSourceNews(
        title: "",
        identifier: UUID().uuidString.lowercased(),
        caption: "",
        date: ISO8601DateFormatter().string(from: Date()),
        tintColor: "#2474FF",
        imageURL: "",
        appID: "",
        notify: false,
        url: ""
    )

    private enum CodingKeys: String, CodingKey {
        case title, identifier, caption, date, tintColor, imageURL, appID, notify, url
    }

    init(
        title: String,
        identifier: String,
        caption: String,
        date: String,
        tintColor: String,
        imageURL: String,
        appID: String,
        notify: Bool,
        url: String
    ) {
        self.title = title
        self.identifier = identifier
        self.caption = caption
        self.date = date
        self.tintColor = tintColor
        self.imageURL = imageURL
        self.appID = appID
        self.notify = notify
        self.url = url
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
        identifier = try values.decodeIfPresent(String.self, forKey: .identifier) ?? UUID().uuidString.lowercased()
        caption = try values.decodeIfPresent(String.self, forKey: .caption) ?? ""
        date = try values.decodeIfPresent(String.self, forKey: .date) ?? ISO8601DateFormatter().string(from: Date())
        tintColor = try values.decodeIfPresent(String.self, forKey: .tintColor) ?? "#2474FF"
        imageURL = try values.decodeIfPresent(String.self, forKey: .imageURL) ?? ""
        appID = try values.decodeIfPresent(String.self, forKey: .appID) ?? ""
        notify = try values.decodeIfPresent(Bool.self, forKey: .notify) ?? false
        url = try values.decodeIfPresent(String.self, forKey: .url) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(title, forKey: .title)
        try values.encode(identifier, forKey: .identifier)
        try values.encode(caption, forKey: .caption)
        try values.encode(date, forKey: .date)
        try values.encode(tintColor, forKey: .tintColor)
        if !imageURL.trimmed.isEmpty { try values.encode(imageURL, forKey: .imageURL) }
        if !appID.trimmed.isEmpty { try values.encode(appID, forKey: .appID) }
        try values.encode(notify, forKey: .notify)
        if !url.trimmed.isEmpty { try values.encode(url, forKey: .url) }
    }
}

nonisolated struct AdminEngineerSourcePrivacyEntry: Identifiable, Hashable, Sendable {
    var id = UUID()
    var key: String
    var value: String
}

nonisolated extension JSONEncoder {
    static var engineerSource: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

nonisolated private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    var isHTTPURL: Bool {
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "https" || scheme == "http") && url.host != nil
    }
}
