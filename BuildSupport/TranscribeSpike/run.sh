#!/bin/bash
# Runs the transcribe.cpp vs MLX matrix one process at a time, network denied.
# Usage: run.sh <spike-dir> <output-dir> [reverse]
# <spike-dir> must contain build/transcribe-spike-bench, models/*.gguf,
# mlx-models/{whisper,parakeet,cohere}, fixtures/<name>-16k.wav and
# mlx-derived/Build/Products/Release/{SpeechBench,SpeechSmoke}. See README.md.
set -euo pipefail
spike="${1:?spike dir}"
out="${2:?output dir}"
order="${3:-forward}"
mkdir -p "$out"
deny_network='(version 1) (allow default) (deny network*)'
products="$spike/mlx-derived/Build/Products/Release"
models=(
  "whisper:whisper-tiny-F32.gguf"
  "parakeet:parakeet-tdt-0.6b-v2-F32.gguf"
  "cohere:cohere-transcribe-03-2026-Q4_K_M.gguf"
)
fixtures=(short padded medium long)
if [[ "$order" == reverse ]]; then
  models=("${models[2]}" "${models[1]}" "${models[0]}")
  fixtures=(long medium padded short)
fi

for entry in "${models[@]}"; do
  family="${entry%%:*}"
  gguf="$spike/models/${entry#*:}"
  for fixture in "${fixtures[@]}"; do
    wav="$spike/fixtures/$fixture-16k.wav"
    tag="$family-$fixture"
    echo "== $tag $(date +%T)" >&2
    # transcribe.cpp: load once, four calls in one process.
    /usr/bin/time -l sandbox-exec -p "$deny_network" \
      "$spike/build/transcribe-spike-bench" "$gguf" "$wav" 4 \
      > "$out/tcpp-$tag.jsonl" 2> "$out/tcpp-$tag-time.txt"
    # MLX: the repository's SpeechBench (reload, prepare, retained paths), four calls each.
    /usr/bin/time -l sandbox-exec -p "$deny_network" \
      "$products/SpeechBench" "$family" "$spike/mlx-models/$family" "$wav" 4 64 \
      > "$out/mlx-$tag.jsonl" 2> "$out/mlx-$tag-time.txt"
    # MLX transcript text, which SpeechBench deliberately omits.
    /usr/bin/time -l sandbox-exec -p "$deny_network" \
      "$products/SpeechSmoke" "$family" "$spike/mlx-models/$family" "$wav" \
      > "$out/mlx-$tag-smoke.txt" 2> "$out/mlx-$tag-smoke-time.txt"
  done
done
