#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/lumawork-wiki-time.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('LumaWork/LumaWork/WikiFeature.swift').read_text()
def block(marker):
    start = source.index(marker)
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]
parts = ['import Foundation', block('struct WikiHealthResponse'), block('struct WikiSearchResult'), block('private struct WikiSearchSnapshot')]
parts += ['struct CatalogSubject { var snapshotID: String?; var catalogUpdatedAt: String?', block('var catalogUpdateMessage: String'), '}']
parts += [Path('LumaWork/Tests/test-wiki-catalog-timestamps.swift').read_text()]
Path(sys.argv[1]).write_text('\n'.join(parts))
PY
TZ=Europe/Simferopol xcrun swift "$test_dir/main.swift"
TZ=UTC xcrun swift "$test_dir/main.swift"
