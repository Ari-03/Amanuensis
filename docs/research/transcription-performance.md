# Transcription performance investigation

September 20, 2026. Baseline commit `1a39367`. Measurements use this development Mac, an Apple M1 with 16 GiB RAM, running macOS 27.0 build 26A428. Speech measurements use Release builds and the repository's pinned MLX dependencies. The initial investigation below describes that baseline. The implementation section records the subsequent changes; local source links now point to the updated implementation.

## Implemented after the investigation

Local speech preparation now starts after microphone capture begins, while the user speaks. The engine retains one model, revalidates source identity before each request, and expires it after 60 seconds idle following transcription. Preparation stays resident until used or unloaded, unless memory pressure evicts it. The app awaits preparation before recognition. Cancellation, model removal, sleep, and quit wait for model release. Memory pressure evicts resources after active inference finishes.

S1-mini now keeps one isolated helper process across chunks and recordings. It verifies and loads the pinned weights once, creates a fresh context and sampler for each request, checks request IDs and model-file identity, and expires after 60 seconds idle. Cancellation, timeouts, crashes, malformed replies, and changed model files discard the helper. Memory pressure lets active cleanup finish before eviction. No transcript context is reused between requests.

| Cohere fixture | Reload each request, later-call median | Prepared production engine, median | Preparation, once |
| --- | --- | --- | --- |
| 3.202 s, 48 kHz | 0.664 s | 0.338 s | 0.315 s |
| 18.280 s, 48 kHz | 1.585 s | 1.276 s | 0.311 s |

Each path ran five times. The reload baseline excludes its first call; the retained median includes all calls and excludes preparation. Outputs matched their references. These are real production-engine calls, with sequential ordering and warm-cache limitations, not live microphone Stop-to-paste measurements. The app now has an opportunity to pay preparation during recording; very short recordings may still wait for it. Raw files are `amanuensis-cohere-implemented-short.jsonl` and `amanuensis-cohere-implemented-medium.jsonl` in [the data directory](data/transcription-performance/).

Four short cleanup cases took 0.62–0.83 seconds each as fresh helper processes. Repeated requests through a loaded helper took 0.08–0.27 seconds, with identical text and token counts; the first persistent request took 0.71 seconds. See [S1 samples](data/transcription-performance/s1-persistent.json). These cleanup timings exclude the Swift runner and speech stages.

Validation covers real-model speech reuse, held preparation, idle expiry, source replacement and deletion, cancellation during loading, recovery, and explicit unload. Helper checks cover real one-shot/persistent equivalence and request isolation, plus runner protocol failures, crash/EOF, timeout, cancellation, forced termination, idle expiry, memory-pressure behavior, and destruction. Package tests and aggregate repository checks pass. The signed Release app passed two consecutive Cohere-to-S1 runs with matching output, network access denied, and clean shutdown. That check exposed a delayed-quit deadlock when termination began inside a Swift task; scheduling termination through the main run loop fixed it. The benchmark README and helper README contain reproduction commands.

Silence trimming and recording-time incremental recognition remain separate experiments. This implementation does not alter recognized audio or the clipboard-restoration delay.

## Baseline findings

At the baseline commit, Amanuensis started recognition only after recording stopped, reloaded the speech model for every recording, and started a fresh cleanup process for each text chunk. Superwhisper documents keeping models loaded and uses different inference backends for Parakeet and Whisper. These differences are supported by code and official documentation. The exact size of the user's Superwhisper gap is not established by these experiments. The remaining investigation sections describe that baseline and the experiments that led to the implementation above.

The user confirmed that the slow recording used **Cohere Transcribe**. That takes precedence over the local configuration snapshot, which happened to have Parakeet selected when inspected. Saved settings do not establish the model used for an earlier recording. The recording's mode and cleanup setting remain unconfirmed, so cleanup costs below are conditional.

## Cohere-specific follow-up

