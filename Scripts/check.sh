#!/bin/bash
set -euo pipefail
app_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$app_root"
xcrun swift-format lint --strict --recursive Amanuensis Tests Packages/LocalSpeech/Sources
swift test
checks_dir="$(mktemp -d "${TMPDIR:-/tmp}/amanuensis-checks.XXXXXX")"
trap 'rm -rf "$checks_dir"' EXIT
xcrun swiftc -swift-version 6 Amanuensis/Core/Domain.swift \
    Amanuensis/Storage/LocalStore.swift Tests/Storage/LocalStoreChecks.swift \
    -o "$checks_dir/storage-checks"
"$checks_dir/storage-checks"
if [[ -x Scripts/check-network.sh ]]; then Scripts/check-network.sh; fi
git diff --check
