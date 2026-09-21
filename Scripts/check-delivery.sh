#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
check_directory="$(mktemp -d "${TMPDIR:-/tmp}/amanuensis-delivery-checks.XXXXXX")"
trap 'rm -rf "$check_directory"' EXIT
xcrun swiftc -swift-version 6 -warnings-as-errors \
    "$repo_root/Amanuensis/Platform/TextDelivery.swift" \
    "$repo_root/Tests/Platform/DeliveryChecks.swift" \
    -o "$check_directory/delivery-checks"
"$check_directory/delivery-checks"
