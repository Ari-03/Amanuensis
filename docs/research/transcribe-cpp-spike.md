# transcribe.cpp as a second speech runtime

November 10, 2026. Baseline commit `7c748a4`. Measurements use this development Mac, an Apple M1 with 16 GiB RAM, running macOS 27.0.1 build 26A434, Xcode with the macOS 26.5 SDK. Every number below comes from a command recorded in this note or in the [spike README](../../BuildSupport/TranscribeSpike/README.md).

## The question

Amanuensis runs Whisper, Parakeet and Cohere through MLX Audio Swift. [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) is an MIT, ggml-based C library that loads GGUF speech models from many families through one C API. Could it ship as a bundled helper process, like the S1-mini llama.cpp helper, and how does it compare with MLX on this Mac for the same models and audio?

## What was built

transcribe.cpp tag `v0.4.1`, commit `4d7c1ccefd39e5a9ea36cca5f8fefc6dcc14b99b`, released October 22, 2026. Its vendored ggml is upstream `d7cb574130e6f01ad25b3289685489200febcd74` with three local patches (`ggml/UPSTREAM`). The GitHub source archive for that commit is 46,097,287 bytes with SHA-256 `77bfafa35bd7eee447ec37b832e99c342c62b7db0c6cb18c36e763563b586b1f`.

```sh
git clone --depth 1 --branch v0.4.1 https://github.com/handy-computer/transcribe.cpp.git
cmake -S transcribe.cpp -B build/tcpp -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_SYSROOT="$(xcrun --sdk macosx --show-sdk-path)" -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DGGML_NATIVE=OFF -DTRANSCRIBE_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
  -DTRANSCRIBE_BUILD_TESTS=OFF -DTRANSCRIBE_BUILD_TOOLS=ON -DTRANSCRIBE_BUILD_EXAMPLES=ON
cmake --build build/tcpp --config Release --parallel 8
```

Configure took 4.9 s and the build 42.1 s wall (166.9 s user) with `/usr/bin/time -p`, using Unix Makefiles on 8 cores with nothing else compiling. CMake reported `backends: metal;cpu` and found Accelerate. The build is static by default (`TRANSCRIBE_BUILD_SHARED OFF`).

| Artifact | Bytes |
| --- | ---: |
| `libtranscribe.a` | 3,863,848 |
| `libggml-metal.a` (embedded Metal source) | 5,616,192 |
| `libggml-cpu.a` + `libggml-base.a` + `libggml.a` | 2,288,104 |
| `transcribe-cli`, unstripped / stripped | 9,157,280 / 8,606,688 |
| Minimal C API program (`probe.cpp`), stripped | 8,489,936 |
| Same, linked with `-Wl,-dead_strip`, stripped | 8,004,168 |
| Shipped `S1MiniHelper` in the October 4 nightly app, for comparison | 7,076,080 |

`otool -L transcribe-cli` lists only system libraries: Accelerate, Foundation, Metal, MetalKit, CoreFoundation, libc++, libobjc and libSystem. No `.metallib` or dylib accompanies the executable. Each process still compiles the embedded Metal source at startup; the log shows 36 `ggml_metal_library_compile_all` entries, which summed to 0.27 to 0.80 s in three sampled bench logs.

Two spike programs link against these static libraries: `bench.cpp` loads a model once and transcribes the same WAV four times in one process, and `probe.cpp` prints reported capabilities. Both are in `BuildSupport/TranscribeSpike/`.

### Models

GGUF files come from the catalog's `published_repo` entries, pinned to the repository revision, and each matched the SHA-256 in the Hugging Face LFS metadata (`curl https://huggingface.co/api/models/<repo>/revision/main?blobs=true`, then `shasum -a 256 --check`: all three `OK`).

