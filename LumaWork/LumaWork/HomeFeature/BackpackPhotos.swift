import CryptoKit
import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class BackpackPhotoStore {
    private(set) var images: [String: UIImage] = [:]
    private var terminalCatalog = BackpackTerminalPhotoCatalog.fallbackPhotos
    private var decodedImages: [URL: (data: Data, image: UIImage)] = [:]

    func image(for item: BackpackItem) -> UIImage? {
        images[item.id]
    }

    func image(for item: OfficeEquipmentItem) -> UIImage? {
        images[item.id]
    }

    func modelCount(for items: [BackpackItem]) -> Int {
        Set(items.map { item in
            BackpackTerminalPhotoCatalog.match(for: item.name, in: terminalCatalog)?.referenceName ?? item.name
        }).count
    }

    func load(for items: [BackpackItem]) async {
        await load(
            for: items.map { ($0.id, [$0.name]) },
            endpoint: "backpack-terminals",
            manifestStore: .backpackTerminals,
            fallback: BackpackTerminalPhotoCatalog.fallbackPhotos,
            updatesTerminalCatalog: true
        )
    }

    func load(for items: [OfficeEquipmentItem]) async {
        await load(
            for: items.map { ($0.id, $0.photoCandidateNames) },
            endpoint: "equipment",
            manifestStore: .officeEquipment,
            fallback: [],
            updatesTerminalCatalog: false
        )
    }

    private func load(
        for items: [(id: String, names: [String])],
        endpoint: String,
        manifestStore: BackpackTerminalPhotoManifestStore,
        fallback: [BackpackTerminalPhoto],
        updatesTerminalCatalog: Bool
    ) async {
        let origin = AppConfig.configuredURL(AppConfig().lumaWorkAPIOrigin)
        let manifestURL = origin
            .appendingPathComponent("api", isDirectory: true)
            .appendingPathComponent("v2", isDirectory: true)
            .appendingPathComponent("media", isDirectory: true)
            .appendingPathComponent(endpoint)
        let cachedCatalog = await manifestStore.cachedPhotos(
            relativeTo: origin,
            fallback: fallback
        )
        await loadImages(for: items, catalog: cachedCatalog, updatesTerminalCatalog: updatesTerminalCatalog)

        guard let refreshedCatalog = await manifestStore.refreshPhotos(
            from: manifestURL,
            relativeTo: origin
        ),
              !Task.isCancelled,
              refreshedCatalog != cachedCatalog
        else { return }
        await loadImages(for: items, catalog: refreshedCatalog, updatesTerminalCatalog: updatesTerminalCatalog)
    }

    private func loadImages(
        for items: [(id: String, names: [String])],
        catalog: [BackpackTerminalPhoto],
        updatesTerminalCatalog: Bool
    ) async {
        guard !Task.isCancelled else { return }
        if updatesTerminalCatalog {
            terminalCatalog = catalog
        }
        let matches = items.compactMap { item -> (String, BackpackTerminalPhoto)? in
            guard let photo = BackpackTerminalPhotoCatalog.match(for: item.names, in: catalog) else { return nil }
            return (item.id, photo)
        }
        let urls = Set(matches.compactMap { $0.1.url })

        let loadedData = await withTaskGroup(of: (URL, Data?).self) { group in
            for url in urls {
                group.addTask {
                    (url, await BackpackPhotoDiskCache.shared.data(for: url))
                }
            }

            var result: [URL: Data] = [:]
            for await (url, data) in group {
                if let data {
                    result[url] = data
                }
            }
            return result
        }

        guard !Task.isCancelled else { return }
        var currentImages: [URL: (data: Data, image: UIImage)] = [:]
        for (url, data) in loadedData {
            if let cached = decodedImages[url], cached.data == data {
                currentImages[url] = cached
            } else if let image = UIImage(data: data) {
                currentImages[url] = (data, image)
            }
        }
        decodedImages = currentImages
        var updatedImages: [String: UIImage] = [:]
        for (itemID, photo) in matches {
            guard let url = photo.url else { continue }
            if let cached = currentImages[url] {
                updatedImages[itemID] = cached.image
            } else if let currentImage = images[itemID] {
                updatedImages[itemID] = currentImage
            }
        }
        images = updatedImages
    }
}

nonisolated private struct BackpackTerminalPhoto: Hashable, Sendable {
    let referenceName: String
    let aliases: [String]
    let url: URL?
}