For this user's case, the Parakeet backend difference is not the explanation. Superwhisper documents Cohere running through MLX at 4-bit precision, matching our runtime family and nominal quantization. Exact artifact revisions and implementation details can still differ. The clearest documented distinction is that Superwhisper preloads Cohere when recording starts, while Amanuensis loads it after Stop. Superwhisper also supports retaining local models between recordings. [Cohere runtime](https://superwhisper.com/benchmarks/cohere-transcribe), [August 6 changelog](https://superwhisper.com/changelog), [model retention](https://superwhisper.com/docs/common-issues/performance-tips)

Three additional experiments used mono 48 kHz PCM16, matching capture format. Each ran five production calls followed by five retained-model calls, with network access denied. All 30 results matched their reference transcript. The short and padded clips were checked against the expected sentence; the longer clip was checked against its first production result.

| Cohere 4-bit input | First production call | Later production median | Retained setup, once | Retained call median |
| --- | --- | --- | --- | --- |
| 3.202 s speech | 0.658 s | 0.640 s | 0.303 s | 0.339 s |
| 18.280 s speech | 2.316 s | 1.596 s | 0.296 s | 1.312 s |
| Same short speech with 5 s silence before and after | 1.212 s | 1.066 s | 0.290 s | 0.761 s |

Later production medians exclude the first call; retained medians include all five calls and exclude setup. Production runs first, and filesystem/Metal caches are not flushed. The previous Cohere short experiment began at 2.410 seconds, while the new short experiment began at 0.658 seconds after other inference runs. A fresh process is therefore not a controlled cold-machine measurement.

The repeatable setup saving is approximately 0.3 seconds per recording on these fixtures. The longer clip still spends about 1.3 seconds in recognition with the model loaded. Retention helps, but the larger Parakeet speedup should not be applied to Cohere. Preloading may also move first-use initialization into the recording interval; initialization deferred until generation must be measured separately before claiming it is eliminated.

