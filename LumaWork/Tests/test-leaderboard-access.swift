import Foundation

extension WorkStatisticsTests {
    @MainActor static func leaderboardAccessTests() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StatisticsURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let access = LeaderboardAccessStore(config: AppConfig(lumaWorkAPIOrigin: "https://fixture.invalid"), ownerID: "fixture-owner", session: session)
        var disabled = 0
        access.onDisabled = { disabled += 1 }
        try check(!access.isEnabled, "unconfirmed startup must be original Analytics")
        StatisticsURLProtocol.handler = { request in
            precondition(request.url!.path == "/api/v2/leaderboard-access")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-bearer")
            precondition(request.value(forHTTPHeaderField: "X-LumaWork-Device-Platform") == "iOS")
            precondition(request.value(forHTTPHeaderField: "X-SimpleOne-Auth") == nil)
            return (200, Data("{\"enabled\":true,\"updatedAt\":null}".utf8), 0)
        }
        await access.refresh()
        try check(access.isEnabled)
        StatisticsURLProtocol.handler = { _ in (503,Data("{}".utf8),0) }
        await access.refresh()
        try check(access.isEnabled, "transient outage must retain the session's confirmed setting")
        StatisticsURLProtocol.handler = { _ in (200,Data("{\"enabled\":false,\"updatedAt\":null}".utf8),0) }
        await access.refresh()
        try check(!access.isEnabled && disabled == 1)
        StatisticsURLProtocol.handler = { _ in (200,Data("{\"enabled\":true,\"updatedAt\":null}".utf8),0.1) }
        let late = Task { await access.refresh() }
        try await Task.sleep(for: .milliseconds(20))
        access.clearProtectedState()
        await late.value
        try check(!access.isEnabled, "late capability response cannot reopen a logged-out session")
        StatisticsURLProtocol.handler = { _ in (200,Data("{\"enabled\":true,\"updatedAt\":null}".utf8),0) }
        let wrongOwner = LeaderboardAccessStore(config:AppConfig(lumaWorkAPIOrigin:"https://fixture.invalid"),ownerID:"another",session:session)
        await wrongOwner.refresh();try check(!wrongOwner.isEnabled)
        // Capability revocation during a cached refresh cancels the reader and clears disk state.
        let cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let cache = LeaderboardCache(directory: cacheDirectory)
        let now = ISO8601DateFormatter().string(from: Date())
        let board = LeaderboardResponse(period:.all,category:.all,city:.all,availableCities:[.all],currentUserInScope:false,timezone:"Europe/Moscow",serverNow:now,periodKey:"all",periodStart:nil,periodEndExclusive:nil,generatedAt:now,rulesVersion:1,registeredUsersCount:0,usersWithDataCount:0,totalCount:0,items:[],me:nil,nextOffset:nil)
        let reader = LeaderboardStore(config:AppConfig(lumaWorkAPIOrigin:"https://fixture.invalid"),cache:cache,ownerID:"fixture-owner",session:session)
        access.onDisabled = { reader.clearProtectedState() }
        reader.onVisibilityDenied = { access.markDisabled() }
        StatisticsURLProtocol.handler = { request in
            request.url!.path.hasSuffix("leaderboard-access") ? (200,Data("{\"enabled\":true,\"updatedAt\":null}".utf8),0) : (200,try JSONEncoder().encode(board),0)
        }
        await access.refresh();reader.configure(sourceUserID:"fixture-so");await reader.show()
        let key = LeaderboardCache.Key(ownerID:"fixture-owner",sourceUserID:"fixture-so",periodKey:"all",period:.all,category:.all,city:"all")
        try check(access.isEnabled && cache.read(key) != nil)
        StatisticsURLProtocol.handler = { request in
            request.url!.path.hasSuffix("leaderboard-access") ? (200,Data("{\"enabled\":false,\"updatedAt\":null}".utf8),0) : (200,try JSONEncoder().encode(board),0.1)
        }
        let pending = Task { await reader.load(refresh:true) }
        try await Task.sleep(for:.milliseconds(20));await access.refresh();await pending.value
        try check(!access.isEnabled && reader.response == nil && cache.read(key) == nil, "late data cannot resurrect an administratively hidden ranking")
        print("PASS: ranking capability startup/offline/disable/logout/owner/platform")
    }
}
