#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/amanuensis-s1-runner.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT
cat > "$test_root/fake-helper" <<'PY'
#!/usr/bin/python3
import json
import os
import signal
import sys
import time

for line in sys.stdin:
    request = json.loads(line)
    text = request["transcript"]
    if text == "ignore-term":
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        time.sleep(10)
    if text == "slow":
        time.sleep(0.2)
    if text == "hang":
        time.sleep(10)
    if text == "crash":
        sys.exit(1)
    if text == "stdout-eof":
        os.close(1)
        time.sleep(10)
    if text == "malformed":
        print("not-json", flush=True)
        continue
    if text == "oversized":
        print("a" * 300000, flush=True)
        continue
    response = {"id": "wrong" if text == "wrong-id" else request["id"],
                "status": "success", "text": str(os.getpid()) + ":" + text}
    serialized = json.dumps(response)
    if text == "duplicate":
        serialized += "\n" + serialized
    print(serialized, flush=True)
    if text == "close-input":
        os.close(0)
        time.sleep(10)
PY
chmod +x "$test_root/fake-helper"
# Warm the fixture interpreter before timing requests. Its first launch can take seconds
# on a fresh macOS runner, independently of the subprocess behavior under test.
"$test_root/fake-helper" </dev/null
xcrun swiftc -swift-version 6 "$repo_root/Amanuensis/Core/Domain.swift" \
  "$repo_root/Amanuensis/Inference/S1MiniRunner.swift" \
  "$repo_root/Tests/Inference/S1MiniRunnerChecks.swift" -o "$test_root/checks"
"$test_root/checks" "$test_root"