| Model | GGUF repository and revision | File, bytes | SHA-256 | Installed MLX counterpart |
| --- | --- | --- | --- | --- |
| Whisper Tiny | `handy-computer/whisper-tiny-gguf` `1bd61cda36bbd22c88fc5a33842498a6e1d30f45` | `whisper-tiny-F32.gguf`, 152,997,824 | `f5e0ecdd9967173fdede25ceb7e5159b3294f05b8dc0c87b0876fccd36f18982` | `openai/whisper-tiny` safetensors, F32 |
| Parakeet TDT 0.6B V2 | `handy-computer/parakeet-tdt-0.6b-v2-gguf` `58239cf6d0ecb0af921e7936c1e5e0a8dba91dbb` | `parakeet-tdt-0.6b-v2-F32.gguf`, 2,471,550,272 | `501ba1e61965cdb28689614c648d2c560d75895b47a2948b9010b4e8c9cf1325` | `mlx-community/parakeet-tdt-0.6b-v2`, F32 |
| Cohere Transcribe 03-2026 | `handy-computer/cohere-transcribe-03-2026-gguf` `7353b6040bdc1be9e5a3823d99d5fe12afe88264` | `cohere-transcribe-03-2026-Q4_K_M.gguf`, 1,558,162,944 | `0ea56826d8bd5d74b7143a4a04e022dc1bb75452cfae49d98b6acb0c1d16a1fb` | `beshkenadze/cohere-transcribe-03-2026-mlx-4bit` |

Whisper and Parakeet match precision. Cohere is the closest available pair, not an exact one: the MLX conversion is MLX 4-bit affine quantization, and Q4_K_M mixes 4-bit and 6-bit k-quant blocks. The GGUF catalog publishes no MLX-style 4-bit file. Total download was 4.18 GB.

The installed MLX models were cloned into the scratch directory with `cp -cR` and their weight hashes matched the pins in the [speech harness README](../../BuildSupport/SpeechSmoke/README.md). No benchmark opened the application support directory directly.

### Catalog at v0.4.1

The `catalog/` directory at the tag holds 77 variant records across 21 families, including one diarizer, one language-ID and one VAD model, and lists 398 downloadable GGUF files. Licenses include Apache-2.0 (26 variants), CC-BY-4.0 (16), MIT (11), one CC-BY-NC-4.0 and several custom licenses. Published speed benchmarks cover `m4`, `m4-max` and `ryzen-4750u` only; no M1 rows exist, so the catalog's speed numbers do not predict this machine.

## Measurements

### Method

Fixtures are synthesized Samantha speech written as 16 kHz mono PCM16 WAV, so both runtimes read identical samples and no resampling differs. Short and medium use the texts from [the earlier investigation](transcription-performance.md) (3.202 s and 18.280 s). Padded is the short clip with 5 s of digital silence on each side from `make-padded-fixture.swift` (13.202 s). Long is new, 64.192 s:

> Good morning everyone. This is a quick update on the quarterly planning work before our review on Friday. First, the mobile release is still on track for the end of the month, although the payment screen needs another round of testing on older phones. Daniel has agreed to coordinate that testing with the support team, and he will share the results in the shared channel by Wednesday evening. Second, the marketing budget for the spring campaign has been reduced by about fifteen percent, so we need to choose which two regions will receive the full launch and which will receive a smaller announcement. I suggest that we keep the full launch in Canada and Australia, because those markets responded well last year. Third, the hiring plan is moving more slowly than expected. We have interviewed six candidates for the data engineering role, and two of them will move to the final stage next week. Finally, please remember to submit your travel requests for the conference in Lisbon before the deadline, because the hotel discount expires soon. If you have any questions about these items, send me a message or add them to the agenda, and we will discuss them together at the start of the meeting.

```sh
say -v Samantha -o long.aiff -f long.txt
afconvert -f WAVE -d LEI16@16000 -c 1 long.aiff long-16k.wav
xcrun swift BuildSupport/SpeechSmoke/make-padded-fixture.swift short-16k.wav padded-16k.wav
BuildSupport/TranscribeSpike/run.sh "$spike" "$spike/results/pass1"
BuildSupport/TranscribeSpike/run.sh "$spike" "$spike/results/pass2" reverse
uv run --no-project python -I BuildSupport/TranscribeSpike/summarize.py "$spike/results/pass1" "$spike/fixtures"
```

`run.sh` runs each process alone under `/usr/bin/time -l` and `sandbox-exec` with network denied, in this order per model and fixture: the transcribe.cpp bench, the repository's `SpeechBench` with 4 repetitions and the 64 MiB cache, then `SpeechSmoke` for the MLX transcript text.

