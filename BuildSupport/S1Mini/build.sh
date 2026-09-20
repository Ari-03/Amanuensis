#!/bin/bash
set -euo pipefail

# Only build-time source retrieval uses the network; the helper cannot download.
s1_root="$(cd "$(dirname "$0")" && pwd)"
s1_cache="${S1MINI_BUILD_CACHE:-${TMPDIR:-/tmp}/amanuensis-s1-build}"
s1_revision=4260903678a7525f43419dc234a942b551a8951e
s1_archive_sha=58ed1960793b36a4e356f0992796e7a271385b4a9e0719dc33e871cbf9ca19f7
s1_source="$s1_cache/llama.cpp-$s1_revision"
command -v cmake >/dev/null || { echo 'Install CMake before building, for example brew install cmake.' >&2; exit 1; }
mkdir -p "$s1_cache" "$s1_root/dist"
if [[ ! -f "$s1_source/include/llama.h" ]]; then
  curl --fail --location --retry 3 "https://github.com/ggml-org/llama.cpp/archive/$s1_revision.tar.gz" -o "$s1_cache/llama.tar.gz"
  printf '%s  %s\n' "$s1_archive_sha" "$s1_cache/llama.tar.gz" | shasum -a 256 --check
  tar -xzf "$s1_cache/llama.tar.gz" -C "$s1_cache"
fi
cmake -S "$s1_root" -B "$s1_root/.build" \
  -DLLAMA_SOURCE="$s1_source" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_SYSROOT="$(DEVELOPER_DIR="$(xcode-select -p)" xcrun --sdk macosx --show-sdk-path)" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DCMAKE_OSX_ARCHITECTURES="${S1MINI_ARCH:-arm64}"
cmake --build "$s1_root/.build" --target S1MiniHelper --parallel "$(sysctl -n hw.ncpu)"
cp "$s1_root/.build/S1MiniHelper" "$s1_root/dist/S1MiniHelper"
cp -R "$s1_root/licenses" "$s1_root/dist/licenses"
codesign --force --sign - "$s1_root/dist/S1MiniHelper"
printf 'Bundle helper: %s\n' "$s1_root/dist/S1MiniHelper"
