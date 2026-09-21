#!/usr/bin/env python3
"""Compare the persistent protocol with one-shot inference using pinned weights."""

import json
import pathlib
import statistics
import subprocess
import sys
import tempfile
import time

helper = pathlib.Path(__file__).parent / "dist" / "S1MiniHelper"
model = pathlib.Path(sys.argv[1])
cases = [
    {"transcript": "my name is Aritra and i work with Convex"},
    {"transcript": "i think the answer is forty two no sorry forty three"},
    {"transcript": "um"},
    {"transcript": "send it on friday no thursday", "structure": "lists"},
]


def start():
    return subprocess.Popen(
        [str(helper), "--model", str(model), "--serve"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def request(process, body, request_id):
    assert process.stdin is not None and process.stdout is not None
    process.stdin.write(json.dumps({**body, "id": request_id}) + "\n")
    process.stdin.flush()
    result = json.loads(process.stdout.readline())
    assert result["id"] == request_id, result
    return result


with tempfile.TemporaryDirectory(prefix="s1-persistent-test-") as directory:
    root = pathlib.Path(directory)
    baseline = []
    one_shot_seconds = []
    for body in cases:
        (root / "input.json").write_text(json.dumps(body))
        started = time.perf_counter()
        subprocess.run(
            [
                str(helper),
                "--model",
                str(model),
                "--input",
                str(root / "input.json"),
                "--output",
                str(root / "output.json"),
            ],
            check=True,
            capture_output=True,
        )
        one_shot_seconds.append(time.perf_counter() - started)
        baseline.append(json.loads((root / "output.json").read_text()))
    process = start()
    try:
        # Warm one request, then change settings/transcripts and repeat in reverse order.
        started = time.perf_counter()
        request(process, cases[0], "warmup")
        cold_seconds = time.perf_counter() - started
        warm_seconds = []
        for index in [0, 1, 2, 3, 3, 2, 1, 0]:
            started = time.perf_counter()
            actual = request(process, cases[index], str(len(warm_seconds)))
            warm_seconds.append(time.perf_counter() - started)
            actual.pop("id")
            assert actual == baseline[index], (actual, baseline[index])
        assert (
            request(process, {"transcript": "hello", "styling": "bad"}, "settings")[
                "errorCode"
            ]
            == "invalid_settings"
        )
        assert (
            request(process, {"transcript": "hello " * 1200}, "limit")["errorCode"]
            == "input_too_long"
        )
        assert process.stdin is not None and process.stdout is not None
        process.stdin.write('{"transcript":"private-fragment"\n')
        process.stdin.flush()
        malformed = process.stdout.readline()
        assert "private-fragment" not in malformed
        assert json.loads(malformed)["errorCode"] == "invalid_request"
        assert request(process, cases[0], "after-error")["text"] == baseline[0]["text"]
        process.stdin.close()
        assert process.wait(timeout=5) == 0
        assert process.stderr is not None and process.stderr.read() == ""
        print(
            json.dumps(
                {
                    "oneShotSeconds": one_shot_seconds,
                    "persistentFirstSeconds": cold_seconds,
                    "persistentWarmSeconds": warm_seconds,
                    "oneShotMedianSeconds": statistics.median(one_shot_seconds),
                    "persistentWarmMedianSeconds": statistics.median(warm_seconds),
                    "transcriptsAndTokenCountsMatch": True,
                },
                indent=2,
            )
        )
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
    # Cancellation terminates a resident worker. A new process starts cleanly.
    process = start()
    try:
        request(process, cases[0], "before-cancel")
        assert process.stdin is not None and process.stdout is not None
        process.stdin.write(
            json.dumps({"id": "cancel", "transcript": "hello " * 900}) + "\n"
        )
        process.stdin.flush()
        time.sleep(0.02)
        process.terminate()
        result = json.loads(process.stdout.readline())
        assert result["status"] == "cancelled", result
        assert process.wait(timeout=5) == 130
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
    process = start()
    try:
        assert request(process, cases[1], "restart")["text"] == baseline[1]["text"]
        assert process.stdin is not None
        process.stdin.close()
        assert process.wait(timeout=5) == 0
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
print(
    "Persistent S1-mini checks passed, including isolation, malformed input, limits, EOF, cancellation, and restart."
)
