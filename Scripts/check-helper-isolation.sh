#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/amanuensis-helper-isolation.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT
source_root="$test_root/clean checkout"
mkdir -p "$source_root/BuildSupport/S1Mini" "$source_root/Scripts"
cp "$repo_root"/BuildSupport/S1Mini/{build.sh,CMakeLists.txt,main.cpp} "$source_root/BuildSupport/S1Mini/"
cp -R "$repo_root/BuildSupport/S1Mini/licenses" "$source_root/BuildSupport/S1Mini/"
cp "$repo_root/Scripts/bundle-helper.sh" "$source_root/Scripts/"

# Run the real scripts; only compilation is replaced so isolation checks take seconds.
cat > "$test_root/cmake" <<'CMAKE'
#!/bin/bash
set -euo pipefail
if [[ "$1" == -S ]]; then
    [[ "$3" == -B && "$4" == "$EXPECTED_HELPER_ROOT/build" ]] || {
        echo 'FAIL: helper compilation uses shared source-tree outputs' >&2
        exit 1
    }
    mkdir -p "$4"
    cp /usr/bin/true "$4/S1MiniHelper"
else
    [[ "$1" == --build && "$2" == "$EXPECTED_HELPER_ROOT/build" ]]
fi
CMAKE
chmod +x "$test_root/cmake"

run_build() {
    local configuration="$1"
    local derived="$test_root/$configuration derived"
    local helper_root="$derived/S1Mini"
    mkdir -p "$helper_root/source/llama.cpp-4260903678a7525f43419dc234a942b551a8951e/include"
    touch "$helper_root/source/llama.cpp-4260903678a7525f43419dc234a942b551a8951e/include/llama.h"
    PATH=/usr/bin:/bin:/usr/sbin:/sbin CMAKE="$test_root/cmake" \
        S1MINI_BUILD_CACHE="$helper_root/source" EXPECTED_HELPER_ROOT="$helper_root" \
        DERIVED_FILE_DIR="$derived" SRCROOT="$source_root" TARGET_BUILD_DIR="$test_root/$configuration products" \
        CONTENTS_FOLDER_PATH=Amanuensis.app/Contents \
        UNLOCALIZED_RESOURCES_FOLDER_PATH=Amanuensis.app/Contents/Resources \
        "$source_root/Scripts/bundle-helper.sh"
    test -x "$helper_root/dist/S1MiniHelper"
    cmp "$helper_root/dist/S1MiniHelper" \
        "$test_root/$configuration products/Amanuensis.app/Contents/Helpers/S1MiniHelper"
}
run_build Debug > "$test_root/debug.log" 2>&1 &
debug_pid=$!
run_build Release > "$test_root/release.log" 2>&1 &
release_pid=$!
result=0
wait "$debug_pid" || result=1
wait "$release_pid" || result=1
if [[ "$result" != 0 ]]; then
    cat "$test_root/debug.log" "$test_root/release.log"
    exit 1
fi
test ! -d "$source_root/BuildSupport/S1Mini/.build"
test ! -d "$source_root/BuildSupport/S1Mini/dist"
echo 'Concurrent helper builds use separate derived-data outputs.'
