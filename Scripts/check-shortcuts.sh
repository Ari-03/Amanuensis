#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
check_directory="$(mktemp -d "${TMPDIR:-/tmp}/amanuensis-shortcut-checks.XXXXXX")"
trap 'rm -rf "$check_directory"' EXIT
xcrun swiftc -swift-version 6 -warnings-as-errors \
    "$repo_root/Amanuensis/Core/Domain.swift" \
    "$repo_root/Amanuensis/Platform/GlobalShortcuts.swift" \
    "$repo_root/Amanuensis/Views/ShortcutRecorder.swift" \
    "$repo_root/Tests/Platform/ShortcutChecks.swift" \
    -o "$check_directory/shortcut-checks"
"$check_directory/shortcut-checks"
