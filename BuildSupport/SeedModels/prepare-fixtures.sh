#!/bin/bash
# Copies already-tested weights. Network access fetches only model cards and license text.
set -euo pipefail
seed_sources="${1:?Usage: prepare-fixtures.sh /path/to/new-fixture-directory}"
if [[ -e "$seed_sources" ]]; then
    echo "Refusing to overwrite an existing fixture directory: $seed_sources" >&2
    exit 1
fi
for source in /tmp/amanuensis-smoke-whisper /tmp/amanuensis-smoke-parakeet /tmp/amanuensis-smoke-cohere; do
    [[ -d "$source" ]] || { echo "Missing tested source: $source" >&2; exit 1; }
done
[[ -f /tmp/amanuensis-s1-mini-q4_k_m.gguf ]] || { echo 'Missing tested S1-mini GGUF.' >&2; exit 1; }
mkdir -p "$seed_sources"
cp -cR /tmp/amanuensis-smoke-whisper "$seed_sources/whisper-tiny"
cp -cR /tmp/amanuensis-smoke-parakeet "$seed_sources/parakeet-v2"
cp -cR /tmp/amanuensis-smoke-cohere "$seed_sources/cohere-transcribe"
mkdir "$seed_sources/s1-mini"
cp -c /tmp/amanuensis-s1-mini-q4_k_m.gguf "$seed_sources/s1-mini/s1-mini-q4_k_m.gguf"

fetch_sidecar() {
    curl --fail --location --silent --show-error "$1" -o "$2.part"
    mv "$2.part" "$2"
}

fetch_sidecar 'https://huggingface.co/openai/whisper-tiny/raw/169d4a4341b33bc18d8881c4b69c2e104e1cc0af/README.md' "$seed_sources/whisper-tiny/README.md"
fetch_sidecar 'https://raw.githubusercontent.com/openai/whisper/86098128c0b4f24f0e2aa2994de830614b474227/LICENSE' "$seed_sources/whisper-tiny/LICENSE"
fetch_sidecar 'https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v2/raw/8ae155301e23d820d82aa60d24817c900e69e487/README.md' "$seed_sources/parakeet-v2/README.md"
fetch_sidecar 'https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2/raw/ae9ad07059c7c739ffaf932226a8fe64ae2620b0/README.md' "$seed_sources/parakeet-v2/UPSTREAM-README.md"
fetch_sidecar 'https://creativecommons.org/licenses/by/4.0/legalcode.txt' "$seed_sources/parakeet-v2/LICENSE"
fetch_sidecar 'https://huggingface.co/beshkenadze/cohere-transcribe-03-2026-mlx-4bit/raw/104bc4391b5b1a12b040859793d7148525e1a08c/README.md' "$seed_sources/cohere-transcribe/README.md"
# Cohere gates its official file repository; the converter card preserves the public provenance.
printf '%s\n' 'Upstream: https://huggingface.co/CohereLabs/cohere-transcribe-03-2026' 'Publisher: Cohere Labs. Upstream revision: b1eacc2686a3d08ceaae5f24a88b1d519620bc09.' 'Public 4-bit conversion by beshkenadze; see README.md.' > "$seed_sources/cohere-transcribe/UPSTREAM.txt"
fetch_sidecar 'https://www.apache.org/licenses/LICENSE-2.0.txt' "$seed_sources/cohere-transcribe/LICENSE"
for name in LICENSE NOTICE README.md; do
    fetch_sidecar "https://huggingface.co/superwhisper/s1-mini-GGUF/raw/34add00a48a2e5d24e5a4ee5405a99620a3a240c/$name" "$seed_sources/s1-mini/$name"
done
printf '%s\n' 'Tested weights copied without conversion. Model cards identify upstream authors and conversion authors.' > "$seed_sources/PREPARED.txt"
printf 'Prepared sources: %s\n' "$seed_sources"