- **Load**: transcribe.cpp is `transcribe_model_load_file` plus `transcribe_session_init`. MLX is `SpeechBench`'s `production_prepare`, which is `LocalSpeechEngine.prepare`.
- **First call**: the first transcription after load in the same process. For MLX it is the first `production_preloaded` call.
- **Warm median**: median of calls 2, 3 and 4 in the same process. For MLX these are `production_preloaded` calls, the path the app ships.
- **RTF**: warm median divided by audio duration.
- **Peak footprint**: `peak memory footprint` from `/usr/bin/time -l`. For transcribe.cpp it is the bench process; for MLX it is the `SpeechSmoke` process, which is one production load and one transcription. See the memory section before comparing these.
- **WER**: word error rate against the reference text after lowercasing and removing punctuation.

Pass 1 ran 11:11 to 11:14 and pass 2, in reverse model and fixture order, 11:17 to 11:21. Before pass 1 I waited 20 minutes for another agent's Xcode build in a different checkout to finish (load average 34.7 at 10:51), then started once the compilers had exited and total CPU was about 5%. Load averages were 1.56 and 2.32 at the start and end of pass 1, and 2.83 and 3.42 for pass 2. At the start of pass 2 another agent's process in a different worktree was using 80.8% CPU; Cohere ran first in that pass. T3 Code, an Electron app from another worktree and Zoom were open but idle throughout. The MLX Cohere padded result in pass 2 (1.046 s against 0.740 s in pass 1) is the clearest sign of contention; treat pass 1 as primary.

### Results

