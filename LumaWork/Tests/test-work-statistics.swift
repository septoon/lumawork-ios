import Foundation

func check(_ value: @autoclosure () throws -> Bool, _ message: String = "assertion failed") throws {
 if try !value() { fatalError(message) }
}
@main struct WorkStatisticsTests {
 @MainActor static func main() async throws {
  let fixturesURL = URL(fileURLWithPath: CommandLine.arguments[1])
  let fixtures = try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: fixturesURL))
  for fixture in fixtures.cases {
   let record = XLSXRequestsParser.record(fromExportRow: fixture.row)!
   let contribution = WorkStatisticsAggregator.contribution(record)
   try check(contribution.monthKey == fixture.month, "month: \(fixture.name): \(contribution.monthKey ?? "unknown")")
   try check(contribution.metrics.completedWithVisitCount == fixture.completed, fixture.name)
   try check(contribution.metrics.returnEquipmentCount == fixture.returned, fixture.name)
   if let category = fixture.category, let operation = fixture.operation {
    try check(contribution.metrics.byCategory[category]?[operation] == 1, fixture.name)
   }
  }
  var index = WorkStatisticsSourceIndex(ownerID: "owner", sourceUserID: "so")
  let records = fixtures.cases.prefix(16).map { XLSXRequestsParser.record(fromExportRow: $0.row)! }
  try index.replaceBaseline(ownerID: "owner", sourceUserID: "so", records: records, syncedAt: Date())
  let initial = try index.makeUpload(expectedRevision: 0)
  try check(initial.months.reduce(0) { $0 + $1.metrics.completedWithVisitCount } == 16)
  try index.replaceBaseline(ownerID: "owner", sourceUserID: "so", records: records+records, syncedAt: Date())
  try check(try index.makeUpload(expectedRevision: 0).months == initial.months)
  let original = records[0]; var edited = original; edited.workStatisticsDate = "2026-10-01T00:00:00Z"
  let change = SimpleOneClosedSyncChange(sysID: "sys-1", requestNumber: original.requestNumber, cursor: .init(updatedAt:"2026-11-07 00:00:00",sysID:"sys-1"),record:edited,excludedFromArchive:false)
  try index.applyCompletedBatch(ownerID:"owner",batch:.init(userID:"so",scope:.wide,changes:[change],watermark:change.cursor,totalCount:nil),syncedAt:Date())
  let changed = try index.makeUpload(expectedRevision:0)
  try check(changed.months.first { $0.month == "2026-10" }?.metrics.completedWithVisitCount == 1)
  let tombstone = SimpleOneClosedSyncChange(sysID:"sys-1",requestNumber:original.requestNumber,cursor:change.cursor,record:nil,excludedFromArchive:true)
  try index.applyCompletedBatch(ownerID:"owner",batch:.init(userID:"so",scope:.wide,changes:[tombstone],watermark:change.cursor,totalCount:nil),syncedAt:Date())
  try check(try index.makeUpload(expectedRevision:0).months.reduce(0){$0+$1.metrics.completedWithVisitCount}==15)
  index.dirty = true; try check(index.requiresAuthoritativeBaseline)
  do {try index.applyCompletedBatch(ownerID:"owner",batch:.init(userID:"so",scope:.wide,changes:[],watermark:change.cursor,totalCount:nil),syncedAt:Date());fatalError("crash recovery accepted stale delta")}catch{}
  do { _ = try index.makeUpload(expectedRevision:0); fatalError("dirty publish") } catch {}
  do {try index.replaceBaseline(ownerID:"another",sourceUserID:"so",records:[],syncedAt:Date());fatalError("owner mismatch")}catch{}
  try index.replaceBaseline(ownerID:"owner",sourceUserID:"so",records:[],syncedAt:Date())
  try check(try index.makeUpload(expectedRevision:0).months.isEmpty)
  var conflict = original; conflict.workStatisticsDate = "2020-01-01"
  do {try index.replaceBaseline(ownerID:"owner",sourceUserID:"so",records:[original,conflict],syncedAt:Date());fatalError("ambiguous duplicate")}catch{}
  let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(initial)) as! [String:Any]
  try check(Set(payload.keys)==Set(["schemaVersion","rulesVersion","requestId","expectedRevision","sourceUserId","sourceSyncedAt","timezone","months","unknownDate"]))
  try check(!String(data:try JSONEncoder().encode(initial),encoding:.utf8)!.contains("fixture-"))
  try await networkTests()
  try await leaderboardAccessTests()
  print("PASS: \(fixtures.cases.count) shared fixtures; baseline/dedupe/date move/tombstone/dirty/owner/empty/privacy")
 }
 struct Fixtures:Decodable { var cases:[Fixture] }
 struct Fixture:Decodable { var name:String;var row:[String:String];var month:String?;var completed:Int;var returned:Int;var category:String?;var operation:String? }
}