private enum BackpackTerminalPhotoCatalog {
    static let fallbackPhotos: [BackpackTerminalPhoto] = [
        photo("Стационарный Unitodi MF960 AL", file: "unitodi-mf960-stationary.webp"),
        photo(
            "Переносной Unitodi MF 960",
            file: "unitodi-mf960-portable.webp",
            aliases: ["Переносной POS-терминал MoreFun UniTodi 960 AL"]
        ),
        photo("Внешняя PIN-клавиатура MoreFun Vanstone (Aisino) UniTodi V10", file: "unitodi-v10.webp"),
        photo("AISINO V73", file: "aisino-v73.webp"),
        photo("Feitian F20", file: "feitian-f20.webp"),
        photo("PAX AF6", file: "pax-af6.webp"),
        photo("Pax D190", file: "pax-d190.webp"),
        photo("Pax D200", file: "pax-d200.webp"),
        photo("Pax D230", file: "pax-d230.webp"),
        photo("Pax D270", file: "pax-d270.webp"),
        photo("Pax Q25", file: "pax-q25.webp"),
        photo("Pax S200", file: "pax-s200.webp"),
        photo("PAX S210", file: "pax-s210.webp"),
        photo("Pax S300", file: "pax-s300.webp"),
        photo("Pax S920", file: "pax-s920.webp"),
        photo(
            "UniTodi P8",
            file: "unitodi-p8.webp",
            aliases: ["Интеллектуальный PIN-PAD Telepower UniTodi P8Bio"]
        )
    ]

    static func match(
        for itemName: String,
        in photos: [BackpackTerminalPhoto]
    ) -> BackpackTerminalPhoto? {
        let normalizedItemName = normalizedName(itemName)
        if let exactMatch = photos.first(where: { photo in
            ([photo.referenceName] + photo.aliases).contains { normalizedName($0) == normalizedItemName }
        }) {
            return exactMatch
        }

        let itemFingerprint = TerminalNameFingerprint(itemName)
        return photos
            .compactMap { photo -> (BackpackTerminalPhoto, Int)? in
                let referenceFingerprint = TerminalNameFingerprint(photo.referenceName)
                guard let score = itemFingerprint.matchScore(with: referenceFingerprint) else { return nil }
                return (photo, score)
            }
            .max { lhs, rhs in lhs.1 < rhs.1 }?
            .0
    }

    static func match(
        for candidateNames: [String],
        in photos: [BackpackTerminalPhoto]
    ) -> BackpackTerminalPhoto? {
        for name in candidateNames {
            if let match = match(for: name, in: photos) { return match }
        }
        return nil
    }

    private static func photo(
        _ referenceName: String,
        file: String,
        aliases: [String] = []
    ) -> BackpackTerminalPhoto {
        let root = AppConfig.configuredURL(AppConfig().lumaWorkAPIOrigin)
            .appendingPathComponent("uploads", isDirectory: true)
            .appendingPathComponent("vehicle-images", isDirectory: true)
            .appendingPathComponent("backpack-terminals", isDirectory: true)
        let url = root
            .appendingPathComponent(file)
            .appending(queryItems: [URLQueryItem(name: "v", value: "20260716")])
        return BackpackTerminalPhoto(referenceName: referenceName, aliases: aliases, url: url)
    }

    private static func normalizedName(_ raw: String) -> String {
        raw
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: AppLocale.russian)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

nonisolated private struct BackpackTerminalPhotoManifest: Decodable, Sendable {
    let version: Int64?
    let items: [Item]

    struct Item: Decodable, Sendable {
        let id: String
        let referenceName: String
        let aliases: [String]
        let fileName: String?
        let url: String?
        let imageUrl: String?
        let revision: Int64?

        private enum CodingKeys: String, CodingKey {
            case id
            case referenceName
            case aliases
            case fileName
            case url
            case imageUrl
            case revision
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            referenceName = try container.decode(String.self, forKey: .referenceName)
            id = try container.decodeIfPresent(String.self, forKey: .id) ?? referenceName
            aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
            fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
            url = try container.decodeIfPresent(String.self, forKey: .url)
            imageUrl = try container.decodeIfPresent(String.self, forKey: .imageUrl)
            revision = try container.decodeIfPresent(Int64.self, forKey: .revision)
        }

        func photo(relativeTo origin: URL) -> BackpackTerminalPhoto? {
            let name = referenceName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }

            let rawURL = (url ?? imageUrl)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedURL: URL?
            if let rawURL, !rawURL.isEmpty {
                resolvedURL = URL(string: rawURL, relativeTo: origin)?.absoluteURL
            } else if let fileName, !fileName.isEmpty {
                let imageURL = origin
                    .appendingPathComponent("uploads", isDirectory: true)
                    .appendingPathComponent("vehicle-images", isDirectory: true)
                    .appendingPathComponent("backpack-terminals", isDirectory: true)
                    .appendingPathComponent(fileName)
                if let revision {
                    resolvedURL = imageURL.appending(queryItems: [URLQueryItem(name: "v", value: String(revision))])
                } else {
                    resolvedURL = imageURL
                }
            } else {
                resolvedURL = nil
            }

            return BackpackTerminalPhoto(referenceName: name, aliases: aliases, url: resolvedURL)
        }
    }
}