| Model | Fixture | Runtime | Load s (p1 / p2) | First call s (p1 / p2) | Warm median s (p1 / p2) | RTF (p1 / p2) | Peak footprint GB | WER |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Whisper Tiny | short (3.2 s) | transcribe.cpp | 0.169 / 0.078 | 0.132 / 0.127 | 0.127 / 0.123 | 0.0395 / 0.0384 | 0.11 | 0.0% |
| Whisper Tiny | short (3.2 s) | MLX | 0.194 / 0.195 | 0.086 / 0.087 | 0.083 / 0.085 | 0.0261 / 0.0267 | 0.37 | 0.0% |
| Whisper Tiny | padded (13.2 s) | transcribe.cpp | 0.188 / 0.083 | 0.191 / 0.127 | 0.194 / 0.130 | 0.0147 / 0.0098 | 0.11 | 0.0% |
| Whisper Tiny | padded (13.2 s) | MLX | 0.200 / 0.195 | 0.085 / 0.087 | 0.077 / 0.086 | 0.0058 / 0.0065 | 0.37 | 0.0% |
| Whisper Tiny | medium (18.3 s) | transcribe.cpp | 0.084 / 0.083 | 0.313 / 0.366 | 0.377 / 0.319 | 0.0206 / 0.0174 | 0.11 | 0.0% |
| Whisper Tiny | medium (18.3 s) | MLX | 0.236 / 0.210 | 0.263 / 0.281 | 0.248 / 0.257 | 0.0136 / 0.0141 | 0.37 | 0.0% |
| Whisper Tiny | long (64.2 s) | transcribe.cpp | 0.094 / 0.134 | 1.310 / 1.041 | 1.505 / 1.025 | 0.0234 / 0.0160 | 0.11 | 1.0% |
| Whisper Tiny | long (64.2 s) | MLX | 0.196 / 0.246 | 1.076 / 0.871 | 1.222 / 0.874 | 0.0190 / 0.0136 | 0.39 | 1.9% |
| Parakeet V2 | short (3.2 s) | transcribe.cpp | 1.910 / 0.761 | 0.407 / 0.132 | 0.114 / 0.115 | 0.0355 / 0.0359 | 0.13 | 0.0% |
| Parakeet V2 | short (3.2 s) | MLX | 0.390 / 0.386 | 0.107 / 0.100 | 0.107 / 0.093 | 0.0335 / 0.0290 | 3.82 | 0.0% |
| Parakeet V2 | padded (13.2 s) | transcribe.cpp | 0.846 / 0.770 | 0.306 / 0.315 | 0.303 / 0.308 | 0.0229 / 0.0234 | 0.14 | 0.0% |
| Parakeet V2 | padded (13.2 s) | MLX | 0.392 / 0.388 | 0.275 / 0.246 | 0.286 / 0.243 | 0.0217 / 0.0184 | 3.82 | 0.0% |
| Parakeet V2 | medium (18.3 s) | transcribe.cpp | 0.817 / 0.795 | 0.513 / 0.463 | 0.464 / 0.516 | 0.0254 / 0.0282 | 0.14 | 0.0% |
| Parakeet V2 | medium (18.3 s) | MLX | 0.410 / 0.409 | 0.511 / 0.373 | 0.476 / 0.367 | 0.0260 / 0.0201 | 3.82 | 0.0% |
| Parakeet V2 | long (64.2 s) | transcribe.cpp | 0.817 / 1.923 | 2.147 / 3.445 | 1.968 / 2.134 | 0.0307 / 0.0332 | 0.17 | 1.0% |
| Parakeet V2 | long (64.2 s) | MLX | 0.376 / 0.393 | 1.513 / 1.206 | 1.468 / 1.207 | 0.0229 / 0.0188 | 3.83 | 1.5% |
| Cohere 03-2026 | short (3.2 s) | transcribe.cpp | 0.565 / 0.719 | 0.815 / 0.308 | 0.314 / 0.299 | 0.0980 / 0.0933 | 0.12 | 0.0% |
| Cohere 03-2026 | short (3.2 s) | MLX | 0.294 / 0.472 | 0.340 / 0.433 | 0.333 / 0.377 | 0.1039 / 0.1177 | 1.82 | 0.0% |
| Cohere 03-2026 | padded (13.2 s) | transcribe.cpp | 0.104 / 0.226 | 0.862 / 0.796 | 0.789 / 0.781 | 0.0598 / 0.0591 | 0.14 | 0.0% |
| Cohere 03-2026 | padded (13.2 s) | MLX | 0.295 / 0.341 | 0.746 / 0.843 | 0.740 / 1.046 | 0.0561 / 0.0792 | 1.99 | 0.0% |
| Cohere 03-2026 | medium (18.3 s) | transcribe.cpp | 0.107 / 0.574 | 1.306 / 1.198 | 1.275 / 1.173 | 0.0698 / 0.0642 | 0.14 | 0.0% |
| Cohere 03-2026 | medium (18.3 s) | MLX | 0.289 / 0.312 | 1.243 / 1.247 | 1.228 / 1.238 | 0.0672 / 0.0677 | 2.05 | 0.0% |
| Cohere 03-2026 | long (64.2 s) | transcribe.cpp | 0.109 / 0.114 | 4.353 / 4.161 | 4.465 / 4.279 | 0.0696 / 0.0667 | 0.20 | 27.7% |
| Cohere 03-2026 | long (64.2 s) | MLX | 0.292 / 0.294 | 4.198 / 4.213 | 4.189 / 4.199 | 0.0653 / 0.0654 | 2.29 | 1.5% |

transcribe.cpp received each clip in one `transcribe_run` call. The MLX adapter splits audio into 30-second windows without overlap. To separate runtime speed from windowing, the long clip was also cut at 30 s and 60 s with Python's `wave` module and each window run through the transcribe.cpp bench (4 calls, median of calls 2 to 4, summed):

| Long clip in 30 s windows, transcribe.cpp | Sum of warm medians | WER |
| --- | ---: | ---: |
| Whisper Tiny | 1.628 s | not scored |
| Parakeet V2 | 1.612 s | not scored |
| Cohere 03-2026 | 4.257 s | 1.5% |

### Reading the timings

