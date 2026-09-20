#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/amanuensis-helper-check.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT
source_root="$test_root/clean checkout"
mkdir -p "$source_root/BuildSupport/S1Mini" "$source_root/Scripts"
cp "$repo_root"/BuildSupport/S1Mini/{build.sh,CMakeLists.txt,main.cpp} "$source_root/BuildSupport/S1Mini/"
cp -R "$repo_root/BuildSupport/S1Mini/licenses" "$source_root/BuildSupport/S1Mini/"
cp "$repo_root/Scripts/bundle-helper.sh" "$source_root/Scripts/"

# Xcode launched from Finder does not inherit the terminal's Homebrew PATH.
PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    DERIVED_FILE_DIR="$test_root/derived files" \
    SRCROOT="$source_root" TARGET_BUILD_DIR="$test_root/products" \
    CONTENTS_FOLDER_PATH=Amanuensis.app/Contents \
    UNLOCALIZED_RESOURCES_FOLDER_PATH=Amanuensis.app/Contents/Resources \
    "$source_root/Scripts/bundle-helper.sh"
bundled="$test_root/products/Amanuensis.app/Contents"
test -x "$bundled/Helpers/S1MiniHelper"
cmp "$source_root/BuildSupport/S1Mini/licenses/S1-mini-NOTICE" "$bundled/Resources/Licenses/S1-mini-NOTICE"
codesign --verify --strict "$bundled/Helpers/S1MiniHelper"
echo 'Clean-checkout helper build and bundling passed with the Xcode PATH.'