private actor BackpackTerminalPhotoManifestStore {
    static let backpackTerminals = BackpackTerminalPhotoManifestStore(cacheName: "BackpackTerminalPhotos")
    static let officeEquipment = BackpackTerminalPhotoManifestStore(cacheName: "OfficeEquipmentPhotos")

    private let persistedManifestURL: URL
    private var persistedPhotos: [BackpackTerminalPhoto]?

    init(cacheName: String) {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = applicationSupport
            .appendingPathComponent("LumaWork", isDirectory: true)
            .appendingPathComponent(cacheName, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        persistedManifestURL = directory.appendingPathComponent("manifest.json")
    }

    func cachedPhotos(
        relativeTo origin: URL,
        fallback: [BackpackTerminalPhoto]
    ) -> [BackpackTerminalPhoto] {
        if let persistedPhotos {
            return persistedPhotos
        }
        guard let data = try? Data(contentsOf: persistedManifestURL),
              let photos = decodePhotos(from: data, relativeTo: origin)
        else {
            return fallback
        }
        persistedPhotos = photos
        return photos
    }

    func refreshPhotos(from manifestURL: URL, relativeTo origin: URL) async -> [BackpackTerminalPhoto]? {
        do {
            var request = URLRequest(url: manifestURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            try Task.checkCancellation()
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let photos = decodePhotos(from: data, relativeTo: origin)
            else { return nil }

            try? data.write(to: persistedManifestURL, options: .atomic)
            persistedPhotos = photos
            return photos
        } catch {
            return nil
        }
    }

    private func decodePhotos(
        from data: Data,
        relativeTo origin: URL
    ) -> [BackpackTerminalPhoto]? {
        guard let manifest = try? JSONDecoder().decode(BackpackTerminalPhotoManifest.self, from: data) else {
            return nil
        }
        return manifest.items.compactMap { $0.photo(relativeTo: origin) }
    }
}

private struct TerminalNameFingerprint {
    private static let brands: Set<String> = ["aisino", "feitian", "morefun", "pax", "unitodi", "vanstone"]
    private static let variants: Set<String> = ["внешняя", "переносной", "стационарный"]

    let terms: Set<String>
    let brandTerms: Set<String>
    let modelTerms: Set<String>
    let variantTerms: Set<String>

    init(_ raw: String) {
        let folded = raw
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: AppLocale.russian)
            .lowercased()
        let tokens = folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        var models = Set(tokens.filter { token in
            token.contains(where: \.isLetter) && token.contains(where: \.isNumber)
        })
        for index in tokens.indices.dropLast() {
            let prefix = tokens[index]
            let suffix = tokens[tokens.index(after: index)]
            if prefix.allSatisfy(\.isLetter), prefix.count <= 3, suffix.allSatisfy(\.isNumber) {
                models.insert(prefix + suffix)
            }
        }

        let tokenSet = Set(tokens)
        terms = tokenSet
        brandTerms = tokenSet.intersection(Self.brands)
        modelTerms = models
        variantTerms = tokenSet.intersection(Self.variants)
    }

    func matchScore(with reference: TerminalNameFingerprint) -> Int? {
        let matchingModels = modelTerms.intersection(reference.modelTerms)
        guard !matchingModels.isEmpty else { return nil }

        let brandScore = brandTerms.intersection(reference.brandTerms).count * 30
        let modelScore = matchingModels.count * 100
        let variantScore = variantTerms.intersection(reference.variantTerms).count * 25
        let termScore = terms.intersection(reference.terms).count * 2
        return modelScore + brandScore + variantScore + termScore
    }
}

private actor BackpackPhotoDiskCache {
    static let shared = BackpackPhotoDiskCache()

    private var memory: [URL: Data] = [:]
    private let directory: URL

    init() {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        directory = root.appendingPathComponent("LumaWork/BackpackTerminalImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func data(for url: URL) async -> Data? {
        if let cached = memory[url] {
            return cached
        }

        let fileURL = directory.appendingPathComponent(cacheKey(url))
        if let data = try? Data(contentsOf: fileURL), UIImage(data: data) != nil {
            memory[url] = data
            return data
        }

        do {
            var request = URLRequest(url: url)
            // Valid images already live in our memory/disk cache. Do not reuse
            // URLCache failures (for example a 404 cached before a photo was published).
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, UIImage(data: data) != nil else {
                return nil
            }
            try Task.checkCancellation()
            try? data.write(to: fileURL, options: .atomic)
            memory[url] = data
            return data
        } catch {
            return nil
        }
    }

    private func cacheKey(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined() + ".image"
    }
}
