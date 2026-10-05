#!/bin/bash
# Exercises the release signing boundary with temporary keys, never the release secret.
set -euo pipefail
app_root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/amanuensis-signing-checks.XXXXXX")"
trap 'rm -rf "$work"' EXIT
app="$work/Amanuensis.app"
version=0.2.0-nightly.10
dmg="$work/Amanuensis-$version-arm64.dmg"
mkdir -p "$app/Contents"
public_key="$(xcrun swift "$app_root/Scripts/update-key.swift" generate "$work/private-key")"
unset AMANUENSIS_UPDATE_PRIVATE_KEY
export AMANUENSIS_UPDATE_PRIVATE_KEY_FILE="$work/private-key"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $version" "$app/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Add :AmanuensisUpdatePublicKey string $public_key" "$app/Contents/Info.plist"
printf 'An update payload for signature checks.\n' >"$dmg"
sign_script="$app_root/Scripts/sign-update.sh"

expect_failure() {
    if "$@" >"$work/output" 2>&1; then
        printf 'Expected failure: %s\n' "$*" >&2
        exit 1
    fi
}

"$sign_script" "$app" "$dmg" "$version" >/dev/null
test -s "$dmg.sig"
xcrun swift "$app_root/Scripts/update-key.swift" verify "$dmg" "$dmg.sig" "$public_key" >/dev/null
cp "$dmg.sig" "$work/original.sig"
expect_failure "$sign_script" "$app" "$dmg" 0.2.0
expect_failure env -u AMANUENSIS_UPDATE_PRIVATE_KEY_FILE "$sign_script" "$app" "$dmg" "$version"
# A mismatched key must fail verification without replacing a previously valid signature.
xcrun swift "$app_root/Scripts/update-key.swift" generate "$work/wrong-key" >/dev/null
expect_failure env AMANUENSIS_UPDATE_PRIVATE_KEY_FILE="$work/wrong-key" "$sign_script" "$app" "$dmg" "$version"
cmp "$dmg.sig" "$work/original.sig"
printf 'tampered\n' >>"$dmg"
expect_failure xcrun swift "$app_root/Scripts/update-key.swift" verify "$dmg" "$dmg.sig" "$public_key"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.2.0' "$app/Contents/Info.plist"
expect_failure "$sign_script" "$app" "$dmg" "$version"
printf 'Update signing checks passed.\n'
