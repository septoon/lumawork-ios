import Foundation
import Observation
import SwiftUI

struct WikiSearchResponse: Decodable {
    let query: String
    let snapshotId: String?
    let results: [WikiSearchResult]
}

struct WikiHealthResponse: Decodable {
    let snapshotId: String?
    let contentVersion: String?
    let articles: Int?
}

struct WikiSearchPage {
    let snapshotID: String?
    let results: [WikiSearchResult]
}

struct WikiSearchResult: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let section: String
    let sourceUrl: String
    let score: Int
    let excerpt: String
    let hasPdf: Bool?
    let pdfUrl: String?
}

struct WikiArticle: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let section: String
    let sourceUrl: String
    let relativePath: String?
    let hasPdf: Bool?
    let pdfUrl: String?
    let pdfRelativePath: String?
    let content: String
    let truncated: Bool?
    let contentLength: Int?
    let snapshotId: String?
}

private struct WikiSearchSnapshot: Codable {
    let query: String
    let snapshotID: String?
    let results: [WikiSearchResult]
}

struct WikiAPI {
    private let origin: URL
    private let token: String?
    private let session: URLSession

    init(config: AppConfig, session: URLSession = .shared) {
        self.origin = AppConfig.configuredURL(config.wikiAPIOrigin)
        self.token = Self.nonEmpty(config.wikiAPIToken?.trimmingCharacters(in: .whitespacesAndNewlines))
        self.session = session
    }

    func health() async throws -> WikiHealthResponse {
        try await request(origin.appendingPathComponent("health"), requiresToken: false)
    }

    func search(query: String, limit: Int = 10) async throws -> WikiSearchPage {
        guard token != nil else {
            throw AppServiceError.message("Не задан WIKI_API_TOKEN.")
        }

        var components = URLComponents(url: origin.appendingPathComponent("search"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit))
        ]

        guard let url = components?.url else {
            throw AppServiceError.message("Не удалось собрать адрес поиска Wiki.")
        }

        let response: WikiSearchResponse = try await request(url)
        return WikiSearchPage(snapshotID: response.snapshotId, results: response.results)
    }

    func article(id: String, maxChars: Int = 90000) async throws -> WikiArticle {
        guard token != nil else {
            throw AppServiceError.message("Не задан WIKI_API_TOKEN.")
        }

        var components = URLComponents(
            url: origin.appendingPathComponent("article").appendingPathComponent(id),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "maxChars", value: String(maxChars))
        ]

        guard let url = components?.url else {
            throw AppServiceError.message("Не удалось собрать адрес статьи Wiki.")
        }

        return try await request(url)
    }

    func pdfURL(for id: String) -> URL {
        let url = origin.appendingPathComponent("pdf").appendingPathComponent(id)
        guard let token else { return url }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "token", value: token)]
        return components?.url ?? url
    }

    func isPDFAvailable(id: String) async -> Bool {
        var request = URLRequest(url: pdfURL(for: id))
        request.httpMethod = "HEAD"
        request.timeoutInterval = 12
        request.setValue("application/pdf", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return (200 ..< 300).contains(httpResponse.statusCode)
        } catch {
            return false
        }
    }

    private func request<Response: Decodable>(
        _ url: URL,
        requiresToken: Bool = true
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if requiresToken, let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            switch AppErrorPresentation.classification(for: error) {
            case .cancellation:
                throw CancellationError()
            case .network:
                throw error
            case .domain:
                throw AppServiceError.message("Wiki временно недоступна.")
            }
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppServiceError.message("Wiki вернула неизвестный ответ.")
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw AppServiceError.message(
                "\(backendMessage(from: data) ?? "Ошибка Wiki"). HTTP \(httpResponse.statusCode)"
            )
        }

        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func backendMessage(from data: Data) -> String? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return (object["message"] as? String) ?? (object["error"] as? String)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

