# LocalSpeech

Native Swift adapter for the pinned MLX Audio Swift speech runtimes. Link the `LocalSpeech` package product in the macOS app. The validated graph requires Swift tools 6.3 and macOS 14 or later; the app may choose a higher deployment target. MLX Audio itself declares Swift 6.2, but its resolved MLX Swift 0.31.6 dependency requires 6.3. The adapter pins that tested MLX version explicitly.

```swift
import LocalSpeech

let engine = LocalSpeechEngine()
// Start this while recording and await it before calling transcribe.
try await engine.prepare(modelDirectory: installedModelURL, family: "whisper")
let transcript = try await engine.transcribe(
    audioURL: recordingURL,
    modelDirectory: installedModelURL,
    family: "whisper"
)
// Also accepts "parakeet" and "cohere".
engine.cancel()
await engine.unload() // Await before removing model files or shutting down.
```

The engine uses a dedicated serial executor and retains one model between calls. `prepare` loads it while recording and holds it until transcription or explicit unload, unless memory pressure evicts it. Transcription also loads on demand if preparation was skipped or failed. After transcription, the model expires after 60 seconds idle. Memory pressure evicts idle models immediately and active models after their request finishes. `LocalSpeechEngine(retentionDuration: .zero)` restores reload-per-request behavior for benchmarks.

A shared runtime lease prevents concurrent inference across engine instances; a request that finds an active lease throws `LocalSpeechError.busy`. Callers must await preparation before transcription. Every call revalidates source metadata and checks directory, file identity, size, and timestamps before reusing weights. A changed model replaces the resident instance. Unused MLX allocations are cleared after requests; retained weights remain alive. There is no cloud fallback, model acquisition, entitlement check, or account dependency in this adapter.

Model folders must contain readable nonempty `.safetensors` weights and these metadata files:

| Family | Required files |
| --- | --- |
| Whisper | `config.json`, `tokenizer.json`, `tokenizer_config.json` |
| Parakeet | `config.json`, including the conversion's vocabulary |
| Cohere | `config.json`, `tokenizer.model`, `tokenizer_config.json` |

The model catalog must obtain compatible artifacts separately. Original Whisper `.pt` files, whisper.cpp `.bin` files, and Core ML directories are not these formats. Compatibility checks inside each runtime may reject malformed or incompatible configurations/weights.

Whisper's upstream loader downloads tokenizers when `tokenizer.json` is absent. The adapter rejects incomplete folders before loading, then copies metadata to a private temporary snapshot and links the weights. Removing the source tokenizer during inference therefore cannot activate that download branch. The snapshot lives with the resident model and is removed on eviction. The app prevents removal during capture/inference and awaits `unload()` before deleting model files, including while the model is idle.

Audio is read in windows of at most 30 seconds, mixed to mono, and resampled to 16 kHz. Generation requests specify English. The adapter joins window results with spaces; boundary accuracy still needs real model/audio testing. It does not expose word timestamps or diarization.

Calling `cancel()` or cancelling the calling Swift task marks the job cancelled. The adapter checks before loading and between windows, and never returns text after cancellation is observed. An upstream synchronous model load or GPU decode already underway cannot be forcibly stopped. Cancellation therefore does not promise an immediate memory release or a fixed wall-clock deadline. The app should stop showing the cancelled recording immediately and avoid starting another local inference until the previous job exits.

`Package.resolved` records the graph used for package validation. The app's Xcode workspace must retain its own resolved graph. Build the shipping app with Xcode so MLX's Metal resources are compiled and copied; a successful command-line `swift build` alone does not establish runnable GPU inference.

The included package tests cover local-file preflight and the tokenizer snapshot without downloading model weights. The separate [speech smoke harness](../../BuildSupport/SpeechSmoke/README.md) has now loaded and transcribed with official Whisper tiny, the documented Parakeet v2 MLX conversion, and a Cohere 4-bit conversion, all with network access denied. Each exactly transcribed the same synthetic English sentence.

`SpeechLifecycle` exercises real-model preparation, repeated-call reuse, held preparation during recording, idle expiry, source replacement and missing files, cancellation during load, recovery, and explicit unload. The implementation benchmark now compares the production engine with retention disabled against the same engine prepared and retained, in addition to the original diagnostic duplicate. See the harness README for commands and results.

Validated on September 19, 2026 with Swift 6.3.3 on arm64: package compilation, five package tests, strict `swift-format` lint, whitespace checks, and the Xcode Release inference harness passed. Twelve-checkpoint Whisper coverage, Parakeet v3, broad accuracy, long recordings, cancellation latency, and the app's shipped resource layout still need their own checks. A passing short synthetic fixture is not a production-readiness claim.
