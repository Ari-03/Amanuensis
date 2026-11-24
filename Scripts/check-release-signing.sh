#!/bin/bash
# Exercises Developer ID release signing with a throwaway certificate and a stand-in for Apple's
# services. Real codesign, security and hdiutil run on a tiny app; the real secrets are never used.
set -euo pipefail
app_root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/amanuensis-release-signing-checks.XXXXXX")"
trap 'rm -rf "$work"' EXIT
checkout="$work/clean checkout"
version=0.2.0-nightly.10
app="$checkout/artifacts/Amanuensis.app"
dmg="$checkout/artifacts/Amanuensis-$version-arm64.dmg"
mkdir -p "$checkout/Scripts" "$checkout/BuildSupport" "$app/Contents/MacOS" "$app/Contents/Helpers" \
    "$work/bin" "$work/runner"
cp "$app_root"/Scripts/{sign-app,sign-release,package-dmg}.sh "$checkout/Scripts/"
cp "$app_root/BuildSupport/Amanuensis.entitlements" "$checkout/BuildSupport/"
keychains="$(security list-keychains -d user)"

fail() {
    echo "FAIL: $*" >&2
    if [[ -f "$work/output" ]]; then cat "$work/output" >&2; fi
    exit 1
}

# Only Apple's side is replaced: the notary service, tickets, Gatekeeper, the timestamp server, and the
# Developer ID requirement, which no throwaway certificate can meet. Calls are logged in order.
cat >"$work/bin/xcrun" <<'SHIM'
#!/bin/bash
set -euo pipefail
echo "xcrun $1 $2 $(basename "$3")" >>"$SHIM_LOG"
[[ "$1 $2" != "notarytool submit" ]] || printf '{"id":"1","status":"%s"}\n' "${SHIM_STATUS:-Accepted}"
# Stapling changes the file, as the real ticket does.
[[ "$1 $2" != "stapler staple" || ! -f "$3" ]] || printf 'ticket' >>"$3"
SHIM
cat >"$work/bin/spctl" <<'SHIM'
#!/bin/bash
echo "spctl $(basename "${!#}")" >>"$SHIM_LOG"
printf '%s: accepted\n%s\n' "${!#}" "${SHIM_GATEKEEPER:-source=Notarized Developer ID}"
SHIM
cat >"$work/bin/codesign" <<'SHIM'
#!/bin/bash
set -euo pipefail
arguments=()
while [[ $# != 0 ]]; do
    case "$1" in
        --timestamp) arguments+=(--timestamp=none) ;;
        -R) if [[ "${SHIM_REQUIREMENT:-skip}" == real ]]; then arguments+=("$1" "$2"); fi; shift ;;
        *) arguments+=("$1") ;;
    esac
    if [[ "$1" == --sign ]]; then echo "codesign $(basename "${!#}")" >>"$SHIM_LOG"; fi
    shift
done
exec /usr/bin/codesign "${arguments[@]}"
SHIM
chmod +x "$work/bin"/*
export PATH="$work/bin:$PATH" SHIM_LOG="$work/log" RUNNER_TEMP="$work/runner" GITHUB_OUTPUT="$work/github-output"
secrets=(AMANUENSIS_SIGNING_CERTIFICATE AMANUENSIS_SIGNING_CERTIFICATE_PASSWORD
    AMANUENSIS_NOTARY_KEY AMANUENSIS_NOTARY_KEY_ID AMANUENSIS_NOTARY_ISSUER_ID)
unset "${secrets[@]}"

# An ad-hoc build without the hardened runtime and with a debugging entitlement, as Xcode makes it.
reset_build() {
    cp /usr/bin/true "$app/Contents/MacOS/Amanuensis"
    cp /usr/bin/true "$app/Contents/Helpers/S1MiniHelper"
    rm -f "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string ari.Amanuensis' \
        -c 'Add :CFBundleExecutable string Amanuensis' -c 'Add :CFBundlePackageType string APPL' \
        -c "Add :CFBundleShortVersionString string $1" "$app/Contents/Info.plist" >/dev/null
    /usr/libexec/PlistBuddy -c 'Add :com.apple.security.get-task-allow bool true' "$work/debug.entitlements" \
        >/dev/null 2>&1 || true
    /usr/bin/codesign --force --sign - "$app/Contents/Helpers/S1MiniHelper" 2>/dev/null
    /usr/bin/codesign --force --sign - --entitlements "$work/debug.entitlements" "$app" 2>/dev/null
    printf 'ad-hoc DMG\n' >"$checkout/artifacts/Amanuensis-$1-arm64.dmg"
    : >"$SHIM_LOG"
    : >"$GITHUB_OUTPUT"
}
run() { "$checkout/Scripts/sign-release.sh" >"$work/output" 2>&1; }
# Every outcome must remove the temporary keychain and key files and leave the search list alone.
check_clean() {
    [[ -z "$(ls -A "$RUNNER_TEMP")" ]] || fail "$1 left files behind"
    [[ "$(security list-keychains -d user)" == "$keychains" ]] || fail "$1 changed the keychain search list"
}
reject() {
    if run; then fail "expected a failure: $2"; fi
    grep -qF "$1" "$work/output" || fail "expected '$1': $2"
    if grep -q notarized=true "$GITHUB_OUTPUT"; then fail "a failed run reported a notarized build"; fi
    check_clean "$2"
}

# A throwaway self-signed certificate named like a Developer ID one, packed as the documentation says.
make_certificate() {
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 2 -keyout "$work/key.pem" -out "$work/$1.pem" \
        -subj "/CN=$2" -extensions code -config <(printf '%s\n' '[req]' 'distinguished_name=dn' '[dn]' '[code]' \
            'keyUsage=critical,digitalSignature' 'extendedKeyUsage=critical,codeSigning') 2>/dev/null
    /usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/$1.pem" -out "$work/$1.p12" \
        -passout pass:check
    base64 <"$work/$1.p12" >"$work/$1.base64"
}
make_certificate developer-id 'Developer ID Application: Amanuensis Check (CHECK00000)'
make_certificate development 'Apple Development: Amanuensis Check (CHECK00000)'
values=("$(cat "$work/developer-id.base64")" check $'-----BEGIN PRIVATE KEY-----\ncheck' KEYID issuer)

# No secrets: the ad-hoc build is untouched.
reset_build "$version"
cp -R "$app" "$work/before.app"
run || fail 'a run without secrets must succeed'
diff -r "$app" "$work/before.app" >/dev/null || fail 'a run without secrets changed the app'
[[ "$(cat "$dmg")" == 'ad-hoc DMG' ]] || fail 'a run without secrets changed the DMG'
[[ "$(cat "$GITHUB_OUTPUT")" == notarized=false ]] || fail 'a run without secrets must report notarized=false'
check_clean 'a run without secrets'

# Each single missing secret, and each secret alone, is refused by name before anything is signed.
for index in "${!secrets[@]}"; do
    reset_build "$version"
    for other in "${!secrets[@]}"; do
        if [[ "$other" != "$index" ]]; then export "${secrets[$other]}=${values[$other]}"; fi
    done
    reject "but not: ${secrets[$index]}." "without ${secrets[$index]}"
    unset "${secrets[@]}"
    export "${secrets[$index]}=${values[$index]}"
    reject 'Set all of them, or remove all of them.' "with only ${secrets[$index]}"
    unset "${secrets[@]}"
    [[ ! -s "$SHIM_LOG" ]] || fail 'a partly configured run reached signing'
done
for index in "${!secrets[@]}"; do export "${secrets[$index]}=${values[$index]}"; done

reset_build "$version"
AMANUENSIS_SIGNING_CERTIFICATE_PASSWORD=wrong reject 'could not be opened' 'a wrong certificate password'
AMANUENSIS_SIGNING_CERTIFICATE="$(cat "$work/development.base64")" \
    reject 'exactly one Developer ID Application identity' 'another kind of certificate'
SHIM_REQUIREMENT=real reject 'test-requirement' 'a certificate Apple did not issue'
reset_build "$version"
SHIM_STATUS=Invalid reject 'did not notarize Amanuensis.zip (status: Invalid)' 'a rejected app'
[[ "$(cat "$dmg")" == 'ad-hoc DMG' ]] || fail 'a rejected app was packaged'
reset_build "$version"
SHIM_GATEKEEPER='override=security disabled' reject 'did not see a notarized build' 'a switched-off Gatekeeper'

# All secrets: inside out, app stapled before packaging, DMG signed after that, in this exact order.
reset_build "$version"
run || fail 'a fully configured run must succeed'
check_clean 'a fully configured run'
cat >"$work/expected" <<LOG
codesign S1MiniHelper
codesign Amanuensis.app
xcrun notarytool submit Amanuensis.zip
xcrun stapler staple Amanuensis.app
xcrun stapler validate Amanuensis.app
spctl Amanuensis.app
codesign $(basename "$dmg")
xcrun notarytool submit $(basename "$dmg")
xcrun stapler staple $(basename "$dmg")
xcrun stapler validate $(basename "$dmg")
spctl $(basename "$dmg")
LOG
# The shim logs xcrun's third argument, which is the file for both tools.
diff "$work/expected" "$SHIM_LOG" || fail 'signing steps ran in the wrong order'
grep -qx notarized=true "$GITHUB_OUTPUT" || fail 'a notarized build must be reported'
[[ "$(tail -c 6 "$dmg")" == ticket ]] || fail 'the DMG changed after stapling'
for code in "$app" "$app/Contents/Helpers/S1MiniHelper"; do
    [[ "$(codesign --display --verbose=2 "$code" 2>&1)" == *'flags=0x10000(runtime)'* ]] \
        || fail "$code lacks the hardened runtime"
done
codesign --display --entitlements - --xml "$app" 2>/dev/null >"$work/entitlements.plist"
[[ "$(plutil -convert json -o - "$work/entitlements.plist")" == '{"com.apple.security.device.audio-input":true}' ]] \
    || fail 'the app must carry only the microphone entitlement'
[[ -z "$(codesign --display --entitlements - --xml "$app/Contents/Helpers/S1MiniHelper" 2>/dev/null)" ]] \
    || fail 'the helper must carry no entitlements'

# macOS keeps a permission while new code meets the old code's designated requirement. A later build
# signed with the same certificate does; a rebuilt ad-hoc app does not.
# codesign prints an ad-hoc requirement as a comment, because it is implied rather than stored.
requirement() { codesign --display --requirements - "$1" 2>/dev/null | sed -n 's/^#* *designated => /=/p'; }
certificate_requirement="$(requirement "$app")"
reset_build 0.2.0-nightly.11
adhoc_requirement="$(requirement "$app")"
/usr/bin/codesign --verify -R "$adhoc_requirement" "$app" || fail 'could not read the ad-hoc requirement'
run || fail 'the second fully configured run must succeed'
/usr/bin/codesign --verify -R "$certificate_requirement" "$app" || fail 'an update changed identity'
if /usr/bin/codesign --verify -R "$adhoc_requirement" "$app" 2>/dev/null; then
    fail 'an ad-hoc requirement must not match another build'
fi
printf 'Release signing checks passed.\n'
