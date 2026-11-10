import Foundation
import Observation
import SwiftUI

// MARK: - Catalog models

enum AdminApplicationPlatform: String, Codable, CaseIterable, Identifiable, Sendable {
    case ios, android

    var id: String { rawValue }
    var title: String { self == .ios ? "iOS" : "Android" }
    var packageType: String { self == .ios ? "IPA" : "APK" }
}

struct AdminApplicationRelease: Codable, Hashable, Identifiable, Sendable {
    let platform: AdminApplicationPlatform
    let version: String
    let build: String
    let publishedAt: Date?
    let notes: String
    let downloadURL: URL?
    let sizeBytes: Int64?
    let minimumSystem: String?
    let checksum: String?

    var id: String { "\(platform.rawValue)-\(version)-\(build)" }
}

struct AdminApplicationCatalog: Codable, Sendable {
    let platform: AdminApplicationPlatform
    let releases: [AdminApplicationRelease]
    let checkedAt: Date
    var latest: AdminApplicationRelease? { releases.first }
}

enum AdminApplicationCatalogParser {
    enum CatalogError: LocalizedError {
        case invalidCatalog
        var errorDescription: String? { "Источник обновлений не содержит корректных данных приложения." }
    }

    static func ios(_ data: Data) throws -> [AdminApplicationRelease] {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let apps = root?["apps"] as? [[String: Any]] ?? []
        guard let app = apps.first(where: { $0["bundleIdentifier"] as? String == "septon.LumaWork" }),
              let rawVersions = app["versions"] as? [[String: Any]] else {
            throw CatalogError.invalidCatalog
        }
        let releases = unique(rawVersions.compactMap { release($0, platform: .ios) })
        guard !releases.isEmpty else { throw CatalogError.invalidCatalog }
        return releases
    }

    static func android(latest: Data, history: Data?, cachedHistory: [AdminApplicationRelease] = []) throws -> [AdminApplicationRelease] {
        guard let raw = try JSONSerialization.jsonObject(with: latest) as? [String: Any],
              raw["applicationId"] as? String == "ru.lumastack.lumawork",
              let current = release(raw, platform: .android) else {
            throw CatalogError.invalidCatalog
        }
        guard let history else { return unique([current] + cachedHistory) }
        guard let rawHistory = try JSONSerialization.jsonObject(with: history) as? [[String: Any]] else {
            throw CatalogError.invalidCatalog
        }
        return unique([current] + rawHistory.compactMap { raw in
            guard raw["applicationId"] as? String == "ru.lumastack.lumawork" else { return nil }
            return release(raw, platform: .android)
        })
    }

    private static func release(_ raw: [String: Any], platform: AdminApplicationPlatform) -> AdminApplicationRelease? {
        let isIOS = platform == .ios
        guard let version = text(raw[isIOS ? "version" : "versionName"]), !version.isEmpty else { return nil }
        let build = text(raw[isIOS ? "buildVersion" : "versionCode"]) ?? ""
        let notes = isIOS
            ? (raw["localizedDescription"] as? String ?? "")
            : ((raw["changelog"] as? [String])?.joined(separator: "\n") ?? raw["changelog"] as? String ?? "")
        let minimum = isIOS ? text(raw["minOSVersion"]).map { "iOS \($0)+" } : text(raw["minSdk"]).map { "API \($0)+" }
        return AdminApplicationRelease(
            platform: platform, version: version, build: build,
            publishedAt: text(raw[isIOS ? "date" : "publishedAt"]).flatMap(date),
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            downloadURL: text(raw[isIOS ? "downloadURL" : "downloadUrl"]).flatMap(httpsURL),
            sizeBytes: text(raw["size"]).flatMap(Int64.init).flatMap { $0 > 0 ? $0 : nil },
            minimumSystem: minimum,
            checksum: text(raw["sha256"])
        )
    }

    private static func unique(_ releases: [AdminApplicationRelease]) -> [AdminApplicationRelease] {
        var seen: Set<String> = []
        return releases.filter { seen.insert($0.id).inserted }
    }

    private static func text(_ raw: Any?) -> String? {
        if let value = raw as? String { return value }
        return (raw as? NSNumber)?.stringValue
    }

    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func httpsURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
}

// MARK: - Catalog loading

@MainActor
@Observable
private final class AdminApplicationStore {
    var catalogs: [AdminApplicationPlatform: AdminApplicationCatalog] = [:]
    var errors: [AdminApplicationPlatform: String] = [:]
    var isLoading = false
    private var hasLoaded = false
    private let cacheKey = "admin-application-catalog"
    private static let origin = URL(string: "https://app.lumastack.ru")!

