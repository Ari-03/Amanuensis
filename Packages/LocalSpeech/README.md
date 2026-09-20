# LocalSpeech

Native Swift adapter for the pinned MLX Audio Swift speech runtimes. Link the `LocalSpeech` package product in the macOS app. The validated graph requires Swift tools 6.3 and macOS 14 or later; the app may choose a higher deployment target. MLX Audio itself declares Swift 6.2, but its resolved MLX Swift 0.31.6 dependency requires 6.3. The adapter pins that tested MLX version explicitly.

```swift
import LocalSpeech

let engine = LocalSpeechEngine()
let transcript = try await engine.transcribe(
    audioURL: recordingURL,
    modelDirectory: installedModelURL,
    family: "whisper"
)
// Also accepts "parakeet" and "cohere".
engine.cancel()
```

The engine uses a dedicated serial executor. It loads one model per job. A shared runtime lease prevents concurrent inference across engine instances; a request that finds an active lease throws `LocalSpeechError.busy`. It releases the model and clears the MLX allocation cache after each request. There is no cloud fallback, model acquisition, entitlement check, or account dependency in this adapter.

Model folders must contain readable nonempty `.safetensors` weights and these metadata files:

| Family | Required files |
| --- | --- |
| Whisper | `config.json`, `tokenizer.json`, `tokenizer_config.json` |
| Parakeet | `config.json`, including the conversion's vocabulary |
| Cohere | `config.json`, `tokenizer.model`, `tokenizer_config.json` |

The model catalog must obtain compatible artifacts separately. Original Whisper `.pt` files, whisper.cpp `.bin` files, and Core ML directories are not these formats. Compatibility checks inside each runtime may reject malformed or incompatible configurations/weights.

Whisper's upstream loader downloads tokenizers when `tokenizer.json` is absent. The adapter rejects incomplete folders before loading, then copies metadata to a private temporary snapshot and links the weights. Removing the source tokenizer during inference therefore cannot activate that download branch. The snapshot is removed after the request. Source weight files must remain accessible until the request finishes. The app's model manager must prevent removal while in use.

Audio is read in windows of at most 30 seconds, mixed to mono, and resampled to 16 kHz. Generation requests specify English. The adapter joins window results with spaces; boundary accuracy still needs real model/audio testing. It does not expose word timestamps or diarization.

Calling `cancel()` or cancelling the calling Swift task marks the job cancelled. The adapter checks before loading and between windows, and never returns text after cancellation is observed. An upstream synchronous model load or GPU decode already underway cannot be forcibly stopped. Cancellation therefore does not promise an immediate memory release or a fixed wall-clock deadline. The app should stop showing the cancelled recording immediately and avoid starting another local inference until the previous job exits.

`Package.resolved` records the graph used for package validation. The app's Xcode workspace must retain its own resolved graph. Build the shipping app with Xcode so MLX's Metal resources are compiled and copied; a successful command-line `swift build` alone does not establish runnable GPU inference.

The included package tests cover local-file preflight and the tokenizer snapshot without downloading model weights. The separate [speech smoke harness](../../BuildSupport/SpeechSmoke/README.md) has now loaded and transcribed with official Whisper tiny, the documented Parakeet v2 MLX conversion, and a Cohere 4-bit conversion, all with network access denied. Each exactly transcribed the same synthetic English sentence.

Validated on September 19, 2026 with Swift 6.3.3 on arm64: package compilation, five package tests, strict `swift-format` lint, whitespace checks, and the Xcode Release inference harness passed. Twelve-checkpoint Whisper coverage, Parakeet v3, broad accuracy, long recordings, cancellation latency, and the app's shipped resource layout still need their own checks. A passing short synthetic fixture is not a production-readiness claim.
