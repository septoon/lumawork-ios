#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
task_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/lumawork-network-diagnostics.XXXXXX")"
trap 'rm -rf "$task_test_dir"' EXIT
python3 - "$task_test_dir/Diagnostics.swift" <<'PY'
from pathlib import Path
import sys
source = Path('LumaWork/LumaWork/AppSupport/EndpointHTTP.swift').read_text()
# Run the actual diagnostics implementation, replacing only the OS logging sink.
# OSLog collection is asynchronous and subject to host retention/permissions.
diagnostics = source[source.index('nonisolated enum NetworkDiagnostics {'):source.index('\nstruct HTTPClient {')]
Path(sys.argv[1]).write_text('import Foundation\n' + diagnostics)
PY
for configuration in Debug Release; do
    flags=()
    if [ "$configuration" = Debug ]; then flags=(-D DEBUG); else flags=(-O); fi
    xcrun swiftc -parse-as-library "${flags[@]}" "$task_test_dir/Diagnostics.swift" \
        LumaWork/Tests/test-network-diagnostics.swift -o "$task_test_dir/tests"
    "$task_test_dir/tests"
done
