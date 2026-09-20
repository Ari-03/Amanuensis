#!/bin/bash
set -euo pipefail
helper_source="$SRCROOT/BuildSupport/S1Mini/dist"
helper_destination="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
# Generated binaries are not tracked. CMake incrementally prepares the helper for every Xcode build.
"$SRCROOT/BuildSupport/S1Mini/build.sh"
mkdir -p "$helper_destination" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Licenses"
cp "$helper_source/S1MiniHelper" "$helper_destination/S1MiniHelper"
cp "$SRCROOT"/BuildSupport/S1Mini/licenses/* "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Licenses/"
/usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$helper_destination/S1MiniHelper"
