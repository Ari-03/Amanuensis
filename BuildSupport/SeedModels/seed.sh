#!/bin/bash
set -euo pipefail
seed_root="$(cd "$(dirname "$0")/../.." && pwd)"
# ModelLibrary asks the LocalSpeech package which files a model needs, so the tool is built as a small
# package around the app's own sources. The package and its build stay in the ignored .build folder,
# which keeps the slow first build of the speech runtime for later runs.
seed_package="$seed_root/BuildSupport/SeedModels/.build/package"
seed_sources="$seed_package/Sources/SeedModels"
rm -rf "$seed_sources"
mkdir -p "$seed_sources"
cp "$seed_root/Amanuensis/Core/Domain.swift" \
    "$seed_root/Amanuensis/Storage/LocalStore.swift" \
    "$seed_root/Amanuensis/Models/ModelCatalog.swift" \
    "$seed_root/Amanuensis/Models/ModelLibrary.swift" \
    "$seed_root/Amanuensis/Models/FileDownload.swift" \
    "$seed_sources/"
# A file named main.swift would be compiled as top-level code, which conflicts with its @main type.
cp "$seed_root/BuildSupport/SeedModels/main.swift" "$seed_sources/SeedModels.swift"
cat > "$seed_package/Package.swift" <<EOF
// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "SeedModels",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: "$seed_root/Packages/LocalSpeech")],
    targets: [
        .executableTarget(
            name: "SeedModels", dependencies: ["LocalSpeech"],
            swiftSettings: [.unsafeFlags(["-warnings-as-errors"])],
            linkerSettings: [.linkedLibrary("sqlite3")])
    ],
    swiftLanguageModes: [.v6]
)
EOF
swift build --package-path "$seed_package" --configuration release
seed_products="$(swift build --package-path "$seed_package" --configuration release --show-bin-path)"
# ModelCatalog loads its rows from the main bundle, which for a command-line tool is its folder.
cp "$seed_root/Amanuensis/Models/ModelCatalog.json" "$seed_products/"
"$seed_products/SeedModels" "$@"
