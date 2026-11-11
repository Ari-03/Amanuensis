# transcribe.cpp spike

Reproduces the measurements in [the transcribe.cpp spike note](../../docs/research/transcribe-cpp-spike.md). Nothing here is built by Xcode or shipped in the app.

- `bench.cpp` loads one GGUF model once and transcribes the same 16 kHz mono WAV several times in one process, printing JSONL with wall times and transcripts. It requests English when the model lists languages, matching the MLX adapter.
- `probe.cpp` prints the capabilities and feature bits the C API reports for a model.
- `run.sh` runs the transcribe.cpp bench, `SpeechBench`, and `SpeechSmoke` for each model and fixture, one process at a time, with network denied.
- `summarize.py` turns a `run.sh` output directory into the Markdown table and word diffs.

All paths below live in a scratch directory outside the repository.

```sh
spike="${TMPDIR}tcpp-spike"
mkdir -p "$spike"/{src,build,models,mlx-models,fixtures,results}

# transcribe.cpp v0.4.1, static, Metal library embedded.
git clone --depth 1 --branch v0.4.1 https://github.com/handy-computer/transcribe.cpp.git "$spike/src/transcribe.cpp"
cmake -S "$spike/src/transcribe.cpp" -B "$spike/build/tcpp" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_SYSROOT="$(xcrun --sdk macosx --show-sdk-path)" -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DGGML_NATIVE=OFF -DTRANSCRIBE_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
  -DTRANSCRIBE_BUILD_TESTS=OFF -DTRANSCRIBE_BUILD_TOOLS=ON -DTRANSCRIBE_BUILD_EXAMPLES=ON
cmake --build "$spike/build/tcpp" --config Release --parallel 8

# Link the spike tools against the static libraries (probe.cpp the same way, without the example library).
b="$spike/build/tcpp"; t="$spike/src/transcribe.cpp"
xcrun clang++ -isysroot "$(xcrun --sdk macosx --show-sdk-path)" -std=c++17 -O2 -arch arm64 \
  -mmacosx-version-min=14.0 -Wall -Wextra -Werror -I"$t/include" -I"$t/examples/common" \
  BuildSupport/TranscribeSpike/bench.cpp "$b/examples/common/libtranscribe-common-example.a" \
  "$b/src/libtranscribe.a" "$b/ggml/src/libggml.a" "$b/ggml/src/ggml-metal/libggml-metal.a" \
  "$b/ggml/src/libggml-cpu.a" "$b/ggml/src/libggml-base.a" \
  -framework Accelerate -framework Metal -framework MetalKit -framework Foundation \
  -o "$spike/build/transcribe-spike-bench"
```

Download the GGUF files from the `handy-computer` Hugging Face repositories at the revisions in the note and check each SHA-256 with `shasum -a 256 --check`. Clone the installed MLX model folders into `$spike/mlx-models/{whisper,parakeet,cohere}` with `cp -cR` so no benchmark reads the app's data directory directly. Build `SpeechBench` and `SpeechSmoke` as in the [speech harness README](../SpeechSmoke/README.md), with `-derivedDataPath "$spike/mlx-derived"`.

Fixtures are synthesized with `say -v Samantha -f <name>.txt -o <name>.aiff`, converted with `afconvert -f WAVE -d LEI16@16000 -c 1`, and the padded clip comes from `make-padded-fixture.swift`. The three reference texts are in the note; save each as `$spike/fixtures/<name>.txt`.

```sh
BuildSupport/TranscribeSpike/run.sh "$spike" "$spike/results/pass1"
uv run --no-project python -I BuildSupport/TranscribeSpike/summarize.py "$spike/results/pass1" "$spike/fixtures"
```

Pass `reverse` as a third argument to `run.sh` to run models and fixtures in the opposite order. Run nothing else on the GPU meanwhile. `TRANSCRIBE_NO_MMAP=1` makes the bench copy weights instead of mapping them, which makes the process footprint include the weights.