The silence experiment holds spoken content and output constant. Adding ten seconds of digital silence increased retained processing by about 0.42 seconds. This supports testing leading/trailing silence trimming for Cohere. It is not a validation of speech detection on quiet voices or microphone noise. The existing adapter skips wholly zero-valued windows, but a window containing both speech and silence still reaches the model. Superwhisper enables silence removal by default. [Changelog](https://superwhisper.com/changelog)

The pinned Cohere runtime already offers an optional Silero VAD argument, but the app uses the generic `generate` method, which passes `vad: nil`. Integrating that path would require separate VAD assets and quality tests. Its `generateStream` API accepts an already-available audio array; changing to that method alone would not start recognition during microphone capture. The decoder also clears the MLX allocation cache internally, so a larger cache limit should not be assumed to solve this delay. [Pinned Cohere implementation](https://github.com/Blaizzy/mlx-audio-swift/blob/01dec7c9bdce3088a6b6b7ab9f2e403458195efb/Sources/MLXAudioSTT/Models/CohereTranscribe/CohereTranscribe.swift)

For Cohere, prioritize stage timings, model retention and preloading, then reuse S1-mini if the selected mode uses cleanup. Test silence trimming for paused recordings. A backend migration is a lower priority until the remaining Cohere generation time is profiled. PCM preprocessing took about 1–8 ms in these new runs, so it is not the leading cost.

The new raw files are `amanuensis-perf-cohere-short48k`, `amanuensis-perf-cohere-medium`, and `amanuensis-perf-cohere-padded48k` in [the measurement directory](data/transcription-performance/), with JSONL and process timing files for each. These experiments preceded the production changes.

## What the user waits for

```mermaid
flowchart LR
    A[Stop recording] --> B[Close audio file]
    B --> C[Save recording state]
    C --> D[Load speech model]
    D --> E[Convert audio and recognize each window]
    E --> F[Save raw transcript]
    F --> G[Optional cleanup]
    G --> H[Apply text rules and save result]
    H --> I[Prepare clipboard and post paste]
    I --> J[Wait 750 ms and restore clipboard]
    J --> K[Ready]
```

The baseline ran these stages sequentially, without loading or recognizing audio while the user spoke. The implementation now starts model preparation during recording; recognition still begins after Stop. [Recording owner](../../Amanuensis/App/AppModel.swift), [speech engine](../../Packages/LocalSpeech/Sources/LocalSpeech/LocalSpeechEngine.swift)

Use three distinct measurements:

- Stop to raw transcript measures capture finalization, storage, speech setup, preprocessing, and recognition.
- Stop to paste posted also includes cleanup, final storage, clipboard preparation, and destination checks. Posting a paste is not acknowledgment that the destination displayed it.
- Stop to ready includes the additional 750 ms clipboard protection interval and completion work.

The 750 ms delay comes **after** the paste events. Removing it does not reduce speech processing or time to posting text, and can break insertion in an application that reads the clipboard late. [Text delivery](../../Amanuensis/Platform/TextDelivery.swift)

## Speech measurements

The rebuilt benchmark compares the real `LocalSpeechEngine` with a diagnostic retained-model path using the same model weights, 30-second windows, resampling, and generation parameters. All measured outputs matched their reference transcript. The short fixture explicitly checks the expected sentence; the longer fixture checks equality to the first production result.

| Parakeet V2 fixture | First production call | Production calls 2–5, median | Retained setup, once | Retained calls 1–5, median |
| --- | --- | --- | --- | --- |
| 3.202 s speech, 22.05 kHz source | 3.764 s | 0.780 s | 0.441 s | 0.097 s |
| 18.280 s speech, 48 kHz PCM16 mono | 1.470 s | 1.036 s | 0.530 s | 0.494 s |

The short production calls after the first ranged from 0.603 to 0.994 seconds. Retained calls ranged from 0.092 to 0.108 seconds. For the longer fixture, the corresponding ranges were 0.971–1.067 seconds and 0.385–0.504 seconds.

Retained timings exclude setup. A first request with no opportunity to preload must still pay setup, plus any deferred initialization. Baseline calls run first in the same process, so the retained model benefits from already-used runtime and OS caches. The steadily falling short baseline times show that warm-up matters even though the app reloads the model. These results demonstrate a promising design with matching output, not an isolated causal estimate or a shipped speedup.

The retained short fixture spent roughly 0.7–1.6 ms reading/converting audio. On the 48 kHz longer fixture that cost was 3–14 ms, compared with roughly 380–490 ms in generation. Audio conversion is not the first place to optimize these clips.

Increasing the retained MLX allocation cache from 64 MiB to 512 MiB produced overlapping longer-clip timings: median 0.479 seconds at 512 MiB versus 0.494 seconds at 64 MiB. Five runs in sequential, unrandomized trials do not establish a useful cache improvement. Keep that experiment separate from retaining model weights.

Whole-process peak memory footprint for the Parakeet comparisons was approximately 3.84 GB. This includes both phases of the experiment, so it is not an isolated resident-model memory measurement. A production design must measure memory while both speech and cleanup models are retained.

Two secondary checks used the same 3.202-second sentence, three production calls followed by three retained calls. Every output matched the expected sentence:

| Model | First production call | Production calls 2–3, median | Retained setup, once | Retained calls 1–3, median |
| --- | --- | --- | --- | --- |
| Whisper Tiny | 1.516 s | 0.311 s | 0.193 s | 0.081 s |
| Cohere Transcribe 4-bit | 2.410 s | 0.648 s | 0.282 s | 0.332 s |

These show the same direction on this fixture. They do not establish that one model should replace another, because their recognition quality was not compared across representative audio.

Raw JSONL and process measurements are saved in [the measurement directory](data/transcription-performance/). These are small development samples; no p95 claim is justified. The fixture creation and benchmark commands are documented in the README linked below.


The initial existing `SpeechSmoke` command also returned the exact expected transcript in 5.092 seconds with Parakeet, with 5.15 seconds process wall time:

```sh
/tmp/amanuensis-speech-smoke-derived/Build/Products/Release/SpeechSmoke \
  parakeet /tmp/amanuensis-smoke-parakeet /tmp/amanuensis-smoke-input.aiff
```

That executable was an existing development artifact. The new benchmark rebuilds the current source and supplies the stronger repeatable comparison. Commands, validation rules, and the distinction between production and experimental paths are in the [benchmark README](../../BuildSupport/SpeechSmoke/README.md).

## Cleanup measurements

S1-mini is already configured for GPU offload, greedy decoding, and the author's non-thinking prompt. There is no evidence that we accidentally enabled reasoning or deliberately selected CPU-only inference. [Helper source](../../BuildSupport/S1Mini/main.cpp), [official model contract](https://huggingface.co/superwhisper/s1-mini-GGUF)

The expensive lifecycle is explicit. For every chunk, `S1MiniRunner` starts a process. The helper rereads and SHA-256 hashes the entire 484,219,808-byte model, initializes llama.cpp, loads weights, allocates a context, and generates a result. The caller processes chunks of at most 2,400 characters serially. If a chunk exceeds the 1,000-token limit, the helper discovers that after loading, and the caller retries smaller chunks with fresh processes. [Runner](../../Amanuensis/Inference/S1MiniRunner.swift), [helper](../../BuildSupport/S1Mini/main.cpp)

A temporary diagnostic build added `std::chrono::steady_clock` measurements around these existing calls. It linked the cached pinned Release llama.cpp libraries, without changing model settings. Each run used a fresh process and the same official Q4_K_M weights. The first newly linked executable invocation is shown separately.

| Synthetic input | Runs | Median process wall time | Median verification | Median backend/model load | Median prompt and generation |
| --- | --- | --- | --- | --- | --- |
| 11 input tokens, 11 output tokens, subsequent processes | 4 | 0.736 s | 0.308 s | 0.208 s | 0.179 s |
| 42 input tokens, 42 output tokens | 5 | 1.047 s | 0.304 s | 0.220 s | 0.474 s |
| First invocation of diagnostic executable, 11 tokens | 1 | 24.079 s | 0.318 s | 23.296 s | 0.194 s |

The short fixture was "Please send the meeting notes to Sarah by Thursday afternoon." The medium fixture asked for those notes, budget and schedule review, estimates, and release questions. All runs produced successful nonempty output. The two token lengths are not an accuracy evaluation.

A background compiler build overlapped these cleanup trials, though no other benchmark used the GPU. Treat the numbers as development measurements, not controlled production latency guarantees.

Verification plus model loading costs about half a second on repeated runs. That is most of the short cleanup's total time. A persistent helper could amortize it across chunks and recordings. This is measured removable setup work, not a measured production speedup from a persistent implementation.

The 24-second first invocation was dominated by backend/model initialization. The older helper notes also mention slow first Metal setup. This experiment did not isolate Metal compilation, filesystem state, or system contention, so it does not prove the user's app experiences that delay. It does establish why first-use and repeated-use latency must be reported separately.

Raw measurements are in [s1-stages.jsonl](data/transcription-performance/s1-stages.jsonl). `load` covers backend initialization and model loading; `context_and_tokenize` covers prompt tokenization and context creation. The individual `prefill` timer ends before sampling synchronizes the result, so the table combines `prefill` and `generation`. Individual median columns need not sum to median wall time. These process measurements omit Swift job-file preparation and final app delivery.

## Other parts of the path

| Area | Evidence and effect | Priority |
| --- | --- | --- |
| Audio conversion | Capture writes 48 kHz mono PCM16. The speech engine reads at most 30 seconds, averages channels, checks samples, and resamples to 16 kHz. Measure before replacing these loops. | Lower unless preprocessing dominates measured spans. |
| Silence | Only a window containing exact digital zeros skips recognition. Normal microphone noise and pauses still reach the model. | Speech detection can reduce work, but preserve quiet speech and word boundaries. |
| Long recordings | Windows run sequentially with fresh per-window generation. Outer windows have no overlap. Parakeet's internal overlap logic is bypassed when each supplied input is already at most 30 seconds. | Benchmark longer dictation and boundary accuracy before changing chunking. |
| Meeting audio | After Stop, the app closes both tracks, rereads them, aligns and mixes them into another WAV, then starts STT. | Prepare inference audio during capture if meeting latency matters. |
| Apple Speech | A fresh transcriber and analyzer process a completed file. Readiness checking does not prepare this per-recording analyzer. | Benchmark separately; these MLX results do not apply to Apple Speech. |
| Clipboard | All representations of the prior clipboard are materialized before posting paste. Large images or deferred providers can add time. | Add a span before redesigning preservation behavior. |

Sources: [capture](../../Amanuensis/Audio/AudioCapture.swift), [local engine](../../Packages/LocalSpeech/Sources/LocalSpeech/LocalSpeechEngine.swift), [meeting capture](../../Amanuensis/Audio/MeetingCapture.swift), [Apple Speech](../../Amanuensis/Inference/AppleSpeechEngine.swift), [clipboard](../../Amanuensis/Platform/TextDelivery.swift), [pinned Parakeet implementation](https://github.com/Blaizzy/mlx-audio-swift/blob/01dec7c9bdce3088a6b6b7ab9f2e403458195efb/Sources/MLXAudioSTT/Models/Parakeet/ParakeetModel.swift).

### Storage is a scaling issue, not the leading measured cost

The store runs on the main actor with SQLite DELETE journaling and FULL synchronization. Every recording upsert reloads and JSON-decodes the entire history. Cleanup-enabled dictation performs four upserts between Stop and paste. [Storage](../../Amanuensis/Storage/LocalStore.swift), [pipeline](../../Amanuensis/App/AppModel.swift)

A temporary optimized Swift executable exercised the actual `LocalStore.upsertRecording` against a disposable database. Each entry contained about 330 characters of synthetic raw text plus the same final text. Five repeated updates gave these medians:

| History size | Median one-upsert time |
| --- | --- |
| 1 record | 0.411 ms |
| 100 records | 1.595 ms |
| 1,000 records | 13.790 ms |

This does not explain a multi-second short-recording delay in a small history. It does show linear growth worth fixing before histories become large. Update the in-memory collection incrementally and move database work off the main actor. Keep durable raw/final checkpoints. DELETE journaling is intentional for deleted transcript retention; changing to WAL or disabling durable writes is not the first optimization.

### Cloud paths need a different investigation

The app uploads the captured WAV unchanged after Stop and waits for the complete response. It then makes a second serial request if cloud cleanup is enabled. The URLSession itself is reused. [Cloud providers](../../Amanuensis/Network/CloudProviders.swift)

48 kHz mono PCM16 is 96,000 bytes per second, or 5.76 MB per minute. At a hypothetical sustained 10 Mbps upload, transmitting that minute alone takes 4.61 seconds, before provider processing. A 16 kHz mono PCM16 file is one-third the size. Provider-supported compressed audio may reduce it further, subject to an accuracy check. These are payload calculations, not measurements of this user's network.

Measure upload bytes and URLSession task timings, then server response and cleanup separately. Output-token caps are ceilings, not proof of generated work. Do not lower them blindly and risk truncated results. No paid API calls or private audio uploads were made in this investigation.

## Comparison with Superwhisper

Superwhisper's official documentation establishes several relevant differences:

- Models remain loaded for a configurable 10 seconds to 1 hour. [Performance guide](https://superwhisper.com/docs/common-issues/performance-tips)
- Cohere preloads when recording begins, added in version 2.17.2. [Changelog](https://superwhisper.com/changelog)
- Parakeet uses Argmax WhisperKit, with parallel long-recording processing; Whisper uses whisper.cpp. Amanuensis runs both through MLX Audio Swift. [Voice models](https://superwhisper.com/docs/models/voice)
- Cohere uses MLX at 4-bit precision, a closer runtime-family match to our Cohere path. It still does not establish identical code, artifact revision, or generation settings. [Cohere benchmark](https://superwhisper.com/benchmarks/cohere-transcribe)

Realtime previews and silence removal are documented, but the sources do not establish whether every final transcript reuses streaming work. Superwhisper's S1-mini process lifetime and prompt caching are also undocumented in the sources inspected. See the [source comparison](superwhisper-performance-sources.md) for details.

Superwhisper's published M4-family benchmarks are not directly comparable to this M1 experiment. Do not calculate an app-to-app speed ratio from them.

## Original recommendations

Items 2 and 3 are now implemented as described above. The remaining items need further measurement or accuracy testing.

1. Add monotonic timings to the real recording path. Record model ID/revision, audio duration, window/chunk counts, bytes, first/resident load state, and timing spans without transcript text. Separate capture close, storage, speech preparation/load/generation/release, cleanup verification/load/generation, clipboard preparation, paste posted, and ready. Current history stores recording length, not processing latency.
2. Retain one selected speech model and preload it during recording. Use an explicit resident-model owner keyed by model identity and artifact revision. Keep the private metadata snapshot alive, hold the model-library lease, release on model change, memory pressure, or an idle timeout. Preserve the existing global serialization of MLX inference and cancellation semantics. Benchmark cache limits separately; retaining a model and increasing MLX's allocation cache are different changes.
3. Keep S1-mini in a persistent isolated helper, at least across chunks of the same recording. Verify the model when loading it, reuse model weights, and reset per-request state. Preserve serial request IDs, deadlines, cancellation, raw-text recovery, and private temporary-file handling. Invalidate on model replacement; do not simply remove verification. Prepare cleanup while speaking or during STT only if memory and GPU contention measurements justify it.
4. Benchmark Parakeet backends before a migration. Compare the retained MLX path against WhisperKit using the same clips, language, precision where possible, and accuracy requirements. For Whisper, compare whisper.cpp separately. The current backend difference is established; the speed benefit of replacing it here is not.
5. Move recognition work into recording. Incremental audio ingestion, stable partial results, and final reconciliation can reduce work remaining at Stop. This is a larger change than retaining models. Preserve audio for recovery and test cancellation, corrections, pauses, and words crossing chunk boundaries. Do not insert partial cleaned text into another application without an explicit product decision.
6. Optimize secondary paths from their measurements. Generate provider-ready audio during capture for cloud STT; reduce history reload work; mix meeting tracks incrementally; add speech detection with quality checks. Keep the clipboard safeguard while separating inference completion from clipboard restoration in the UI.

Keeping both models resident costs memory. On a 16 GiB Mac, idle expiry and pressure-driven eviction matter. Preloading moves work earlier; it does not remove total computation, and simultaneous GPU work can make both stages slower. Start with one resident speech model and sequential inference, then test cleanup overlap.

## What remains unmeasured

There is no matched Superwhisper run on this host. We have not measured live microphone Stop-to-paste, Accessibility timing in target applications, cloud providers, long meetings, accents, noisy audio, or actual system-wide memory pressure. The short fixtures do not establish word error rate or production tail latency. The changes above are available in the local Release artifact; they have not been published as a release.

For the acceptance benchmark, replay identical short, medium, and long clips in both apps. Match model version, language, cleanup mode, and hardware. Record first-after-launch, repeated, and post-idle runs separately. Use at least 20 runs per condition before quoting p50/p95, and alternate test order to reduce thermal and cache bias. Include real microphone recordings, pauses and background noise, 30-second chunk boundaries, S1 chunk/token limits, model switches, cancellation, and model removal. Report accuracy and memory alongside latency.
