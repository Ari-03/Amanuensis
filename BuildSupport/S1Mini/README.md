# S1-mini helper

`S1MiniHelper` runs the official `S1-mini` by `Superwhisper` Q4_K_M weights locally through statically linked llama.cpp. It needs no Ollama installation, server, API key, or network connection. The helper accepts only the pinned model checksum below. It does not download models or insert text into another app.

## Build and bundle

Requires Xcode and CMake. Normal Xcode builds prepare this helper automatically. Run `BuildSupport/S1Mini/build.sh` only when building the helper on its own. The script searches the terminal PATH and standard Homebrew/CMake app locations; `CMAKE` can specify an absolute executable path. The script fetches llama.cpp at commit `4260903678a7525f43419dc234a942b551a8951e`, verifies the source archive hash on download, and builds arm64 for macOS 14+. `S1MINI_BUILD_CACHE` changes the source cache location. `S1MINI_ARCH` changes the CMake target architecture; only arm64 is validated here.

Xcode keeps dependency sources, CMake outputs, and the staged executable inside `DERIVED_FILE_DIR/S1Mini`, separate for each configuration and derived-data location. Standalone builds use `BuildSupport/S1Mini/.build` and `dist`; `S1MINI_BUILD_DIR` and `S1MINI_DIST_DIR` override those locations.

The standalone distributable executable is `BuildSupport/S1Mini/dist/S1MiniHelper`. Copy it into the app's `Contents/Helpers/S1MiniHelper`, preserve executable permissions, and sign it with the application signing identity before signing the app. The build script uses ad hoc signing for local testing. Copy `dist/licenses/` into the app's third-party notices resources. Metal kernels are embedded; no downloaded dylibs or `.metallib` files need to accompany the executable. `otool -L` should list only system libraries/frameworks.

Build output and dependency source remain ignored or outside the repository. Run `xcrun clang-format --dry-run --Werror BuildSupport/S1Mini/main.cpp` for formatting validation. The helper compiles with warnings treated as errors.

## Model

