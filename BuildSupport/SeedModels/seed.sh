#!/bin/bash
set -euo pipefail
seed_root="$(cd "$(dirname "$0")/../.." && pwd)"
seed_build="$(mktemp -d "${TMPDIR:-/tmp}/amanuensis-seed-build.XXXXXX")"
trap 'rm -rf "$seed_build"' EXIT
xcrun swiftc -parse-as-library -swift-version 6 -warnings-as-errors \
    "$seed_root/Amanuensis/Core/Domain.swift" \
    "$seed_root/Amanuensis/Storage/LocalStore.swift" \
    "$seed_root/Amanuensis/Models/ModelCatalog.swift" \
    "$seed_root/Amanuensis/Models/ModelLibrary.swift" \
    "$seed_root/BuildSupport/SeedModels/main.swift" \
    -o "$seed_build/seed-models"
"$seed_build/seed-models" "$@"
