import Foundation
import Observation

@MainActor @Observable final class LeaderboardStore {
    var period: LeaderboardPeriod = .all
    var category: LeaderboardCategory = .all
    var city: LeaderboardCity = .all
    private(set) var availableCities: [LeaderboardCity] = [.all]
    private(set) var response: LeaderboardResponse?
    private(set) var loading = false
    private(set) var isRefreshing = false
    private(set) var isLoadingPage = false
    private(set) var error: String?
    private(set) var cacheTime: Date?
    private(set) var isShowingCache = false
    @ObservationIgnored var onVisibilityDenied: (() -> Void)?
    @ObservationIgnored private let api: WorkStatisticsAPI
    @ObservationIgnored private let cache: LeaderboardCache
    @ObservationIgnored private let cacheOwnerID: String?
    @ObservationIgnored private var access: SimpleOneAccessSnapshot?
    @ObservationIgnored private var sourceUserID = ""
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var visible = false

    init(config: AppConfig, cache: LeaderboardCache = LeaderboardCache(), ownerID: String? = nil, session: URLSession = .shared) {
        api = WorkStatisticsAPI(config: config, session: session); self.cache = cache; self.cacheOwnerID = ownerID
    }
    var filterID: String { [period.rawValue, category.rawValue, city.key].joined(separator: "|") }

    func configure(sourceUserID: String) {
        let current = try? SimpleOneProtectedAccess.capture()
        guard current != access || self.sourceUserID != sourceUserID else { return }
        if access != nil || !self.sourceUserID.isEmpty || current == nil { clearProtectedState() }
        access = current; self.sourceUserID = sourceUserID
    }
    func show() async {
        visible = true
        await load()
    }
    func hide() {
        visible = false; generation = UUID(); loadTask?.cancel(); loadTask = nil
        loading = false; isRefreshing = false; isLoadingPage = false
    }
    func load(refresh: Bool = false) async {
        guard let access, !sourceUserID.isEmpty else { error = "Войдите в SimpleOne, чтобы открыть рейтинг."; return }
        let stamp = UUID(); generation = stamp
        loadTask?.cancel()
        let key = makeKey(owner: access.ownerID)
        if !refresh || response?.period != period || response?.category != category || response?.city != city || response?.periodKey != key.periodKey {
            let saved = await Task.detached(priority: .utility) { [cache] in cache.read(key) }.value
            guard generation == stamp, (try? SimpleOneProtectedAccess.capture()) == access else { return }
            response = saved?.response; cacheTime = saved?.savedAt; isShowingCache = saved != nil
            if let response { availableCities = response.availableCities }
        }
        loading = response == nil; isRefreshing = response != nil; error = nil
        let period = period, category = category, city = city
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if generation == stamp { loading = false; isRefreshing = false } }
            do {
                let value = try await api.leaderboard(period: period, category: category, city: city.key)
                try SimpleOneProtectedAccess.validate(access)
                guard generation == stamp else { return }
                try value.validate(period: period, category: category, city: city.key)
                // No suspension between the owner/generation guard and atomic cache commit.
                try cache.save(value, key: key)
                response = value; availableCities = value.availableCities
                cacheTime = Date(); isShowingCache = false
            } catch is CancellationError { return }
            catch {
                guard generation == stamp else { return }
                if (error as? WorkStatisticsAPIError)?.code == "LEADERBOARD_DISABLED" {
                    clearProtectedState(); onVisibilityDenied?(); return
                }
                if (try? SimpleOneProtectedAccess.capture()) != access || (error as? WorkStatisticsAPIError)?.status == 401 || (error as? WorkStatisticsAPIError)?.status == 403 {
                    clearProtectedState(); self.error = "Доступ к рейтингу отозван. Войдите снова."
                    return
                }
                if let cities = (error as? WorkStatisticsAPIError)?.availableCities { availableCities = cities }
                self.error = (error as? WorkStatisticsAPIError)?.errorDescription ?? "Не удалось обновить рейтинг. Проверьте подключение."
                isShowingCache = response != nil
            }
        }
        loadTask = task
        await task.value
    }
    func loadNextPage() async {
        guard !loading, !isRefreshing, !isLoadingPage, let offset = response?.participantsOnly.nextOffset, let access else { return }
        let stamp = generation
        isLoadingPage = true
        defer { if generation == stamp { isLoadingPage = false } }
        do {
            let page = try await api.leaderboard(period: period, category: category, city: city.key, offset: offset)
            try SimpleOneProtectedAccess.validate(access)
            guard generation == stamp, var current = response else { return }
            try page.validate(period: period, category: category, city: city.key)
            guard page.periodKey == current.periodKey else { await load(refresh: true); return }
            var seen = Set(current.items.map(\.userId))
            current.items += page.items.filter { seen.insert($0.userId).inserted }
            current.nextOffset = page.nextOffset
            current.usersWithDataCount = page.usersWithDataCount
            current.registeredUsersCount = page.registeredUsersCount
            current.totalCount = page.totalCount
            response = current
            // Persist only complete first-page responses; live offset pages have no common snapshot token.
        } catch {
            guard generation == stamp else { return }
            if (error as? WorkStatisticsAPIError)?.code == "LEADERBOARD_DISABLED" {
                clearProtectedState(); onVisibilityDenied?(); return
            }
            if (try? SimpleOneProtectedAccess.capture()) != access || (error as? WorkStatisticsAPIError)?.status == 401 || (error as? WorkStatisticsAPIError)?.status == 403 {
                clearProtectedState(); self.error = "Доступ к рейтингу отозван. Войдите снова."
            } else { self.error = "Не удалось загрузить следующие строки." }
        }
    }
    func pauseForBackground() {
        generation = UUID(); loadTask?.cancel(); loadTask = nil
        loading = false; isRefreshing = false; isLoadingPage = false
    }
    func resumeIfVisible() {
        guard visible else { return }
        Task { await load(refresh: true) }
    }
    func clearProtectedState() {
        generation = UUID(); loadTask?.cancel(); loadTask = nil
        if let owner = access?.ownerID ?? cacheOwnerID { cache.removeOwner(owner) }
        response = nil; access = nil; sourceUserID = ""
        loading = false; isRefreshing = false; isLoadingPage = false
        cacheTime = nil; isShowingCache = false; error = nil; availableCities = [.all]
    }
    private func makeKey(owner: String) -> LeaderboardCache.Key {
        .init(ownerID: owner, sourceUserID: sourceUserID, periodKey: period.key(), period: period, category: category, city: city.key)
    }
}
