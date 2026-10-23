#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/lumawork-gsm-import.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
app = Path('LumaWork/LumaWork')
src = (app / 'GsmReportFeature.swift').read_text()
phone = (app / 'GsmPhoneField.swift').read_text()
Path(sys.argv[1], 'Models.swift').write_text('import Foundation\n' + src[src.index('nonisolated struct GsmProjectOption:'):src.index('protocol GsmProfileServing')] + phone[phone.index('nonisolated enum GsmPhoneFormatter'):phone.index('struct GsmPhoneTextField')])
auth = (app / 'LumaWorkAuthFeature.swift').read_text()
with Path(sys.argv[1], 'Models.swift').open('a') as output:
    output.write(auth[auth.index('struct UserProfileData:'):auth.index('struct AppSession:')])
    output.write('private extension String { var nilIfBlank: String? { isEmpty ? nil : self } }\n')
protocols = src[src.index('protocol GsmProfileServing'):src.index('struct GsmProfileAPI:')]
store = src[src.index('@MainActor\n@Observable\nfinal class GsmProfileSettingsStore'):src.index('struct GsmReportAPI')]
validation = (app / 'VehicleFeature.swift').read_text()
validation = validation[validation.index('enum VehicleInputValidation'):validation.index('struct VehicleAPI')]
Path(sys.argv[1], 'Store.swift').write_text('import Foundation\nimport Observation\n' + protocols + store + validation)
PY
xcrun swiftc -parse-as-library "$test_dir/Models.swift" \
  LumaWork/LumaWork/ClosedRequestsFeature/ClosedRequestsXLSXArchive.swift \
  LumaWork/LumaWork/GsmProfileXlsx.swift \
  LumaWork/Tests/test-gsm-profile-import.swift -o "$test_dir/tests"
"$test_dir/tests" "$test_dir/stored.xlsx"
python3 - "$test_dir" <<'REPACK'
from pathlib import Path
import zipfile, sys
from datetime import date, timedelta
root = Path(sys.argv[1])
with zipfile.ZipFile(root / 'stored.xlsx') as source, zipfile.ZipFile(root / 'deflated.xlsx', 'w', compression=zipfile.ZIP_DEFLATED) as target:
    for name in source.namelist():
        target.writestr(name, source.read(name))
previous = date.today().replace(day=1) - timedelta(days=1)
months = ['январь', 'февраль', 'март', 'апрель', 'май', 'июнь', 'июль', 'август', 'сентябрь', 'октябрь', 'ноябрь', 'декабрь']
with zipfile.ZipFile(root / 'stored.xlsx') as source, zipfile.ZipFile(root / 'current.xlsx', 'w', compression=zipfile.ZIP_DEFLATED) as target:
    for name in source.namelist():
        data = source.read(name)
        if name == 'xl/worksheets/s0.xml':
            data = data.decode().replace('<s:t>сентябрь</s:t>', f'<s:t>{months[previous.month - 1]}</s:t>').replace('<s:t>2026</s:t>', f'<s:t>{previous.year}</s:t>').encode()
        target.writestr(name, data)
REPACK
"$test_dir/tests" --compressed "$test_dir/deflated.xlsx"

xcrun swiftc -parse-as-library "$test_dir/Models.swift" "$test_dir/Store.swift" \
  LumaWork/LumaWork/AppSupport/AppOfflineSnapshot.swift \
  LumaWork/LumaWork/ClosedRequestsFeature/ClosedRequestsXLSXArchive.swift \
  LumaWork/LumaWork/GsmProfileXlsx.swift \
  LumaWork/Tests/test-gsm-profile-draft.swift -o "$test_dir/draft-tests"
"$test_dir/draft-tests" "$test_dir/current.xlsx"
