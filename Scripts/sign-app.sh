#!/bin/bash
# Signs a built app from the inside out with the hardened runtime.
#
#   Scripts/sign-app.sh <app> <identity> [keychain]
#
# Release builds pass a Developer ID identity. `-` signs ad hoc, which checks the hardened runtime
# locally without a certificate. Only the app gets entitlements; the helper needs none.
set -euo pipefail
app_root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "Usage: $0 <app> <identity> [keychain]" >&2
    exit 1
fi
app="$1"
options=(--force --options runtime --sign "$2")
# Apple's timestamp server only countersigns certificate signatures.
if [[ "$2" == - ]]; then options+=(--timestamp=none); else options+=(--timestamp); fi
if [[ $# == 3 ]]; then options+=(--keychain "$3"); fi

codesign "${options[@]}" "$app/Contents/Helpers/S1MiniHelper"
# Xcode's local signature may carry debugging entitlements. Replace them with the checked-in list.
codesign "${options[@]}" --entitlements "$app_root/BuildSupport/Amanuensis.entitlements" "$app"

codesign --verify --deep --strict "$app"
# Anything executable added later must be signed above too, or notarization rejects the app.
while IFS= read -r -d '' file; do
    if [[ "$(file -b "$file")" != Mach-O* ]]; then continue; fi
    if [[ "$(codesign --display --verbose=2 "$file" 2>&1)" != *flags=*runtime* ]]; then
        echo "Sign $file in Scripts/sign-app.sh: it has no hardened runtime signature." >&2
        exit 1
    fi
done < <(find "$app/Contents" -type f -print0)
# Permissions follow this requirement. An ad-hoc one names a single build; a Developer ID one does not.
codesign --display --requirements - "$app"
