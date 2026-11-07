#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
task_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/lumawork-statistics.XXXXXX")"
trap 'rm -rf "$task_test_dir"' EXIT
python3 - "$task_test_dir" <<'PY'
from pathlib import Path
import sys
app=Path('LumaWork/LumaWork');out=Path(sys.argv[1])
s=(app/'AppModels.swift').read_text();out.joinpath('Models.swift').write_text('import Foundation\n'+s[s.index('nonisolated struct ClosedRequestInfoField:'):s.index('nonisolated struct TimeReportEntry:')])
s=(app/'ClosedRequestsFeature/ClosedRequestsIncrementalSync.swift').read_text();out.joinpath('Sync.swift').write_text(s[:s.index('nonisolated extension SimpleOneRequestsService')])
s=(app/'ClosedRequestsFeature/ClosedRequestsXLSXRequestsParser.swift').read_text();start=s.index('    nonisolated static func parse(data:');end=s.index('    nonisolated static func record(fromExportRow');out.joinpath('Parser.swift').write_text(s[:start]+s[end:s.index('nonisolated final class SharedStringsXMLParser')])
PY
xcrun swiftc -parse-as-library "$task_test_dir/Models.swift" "$task_test_dir/Sync.swift" "$task_test_dir/Parser.swift" \
 LumaWork/LumaWork/AppSupport/AppConfig.swift \
 LumaWork/LumaWork/ClosedRequestsFeature/ClosedRequestsArchiveQuery.swift \
 LumaWork/LumaWork/HomeFeature/ProfileWorkClassification.swift \
 LumaWork/LumaWork/ClosedRequestsFeature/ClosedRequestsMerchantTINSupport.swift \
 LumaWork/LumaWork/WorkStatisticsFeature/WorkStatisticsModels.swift \
 LumaWork/LumaWork/WorkStatisticsFeature/WorkStatisticsAggregator.swift \
 LumaWork/LumaWork/WorkStatisticsFeature/WorkStatisticsSourceIndex.swift \
 LumaWork/LumaWork/SimpleOneRequestsFeature/SimpleOneProtectedAccess.swift \
 LumaWork/LumaWork/WorkStatisticsFeature/LeaderboardModels.swift \
 LumaWork/LumaWork/WorkStatisticsFeature/LeaderboardCache.swift \
 LumaWork/LumaWork/WorkStatisticsFeature/LeaderboardStore.swift \
 LumaWork/LumaWork/WorkStatisticsFeature/WorkStatisticsAPI.swift \
 LumaWork/LumaWork/WorkStatisticsFeature/WorkStatisticsSyncCoordinator.swift \
 LumaWork/Tests/work-statistics-test-access.swift \
 LumaWork/LumaWork/WorkStatisticsFeature/LeaderboardAccessStore.swift \
 LumaWork/Tests/test-leaderboard-access.swift \
 LumaWork/Tests/test-work-statistics-network.swift \
 LumaWork/Tests/test-work-statistics.swift -o "$task_test_dir/tests"
TZ=Pacific/Honolulu "$task_test_dir/tests" LumaWork/Tests/Fixtures/work-statistics-fixtures.json
TZ=Asia/Tokyo "$task_test_dir/tests" LumaWork/Tests/Fixtures/work-statistics-fixtures.json