    init() {
        if let snapshot = AppOfflineSnapshotStore.load([AdminApplicationCatalog].self, key: cacheKey) {
            catalogs = Dictionary(snapshot.value.map { ($0.platform, $0) }, uniquingKeysWith: { _, latest in latest })
        }
    }

    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await refresh()
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        async let ios = fetch(.ios)
        async let android = fetch(.android)
        let results = await (ios, android)
        for catalog in [results.0, results.1].compactMap({ $0 }) { catalogs[catalog.platform] = catalog }
        if !catalogs.isEmpty { AppOfflineSnapshotStore.save(Array(catalogs.values), key: cacheKey) }
    }

    private func fetch(_ platform: AdminApplicationPlatform) async -> AdminApplicationCatalog? {
        errors[platform] = nil
        do {
            let releases: [AdminApplicationRelease]
            switch platform {
            case .ios:
                releases = try await AdminApplicationCatalogParser.ios(download("source.json"))
            case .android:
                async let latest = download("android/latest.json")
                async let history = download("android/history.json")
                let latestData = try await latest
                let historyData = try? await history
                let cachedHistory = catalogs[platform]?.releases ?? []
                let historyWarning = cachedHistory.isEmpty
                    ? "Актуальная версия загружена, история Android временно недоступна."
                    : "Актуальная версия загружена. История Android временно недоступна; показаны сохранённые релизы."
                do {
                    releases = try AdminApplicationCatalogParser.android(latest: latestData, history: historyData, cachedHistory: cachedHistory)
                    if historyData == nil { errors[platform] = historyWarning }
                } catch {
                    releases = try AdminApplicationCatalogParser.android(latest: latestData, history: nil, cachedHistory: cachedHistory)
                    errors[platform] = historyWarning
                }
            }
            return AdminApplicationCatalog(platform: platform, releases: releases, checkedAt: Date())
        } catch {
            errors[platform] = appUserFacingErrorMessage(error)
            return nil
        }
    }

    private func download(_ path: String) async throws -> Data {
        var request = URLRequest(url: Self.origin.appendingPathComponent(path))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 2 * 1024 * 1024 else {
            throw AppServiceError.message("Источник обновлений временно недоступен.")
        }
        return data
    }
}

// MARK: - Application overview

struct AdminApplicationScreen: View {
    @State private var store = AdminApplicationStore()

    var body: some View {
        AppScreen {
            AppSectionHeader(title: "Актуальные версии", caption: "Опубликованные сборки для установки")
            ForEach(AdminApplicationPlatform.allCases) { platform in
                AdminApplicationPlatformCard(
                    platform: platform, catalog: store.catalogs[platform],
                    error: store.errors[platform], isLoading: store.isLoading
                )
            }

            AppSectionHeader(title: "История обновлений")
            AppCard {
                ForEach(AdminApplicationPlatform.allCases) { platform in
                    if platform == .android { Divider() }
                    NavigationLink {
                        AdminApplicationHistoryScreen(platform: platform, store: store)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(platform.title).font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.ink)
                                Text("Релизов в каталоге: \(store.catalogs[platform]?.releases.count ?? 0)")
                                    .font(.caption).foregroundStyle(AppTheme.mutedTint)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(AppTheme.mutedTint)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            AppSectionHeader(title: "Установка и сведения")
            AppCard {
                LabeledContent("На этом устройстве", value: AppBuildIdentity.display)
                    .font(.subheadline).foregroundStyle(AppTheme.ink)
                Divider()
                Link(destination: URL(string: "https://app.lumastack.ru")!) {
                    Label("Открыть страницу приложения", systemImage: "globe")
                }
                Divider()
                Link(destination: URL(string: "sidestore://source?url=https%3A%2F%2Fapp.lumastack.ru%2Fsource.json")!) {
                    Label("Добавить источник SideStore", systemImage: "square.and.arrow.down")
                }
            }
        }
        .navigationTitle("Приложение")
        .navigationBarTitleDisplayMode(.inline)
        .appSidebarBackButton()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(store.isLoading)
                    .accessibilityLabel("Обновить версии приложения")
            }
        }
        .task { await store.load() }
        .refreshable { await store.refresh() }
    }
}

private struct AdminApplicationPlatformCard: View {
    let platform: AdminApplicationPlatform
    let catalog: AdminApplicationCatalog?
    let error: String?
    let isLoading: Bool

    var body: some View {
        AppCard {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(platform.title).font(.headline).foregroundStyle(AppTheme.mutedTint)
                    if let release = catalog?.latest {
                        Text(release.version).font(.largeTitle.weight(.bold)).foregroundStyle(AppTheme.ink)
                        Text(release.build.isEmpty ? "Сборка не указана" : "Сборка \(release.build)")
                            .font(.subheadline).foregroundStyle(AppTheme.mutedTint)
                    }
                }
                Spacer()
                Text(platform.packageType)
                    .font(.caption.weight(.bold)).foregroundStyle(AppTheme.primaryTint)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(AppTheme.primaryTint.opacity(0.12), in: Capsule())
            }
            if let release = catalog?.latest {
                Divider()
                HStack {
                    Label(release.dateLabel, systemImage: "calendar")
                    Spacer()
                    Text(release.sizeLabel)
                }
                .font(.caption).foregroundStyle(AppTheme.mutedTint)
                if let minimum = release.minimumSystem {
                    LabeledContent("Минимальная система", value: minimum)
                        .font(.caption).foregroundStyle(AppTheme.mutedTint)
                }
                HStack {
                    NavigationLink { AdminApplicationReleaseScreen(release: release) } label: {
                        Label("Что нового", systemImage: "text.alignleft")
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    if let url = release.downloadURL {
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Поделиться сборкой \(platform.title)")
                    }
                }
                .font(.subheadline)
                if let checkedAt = catalog?.checkedAt {
                    Text("Проверено \(checkedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(AppLocale.russian)))")
                        .font(.caption2).foregroundStyle(AppTheme.mutedTint)
                }
            } else if isLoading {
                ProgressView("Загружаются сведения о версии")
            } else if error == nil {
                Text("Нет данных о публикации").font(.subheadline).foregroundStyle(AppTheme.mutedTint)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(AppTheme.dangerTint)
            }
        }
    }
}

