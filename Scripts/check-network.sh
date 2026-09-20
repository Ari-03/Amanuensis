#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
check_directory="$(mktemp -d "${TMPDIR:-/tmp}/amanuensis-network-checks.XXXXXX")"
trap 'rm -rf "$check_directory"' EXIT

xcrun swiftc -swift-version 6 -warnings-as-errors -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    "$repo_root/Amanuensis/Core/Domain.swift" \
    "$repo_root/Amanuensis/Network/CredentialStore.swift" \
    "$repo_root/Amanuensis/Network/CloudProviders.swift" \
    "$repo_root/Tests/Network/CloudProviderChecks.swift" \
    -o "$check_directory/cloud-provider-checks"
"$check_directory/cloud-provider-checks"
