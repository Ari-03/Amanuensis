#!/bin/bash
set -euo pipefail
app_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$app_root"
# Release builds set AMANUENSIS_VERSION (for example 0.2.0-preview.1) and AMANUENSIS_BUILD_NUMBER
# from the git tag; local builds keep the versions in the Xcode project.
version_settings=()
if [[ -n "${AMANUENSIS_VERSION:-}" ]]; then version_settings+=("MARKETING_VERSION=$AMANUENSIS_VERSION"); fi
if [[ -n "${AMANUENSIS_BUILD_NUMBER:-}" ]]; then
    version_settings+=("CURRENT_PROJECT_VERSION=$AMANUENSIS_BUILD_NUMBER")
fi
xcodebuild -project Amanuensis.xcodeproj -scheme Amanuensis \
    -configuration Release -jobs 4 -skipPackagePluginValidation -skipMacroValidation \
    -onlyUsePackageVersionsFromResolvedFile -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$app_root/DerivedData" \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual ${version_settings[@]+"${version_settings[@]}"} build
mkdir -p artifacts
# ditto merges directories, so remove the previous export to avoid stale bundled files.
rm -rf artifacts/Amanuensis.app
ditto DerivedData/Build/Products/Release/Amanuensis.app artifacts/Amanuensis.app
codesign --verify --deep --strict artifacts/Amanuensis.app
printf 'Ready: %s/artifacts/Amanuensis.app\n' "$app_root"
