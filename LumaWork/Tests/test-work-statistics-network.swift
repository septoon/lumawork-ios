import Foundation

extension WorkStatisticsTests {
 @MainActor static func networkTests() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StatisticsURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let config = AppConfig(lumaWorkAPIOrigin: "https://fixture.invalid")
    let log = StatisticsRequestLog()
    let now = ISO8601DateFormatter().string(from: Date())
    let me = WorkStatisticsMe(serverRevision:0,hasSnapshot:false,sourceUserId:"fixture-so",sourceSyncedAt:nil,receivedAt:nil,rulesVersion:1)
    StatisticsURLProtocol.handler = { request in
        log.append(request)
        precondition(request.value(forHTTPHeaderField:"Authorization")=="Bearer fixture-bearer")
        precondition(request.value(forHTTPHeaderField:"X-SimpleOne-Auth")=="fixture-so-auth")
        if request.httpMethod == "PUT" {
            let data = statisticsRequestBody(request)
            let payload = try JSONDecoder().decode(WorkStatisticsUpload.self,from:data)
            let body = String(data: data, encoding: .utf8)!
            precondition(!body.contains("requestNumber") && !body.contains("rawInfo") && !body.contains("fixture-private"))
            return (200,try JSONEncoder().encode(WorkStatisticsReceipt(accepted:true,serverRevision:1,requestId:payload.requestId,sourceSyncedAt:payload.sourceSyncedAt,receivedAt:now)),0)
        }
        return (200,try JSONEncoder().encode(me),0)
    }
    let sync = WorkStatisticsSyncCoordinator(config:config,directory:folder.appendingPathComponent("sync"),session:session)
    await sync.beginRefresh(sourceUserID:"fixture-so")
    try sync.markSourcePassDirty()
    try check(log.all.count == 1 && log.all[0].httpMethod == "GET", "preflight before source")
    await sync.commitBaseline(records:[],narrow:nil,wide:nil)
    try await Task.sleep(for:.milliseconds(100))
    try check(log.all.filter{$0.httpMethod=="PUT"}.count == 1)
    sync.endRefresh()
    // Narrow completion must not publish an all-time snapshot.
    let before = log.all.count
    await sync.beginRefresh(sourceUserID:"fixture-so")
    try sync.markSourcePassDirty()
    await sync.commitBatch(.init(userID:"fixture-so",scope:.narrow,changes:[],watermark:nil,totalCount:0))
    try await Task.sleep(for:.milliseconds(50))
    try check(log.all.count == before+1)
    try sync.markSourcePassDirty()
    await sync.commitBatch(.init(userID:"fixture-so",scope:.wide,changes:[],watermark:nil,totalCount:0))
    try await Task.sleep(for:.milliseconds(100))
    try check(log.all.filter{$0.httpMethod=="PUT"}.count == 2)
    sync.endRefresh()
    // Abort after dirty marker, then one successful recovery must fetch a fresh revision.
    await sync.beginRefresh(sourceUserID:"fixture-so"); try sync.markSourcePassDirty(); sync.endRefresh()
    let aborted = log.all.count
    await sync.beginRefresh(sourceUserID:"fixture-so")
    try check(log.all.count == aborted+1, "aborted pass cannot suppress next preflight")
    try sync.markSourcePassDirty();await sync.commitBaseline(records:[],narrow:nil,wide:nil)
    try await Task.sleep(for:.milliseconds(100)); sync.endRefresh()
    try check(log.all.filter{$0.httpMethod=="PUT"}.count == 3)
    // Offline preflight remains unsendable after source completion and restart.
    StatisticsURLProtocol.handler = { request in log.append(request); return (503,Data("{}".utf8),0) }
    let offline = WorkStatisticsSyncCoordinator(config:config,directory:folder.appendingPathComponent("offline"),session:session)
    await offline.beginRefresh(sourceUserID:"fixture-so"); try offline.markSourcePassDirty()
    await offline.commitBaseline(records:[],narrow:nil,wide:nil); offline.endRefresh()
    let offlineCount = log.all.count
    let restored = WorkStatisticsSyncCoordinator(config:config,directory:folder.appendingPathComponent("offline"),session:session)
    restored.resumePending(sourceUserID:"fixture-so")
    try await Task.sleep(for:.milliseconds(50)); try check(log.all.count == offlineCount)
    // A revision conflict must never fetch a newer revision and resend the old payload.
    StatisticsURLProtocol.handler = { request in
        log.append(request)
        return request.httpMethod == "PUT" ? (409,Data("{\"error\":\"REVISION_CONFLICT\"}".utf8),0) : (200,try JSONEncoder().encode(me),0)
    }
    await sync.beginRefresh(sourceUserID:"fixture-so"); try sync.markSourcePassDirty();await sync.commitBaseline(records:[],narrow:nil,wide:nil)
    try await Task.sleep(for:.milliseconds(100));let conflictCount=log.all.count
    sync.resumePending(sourceUserID:"fixture-so");try await Task.sleep(for:.milliseconds(50));try check(log.all.count==conflictCount)
    sync.endRefresh()
    // Durable retry after a simulated process restart preserves the exact accepted candidate.
    let retryLog = StatisticsPayloadLog()
    StatisticsURLProtocol.handler = { request in
        if request.httpMethod == "PUT" {
            retryLog.append(try JSONDecoder().decode(WorkStatisticsUpload.self,from:statisticsRequestBody(request)))
            return (503,Data("{}".utf8),0)
        }
        return (200,try JSONEncoder().encode(me),0)
    }
    let retryFolder = folder.appendingPathComponent("retry")
    let retrySync = WorkStatisticsSyncCoordinator(config:config,directory:retryFolder,session:session)
    await retrySync.beginRefresh(sourceUserID:"fixture-so");try retrySync.markSourcePassDirty();await retrySync.commitBaseline(records:[],narrow:nil,wide:nil)
    try await Task.sleep(for:.milliseconds(60));try check(retryLog.all.count == 1)
    let restartedFolder = folder.appendingPathComponent("restarted")
    try FileManager.default.copyItem(at:retryFolder,to:restartedFolder)
    retrySync.clearProtectedState()
    StatisticsURLProtocol.handler = { request in
        let payload = try JSONDecoder().decode(WorkStatisticsUpload.self,from:statisticsRequestBody(request));retryLog.append(payload)
        return (200,try JSONEncoder().encode(WorkStatisticsReceipt(accepted:true,serverRevision:1,requestId:payload.requestId,sourceSyncedAt:payload.sourceSyncedAt,receivedAt:now)),0)
    }
    let restarted = WorkStatisticsSyncCoordinator(config:config,directory:restartedFolder,session:session)
    restarted.resumePending(sourceUserID:"fixture-so");try await Task.sleep(for:.milliseconds(100))
    try check(retryLog.all.count == 2 && retryLog.all[0] == retryLog.all[1], "restart must resend identical requestId and aggregates without late preflight")
    restarted.clearProtectedState()
    // Disk cache restoration, filter isolation, stale replies and logout.
    let cache = LeaderboardCache(directory:folder.appendingPathComponent("cache"))
    let board = LeaderboardResponse(period:.all,category:.all,city:.all,availableCities:[.all,.init(key:"москва",title:"Москва")],currentUserInScope:false,timezone:"Europe/Moscow",serverNow:now,periodKey:"all",periodStart:nil,periodEndExclusive:nil,generatedAt:now,rulesVersion:1,registeredUsersCount:0,usersWithDataCount:0,totalCount:0,items:[],me:nil,nextOffset:nil)
    let zero = LeaderboardEntry(userId:"zero",displayName:"Zero",avatarUrl:nil,rank:nil,value:0,completedWithVisitCount:0,
        categoryCounts:Dictionary(uniqueKeysWithValues:["portable","stationary","integration","fiscal"].map { ($0,0) }),hasData:true,sourceSyncedAt:now,receivedAt:now,isCurrentUser:false)
    var missing = zero; missing.userId = "missing"; missing.hasData = false; missing.value = nil; missing.completedWithVisitCount = nil; missing.isCurrentUser = true
    var mixed = board; mixed.items = [zero, missing]; mixed.me = missing; mixed.currentUserInScope = true
    mixed.registeredUsersCount = 60; mixed.totalCount = 60; mixed.usersWithDataCount = 1; mixed.nextOffset = 50
    let participants = mixed.participantsOnly
    try check(participants.items.map(\.userId) == ["zero"] && participants.me == nil && !participants.currentUserInScope && participants.nextOffset == nil, "only uploaded users, including zero; no empty tail pages")
    mixed.usersWithDataCount = 55
    try check(mixed.participantsOnly.nextOffset == 50, "preserve server offsets while participants remain")

