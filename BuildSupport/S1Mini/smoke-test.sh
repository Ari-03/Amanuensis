#!/bin/bash
set -euo pipefail
s1_root="$(cd "$(dirname "$0")" && pwd)"
s1_helper="$s1_root/dist/S1MiniHelper"
s1_model="${1:?Usage: smoke-test.sh /path/to/s1-mini-q4_k_m.gguf}"
s1_test="$(mktemp -d "${TMPDIR:-/tmp}/s1-mini-smoke.XXXXXX")"
trap 'rm -rf "$s1_test"' EXIT

run_case() {
  jq -n --arg transcript "$1" '{transcript:$transcript}' > "$s1_test/input.json"
  "$s1_helper" --model "$s1_model" --input "$s1_test/input.json" --output "$s1_test/output.json"
  jq -e "$2" "$s1_test/output.json" >/dev/null
  jq -c '{status,text,inputTokens,outputTokens}' "$s1_test/output.json"
}

run_case 'my name is Aritra and i work with Convex' '.status == "success" and (.text | contains("Aritra")) and (.text | contains("Convex"))'
run_case 'i think the answer is forty two no sorry forty three' '.status == "success" and (.text | contains("43")) and (.text | contains("42") | not)'
run_case 'um' '.status == "empty" and .text == ""'

printf '{"transcript":"hello","styling":"balanced"}' > "$s1_test/input.json"
if "$s1_helper" --model "$s1_model" --input "$s1_test/input.json" --output "$s1_test/output.json"; then
  echo 'Unsupported styling unexpectedly succeeded.' >&2; exit 1
fi
jq -e '.errorCode == "invalid_settings" and .text == ""' "$s1_test/output.json" >/dev/null

printf '{"transcript":"hello"}' > "$s1_test/input.json"
printf 'GGUF' > "$s1_test/invalid.gguf"
if "$s1_helper" --model "$s1_test/invalid.gguf" --input "$s1_test/input.json" --output "$s1_test/output.json"; then
  echo 'Corrupt model unexpectedly succeeded.' >&2; exit 1
fi
jq -e '.errorCode == "model_checksum_mismatch" and .text == ""' "$s1_test/output.json" >/dev/null

jq -n '{transcript:("hello " * 1200)}' > "$s1_test/input.json"
if "$s1_helper" --model "$s1_model" --input "$s1_test/input.json" --output "$s1_test/output.json"; then
  echo 'Oversized transcript unexpectedly succeeded.' >&2; exit 1
fi
jq -e '.errorCode == "input_too_long" and .text == ""' "$s1_test/output.json" >/dev/null

printf '{"transcript":"private-test-fragment"' > "$s1_test/input.json"
if "$s1_helper" --model "$s1_model" --input "$s1_test/input.json" --output "$s1_test/output.json" 2> "$s1_test/stderr"; then
  echo 'Malformed input unexpectedly succeeded.' >&2; exit 1
fi
jq -e '.errorCode == "invalid_request" and (.error | contains("private-test-fragment") | not)' "$s1_test/output.json" >/dev/null
[[ ! -s "$s1_test/stderr" ]]

printf '{"transcript":"hello"}' > "$s1_test/input.json"
"$s1_helper" --model "$s1_model" --input "$s1_test/input.json" --output "$s1_test/cancelled.json" &
s1_pid=$!
sleep 0.05
kill -TERM "$s1_pid"
s1_exit=0
wait "$s1_pid" || s1_exit=$?
[[ "$s1_exit" == 130 ]]
jq -e '.status == "cancelled" and .text == ""' "$s1_test/cancelled.json" >/dev/null
echo 'S1-mini smoke tests passed, including invalid settings, checksum rejection, and cancellation.'