- Warm speed is close to parity. MLX is faster for Whisper Tiny in every row (0.083 s against 0.127 s on the short clip). For Parakeet, the short, padded and medium clips are within about 0.1 s, and MLX is faster on the long clip in both passes (1.468 and 1.207 s against 1.968 and 2.134 s, or 1.612 s windowed). For Cohere, the short, padded and medium clips are within 0.05 s on the uncontended pass 1; transcribe.cpp is slower on the long clip by 0.276 s in pass 1 and 0.080 s in pass 2.
- Load is not consistently faster for either runtime. transcribe.cpp maps Parakeet's F32 file and took 0.76 to 1.92 s to load it, against 0.38 to 0.41 s for MLX. It loaded Whisper and Cohere in 0.08 to 0.19 s and 0.10 to 0.72 s.
- A fresh transcribe.cpp process paid extra on its first call: Parakeet short went from 0.114 s warm to 0.407 s first, and Cohere short from 0.314 to 0.815 s. That matters only if the helper is not prepared during recording.
- One first-ever cost appeared. The first process to load any model with the new build, `transcribe-probe` on Whisper Tiny, reported `load_ms` 8686.4. Later processes loaded the same file in 0.08 to 0.19 s. This is a single observation, comparable to the 24-second first S1-mini invocation in the earlier note, and was not isolated.

### Memory

The transcribe.cpp footprint column does not include model weights. On Metal it memory-maps the GGUF file (`parakeet: weights memory-mapped: 2357.0 MiB in MTL0_Mapped`), and `footprint -p` on a running Parakeet bench reported 157 MB of footprint, with `vmmap --summary` listing a 2.5 GB virtual `mapped file` region of which 60.1 MB was resident to the process. Those clean file-backed pages are not charged to the process. To compare like for like, the bench was rerun with `TRANSCRIBE_NO_MMAP=1`, which copies weights into process memory:

| Model and clip | transcribe.cpp, copied weights | MLX `SpeechSmoke` |
| --- | ---: | ---: |
| Whisper Tiny, medium | 0.27 GB | 0.37 GB |
| Cohere 03-2026, medium | 1.72 GB | 2.05 GB |
| Parakeet V2, long | 2.66 GB | 3.83 GB |

With copied weights, calls 2 to 4 took 0.282 to 0.292 s for Whisper medium and 1.162 to 1.183 s for Cohere medium; Parakeet long calls 2 to 12 took 2.137 to 2.918 s. transcribe.cpp also reported compute buffers that do not appear in these process totals: `sched buffer MTL0 -> 913.1 MB` for Cohere and `290.9 MB` for Parakeet. Whether those are fully committed was not established. On this measurement transcribe.cpp uses 0.1 to 1.2 GB less process memory, and with mapping the weights become reclaimable file pages rather than dirty memory.

## Transcript accuracy notes

Every short, padded and medium transcript matched its reference words in both runtimes. Every repeated call in a process returned the same text. Differences appeared only on the 64-second clip.

- **Cohere through transcribe.cpp silently dropped 22 seconds.** Given the whole clip, all eight calls across both passes returned `TRANSCRIBE_OK` with text that jumps from "keep the full launch in Canada and Australia," to "because the hotel discount expires soon." Fifty-five of the 206 reference words are missing (WER 27.7%, including the "fifteen percent" substitution below). No warning or truncation status was logged. The model reports `max_audio_ms` 400000, so 64 seconds is inside its advertised limit. Split into 30-second windows, the same model and runtime produced the full text with the same two differences as MLX (WER 1.5%). A transcribe.cpp integration must keep the app's 30-second windowing for Cohere rather than relying on the library limit.
- All six long transcripts write "fifteen percent" as "15%". That is model text normalization, not an error, but it counts as a substitution here.
- MLX made two errors that transcribe.cpp did not, both near its 30-second window seams: Parakeet inserted "it." and Whisper dropped "add them". MLX Cohere and windowed transcribe.cpp Cohere both dropped "a" before "smaller" at the 30-second cut. Whole-clip Parakeet and Whisper in transcribe.cpp avoided these seam errors.
- Punctuation differed slightly. transcribe.cpp Whisper Tiny omitted the final period on the short clip ("afternoon" against "afternoon."). On the long clip, sentence boundaries and capitalization differed in four places for Whisper and five for Cohere.

One synthesized voice cannot establish accuracy for real microphones, accents or noise. These results show the two runtimes agree on clean speech and that long-input handling differs.

## C API capabilities

All line numbers refer to `include/transcribe.h` at `v0.4.1`.

