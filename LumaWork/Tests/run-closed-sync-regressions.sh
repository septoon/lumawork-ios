#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
task_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/lumawork-closed-sync.XXXXXX")"
trap 'rm -rf "$task_test_dir"' EXIT
python3 - "$task_test_dir" <<'PY'
from pathlib import Path
import sys
app = Path('LumaWork/LumaWork')
out = Path(sys.argv[1])
def block(source, marker):
    start = source.index(marker)
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]
models = (app / 'AppModels.swift').read_text()
out.joinpath('Models.swift').write_text('import Foundation\n' + models[models.index('nonisolated struct ClosedRequestInfoField:'):models.index('nonisolated struct TimeReportEntry:')])
network = (app / 'SimpleOneRequestsFeature/SimpleOneRequestsService+Network.swift').read_text()
details = (app / 'SimpleOneRequestsFeature/SimpleOneRequestsService+Details.swift').read_text()
mapping = (app / 'SimpleOneRequestsFeature/SimpleOneRequestsService+Mapping.swift').read_text()
errors = (app / 'SimpleOneRequestsFeature/SimpleOneRequestsModels.swift').read_text()
formatting = (app / 'AppSupport/AppFormattingQRCode.swift').read_text()
parts = ['import Foundation', block(errors, 'enum SimpleOneServiceError:'), block(formatting, 'nonisolated func stringValue(')]
parts += ['nonisolated struct SimpleOneRequestsService: Sendable { let baseURL: URL; let session: URLSession }', 'nonisolated extension SimpleOneRequestsService {']
parts += [block(network, m) for m in ['func listItems(', 'func totalCount(', 'func intValue(', 'func request(\n        url:']]
parts += [block(details, m) for m in ['func flattenedRecordItem(', 'func recordItem(']]
parts += [block(mapping, 'func serverError('), 'func closedSimpleOneCondition(userID: String) -> String { "wide" }', '}']
parts += [mapping[mapping.index('nonisolated func fieldDisplayString('):]]
out.joinpath('Service.swift').write_text('\n'.join(parts))
sync = (app / 'ClosedRequestsFeature/ClosedRequestsIncrementalSync.swift').read_text()
out.joinpath('Sync.swift').write_text(sync[:sync.index('@MainActor\nextension SimpleOneRequestsStore')])
parser = (app / 'ClosedRequestsFeature/ClosedRequestsXLSXRequestsParser.swift').read_text()
# Exercise the real export-row parser without the ZIP/XML import entry point.
parse = block(parser, 'nonisolated static func parse(data:')
out.joinpath('Parser.swift').write_text(parser[:parser.index('nonisolated final class SharedStringsXMLParser')].replace(parse, ''))
store = (app / 'ClosedRequestsFeature/ClosedRequestsStore.swift').read_text()
properties = store[store.index('    @ObservationIgnored var workStatistics:'):store.index('    init()')].replace('@ObservationIgnored ', '')
parts = ['import Foundation', 'import OSLog', '@MainActor final class WorkStatisticsSyncCoordinator { var events: [String] = []; func beginRefresh(sourceUserID: String) async { events.append("preflight") }; func markSourcePassDirty() throws { events.append("dirty") }; func commitBatch(_ batch: SimpleOneClosedSyncBatch) async { events.append("commit") }; func endRefresh() { events.append("end") } }', '@MainActor final class SyncStoreHarness {', properties, 'init(snapshot: ClosedRequestsSnapshot) { self.snapshot = snapshot }', block(store, 'func beginClosedRequestsSync(')]
parts += [block(store, m) for m in ['func finishClosedRequestsSync(', 'func cancelClosedRequestsSync(', 'func synchronizeFromSimpleOne(', 'private func receiveClosedSyncProgress(', 'private func flushClosedSyncCheckpoint(', 'func waitForClosedRequestsSyncAvailability(', 'func applyClosedRequestsSyncBatch(', 'func shouldRunWideClosedRequestsSync(']]
parts += [block(store, m) for m in ['nonisolated private struct ClosedRequestsSyncApplication:', 'nonisolated private static func prepareClosedRequestsSyncBatch(', 'nonisolated private static func mergeSnapshot(', 'nonisolated private static func manualImportSyncState(', 'nonisolated private static func duplicateImportNotice(', 'nonisolated private static func closureCodeImportSummary(', 'nonisolated private static func isCompletedWithVisitClosureCode(', 'nonisolated private static func sortRecords(', 'nonisolated private static func sortDateText(', 'nonisolated private static func isReturnEquipment(', 'nonisolated private static func preservingMerchantTIN(', 'nonisolated private static func normalizedSimpleOneInfoKey(', 'nonisolated private static func parseClosedAt(']]
parts += [block(store, 'nonisolated private static let closedAtParsingFormatters:') + '()', 'nonisolated(unsafe) static var persistedWrites = 0', 'nonisolated private static func saveSnapshotToDisk(_ snapshot: ClosedRequestsSnapshot) throws {}', 'nonisolated private static func saveSnapshotDataToDisk(_ data: Data) throws { persistedWrites += 1 }', 'func setVerifiedRefreshForTest(_ value: Bool) { isRefreshingVerifiedArchive = value }', 'nonisolated static func apply(_ batch: SimpleOneClosedSyncBatch, to snapshot: ClosedRequestsSnapshot) throws -> ClosedRequestsSnapshot { try prepareClosedRequestsSyncBatch(batch, existingSnapshot: snapshot).snapshot }', 'nonisolated static func importing(_ incoming: ClosedRequestsSnapshot, into existing: ClosedRequestsSnapshot) -> ClosedRequestsSnapshot { mergeSnapshot(existing: existing, incoming: incoming).snapshot }', '}', 'func appUserFacingErrorMessage(_ error: Error) -> String? { error.localizedDescription }']
parts = [p.replace('SimpleOneRequestsStore', 'SyncSimpleOneHarness') for p in parts]
out.joinpath('Store.swift').write_text('\n'.join(parts))
PY
xcrun swiftc -parse-as-library "$task_test_dir/Models.swift" "$task_test_dir/Service.swift" \
    "$task_test_dir/Sync.swift" "$task_test_dir/Parser.swift" "$task_test_dir/Store.swift" \
    LumaWork/LumaWork/HomeFeature/ProfileWorkClassification.swift \
    LumaWork/LumaWork/WorkStatisticsFeature/WorkStatisticsModels.swift \
    LumaWork/LumaWork/WorkStatisticsFeature/WorkStatisticsAggregator.swift \
    LumaWork/LumaWork/AppSupport/AppConfig.swift \
    LumaWork/LumaWork/ClosedRequestsFeature/ClosedRequestsArchiveQuery.swift \
    LumaWork/LumaWork/ClosedRequestsFeature/ClosedRequestsMerchantTINSupport.swift \
    LumaWork/Tests/test-closed-sync.swift -o "$task_test_dir/tests"
"$task_test_dir/tests"
