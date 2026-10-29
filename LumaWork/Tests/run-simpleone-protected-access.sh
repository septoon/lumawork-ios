#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/lumawork-so-access.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -parse-as-library LumaWork/LumaWork/SimpleOneRequestsFeature/SimpleOneProtectedAccess.swift LumaWork/Tests/SimpleOneProtectedAccessTests.swift -o "$test_dir/tests"
"$test_dir/tests"
