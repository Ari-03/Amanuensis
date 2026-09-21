#!/bin/bash
set -euo pipefail
if [[ "$#" != 5 ]]; then
    echo 'Usage: check-packaged-speech.sh APP AUDIO MODEL_DIRECTORY FAMILY S1_MODEL' >&2
    exit 2
fi
smoke_root="$(mktemp -d "${TMPDIR:-/tmp}/amanuensis-packaged-check.XXXXXX")"
smoke_pid=''
cleanup() {
    if [[ -n "$smoke_pid" ]]; then kill -TERM "$smoke_pid" 2>/dev/null || true; fi
    rm -rf "$smoke_root"
}
trap cleanup EXIT
codesign --verify --deep --strict "$1"
sandbox-exec -p '(version 1) (allow default) (deny network*)' \
    "$1/Contents/MacOS/Amanuensis" --speech-smoke "$2" "$3" "$4" "$5" \
    "$smoke_root/result.json" > "$smoke_root/app.log" 2>&1 &
smoke_pid=$!
attempts=0
while kill -0 "$smoke_pid" 2>/dev/null; do
    if [[ "$attempts" -ge 90 ]]; then
        echo 'FAIL: packaged speech test did not finish inference and shutdown within 90 seconds.' >&2
        exit 1
    fi
    sleep 1
    attempts=$((attempts + 1))
done
wait "$smoke_pid"
smoke_pid=''
jq -e '.status == "success" and (.transcript | length > 0) and (.cleaned | type == "string")' \
    "$smoke_root/result.json" > /dev/null
echo 'Packaged speech and persistent cleanup passed twice with identical output, network denied, and clean shutdown.'