@MainActor
@Observable
final class WikiStore {
    let service: WikiAPI
    private let cacheKey: String

    var query = "инструкция"
    var results: [WikiSearchResult] = []
    var snapshotID: String?
    var articleCount: Int?
    var isSearching = false
    var errorMessage: String?

    init(service: WikiAPI, cacheID: String? = nil) {
        self.service = service
        cacheKey = AppOfflineSnapshotStore.scopedKey("wiki-search", userID: cacheID)
        if let snapshot = AppOfflineSnapshotStore.load(
            WikiSearchSnapshot.self,
            key: cacheKey
        ) {
            query = snapshot.value.query
            snapshotID = snapshot.value.snapshotID
            results = snapshot.value.results
        }
    }

    var searchTaskID: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func refreshContentVersion() async {
        guard let health = try? await service.health(), !Task.isCancelled else { return }
        articleCount = health.articles
        let currentVersion = health.snapshotId ?? health.contentVersion
        guard let currentVersion, !currentVersion.isEmpty else { return }

        if let snapshotID, snapshotID != currentVersion {
            results = []
            AppOfflineSnapshotStore.save(
                WikiSearchSnapshot(query: searchTaskID, snapshotID: currentVersion, results: []),
                key: cacheKey
            )
        } else if snapshotID == nil {
            AppOfflineSnapshotStore.save(
                WikiSearchSnapshot(
                    query: searchTaskID,
                    snapshotID: currentVersion,
                    results: results
                ),
                key: cacheKey
            )
        }
        snapshotID = currentVersion
    }

    func searchIfNeeded() async {
        let normalizedQuery = searchTaskID
        guard !normalizedQuery.isEmpty else {
            results = []
            errorMessage = nil
            isSearching = false
            return
        }

        isSearching = true
        errorMessage = nil
        defer {
            if searchTaskID == normalizedQuery {
                isSearching = false
            }
        }

        do {
            try await Task.sleep(nanoseconds: 350_000_000)
            let page = try await service.search(query: normalizedQuery)
            guard !Task.isCancelled, searchTaskID == normalizedQuery else { return }
            snapshotID = page.snapshotID ?? snapshotID
            results = page.results
            AppOfflineSnapshotStore.save(
                WikiSearchSnapshot(
                    query: normalizedQuery,
                    snapshotID: snapshotID,
                    results: page.results
                ),
                key: cacheKey
            )
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, searchTaskID == normalizedQuery else { return }
            errorMessage = appUserFacingErrorMessage(error)
        }
    }
}

struct WikiScreen: View {
    @Bindable var store: WikiStore

    private let quickQueries = [
        "SimpleOne",
        "PinPad",
        "ККТ",
        "VPN",
        "GoFix"
    ]

    var body: some View {
        AppScreen {
            AppSectionHeader(
                title: "Вики",
                caption: "Инструкции и решения по оборудованию, ПО и рабочим процессам."
            )

            quickSearchSection
            resultsContent
        }
        .navigationBarTitleDisplayMode(.inline)
        .appNativeSearch(text: $store.query, prompt: "Поиск по инструкциям")
        .task(id: store.searchTaskID) {
            await store.searchIfNeeded()
        }
        .task {
            await store.refreshContentVersion()
        }
        .task(id: store.errorMessage) {
            await appDismissTransientMessage(store.errorMessage) { value in
                if store.errorMessage == value {
                    store.errorMessage = nil
                }
            }
        }
        .refreshable {
            await store.searchIfNeeded()
        }
    }