    StatisticsURLProtocol.handler = { request in
        log.append(request)
        let c = URLComponents(url: request.url!, resolvingAgainstBaseURL:false)!
        var value = board
        value.category = LeaderboardCategory(rawValue:c.queryItems!.first{$0.name=="category"}!.value!)!
        value.city = c.queryItems!.first{$0.name=="city"}!.value! == "all" ? .all : .init(key:"москва",title:"Москва")
        return (200,try JSONEncoder().encode(value),0)
    }
    let store = LeaderboardStore(config:config,cache:cache,session:session)
    store.configure(sourceUserID:"fixture-so");await store.show()
    try check(store.response?.items.isEmpty == true && !store.loading && !store.isRefreshing)
    let key = LeaderboardCache.Key(ownerID:"fixture-owner",sourceUserID:"fixture-so",periodKey:"all",period:.all,category:.all,city:"all")
    try check(cache.read(key) != nil, "empty success is cached")
    try cache.save(mixed, key:key)
    try check(cache.read(key)?.response.participantsOnly.items.map(\.userId) == ["zero"], "legacy cache must hide users without SO upload")
    var noUploads = mixed; noUploads.items = [missing]; noUploads.usersWithDataCount = 0
    try check(noUploads.participantsOnly.items.isEmpty && noUploads.participantsOnly.nextOffset == nil, "empty participants do not expose no-data pages")
    try cache.save(board,key:key)
    StatisticsURLProtocol.handler = { _ in (503,Data("{}".utf8),0.1) }
    let reboot = LeaderboardStore(config:config,cache:cache,session:session);reboot.configure(sourceUserID:"fixture-so")
    let load = Task {await reboot.show()};try await Task.sleep(for:.milliseconds(30))
    try check(reboot.isRefreshing && !reboot.loading && reboot.response != nil)
    await load.value;try check(reboot.isShowingCache && !reboot.isRefreshing && cache.read(key) != nil)
    reboot.city = .init(key:"москва",title:"Москва")
    let change = Task {await reboot.load()};try await Task.sleep(for:.milliseconds(30))
    try check(reboot.loading && reboot.response == nil, "different city must not show all cache")
    reboot.hide();await change.value;try check(!reboot.loading && !reboot.isRefreshing)
    reboot.clearProtectedState();try check(cache.read(key) == nil)
    for status in [401,403] {
        var pagedValue = board; pagedValue.nextOffset = 50; pagedValue.usersWithDataCount = 51; pagedValue.registeredUsersCount = 51; pagedValue.totalCount = 51
        let paged = pagedValue
        StatisticsURLProtocol.handler = { request in
            let offset = URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems!.first{$0.name=="offset"}!.value!
            return offset == "0" ? (200,try JSONEncoder().encode(paged),0) : (status,Data("{\"error\":\"USER_BLOCKED\"}".utf8),0)
        }
        let denied = LeaderboardStore(config:config,cache:cache,session:session);denied.configure(sourceUserID:"fixture-so");await denied.show()
        try check(cache.read(key) != nil)
        await denied.loadNextPage()
        try check(denied.response == nil && cache.read(key) == nil, "pagination denial must revoke cached ranking")
    }
    // Logout before first opening the rating still removes the owner's persisted cache.
    try cache.save(board,key:key)
    let unopened = LeaderboardStore(config:config,cache:cache,ownerID:"fixture-owner",session:session)
    unopened.clearProtectedState();try check(cache.read(key) == nil)
    // Revocation while a request is suspended cannot repopulate the cache.
    StatisticsURLProtocol.handler = { _ in (200,try JSONEncoder().encode(board),0.1) }
    let late = LeaderboardStore(config:config,cache:cache,session:session);late.configure(sourceUserID:"fixture-so")
    let pending = Task {await late.show()};try await Task.sleep(for:.milliseconds(20))
    SimpleOneSessionKeychain.deleteAuthKey();late.clearProtectedState();await pending.value
    try check(late.response == nil && cache.read(key) == nil)
    SimpleOneSessionKeychain.auth = "fixture-so-auth"
    print("PASS: HTTP aggregate privacy; preflight/wide gate/conflict/unsendable outbox; disk cache/filter/offline/logout/cancellation")
 }
}
