#!/bin/bash
set -euo pipefail
app_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$app_root"

case "${1:-}" in
    '') Scripts/build.sh ;;
    --skip-build) ;;
    *)
        echo "Usage: $0 [--skip-build]" >&2
        exit 1
        ;;
esac
if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [--skip-build]" >&2
    exit 1
fi

app="$app_root/artifacts/Amanuensis.app"
codesign --verify --deep --strict "$app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
name="Amanuensis-$version-preview-arm64"
work="$(mktemp -d "${TMPDIR:-/tmp}/amanuensis-dmg.XXXXXX")"
mounted=false
cleanup() {
    if [[ "$mounted" == true ]]; then
        hdiutil detach "$work/mount" -force >/dev/null || return
    fi
    rm -rf "$work"
}
trap cleanup EXIT

mkdir -p "$work/staging" "$work/mount"
ditto "$app" "$work/staging/Amanuensis.app"
ln -s /Applications "$work/staging/Applications"
cat >"$work/staging/Read me.txt" <<'INFO'
Amanuensis requires an Apple Silicon Mac with macOS 26 or later.

Drag Amanuensis to Applications, eject this disk, then open the installed app.
Speech and cleanup models download separately from the app's Models page.

This development build is ad-hoc signed and is not notarized by Apple.
macOS may block downloaded copies. For a build you trust, follow Apple's
instructions: https://support.apple.com/en-us/102445
INFO
hdiutil create -volname Amanuensis -srcfolder "$work/staging" \
    -fs HFS+ -format UDZO "$work/$name.dmg"
hdiutil verify "$work/$name.dmg"

# Verify the app inside the actual disk image, including its bundled helper.
hdiutil attach "$work/$name.dmg" -readonly -nobrowse -mountpoint "$work/mount"
mounted=true
test "$(readlink "$work/mount/Applications")" = /Applications
codesign --verify --deep --strict "$work/mount/Amanuensis.app"
test -x "$work/mount/Amanuensis.app/Contents/Helpers/S1MiniHelper"
codesign --verify --strict "$work/mount/Amanuensis.app/Contents/Helpers/S1MiniHelper"
hdiutil detach "$work/mount"
mounted=false

mv "$work/$name.dmg" "$app_root/artifacts/$name.dmg"
cd "$app_root/artifacts"
shasum -a 256 "$name.dmg"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'dmg-path=artifacts/%s.dmg\n' "$name" >>"$GITHUB_OUTPUT"
fi
printf 'Ready: %s/artifacts/%s.dmg\n' "$app_root" "$name"
