#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
task_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/lumawork-route-deletion.XXXXXX")"
trap 'rm -rf "$task_test_dir"' EXIT
python3 - "$task_test_dir" <<'PY'
from pathlib import Path
import sys
app = Path('LumaWork/LumaWork')
models = (app / 'AppModels.swift').read_text()
geometry = (app / 'HomeFeature/AppleRouteDistance.swift').read_text()
# Compile the production route DTOs and geometry types without the UIKit app shell or calculator.
Path(sys.argv[1], 'Models.swift').write_text(
    'import Foundation\nimport MapKit\n' +
    models[models.index('enum RouteWorkType:'):models.index('struct VirtualCardData:')] +
    geometry[geometry.index('nonisolated enum AppleRouteDistanceError:'):geometry.index('@available(iOS 26.0, macOS 26.0, *)')] +
    '\nenum AppLocale { static let russian = Locale(identifier: "ru_RU") }\n')
PY
xcrun swiftc -parse-as-library "$task_test_dir/Models.swift" \
    LumaWork/LumaWork/AddressNormalization.swift \
    LumaWork/LumaWork/HomeFeature/RouteLocalStorage.swift \
    LumaWork/Tests/test-route-day-deletion.swift -o "$task_test_dir/tests"
"$task_test_dir/tests"