- **Holding a model between requests.** Supported and intended. `transcribe_model_load_file` (line 1597) returns a model; `transcribe_session_init(model, params, &session)` (line 1621) creates sessions from it; `transcribe_run` (line 1708) "replaces the previous result on the same session" (lines 1700 to 1702). The spike bench reused one session for four calls in every row above.
- **Thread safety.** Lines 7 to 13: "transcribe_model_* functions are thread-safe", and, as a "KNOWN 0.x LIMITATION", "concurrent COMPUTE is not yet supported: at most one transcribe_run / transcribe_run_batch / active stream may be in flight across ALL sessions of a given model at a time." Lines 24 to 25: "transcribe_session_* functions are not thread-safe. A session must be used by at most one thread at a time." A helper process serving one request at a time fits this.
- **Cancellation.** `transcribe_set_abort_callback(session, cb, user_data)` (line 1835). Lines 1804 to 1807: "Polled between chunks AND between decode steps (after each token). Abort latency is therefore one decode step ... Mid-encoder abort is not supported today". An aborted run returns `TRANSCRIBE_ERR_ABORTED` (line 228), keeps partial text, and `transcribe_was_aborted` (line 1844) distinguishes it. `TRANSCRIBE_FEATURE_CANCELLATION` reports whether a family honors it; all three models here reported `true`. The catalog's M4 Max CPU rows put most of a call in the encoder (Parakeet V2 Q4_K_M on the 35 s sample: 1055.6 ms encode, 28.2 ms decode; Cohere: 3342.4 ms encode, 190.4 ms decode), so most of a Parakeet or Cohere call could not be aborted this way. The existing SIGTERM-then-SIGKILL process cancellation would remain the reliable path.
- **Streaming and partial results.** `transcribe_stream_begin` (line 2304), `transcribe_stream_feed` (2332), `transcribe_stream_finalize` (2348), `transcribe_stream_reset` (2366) and `transcribe_stream_get_text` (2211). `struct transcribe_stream_text` (line 2198) exposes `full_text`, an append-only `committed_text` and a volatile `tentative_text`. Streaming is gated by `transcribe_capabilities::supports_streaming` (line 1319). All three models measured here report `"streaming":false`; the catalog lists streaming for Nemotron, Moonshine Streaming, Voxtral Realtime, Multitalker Parakeet and some Parakeet variants. For offline runs, partial text is available only after an abort or `TRANSCRIBE_ERR_OUTPUT_TRUNCATED` (line 296).
- **Language selection and detection.** `transcribe_run_params::language` (line 1233), documented at lines 1165 to 1166 as a "source language hint as a BCP-47-ish short code, or NULL to autodetect (only if the model supports it)". `supports_language_detect` (line 1317) and the `languages` list gate it, and `transcribe_detected_language` (line 2553) returns the result. Probe output: Whisper Tiny 99 languages with detection; Parakeet V2 one language, no detection; Cohere 14 languages, no detection. A separate language-ID model role exists (`include/transcribe/langid.h`).
- **Vocabulary and prompt biasing.** `vocabulary` and `n_vocabulary` (line 1239), `prompt` (line 1241) and `prefix`, each gated by a feature bit through `transcribe_model_supports` (line 1515). Unsupported vocabulary is "Ignored with a WARN" (lines 1211 to 1213), and so is an unsupported prompt (line 1216). Per `docs/prompting.md`, vocabulary works for Whisper, Qwen3-ASR, Granite, Fun-ASR-Nano and MOSS. The probe confirmed Whisper Tiny reports `vocabulary`, `context_prompt` and `transcript_prefix`, while Parakeet V2 and Cohere report none of them.
- **Capability queries.** `transcribe_model_get_capabilities` (line 1436) fills `struct transcribe_capabilities` (line 1287) with sample rate, languages, `max_audio_ms` (line 1372) and the streaming, translate, detection and speculative-decoding flags. `transcribe_model_supports` (line 1515) answers the eleven `TRANSCRIBE_FEATURE_*` bits listed at lines 1501 to 1513. `transcribe_session_get_limits` (line 1945) reports per-session limits.
- **Input format.** Lines 1128 to 1130: "v1 accepts only 16 kHz mono float32 PCM ... the library does not link a resampler". The app's existing 48 kHz to 16 kHz conversion would stay in Swift.
- **Long input.** `docs/input-limits.md` says over-length input is rejected with `TRANSCRIBE_ERR_INPUT_TOO_LONG` and mid-decode exhaustion returns `TRANSCRIBE_ERR_OUTPUT_TRUNCATED`, so "a truncated transcript is never returned as `TRANSCRIBE_OK`". The Cohere result above is a content omission that passed both checks.

