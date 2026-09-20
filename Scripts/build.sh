#!/bin/bash
set -euo pipefail
app_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$app_root"
xcodebuild -project Amanuensis.xcodeproj -scheme Amanuensis \
    -configuration Release -jobs 4 -skipPackagePluginValidation -skipMacroValidation -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$app_root/DerivedData" \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual build
mkdir -p artifacts
ditto DerivedData/Build/Products/Release/Amanuensis.app artifacts/Amanuensis.app
codesign --verify --deep --strict artifacts/Amanuensis.app
printf 'Ready: %s/artifacts/Amanuensis.app\n' "$app_root"
