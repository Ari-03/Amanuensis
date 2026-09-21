# Local speech smoke harness

This executable loads an existing model folder through the same `LocalSpeechEngine` used by the app. It accepts a family, model directory, and audio file. It prints the transcript and elapsed time, and fails for errors or empty output. It never downloads models or records a microphone.

Build on the selected Xcode installation with its Metal toolchain installed:

```sh
cd BuildSupport/SpeechSmoke
xcrun xcodebuild -scheme SpeechSmoke \
  -destination 'platform=macOS,arch=arm64' -configuration Release \
  -derivedDataPath /tmp/amanuensis-speech-smoke-derived \
  -skipPackagePluginValidation -skipMacroValidation -jobs 4 \
  build CODE_SIGNING_ALLOWED=NO
```

If Xcode reports a missing Metal toolchain, obtain Apple's component with `xcrun xcodebuild -downloadComponent MetalToolchain`. The package validation flags permit command-line builds of the pinned dependency plugins and macros. They do not disable app sandboxing or macOS security settings.

Create a synthetic English fixture without recording or playing microphone audio:

```sh
say -v Samantha -o /tmp/amanuensis-smoke-input.aiff \
  'Please send the meeting notes to Sarah by Thursday afternoon.'
```

Run in a process sandbox that denies network access:

```sh
sandbox-exec -p '(version 1) (allow default) (deny network*)' \
  /tmp/amanuensis-speech-smoke-derived/Build/Products/Release/SpeechSmoke \
  whisper /tmp/amanuensis-smoke-whisper /tmp/amanuensis-smoke-input.aiff
```

Use `parakeet` or `cohere` with a corresponding complete local folder for the other adapters. Run models sequentially on the 16 GiB development Mac. The sandbox command is a development check, not the app's deployment architecture.

## Pinned smoke artifacts

These are independently downloaded public artifacts, not files from Superwhisper. The temporary model files are excluded from the repository.