`probe.cpp` output for the three models:

```json
{"arch":"whisper","variant":"whisper-tiny","backend":"MTL0","sample_rate":16000,"n_languages":99,"language_detect":true,"translate":true,"streaming":false,"max_audio_ms":0,"features":{"initial_prompt":true,"temperature_fallback":true,"long_form":true,"cancellation":true,"pnc":false,"itn":false,"diarization":false,"vocabulary":true,"context_prompt":true,"instruct":false,"transcript_prefix":true}}
{"arch":"parakeet","variant":"tdt-0.6b-v2","backend":"MTL0","sample_rate":16000,"n_languages":1,"language_detect":false,"translate":false,"streaming":false,"max_audio_ms":0,"features":{"initial_prompt":false,"temperature_fallback":false,"long_form":false,"cancellation":true,"pnc":false,"itn":false,"diarization":false,"vocabulary":false,"context_prompt":false,"instruct":false,"transcript_prefix":false}}
{"arch":"cohere_asr","variant":"cohere-transcribe-03-2026","backend":"MTL0","sample_rate":16000,"n_languages":14,"language_detect":false,"translate":false,"streaming":false,"max_audio_ms":400000,"features":{"initial_prompt":false,"temperature_fallback":false,"long_form":false,"cancellation":true,"pnc":false,"itn":false,"diarization":false,"vocabulary":false,"context_prompt":false,"instruct":false,"transcript_prefix":false}}
```

## Integration estimate

This is an estimate from reading the existing helper; no helper was built.

- **Source pinning.** Copy `BuildSupport/S1Mini/build.sh`: fetch `https://github.com/handy-computer/transcribe.cpp/archive/4d7c1ccefd39e5a9ea36cca5f8fefc6dcc14b99b.tar.gz` and check the SHA-256 above. transcribe.cpp vendors its own ggml at a different revision from the pinned llama.cpp, so the two must stay in separate executables; linking both into one process would collide on ggml symbols.
- **CMake.** A `CMakeLists.txt` like S1-mini's: force `TRANSCRIBE_BUILD_SHARED`, `TRANSCRIBE_BUILD_TESTS`, `TRANSCRIBE_BUILD_EXAMPLES` and `TRANSCRIBE_BUILD_TOOLS` off, `GGML_NATIVE` off, `TRANSCRIBE_METAL` and `GGML_METAL_EMBED_LIBRARY` on, `add_subdirectory` the source, and link one `main.cpp` against `transcribe`. A JSON parser is needed; S1-mini gets nlohmann from llama.cpp's `vendor/`, which this tree does not provide, so it would need its own pinned copy or a hand-written line format. The build took 42 s here, adding that much to clean app builds.
- **Metal resources.** None to bundle. The Metal source is embedded and compiled per process at startup, as in the S1-mini helper.
- **Code signing.** Same as S1-mini: copy to `Contents/Helpers/`, sign with the app identity in `Scripts/bundle-helper.sh`, and extend the `codesign --verify` and `test -x` checks in `Scripts/package-dmg.sh`. The app entitlements only declare audio input, so reading GGUF files from application support needs no new entitlement.
- **Binary size.** About 8.0 to 8.5 MB stripped, from the minimal program above, against an app bundle of 62,552 KB (`du -sk` of the October 4 nightly). Roughly a 13% larger app.
- **Protocol.** Mirror the persistent S1-mini protocol: `--model <path> --serve`, one JSON request per line with an `id`, one JSON response per line. Unlike cleanup text, audio is large: 64 s of 16 kHz float32 is 4.1 MB. Either send a header line with the `id` and sample count followed by raw little-endian float32 bytes on stdin, or pass a private temporary file path. The Swift side keeps the existing reading, channel mixing, 16 kHz resampling and 30-second windowing, and sends one window per request. Responses carry `status`, `text` and an error code. Verifying the full model hash on every load, as S1-mini does, would cost more for larger files: `openssl dgst -sha256` took 1.39 s for the 2.47 GB Parakeet file, against S1-mini's measured 0.308 s for 484 MB. Verify at install and check file identity per request, as the runner already does.
- **Reusable from `S1MiniRunner.swift` (454 lines).** The process session lifecycle is generic: starting the child, line buffering with a size cap, request IDs, `F_SETNOSIGPIPE`, deadline, SIGTERM with a two-second grace before SIGKILL, idle expiry, memory-pressure release, `ModelKey` file-identity checks, and `unload()`. The request and response types, chunking by tokens and dictation-mode mapping are specific. Extracting a shared helper-session type parameterized by request and response is the main Swift change, plus a new engine wrapper that LocalSpeech's callers can select by model format.
- **Reusable from `BuildSupport/S1Mini/main.cpp` (402 lines).** The `serve` loop, `ModelFile` identity checks, signal handling, line limits and sanitized failure results carry over. Prompt construction, tokenization and sampling do not; transcription replaces them with `transcribe_run` and an abort callback tied to the signal flag.
- **Catalog work.** GGUF entries need repository, revision, file, size and SHA-256, all of which the Handy catalog and Hugging Face metadata provide. Licenses differ per variant and must be shown per model.
- **Validation.** The existing `check-helper-build.sh`, `check-helper-isolation.sh`, runner lifecycle checks and `check-packaged-speech.sh` each need a transcribe.cpp counterpart, plus a long-audio accuracy check because of the Cohere result.