    private var quickSearchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Быстрый поиск", systemImage: "sparkle.magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.mutedTint)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(quickQueries, id: \.self) { query in
                        Button {
                            AppHaptics.trigger()
                            store.query = query
                        } label: {
                            Text(query)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(store.searchTaskID == query ? .white : AppTheme.primaryTint)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(
                                    store.searchTaskID == query
                                        ? AnyShapeStyle(AppTheme.primaryTint)
                                        : AnyShapeStyle(AppTheme.primaryTint.opacity(0.11)),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var resultsContent: some View {
        if let errorMessage = store.errorMessage {
            AppNoticeBanner(text: errorMessage, tint: AppTheme.dangerTint, isCritical: true)
        }

        if store.isSearching && store.results.isEmpty {
            AppLoadingView(title: "Ищем в базе знаний: \(store.searchTaskID)")
        } else if store.results.isEmpty {
            AppEmptyState(
                title: "Результатов пока нет",
                message: "Измените запрос, выберите быстрый фильтр или повторите поиск.",
                systemName: "magnifyingglass"
            )
        } else {
            AppSectionHeader(
                title: "Результаты",
                caption: "Найдено: \(store.results.count) · «\(store.searchTaskID)»"
            )

            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(store.results) { result in
                    NavigationLink {
                        WikiArticleScreen(
                            service: store.service,
                            result: result,
                            snapshotID: store.snapshotID
                        )
                    } label: {
                        WikiResultCard(result: result)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct WikiResultCard: View {
    let result: WikiSearchResult

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "doc.text.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.secondaryTint)
                        .frame(width: 36, height: 36)
                        .background(AppTheme.secondaryTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                    VStack(alignment: .leading, spacing: 5) {
                        Text(result.title)
                            .font(.headline)
                            .foregroundStyle(AppTheme.ink)
                            .lineLimit(3)

                        if !result.section.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(result.section)
                                .font(.caption)
                                .foregroundStyle(AppTheme.mutedTint)
                                .lineLimit(2)
                        }
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppTheme.mutedTint)
                }

                Text(result.excerpt.cleanedWikiSnippet)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.mutedTint)
                    .lineLimit(3)

                if result.hasPdf == true {
                    Label("Есть PDF", systemImage: "doc.richtext")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.primaryTint)
                }
            }
        }
    }
}

private struct WikiArticleScreen: View {
    let service: WikiAPI
    let result: WikiSearchResult
    let snapshotID: String?

    @State private var article: WikiArticle?
    @State private var document: WikiArticleDocument?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isPDFAvailable = false
    @State private var didCheckPDF = false

    var body: some View {
        AppScreen {
            if let errorMessage {
                AppNoticeBanner(text: errorMessage, tint: AppTheme.dangerTint, isCritical: true)
            }

            if isLoading && article == nil {
                AppLoadingView(title: "Загружаем статью «\(result.title)»")
            } else if let article, let document {
                articleContent(article, document: document)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    AppEmptyState(
                        title: "Статья пока недоступна",
                        message: "Повторите загрузку или откройте источник.",
                        systemName: "doc.text.magnifyingglass"
                    )

                    Button("Повторить") {
                        Task { await loadArticle() }
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle(result.title)
        .navigationBarTitleDisplayMode(.inline)
        .appSidebarBackButton()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if isPDFAvailable {
                        Link(destination: service.pdfURL(for: result.id)) {
                            Label("Открыть PDF", systemImage: "doc.richtext")
                        }
                    }

                    Button {
                        AppClipboard.copy(article?.content ?? result.excerpt)
                    } label: {
                        Label("Скопировать текст", systemImage: "doc.on.doc")
                    }

                    if let sourceURL {
                        Link(destination: sourceURL) {
                            Label("Открыть источник", systemImage: "safari")
                        }
                    }
                } label: {
                    Label("Действия", systemImage: "ellipsis.circle")
                }
            }
        }
        .task(id: result.id) {
            await loadArticle()
            await checkPDF()
        }
        .task(id: errorMessage) {
            await appDismissTransientMessage(errorMessage) { value in
                if errorMessage == value {
                    errorMessage = nil
                }
            }
        }
    }

    private var sourceURL: URL? {
        URL(string: article?.sourceUrl ?? result.sourceUrl)
    }

    private func articleContent(_ article: WikiArticle, document: WikiArticleDocument) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            AppCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text(document.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)
                        .textSelection(.enabled)

                    Text(document.section)
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.mutedTint)
                        .textSelection(.enabled)

                    HStack(spacing: 8) {
                        AppBadge(text: "Wiki", tint: AppTheme.primaryTint)
                        if let convertedAt = document.convertedAt {
                            AppBadge(text: convertedAt, tint: AppTheme.secondaryTint)
                        }
                    }

                    if article.truncated == true {
                        AppNoticeBanner(
                            text: "Статья обрезана сервером. Уточните запрос или откройте источник.",
                            tint: AppTheme.secondaryTint,
                            style: .information
                        )
                    }
                }
            }

            articleActionsCard

            AppCard {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(document.blocks) { block in
                        WikiArticleBlockView(block: block)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var articleActionsCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                AppSectionHeader(title: "Действия")

                HStack(spacing: 10) {
                    if isPDFAvailable {
                        Link(destination: service.pdfURL(for: result.id)) {
                            Label("PDF", systemImage: "doc.richtext")
                        }
                        .buttonStyle(AppActionButtonStyle())
                    } else {
                        Label(didCheckPDF ? "PDF недоступен" : "Проверяем PDF", systemImage: "doc.richtext")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.mutedTint)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity)
                            .background(AppTheme.ghostFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }

                    if let sourceURL {
                        Link(destination: sourceURL) {
                            Label("Источник", systemImage: "safari")
                        }
                        .buttonStyle(AppActionButtonStyle())
                    }
                }

                if didCheckPDF && !isPDFAvailable {
                    Text("Для этой статьи пока нет рабочего PDF endpoint.")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.mutedTint)
                }
            }
        }
    }

    private func loadArticle() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let version = snapshotID ?? "legacy"
        let cacheKey = "wiki-article-\(version)-\(result.id)"
        if let snapshot = AppOfflineSnapshotStore.load(WikiArticle.self, key: cacheKey) {
            article = snapshot.value
            document = WikiArticleDocument(article: snapshot.value)
        }

        do {
            let loadedArticle = try await service.article(id: result.id)
            article = loadedArticle
            document = WikiArticleDocument(article: loadedArticle)
            let loadedVersion = loadedArticle.snapshotId ?? version
            AppOfflineSnapshotStore.save(
                loadedArticle,
                key: "wiki-article-\(loadedVersion)-\(result.id)"
            )
        } catch is CancellationError {
            return
        } catch {
            if article == nil {
                errorMessage = appUserFacingErrorMessage(error)
            }
        }
    }

    private func checkPDF() async {
        didCheckPDF = false
        let isAvailable = await service.isPDFAvailable(id: result.id)
        guard !Task.isCancelled else { return }
        isPDFAvailable = isAvailable
        didCheckPDF = true
    }
}