| Family | Source and revision | Weight size | Published SHA-256 |
| --- | --- | --- | --- |
| Whisper tiny | [openai/whisper-tiny](https://huggingface.co/openai/whisper-tiny/tree/169d4a4341b33bc18d8881c4b69c2e104e1cc0af), `169d4a4341b33bc18d8881c4b69c2e104e1cc0af` | 151,061,672 bytes | `7ebd0e69e78190ffe1438491fa05cc1f5c1aa3a4c4db3bc1723adbb551ea2395` |
| Parakeet TDT 0.6B v2 | [mlx-community conversion](https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v2/tree/8ae155301e23d820d82aa60d24817c900e69e487), `8ae155301e23d820d82aa60d24817c900e69e487` | 2,471,559,904 bytes | `b958c37a6baa6874a279108755c8f2818e27bf647d72d54800a234a421341dfe` |
| Cohere Transcribe 03-2026 4-bit | [beshkenadze conversion](https://huggingface.co/beshkenadze/cohere-transcribe-03-2026-mlx-4bit/tree/104bc4391b5b1a12b040859793d7148525e1a08c), `104bc4391b5b1a12b040859793d7148525e1a08c` | 1,505,114,042 bytes | `5284ab5b678da720da092604323c7ce82cffe544e42b2da95064fbc85e281609` |

Whisper additionally uses its pinned tokenizer/configuration JSON files, vocabulary, and merges. Parakeet needs its pinned `config.json`. Cohere needs its pinned `config.json`, `tokenizer_config.json`, and `tokenizer.model`.

One synthetic sentence can prove artifact loading and basic execution. It cannot establish accuracy across accents, microphone quality, long recordings, chunk boundaries, every Whisper checkpoint, or general production readiness.

## Results, September 19, 2026

Built successfully with Xcode in Release after installing Apple's Metal Toolchain 17F109. The host uses arm64, 16 GiB RAM, and Swift 6.3.3. Each model ran in a separate process with network access denied by the sandbox profile above. All three returned this exact transcript:

> Please send the meeting notes to Sarah by Thursday afternoon.

| Model | Engine load plus transcription | Peak process memory footprint reported by `/usr/bin/time -l` | Exit |
| --- | --- | --- | --- |
| Whisper tiny | 2.882 seconds | 331,891,624 bytes | 0 |
| Parakeet TDT 0.6B v2 | 5.380 seconds | 3,832,270,040 bytes | 0 |
| Cohere Transcribe 03-2026 4-bit | 3.166 seconds | 1,807,992,752 bytes | 0 |

The fixture is 3.202 seconds of synthesized Samantha speech, originally mono 22,050 Hz. The engine read and resampled it to 16 kHz. All weight hashes matched the values above. The runtime adapter required no changes after these inference checks. The harness entry file was renamed from `main.swift` to `SpeechSmoke.swift` because Xcode otherwise treated its `@main` declaration as a second entry point.

These are single-run smoke measurements, including model loading. Filesystem caches and other development activity were uncontrolled. They are not comparative product benchmarks or a complete accounting of GPU memory. All three processes reported zero swaps. Temporary result logs are `/tmp/amanuensis-smoke-whisper-result.log`, `/tmp/amanuensis-smoke-parakeet-result.log`, and `/tmp/amanuensis-smoke-cohere-result.log`.

## Speech performance experiment

The implementation now adds two production measurements. `reload_each_request` uses `LocalSpeechEngine(retentionDuration: .zero)` to preserve the original baseline. `production_prepare` measures preparation once; `production_preloaded` measures subsequent calls to the retained production engine. The `retained_setup` and `retained` rows remain the original laboratory duplicate for comparison. Historical JSONL files recorded before the implementation used `production` for the reload-per-request path.

`SpeechBench` compares repeated calls to the production `LocalSpeechEngine` with an experimental model retained across calls. It is a diagnostic executable, excluded from the app. Its retained path duplicates the engine's 30-second PCM windows, channel averaging, 16 kHz resampling, silence handling, and generation parameters. Keep that duplicate in sync before reusing this experiment after engine changes.

The executable takes `<family> <model-directory> <audio-file> [repetitions=3] [retained-cache-MiB=64] [expected-transcript]`. It validates every result against the supplied expected transcript, or the first production result when none is supplied. Empty or changed transcripts fail the run. Output contains JSONL timing and character counts, without transcript text. The baseline always uses the production 64 MiB allocator cache; the optional cache setting applies only to the retained path.

Build from this directory, reusing existing package checkouts when available:

```sh
xcrun xcodebuild -scheme SpeechBench \
  -destination 'platform=macOS,arch=arm64' -configuration Release \
  -derivedDataPath /tmp/amanuensis-perf-derived \
  -clonedSourcePackagesDirPath /private/tmp/amanuensis-local-speech-build \
  -skipPackagePluginValidation -skipMacroValidation -jobs 4 \
  build CODE_SIGNING_ALLOWED=NO

sandbox-exec -p '(version 1) (allow default) (deny network*)' \
  /tmp/amanuensis-perf-derived/Build/Products/Release/SpeechBench \
  parakeet /tmp/amanuensis-smoke-parakeet /tmp/amanuensis-smoke-input.aiff \
  5 64 'Please send the meeting notes to Sarah by Thursday afternoon.' \
  > /tmp/amanuensis-perf-parakeet-short.jsonl
```

Run GPU experiments sequentially. `production.totalSeconds` includes snapshot, model construction, preprocessing, inference, destruction and cache cleanup. `retained_setup` reports the metadata snapshot and model constructor once. Each `retained` row then reports preprocessing and generation separately. Model construction can defer work until the first generation; the first retained row is not a steady-state measurement. Likewise the first production row may include process and Metal initialization. These are wall-clock stage measurements, not GPU kernel profiles. Filesystem and Metal caches are not flushed.

The retained path snapshots metadata and links local weight files before loading. Execute it with network denied as shown above. It does not implement the app's full cancellation and concurrency behavior, so measured gains are evidence for a production design, not a ready replacement.

For an 18.280-second synthetic fixture:

```sh
say -v Samantha -o /tmp/amanuensis-perf-medium.aiff \
  'Please send the meeting notes to Sarah by Thursday afternoon. We should review the project timeline and confirm that the new dashboard is ready for the customer demonstration next week. I would also like to schedule a short planning session on Monday morning so that everyone understands the remaining tasks and can raise any concerns before we begin.'
afconvert /tmp/amanuensis-perf-medium.aiff /tmp/amanuensis-perf-medium-48k.wav \
  -f WAVE -d LEI16@48000

/usr/bin/time -l sandbox-exec -p '(version 1) (allow default) (deny network*)' \
  /tmp/amanuensis-perf-derived/Build/Products/Release/SpeechBench \
  parakeet /tmp/amanuensis-smoke-parakeet /tmp/amanuensis-perf-medium-48k.wav \
  5 64 > /tmp/amanuensis-perf-parakeet-medium.jsonl \
  2> /tmp/amanuensis-perf-parakeet-medium-time.txt
```

This experiment isolates speech inference. It does not measure recording finalization, context gathering, language-model cleanup, output delivery, or Superwhisper. Baseline-first execution and shared OS caches also mean it is not a randomized or cold-storage benchmark.

### Results, September 20, 2026

Release build on Apple M1 with 16 GiB RAM, macOS 27.0 build 26A428. All five experiments completed with network denied. Every short result exactly matched the supplied sentence. Every medium result matched its first production transcript, 351 characters. The 3.202-second input is mono 22,050 Hz; the 18.280-second input was converted to mono 48 kHz Int16 to approximate the app's capture format.

| Family and input | First production call | Later production median | Retained setup | Retained call median | Calls per path |
| --- | ---: | ---: | ---: | ---: | ---: |
| Parakeet, short, 64 MiB | 3.764 s | 0.780 s | 0.441 s | 0.097 s | 5 |
| Parakeet, medium, 64 MiB | 1.470 s | 1.036 s | 0.530 s | 0.494 s | 5 |
| Parakeet, medium, 512 MiB retained cache | 1.159 s | 1.010 s | 0.438 s | 0.479 s | 5 |
| Whisper tiny, short, 64 MiB | 1.516 s | 0.311 s | 0.193 s | 0.081 s | 3 |
| Cohere 4-bit, short, 64 MiB | 2.410 s | 0.648 s | 0.282 s | 0.332 s | 3 |

The later production median excludes iteration 1. The retained median includes every retained call. Setup is paid once and excluded from retained calls. Relative to these production medians, the retained Parakeet path measured 87.5% lower call latency on the short input and 52.4% lower on the medium input. These observed differences combine model retention, allocator reuse and runtime warming; they do not isolate a single cause. The short baseline itself dropped from 0.994 to 0.603 seconds across later calls, so it had not reached a stable plateau.

The medium 64 and 512 MiB retained ranges overlap, 0.385–0.504 and 0.402–0.495 seconds. This sample does not support increasing the cache limit. Preprocessing took 0.7–1.6 milliseconds for short Parakeet and 3.3–14.4 milliseconds for medium Parakeet at 64 MiB. Model loading and generation deserve priority over PCM loop optimization for these inputs.

Whole-process peak memory footprint from `/usr/bin/time -l` was 3.837 GB for short Parakeet, 3.843 GB for medium Parakeet, 3.842 GB for medium with a 512 MiB retained cache, 0.377 GB for Whisper, and 1.847 GB for Cohere. These are peaks spanning both paths, not measurements of steady retained-model memory. Repetitions are too few for percentile claims.

Raw timing rows and process measurements are retained in [the research data directory](../../docs/research/data/transcription-performance/). Files are named `amanuensis-perf-<family>-<input>.jsonl` with corresponding `-time.txt` files. The temporary build log is `/tmp/amanuensis-perf-build.log`. The same pinned model artifacts listed above were used.

### Cohere follow-up

The user identified Cohere as the model used for the slow recording. Three additional experiments used five calls per path, all with exact transcript equality checks and network denied. Later production medians exclude iteration 1, and retained medians exclude setup.

| Cohere input, 64 MiB cache | First production call | Later production median | Retained setup | Retained call median |
| --- | ---: | ---: | ---: | ---: |
| Short, converted to 48 kHz PCM16 | 0.658 s | 0.640 s | 0.303 s | 0.339 s |
| Medium, 18.280 s at 48 kHz | 2.316 s | 1.596 s | 0.296 s | 1.312 s |
| Short speech with 10 s added silence, 13.202 s total | 1.212 s | 1.066 s | 0.290 s | 0.761 s |

The model setup saving is about 0.3 seconds on these fixtures. The longer clip still spends about 1.3 seconds recognizing speech after setup. Adding silence around the same sentence costs about 0.42 seconds in the retained path. This supports a silence-trimming experiment, but says nothing about detection accuracy for quiet speech or real background noise.

Create the short and padded fixtures from this directory:

```sh
afconvert -f WAVE -d LEI16@48000 -c 1 \
  /tmp/amanuensis-smoke-input.aiff /tmp/amanuensis-perf-short-48k.wav
xcrun swift make-padded-fixture.swift \
  /tmp/amanuensis-perf-short-48k.wav /tmp/amanuensis-perf-padded-48k.wav

/usr/bin/time -l sandbox-exec -p '(version 1) (allow default) (deny network*)' \
  /tmp/amanuensis-perf-derived/Build/Products/Release/SpeechBench \
  cohere /tmp/amanuensis-smoke-cohere /tmp/amanuensis-perf-padded-48k.wav \
  5 64 'Please send the meeting notes to Sarah by Thursday afternoon.'
```

Use the short WAV for the short run. Use `/tmp/amanuensis-perf-medium-48k.wav` and omit the expected-transcript argument for the medium run, which validates against its first production output. The medium fixture is created above. New raw files use suffixes `cohere-short48k`, `cohere-medium`, and `cohere-padded48k` in the research data directory. These sequential experiments retain the same ordering/cache limitations as the original trials. A fresh process does not imply a cold filesystem or Metal runtime.

### Implemented retention

Using the same fixtures and five calls per path, the real retained engine measured 0.338 seconds on the short clip and 1.276 seconds on the medium clip, versus 0.664 and 1.585 seconds with retention disabled. Reload-per-request medians exclude the first call, and retained medians include all five calls. Preparation took 0.315 and 0.311 seconds respectively and is excluded from those retained-call timings. Every output matched its reference. Raw results are `amanuensis-cohere-implemented-short.jsonl` and `amanuensis-cohere-implemented-medium.jsonl` in the research data directory. These are inference measurements, not live Stop-to-paste timings.

The `SpeechLifecycle` executable tests the real engine's reuse, recording preparation that lasts beyond its idle interval, idle expiry after transcription, file replacement, missing metadata, cancellation during loading, subsequent recovery, and explicit unload. It observes the lifetime of private model snapshots. Use an isolated temporary directory and run without other inference tests in that directory:

```sh
xcrun xcodebuild -scheme SpeechLifecycle \
  -destination 'platform=macOS,arch=arm64' -configuration Release \
  -derivedDataPath /tmp/amanuensis-perf-derived \
  -clonedSourcePackagesDirPath /private/tmp/amanuensis-local-speech-build \
  -skipPackagePluginValidation -skipMacroValidation -jobs 4 \
  build CODE_SIGNING_ALLOWED=NO

speech_test_temp="$(mktemp -d /tmp/amanuensis-lifecycle.XXXXXX)"
TMPDIR="$speech_test_temp/" sandbox-exec -p '(version 1) (allow default) (deny network*)' \
  /tmp/amanuensis-perf-derived/Build/Products/Release/SpeechLifecycle \
  cohere /tmp/amanuensis-smoke-cohere /tmp/amanuensis-perf-short-48k.wav
rmdir "$speech_test_temp"
```

The Cohere lifecycle run passed after implementation. Package tests also verify that replacing weights invalidates model identity and that missing tokenizer metadata fails before reuse.

From the repository root, validate the built app and bundled helper together:

```sh
Scripts/check-packaged-speech.sh artifacts/Amanuensis.app \
  /tmp/amanuensis-perf-short-48k.wav /tmp/amanuensis-smoke-cohere cohere \
  /tmp/amanuensis-s1-mini-q4_k_m.gguf
```

This checks the app signature, denies network access, runs speech and cleanup twice, requires matching output, unloads both engines, and requires the app to exit within 90 seconds. It passed for the implemented Cohere and S1-mini paths. It does not capture the microphone or paste into another application.
