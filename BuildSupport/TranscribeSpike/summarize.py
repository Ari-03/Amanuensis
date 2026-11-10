"""Summarize one run.sh output directory as a Markdown table plus word diffs.

Usage: uv run --no-project python -I summarize.py <output-dir> <fixtures-dir>
Reference text is read from <fixtures-dir>/<fixture>.txt.
"""

import difflib
import json
import re
import statistics
import sys
from pathlib import Path

FAMILIES = ("whisper", "parakeet", "cohere")
FIXTURES = ("short", "padded", "medium", "long")
REFERENCE = {"padded": "short"}  # padded audio speaks the short sentence


def rows(path: Path) -> list[dict]:
    return [
        json.loads(line)
        for line in path.read_text().splitlines()
        if line.startswith("{")
    ]


def peak(path: Path) -> tuple[float, float]:
    """Return (max RSS, peak memory footprint) in GB from `/usr/bin/time -l` output."""
    text = path.read_text()
    rss = re.search(r"(\d+)\s+maximum resident set size", text)
    footprint = re.search(r"(\d+)\s+peak memory footprint", text)
    return (
        int(rss.group(1)) / 1e9 if rss else 0.0,
        int(footprint.group(1)) / 1e9 if footprint else 0.0,
    )


def words(text: str) -> list[str]:
    return re.sub(r"[^a-z0-9' ]", " ", text.lower()).split()


def word_diff(reference: str, hypothesis: str) -> tuple[float, list[str]]:
    """Word error rate after lowercasing and removing punctuation, plus the edit list."""
    ref, hyp = words(reference), words(hypothesis)
    edits, errors = [], 0
    for op, i1, i2, j1, j2 in difflib.SequenceMatcher(
        a=ref, b=hyp, autojunk=False
    ).get_opcodes():
        if op == "equal":
            continue
        errors += max(i2 - i1, j2 - j1)
        edits.append(f"{op}: '{' '.join(ref[i1:i2])}' -> '{' '.join(hyp[j1:j2])}'")
    return errors / len(ref), edits


def main() -> None:
    out, fixtures = Path(sys.argv[1]), Path(sys.argv[2])
    print(
        "| Model | Fixture | Runtime | Load s | First call s | Warm median s | RTF | Max RSS GB | Footprint GB | WER |"
    )
    print("| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    notes = []
    for family in FAMILIES:
        for fixture in FIXTURES:
            tag = f"{family}-{fixture}"
            reference = (
                (fixtures / f"{REFERENCE.get(fixture, fixture)}.txt")
                .read_text()
                .strip()
            )
            tcpp = rows(out / f"tcpp-{tag}.jsonl")
            runs = [r for r in tcpp if r["mode"] == "run"]
            texts = {r["text"].strip() for r in runs}
            mlx = rows(out / f"mlx-{tag}.jsonl")
            prepared = [r for r in mlx if r["mode"] == "production_preloaded"]
            smoke = (out / f"mlx-{tag}-smoke.txt").read_text()
            mlx_text = re.search(r"TRANSCRIPT: (.*)", smoke).group(1).strip()
            audio = runs[0]["audioSeconds"]
            results = {
                "transcribe.cpp": (
                    tcpp[0]["totalSeconds"],
                    runs[0]["totalSeconds"],
                    statistics.median(r["totalSeconds"] for r in runs[1:]),
                    peak(out / f"tcpp-{tag}-time.txt"),
                    runs[-1]["text"].strip(),
                ),
                "MLX": (
                    next(
                        r["totalSeconds"]
                        for r in mlx
                        if r["mode"] == "production_prepare"
                    ),
                    prepared[0]["totalSeconds"],
                    statistics.median(r["totalSeconds"] for r in prepared[1:]),
                    peak(out / f"mlx-{tag}-smoke-time.txt"),
                    mlx_text,
                ),
            }
            for runtime, (load, first, warm, (rss, footprint), text) in results.items():
                wer, edits = word_diff(reference, text)
                print(
                    f"| {family} | {fixture} ({audio:.1f} s) | {runtime} | {load:.3f} | {first:.3f} | "
                    f"{warm:.3f} | {warm / audio:.4f} | {rss:.2f} | {footprint:.2f} | {wer:.1%} |"
                )
                notes.append(f"- {tag} {runtime}: {'; '.join(edits) or 'exact words'}")
            if len(texts) != 1:
                notes.append(
                    f"- {tag} transcribe.cpp: calls returned {len(texts)} different transcripts"
                )
    print(
        "\nWord differences against the reference (lowercased, punctuation removed):\n"
    )
    print("\n".join(notes))


if __name__ == "__main__":
    main()
