#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
check_directory="$(mktemp -d "${TMPDIR:-/tmp}/amanuensis-playback-checks.XXXXXX")"
trap 'rm -rf "$check_directory"' EXIT

xcrun swiftc -swift-version 6 -warnings-as-errors -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    "$repo_root/Amanuensis/Core/Domain.swift" \
    "$repo_root/Amanuensis/Audio/PlaybackController.swift" \
    "$repo_root/Tests/Platform/PlaybackChecks.swift" \
    -o "$check_directory/playback-checks"
"$check_directory/playback-checks"