Download or import `s1-mini-q4_k_m.gguf` from [Superwhisper's pinned official release](https://huggingface.co/superwhisper/s1-mini-GGUF/blob/34add00a48a2e5d24e5a4ee5405a99620a3a240c/s1-mini-q4_k_m.gguf).

- Bytes: `484219808`
- SHA-256: `3b41ebe2502cbd03e811d5d16b022f5ab551eda58d62597d152f89535003c634`
- License: Apache-2.0 plus the additional naming clause in `licenses/S1-mini-LICENSE`; preserve the exact identification `S1-mini` by `Superwhisper`.

The helper verifies the file hash before every load. Store weights in application support, outside the signed app bundle. Never reuse a locked proprietary-app asset or require that app to be installed.

## Process contract

```sh
S1MiniHelper --model /path/model.gguf --input /private/path/request.json --output /private/path/result.json
```

```json
{"transcript":"um send it on friday no thursday","styling":"semi-formal","structure":"prose","context":"general"}
```

`transcript` is required. Other defaults match the example. Supported styling values are `casual`, `semi-casual`, `semi-formal`, and `formal`; structure is `prose` or `lists`; context is `general` or `email`. Unknown control values are rejected.

```json
{"status":"success","text":"Send it on Thursday.","model":"S1-mini by Superwhisper","inputTokens":10,"outputTokens":6}
```

Token counts above are illustrative. Successful completion exits 0 with `success` or `empty`; empty text is a valid filler-suppression outcome. Errors exit 1 and add `errorCode` and `error`, with no partial text. SIGTERM/SIGINT cancellation exits 130 with `cancelled`. Counts are zero on errors. Result files are written atomically with private file permissions. No transcript is printed to stdout/stderr or passed through argv.

The caller must create a private temporary directory, delete request/result files afterward, and read results only after process exit. It must retain the raw transcript, handle absent result files if the process crashes, and enforce a deadline. To cancel, send SIGTERM, allow a short grace interval, then SIGKILL if necessary. Model-load progress and decode boundaries check cancellation. Do not paste when the operation was cancelled, even if a completion raced with cancellation.

## Model contract and limits

The helper uses the author's exact system prompt and literal non-thinking assistant prefix, with a greedy sampler. Transcript content is tokenized without interpreting embedded chat delimiters. [Official format and settings](https://huggingface.co/superwhisper/s1-mini-GGUF).

Each request accepts at most 1,000 transcript tokens. Longer requests return `input_too_long`; the app must split long material on sentence boundaries before cleanup or retain the raw transcript. The generation budget is 1.3 times the transcript token count plus 32. Missing EOS at the bound, model control text, invalid JSON/UTF-8, and unsupported settings produce errors rather than partial cleanup. This validation cannot prove that the model preserved every fact; raw text must remain available.

The app uses the persistent protocol below. The one-shot command remains available for diagnostics. No cloud fallback exists.

## Persistent process

```sh
S1MiniHelper --model /path/model.gguf --serve
```

Write one JSON object per line to stdin. Each request uses the same fields as above and a required, nonempty `id` string of at most 128 bytes. Responses arrive on stdout, one JSON object per line, carrying the matching `id`. Transcript text stays inside these pipes and is never placed in arguments, logs, or temporary files. Stderr remains silent during normal operation. Malformed requests return a sanitized error with a null ID when no ID could be read. Each line is limited to 262,144 bytes.

The helper validates and loads its pinned model once, on the first valid request. Each request creates a fresh context and greedy sampler; no previous transcript or KV cache is reused. File identity, size, modification time, and change time must still match before and after inference. A changed model ends the process with `model_changed`, preventing reuse of stale weights. Stdin EOF releases the model and exits. SIGTERM/SIGINT during inference returns `cancelled` and exits 130.

`S1MiniRunner` allows one request at a time, checks response IDs and sizes, and enforces a deadline of at most 120 seconds per chunk. Cancellation, a deadline, protocol errors, or a crash discard the process. The next cleanup starts a fresh helper. SIGTERM gets a two-second grace period before SIGKILL. Successful requests reuse the helper across chunks and recordings until 60 seconds of inactivity. Memory pressure releases it after the active transcript finishes, or immediately while idle. The runner checks file metadata before each request and replaces the process when it changes.

Call `await runner.unload()` before deleting a model or releasing its library lease for removal. It cancels pending work and returns only after the helper exits and releases mapped model files. The app also calls it on sleep and shutdown. Old disk jobs from earlier versions are swept during initialization; new requests create no job files.

On this M1 development Mac, four short one-shot requests took 0.62–0.83 seconds. The same requests repeated in forward and reverse order through one loaded helper took 0.08–0.27 seconds, with identical text and token counts. The first persistent request took 0.71 seconds. These measurements include full helper inference and IPC but exclude the Swift runner and speech recognition. See `docs/research/data/transcription-performance/s1-persistent.json` for samples.

## Verify

Run `Scripts/check-s1-runner.sh` for model-free runner lifecycle checks. Run `uv run --no-project python BuildSupport/S1Mini/persistent-test.py /path/to/s1-mini-q4_k_m.gguf` for real inference equivalence, request isolation, malformed input, token limits, EOF, cancellation, restart, and timings.

Run `BuildSupport/S1Mini/smoke-test.sh /path/to/s1-mini-q4_k_m.gguf`. It exercises names, numeric self-correction, filler suppression, unsupported controls, corrupt imports, and SIGTERM cancellation using real inference.

Verified September 19, 2026 on this arm64 development Mac with the pinned weights. Names retained Aritra and Convex; numeric correction retained 43 and removed 42; filler-only input returned `empty`. Email cleanup produced a greeting, a $43 invoice request, and Aritra's sign-off. That request took 1.36 seconds after initial Metal setup; this is a single development measurement, not a latency guarantee. The first inference took longer while the OS prepared Metal resources. Invalid controls, checksum mismatch, and cancellation tests passed.

Included notices cover Superwhisper's model, llama.cpp, and nlohmann JSON. The model derives from Qwen3-0.6B as recorded in the upstream NOTICE. Follow the upstream licenses when redistributing modified code or assets.

Run `Scripts/check-helper-build.sh` to verify automatic preparation and bundling from a source-only temporary checkout with Xcode's restricted PATH.

Run `Scripts/check-helper-isolation.sh` for a fast concurrent-build path check using a fake compiler.
