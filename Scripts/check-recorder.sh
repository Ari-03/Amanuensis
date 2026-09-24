#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
check_directory="$(mktemp -d "${TMPDIR:-/tmp}/amanuensis-recorder-checks.XXXXXX")"
trap 'rm -rf "$check_directory"' EXIT
xcrun swiftc -swift-version 6 -warnings-as-errors -target arm64-apple-macos26.0 \
    "$repo_root/Amanuensis/Core/Domain.swift" \
    "$repo_root/Amanuensis/Core/AudioSpectrum.swift" \
    "$repo_root/Amanuensis/Platform/RecorderPanel.swift" \
    "$repo_root/Amanuensis/Views/RecorderView.swift" \
    "$repo_root/Amanuensis/Views/SharedViews.swift" \
    "$repo_root/Tests/Platform/RecorderChecks.swift" \
    -o "$check_directory/recorder-checks"
"$check_directory/recorder-checks"
