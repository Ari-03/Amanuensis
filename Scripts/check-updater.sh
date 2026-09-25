#!/bin/bash
# Exercises the in-app updater end to end without GitHub: serves a signed DMG from a local web
# server, then checks channel filtering, signature rejection, download verification, and the bundle
# swap against a throwaway copy of the app. Needs a built app and its DMG.
#
#   Scripts/check-updater.sh [app-bundle] [dmg]
#
# Defaults to artifacts/Amanuensis.app and the newest artifacts/Amanuensis-*-arm64.dmg.
set -euo pipefail
app_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$app_root"
app="${1:-artifacts/Amanuensis.app}"
dmg="${2:-$(ls -t artifacts/Amanuensis-*-arm64.dmg 2>/dev/null | head -n 1)}"
if [[ ! -d "$app" || -z "$dmg" || ! -f "$dmg" ]]; then
    echo "Build the app and DMG first: Scripts/package-dmg.sh" >&2
    exit 1
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/amanuensis-updater-check.XXXXXX")"
server_pid=""
cleanup() {
    if [[ -n "$server_pid" ]]; then { kill "$server_pid" && wait "$server_pid"; } 2>/dev/null || true; fi
    rm -rf "$work"
}
trap cleanup EXIT

# The "installed" copy reports an old version and trusts a throwaway key generated for this run.
mkdir -p "$work/installed" "$work/serve"
ditto "$app" "$work/installed/Amanuensis.app"
installed_plist="$work/installed/Amanuensis.app/Contents/Info.plist"
public_key="$(xcrun swift Scripts/update-key.swift generate "$work/private-key")"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 0.0.1" "$installed_plist"
/usr/libexec/PlistBuddy -c "Set :AmanuensisUpdatePublicKey $public_key" "$installed_plist"

# Serve the real DMG flagged as a prerelease so both channels are exercised. The tag must equal the
# version inside the DMG, because the installer compares them.
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
dmg_name="$(basename "$dmg")"
ln "$dmg" "$work/serve/$dmg_name" 2>/dev/null || cp "$dmg" "$work/serve/$dmg_name"
AMANUENSIS_UPDATE_PRIVATE_KEY_FILE="$work/private-key" xcrun swift Scripts/update-key.swift sign "$dmg" \
    >"$work/good.sig"
xcrun swift Scripts/update-key.swift verify "$dmg" "$work/good.sig" "$public_key" >/dev/null
tr 'A-Za-z' 'N-ZA-Mn-za-m' <"$work/good.sig" >"$work/bad.sig"
cp "$work/bad.sig" "$work/serve/$dmg_name.sig"
size="$(stat -f %z "$dmg")"

python3 -u -m http.server 0 --bind 127.0.0.1 --directory "$work/serve" >"$work/server.log" 2>&1 &
server_pid=$!
port=""
for _ in $(seq 1 50); do
    port="$(sed -n 's/.*port \([0-9]*\).*/\1/p' "$work/server.log" | head -n 1)"
    if [[ -n "$port" ]]; then break; fi
    sleep 0.1
done
if [[ -z "$port" ]]; then
    echo "The local web server did not start" >&2
    cat "$work/server.log" >&2
    exit 1
fi
base="http://127.0.0.1:$port"
cat >"$work/serve/releases.json" <<JSON
[
  {"tag_name": "v9.9.9", "draft": true, "prerelease": false, "html_url": "$base/draft",
   "assets": [{"name": "Amanuensis-9.9.9-arm64.dmg", "size": 1, "browser_download_url": "$base/missing.dmg"},
              {"name": "Amanuensis-9.9.9-arm64.dmg.sig", "size": 1, "browser_download_url": "$base/missing.sig"}]},
  {"tag_name": "v$version", "draft": false, "prerelease": true, "html_url": "$base/notes",
   "assets": [{"name": "$dmg_name", "size": $size, "browser_download_url": "$base/$dmg_name"},
              {"name": "$dmg_name.sig", "size": 100, "browser_download_url": "$base/$dmg_name.sig"}]}
]
JSON

xcrun swiftc -swift-version 6 -warnings-as-errors -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    Amanuensis/Core/Updates.swift Amanuensis/App/AppUpdater.swift Tests/App/UpdaterChecks.swift \
    -o "$work/updater-checks"
"$work/updater-checks" "$work/installed/Amanuensis.app" "$base/releases.json" \
    "$work/good.sig" "$work/bad.sig" "$work/serve/$dmg_name.sig"
