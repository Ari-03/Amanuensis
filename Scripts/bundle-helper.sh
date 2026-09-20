#!/bin/bash
set -euo pipefail
# Xcode isolates this directory by target, configuration, and derived-data location.
helper_work="$DERIVED_FILE_DIR/S1Mini"
helper_source="$helper_work/dist"
helper_destination="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
# Generated binaries are not tracked. CMake incrementally prepares the helper for every Xcode build.
S1MINI_BUILD_CACHE="$helper_work/source" \
    S1MINI_BUILD_DIR="$helper_work/build" S1MINI_DIST_DIR="$helper_source" \
    "$SRCROOT/BuildSupport/S1Mini/build.sh"
mkdir -p "$helper_destination" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Licenses"
cp "$helper_source/S1MiniHelper" "$helper_destination/S1MiniHelper"
cp "$SRCROOT"/BuildSupport/S1Mini/licenses/* "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Licenses/"
/usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$helper_destination/S1MiniHelper"
