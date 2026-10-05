#!/bin/bash
# Signs a verified DMG and checks its signature against the public key in the built app.
set -euo pipefail
app_root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# != 3 ]]; then
    echo "Usage: $0 <app> <dmg> <expected-version>" >&2
    exit 1
fi
app="$1"
dmg="$2"
version="$3"
if [[ -z "${AMANUENSIS_UPDATE_PRIVATE_KEY:-}${AMANUENSIS_UPDATE_PRIVATE_KEY_FILE:-}" ]]; then
    echo "Add the AMANUENSIS_UPDATE_PRIVATE_KEY repository secret before releasing." >&2
    exit 1
fi
test -s "$dmg"
if [[ "$(basename "$dmg")" != "Amanuensis-$version-arm64.dmg" ]] \
    || [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" != "$version" ]]; then
    echo "The DMG filename and app bundle must both match version $version." >&2
    exit 1
fi
public_key="$(/usr/libexec/PlistBuddy -c 'Print :AmanuensisUpdatePublicKey' "$app/Contents/Info.plist")"
signature="$(mktemp "$dmg.sig.XXXXXX")"
trap 'rm -f "$signature"' EXIT
xcrun swift "$app_root/Scripts/update-key.swift" sign "$dmg" >"$signature"
xcrun swift "$app_root/Scripts/update-key.swift" verify "$dmg" "$signature" "$public_key"
mv "$signature" "$dmg.sig"