private extension String {
    var cleanedWikiSnippet: String {
        replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct WikiArticleDocument {
    let title: String
    let section: String
    let sourceURL: String
    let convertedAt: String?
    let blocks: [WikiArticleBlock]

    init(article: WikiArticle) {
        let rawLines = article.content
            .replacingOccurrences(of: "\r", with: "")
            .components(separatedBy: "\n")
        var lines = Self.removingFrontMatter(from: rawLines)

        let extractedTitle = Self.firstValue(prefix: "#", in: lines) ?? article.title
        let extractedSection = Self.metadataValue(prefix: "Раздел:", in: lines) ?? article.section
        let extractedSource = Self.metadataValue(prefix: "Источник:", in: lines) ?? article.sourceUrl
        let extractedDate = Self.metadataValue(prefix: "Дата конвертации:", in: lines)

        lines.removeAll { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed == "---" ||
                trimmed == "# \(extractedTitle)" ||
                trimmed.hasPrefix("Источник:") ||
                trimmed.hasPrefix("Раздел:") ||
                trimmed.hasPrefix("Дата конвертации:")
        }

        self.title = extractedTitle
        self.section = extractedSection
        self.sourceURL = extractedSource
        self.convertedAt = extractedDate?.wikiShortDate
        self.blocks = Self.parseBlocks(lines)
    }

    private static func parseBlocks(_ lines: [String]) -> [WikiArticleBlock] {
        var blocks: [WikiArticleBlock] = []
        var paragraph = [String]()
        var bullets = [String]()
        var imageOrdinal = 0

        func flushParagraph() {
            let text = paragraph.joined(separator: " ").wikiCleanText
            paragraph.removeAll()
            guard !text.isEmpty else { return }
            blocks.append(.paragraph(text: text, isImportant: text.localizedCaseInsensitiveContains("ВАЖНО")))
        }

        func flushBullets() {
            let cleaned = bullets.map(\.wikiCleanText).filter { !$0.isEmpty }
            bullets.removeAll()
            guard !cleaned.isEmpty else { return }
            blocks.append(.bullets(cleaned))
        }

        for line in lines {
            var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                flushParagraph()
                flushBullets()
                continue
            }

            if let imageTitle = trimmed.wikiImageTitle {
                flushParagraph()
                flushBullets()
                blocks.append(.image(title: imageTitle, ordinal: imageOrdinal))
                imageOrdinal += 1

                let remainingText = trimmed.wikiRemovingImageMarkup.wikiCleanText
                if !remainingText.isEmpty {
                    paragraph.append(remainingText)
                }
                continue
            }

            let lineWithoutImageWrapper = trimmed.wikiRemovingImageWrapperPrefix
            if lineWithoutImageWrapper != trimmed {
                flushParagraph()
                flushBullets()
                trimmed = lineWithoutImageWrapper
                guard !trimmed.isEmpty else { continue }
            }

            if trimmed.hasPrefix("## ") || trimmed.hasPrefix("### ") {
                flushParagraph()
                flushBullets()
                let level = trimmed.hasPrefix("### ") ? 3 : 2
                blocks.append(.heading(level: level, title: trimmed.replacingOccurrences(of: #"^#{2,3}\s+"#, with: "", options: .regularExpression).wikiCleanText))
                continue
            }

            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph()
                bullets.append(String(trimmed.dropFirst(2)))
                continue
            }

            if trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) != nil {
                flushParagraph()
                bullets.append(trimmed.replacingOccurrences(of: #"^\d+\.\s+"#, with: "", options: .regularExpression))
                continue
            }

            paragraph.append(trimmed)
        }

        flushParagraph()
        flushBullets()
        return blocks.isEmpty ? [.paragraph(text: "Статья не содержит распознанного текста.", isImportant: false)] : blocks
    }

    private static func removingFrontMatter(from lines: [String]) -> [String] {
        guard let openingIndex = lines.firstIndex(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }), lines[openingIndex].trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            return lines
        }

        guard let closingIndex = lines.indices.dropFirst(openingIndex + 1).first(where: {
            lines[$0].trimmingCharacters(in: .whitespacesAndNewlines) == "---"
        }) else {
            return lines
        }

        return Array(lines.dropFirst(closingIndex + 1))
    }

    private static func metadataValue(prefix: String, in lines: [String]) -> String? {
        lines.first { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(prefix) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstValue(prefix: String, in lines: [String]) -> String? {
        lines.first { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(prefix + " ") }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum WikiArticleBlock: Identifiable {
    case heading(level: Int, title: String)
    case paragraph(text: String, isImportant: Bool)
    case bullets([String])
    case image(title: String, ordinal: Int)

    var id: String {
        switch self {
        case .heading(let level, let title):
            return "h\(level)-\(title)"
        case .paragraph(let text, let isImportant):
            return "p\(isImportant)-\(text.prefix(40))"
        case .bullets(let items):
            return "b-\(items.joined(separator: "|").prefix(40))"
        case .image(let title, let ordinal):
            return "i-\(ordinal)-\(title)"
        }
    }
}

private struct WikiArticleBlockView: View {
    let block: WikiArticleBlock

    var body: some View {
        switch block {
        case .heading(let level, let title):
            Text(title)
                .font(level == 2 ? .headline.weight(.semibold) : .subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.ink)
                .padding(.top, level == 2 ? 8 : 2)
                .textSelection(.enabled)

        case .paragraph(let text, let isImportant):
            Text(text)
                .font(.subheadline)
                .foregroundStyle(isImportant ? AppTheme.ink : AppTheme.mutedTint)
                .lineSpacing(3)
                .padding(isImportant ? 12 : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    isImportant ? AnyShapeStyle(AppTheme.secondaryTint.opacity(0.12)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .textSelection(.enabled)

        case .bullets(let items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(AppTheme.primaryTint)
                            .frame(width: 5, height: 5)
                            .padding(.top, 7)
                        Text(item)
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.ink)
                            .lineSpacing(2)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(12)
            .background(AppTheme.subpanelSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

        case .image:
            HStack(spacing: 10) {
                Image(systemName: "photo")
                    .foregroundStyle(AppTheme.secondaryTint)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Фото недоступно в статье")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)

                    Text("Изображение доступно в PDF")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.mutedTint)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.ghostFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }
}

private extension String {
    var wikiCleanText: String {
        var value = self
            .replacingOccurrences(of: #"\[!\[[^\]]*\]\([^)]+\)\]\([^)]+\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"!\[[^\]]*\]\([^)]+\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\[\]\([^)]+\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"^(?:>\s*)*\]\(https?://[^)]+\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\*\*([^*]+)\*\*"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"__([^_]+)__"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"_([^_]+)_"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "\\", with: "")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        value = value.replacingOccurrences(of: "ВАЖНО!", with: "ВАЖНО:")
        return value
    }

    var wikiImageTitle: String? {
        if range(of: #"\[\]\([^)]+\)"#, options: .regularExpression) != nil {
            return "Изображение"
        }

        let patterns = [
            #"\[!\[([^\]]*)\]\([^)]+\)\]\([^)]+\)"#,
            #"!\[([^\]]*)\]\([^)]+\)"#
        ]

        for pattern in patterns {
            guard let range = range(of: pattern, options: .regularExpression) else { continue }
            let raw = String(self[range])
                .replacingOccurrences(of: pattern, with: "$1", options: .regularExpression)
                .wikiCleanText
            return raw.isEmpty ? "Изображение" : raw
        }

        return nil
    }

    var wikiRemovingImageMarkup: String {
        replacingOccurrences(
            of: #"\[!\[[^\]]*\]\([^)]+\)\]\([^)]+\)"#,
            with: "",
            options: .regularExpression
        )
        .replacingOccurrences(
            of: #"!\[[^\]]*\]\([^)]+\)"#,
            with: "",
            options: .regularExpression
        )
        .replacingOccurrences(
            of: #"\[\]\([^)]+\)"#,
            with: "",
            options: .regularExpression
        )
        .wikiRemovingImageWrapperPrefix
    }

    var wikiRemovingImageWrapperPrefix: String {
        let source = trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutLink = source.replacingOccurrences(
            of: #"^(?:>\s*)*\]\(https?://[^)]+\)"#,
            with: "",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)

        let meaningfulText = withoutLink
            .replacingOccurrences(of: #"[>\[\]\\*_;⇒→.\-]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !meaningfulText.isEmpty else { return "" }
        guard withoutLink != source else { return source }

        return withoutLink
            .replacingOccurrences(of: #"^[>\[\]\\;⇒→.]+\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var wikiShortDate: String {
        replacingOccurrences(of: #"T.*$"#, with: "", options: .regularExpression)
    }
}