I estimate a 250 to 350 line helper, a 60 line build script and CMake file, a 300 to 400 line Swift refactor and engine, and the checks above. That is comparable to the S1-mini helper effort, not a small addition.

## Recommendation

**Do not adopt transcribe.cpp now, either as a replacement or as a second runtime for the models the app already ships.** Revisit it as a second runtime only when the product wants a specific model family that exists as GGUF and not for MLX Audio Swift, and budget the helper work above for that model.

The measurements that decide it:

1. **No speed gain on this Mac for the shipped models.** Warm medians are at parity or favor MLX: Whisper Tiny short 0.127 s against 0.083 s, Parakeet long 1.968 s against 1.468 s (1.612 s with matching 30-second windows), Cohere medium 1.275 s against 1.228 s. Replacing MLX would add a process boundary and a second build chain without making transcription faster.
2. **Long Cohere audio failed silently.** On the 64-second clip transcribe.cpp returned `TRANSCRIBE_OK` while omitting 55 of 206 reference words (WER 27.7% against 1.5% for MLX). It returned the full text only when given the same 30-second windows the app already uses, so the library's long-input contract cannot be relied on without more accuracy testing.
3. **The memory advantage is real but secondary.** With weights copied, transcribe.cpp used 2.66 GB for Parakeet against 3.83 GB for MLX, and 1.72 against 2.05 GB for Cohere. With default mapping the weights become reclaimable file pages. This would matter if the app needs speech and S1-mini cleanup resident together on 16 GiB Macs, but it does not outweigh the integration cost on its own.

What transcribe.cpp offers is breadth. One C API covers 77 catalog variants across 21 families, including language ID, VAD and streaming models. For the three models already shipped, that breadth adds nothing.

## What is still unknown

- Abort latency in practice. The header documents per-decode-step polling and no mid-encoder abort; it was not measured.
- Whether the 913 MB Cohere and 291 MB Parakeet Metal compute buffers are committed memory, and total system memory with mapped weights under pressure.
- The cause and frequency of the Cohere omission: whether it depends on clip length, content or Q4_K_M quantization, and whether other hard-cap families behave the same.
- The 8.7-second first load after building. Whether it recurs after reboot, app update or OS update was not tested.
- Streaming models, F16 or quantized Parakeet and Whisper files, and families without an MLX counterpart, none of which were measured.
- Real microphone audio, accents, noise and non-English speech. The fixtures are one synthesized voice.
- Behavior on newer Apple silicon. The log notes `tensor API disabled for pre-M5 and pre-A19 devices`, so M5-class results may differ from this M1.
- Raw results were kept in the scratch directory for this spike (`$TMPDIR/tcpp-spike/results`), not in the repository. `run.sh` and `summarize.py` regenerate them.