// MARK: - History and release details

private struct AdminApplicationHistoryScreen: View {
    let platform: AdminApplicationPlatform
    let store: AdminApplicationStore
    @State private var searchText = ""

    private var releases: [AdminApplicationRelease] {
        let all = store.catalogs[platform]?.releases ?? []
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return all }
        return all.filter { "\($0.version) \($0.build) \($0.notes)".localizedCaseInsensitiveContains(query) }
    }

    private var years: [Int] {
        Set(releases.map { $0.publishedAt.map { Calendar.current.component(.year, from: $0) } ?? 0 }).sorted(by: >)
    }

    var body: some View {
        AppScreen(bottomContentPadding: 88) {
            if let error = store.errors[platform] {
                AppNoticeBanner(text: error, tint: AppTheme.dangerTint)
            }
            if releases.isEmpty {
                AppEmptyState(title: "Обновления не найдены", message: "Обновите каталог или измените поисковый запрос.", systemName: "clock.arrow.circlepath")
            }
            ForEach(years, id: \.self) { year in
                AppSectionHeader(title: year == 0 ? "Без даты" : String(year))
                ForEach(releases.filter { ($0.publishedAt.map { Calendar.current.component(.year, from: $0) } ?? 0) == year }) { release in
                    NavigationLink { AdminApplicationReleaseScreen(release: release) } label: {
                        AdminApplicationHistoryRow(release: release, isLatest: release.id == store.catalogs[platform]?.latest?.id)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Обновления \(platform.title)")
        .navigationBarTitleDisplayMode(.inline)
        .appSidebarBackButton()
        .appNativeSearch(text: $searchText, prompt: "Версия, сборка или изменения")
        .refreshable { await store.refresh() }
    }
}

private struct AdminApplicationHistoryRow: View {
    let release: AdminApplicationRelease
    let isLatest: Bool

    var body: some View {
        AppCard {
            HStack(alignment: .firstTextBaseline) {
                Text(release.version).font(.headline).foregroundStyle(AppTheme.ink)
                if isLatest {
                    Text("Актуальная").font(.caption2.weight(.semibold)).foregroundStyle(AppTheme.primaryTint)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppTheme.mutedTint)
            }
            Text("Сборка \(release.build.isEmpty ? "—" : release.build) · \(release.dateLabel)")
                .font(.caption).foregroundStyle(AppTheme.mutedTint)
            if !release.notes.isEmpty {
                Text(release.notes).font(.subheadline).foregroundStyle(AppTheme.ink).lineLimit(2)
            }
        }
    }
}

private struct AdminApplicationReleaseScreen: View {
    let release: AdminApplicationRelease

    var body: some View {
        AppScreen {
            AppCard {
                Text("\(release.platform.title) \(release.version)")
                    .font(.title2.weight(.bold)).foregroundStyle(AppTheme.ink)
                LabeledContent("Сборка", value: release.build.isEmpty ? "Не указана" : release.build)
                LabeledContent("Дата публикации", value: release.dateLabel)
                LabeledContent("Размер файла", value: release.sizeLabel)
                if let minimum = release.minimumSystem { LabeledContent("Минимальная система", value: minimum) }
            }
            AppSectionHeader(title: "Что нового")
            AppCard {
                Text(release.notes.isEmpty ? "Описание обновления не опубликовано." : release.notes)
                    .font(.body).foregroundStyle(AppTheme.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let url = release.downloadURL {
                AppSectionHeader(title: "Сборка для установки")
                AppCard {
                    Link(destination: url) { Label("Скачать \(release.platform.packageType)", systemImage: "arrow.down.circle") }
                    Divider()
                    ShareLink(item: url) { Label("Поделиться ссылкой", systemImage: "square.and.arrow.up") }
                }
            }
            if let checksum = release.checksum, !checksum.isEmpty {
                DisclosureGroup("Контрольная сумма SHA-256") {
                    Text(checksum).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
                .background(AppTheme.cardSurface.opacity(0.82), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .navigationTitle("\(release.platform.title) \(release.version)")
        .navigationBarTitleDisplayMode(.inline)
        .appSidebarBackButton()
    }
}

private extension AdminApplicationRelease {
    var dateLabel: String {
        publishedAt?.formatted(.dateTime.day().month(.abbreviated).year().locale(AppLocale.russian)) ?? "Дата не указана"
    }

    var sizeLabel: String {
        sizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Размер не указан"
    }
}
