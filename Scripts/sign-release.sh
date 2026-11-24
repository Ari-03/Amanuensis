#!/bin/bash
# Replaces the ad-hoc build in artifacts/ with a Developer ID signed, notarized and stapled app and DMG.
# Run it after Scripts/package-dmg.sh and before Scripts/sign-update.sh, because it changes the DMG.
# With none of the secrets below set, it leaves the ad-hoc build alone. With only some, it fails.
# See docs/release-signing.md.
set -euo pipefail
app_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$app_root"

fail() {
    echo "Release signing: $*" >&2
    exit 1
}
set_output() {
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then printf 'notarized=%s\n' "$1" >>"$GITHUB_OUTPUT"; fi
}

secrets=(
    AMANUENSIS_SIGNING_CERTIFICATE          # Base64 PKCS#12: Developer ID Application certificate and key
    AMANUENSIS_SIGNING_CERTIFICATE_PASSWORD # Password of that PKCS#12
    AMANUENSIS_NOTARY_KEY                   # App Store Connect API key, the text of the .p8 file
    AMANUENSIS_NOTARY_KEY_ID
    AMANUENSIS_NOTARY_ISSUER_ID
)
missing=()
for name in "${secrets[@]}"; do
    if [[ -z "${!name:-}" ]]; then missing+=("$name"); fi
done
if [[ ${#missing[@]} == "${#secrets[@]}" ]]; then
    echo "No Developer ID secrets are set. Keeping the ad-hoc signed build."
    set_output false
    exit 0
fi
if [[ ${#missing[@]} != 0 ]]; then
    fail "some Developer ID secrets are set, but not: ${missing[*]}. Set all of them, or remove all of them."
fi

app="$app_root/artifacts/Amanuensis.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
dmg="$app_root/artifacts/Amanuensis-$version-arm64.dmg"
[[ -s "$dmg" ]] || fail "build $dmg first"

# mktemp makes this directory private. A umask would also restrict the files packaged into the DMG.
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/amanuensis-release-signing.XXXXXX")"
keychain="$work/signing.keychain-db"
cleanup() {
    security delete-keychain "$keychain" >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT

# Move the secrets into private files, so that no later command inherits them.
base64 -D <<<"$AMANUENSIS_SIGNING_CERTIFICATE" >"$work/certificate.p12" \
    || fail "AMANUENSIS_SIGNING_CERTIFICATE is not base64"
printf '%s\n' "$AMANUENSIS_NOTARY_KEY" >"$work/notary-key.p8"
certificate_password="$AMANUENSIS_SIGNING_CERTIFICATE_PASSWORD"
notary_credentials=(--key "$work/notary-key.p8" --key-id "$AMANUENSIS_NOTARY_KEY_ID"
    --issuer "$AMANUENSIS_NOTARY_ISSUER_ID")
unset "${secrets[@]}"

# On macOS 26, codesign finds an identity only in a keychain on the search list, even with --keychain.
# Deleting the keychain in cleanup also takes it off the list.
# The runner's System keychain holds Apple's Developer ID G2 intermediate certificate.
keychain_password="$(openssl rand -hex 24)"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 7200 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
# Read it on its own line, so a failed read stops here instead of replacing the list.
current_list="$(security list-keychains -d user | sed 's/^ *"\(.*\)"$/\1/')"
search_list=()
while IFS= read -r line; do if [[ -n "$line" ]]; then search_list+=("$line"); fi; done <<<"$current_list"
security list-keychains -d user -s "$keychain" ${search_list[@]+"${search_list[@]}"}
security import "$work/certificate.p12" -k "$keychain" -f pkcs12 -P "$certificate_password" \
    -T /usr/bin/codesign >/dev/null \
    || fail "AMANUENSIS_SIGNING_CERTIFICATE could not be opened with AMANUENSIS_SIGNING_CERTIFICATE_PASSWORD"
security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain" >/dev/null
rm "$work/certificate.p12"
identity="$(security find-identity -p codesigning "$keychain" \
    | sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "Developer ID Application: .*/\1/p' | sort -u)"
[[ "$identity" =~ ^[0-9A-F]{40}$ ]] \
    || fail "the certificate must hold exactly one Developer ID Application identity with its private key"

# Apple's documented Developer ID Application requirement. It rejects self-signed and other certificates.
requirement='=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists'
requirement+=' and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'

# Submits a file to Apple and waits. notarytool can exit 0 for a rejected file, so read its status.
notarize() {
    local id status
    xcrun notarytool submit "$1" "${notary_credentials[@]}" --wait --timeout 20m \
        --output-format json >"$work/notary.json" || true
    status="$(jq -r '.status // empty' "$work/notary.json" 2>/dev/null || true)"
    if [[ "$status" != Accepted ]]; then
        id="$(jq -r '.id // empty' "$work/notary.json" 2>/dev/null || true)"
        if [[ -n "$id" ]]; then xcrun notarytool log "$id" "${notary_credentials[@]}" >&2 || true; fi
        fail "Apple did not notarize $(basename "$1") (status: ${status:-none})"
    fi
}

# Attaches Apple's ticket, so Gatekeeper accepts the file offline. A new ticket can take a moment to appear.
staple() {
    local attempt
    for attempt in 1 2 3 4 5; do
        if xcrun stapler staple "$1"; then break; fi
        if [[ "$attempt" == 5 ]]; then fail "could not staple $(basename "$1")"; fi
        sleep 15
    done
    xcrun stapler validate "$1"
}

# spctl succeeds when Gatekeeper is switched off, so require the notarized source as well.
assess() {
    local result
    result="$(spctl --assess --verbose=4 "$@" 2>&1)" || fail "Gatekeeper rejected the build: $result"
    printf '%s\n' "$result"
    [[ "$result" == *"source=Notarized Developer ID"* ]] || fail "Gatekeeper did not see a notarized build"
}

Scripts/sign-app.sh "$app" "$identity" "$keychain"
codesign --verify --strict -R "$requirement" "$app/Contents/Helpers/S1MiniHelper"
codesign --verify --strict -R "$requirement" "$app"
ditto -c -k --keepParent "$app" "$work/Amanuensis.zip"
notarize "$work/Amanuensis.zip"
# Staple the app before packaging, so the copy dragged out of the DMG carries its own ticket.
staple "$app"
assess --type execute "$app"

AMANUENSIS_NOTARIZED=true Scripts/package-dmg.sh --skip-build
codesign --force --timestamp --keychain "$keychain" --sign "$identity" "$dmg"
codesign --verify --strict -R "$requirement" "$dmg"
notarize "$dmg"
staple "$dmg"
assess --type open --context context:primary-signature "$dmg"
set_output true
printf 'Notarized: %s\n' "$dmg"
