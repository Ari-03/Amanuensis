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
    family: "whisper",
    language: "fr"
)
// Any name in LocalSpeechFamily.all: "parakeet", "cohere", "moonshine", "qwen3asr", "nemotron".
engine.cancel()
await engine.unload() // Await before removing model files or shutting down.
```

The engine uses a dedicated serial executor and retains one model between calls. `prepare` loads it while recording and holds it until transcription or explicit unload, unless memory pressure evicts it. Transcription also loads on demand if preparation was skipped or failed. After transcription, the model expires after 60 seconds idle. Memory pressure evicts idle models immediately and active models after their request finishes. `LocalSpeechEngine(retentionDuration: .zero)` restores reload-per-request behavior for benchmarks.

A shared runtime lease prevents concurrent inference across engine instances; a request that finds an active lease throws `LocalSpeechError.busy`. Callers must await preparation before transcription. Every call revalidates source metadata and checks directory, file identity, size, and timestamps before reusing weights. A changed model replaces the resident instance. Unused MLX allocations are cleared after requests; retained weights remain alive. There is no cloud fallback, model acquisition, entitlement check, or account dependency in this adapter.

Everything that differs between families is one entry in `LocalSpeechFamily.all`: its loader, required files, how its `config.json` is recognized, whether it can detect the language, and how its runtime takes the language. The app's model library asks the same entry which files a download keeps and whether an installed folder is complete. Adding a family is an entry there plus catalog rows. Model folders must contain readable nonempty `.safetensors` weights and the entry's `requiredFiles`, for example `config.json`, `tokenizer.json` and `tokenizer_config.json` for Whisper, or `config.json` with its embedded vocabulary for Parakeet.

The model catalog must obtain compatible artifacts separately. Original Whisper `.pt` files, whisper.cpp `.bin` files, and Core ML directories are not these formats. Compatibility checks inside each runtime may reject malformed or incompatible configurations/weights.

Whisper's upstream loader downloads tokenizers when `tokenizer.json` is absent. The adapter rejects incomplete folders before loading, then copies metadata to a private temporary snapshot and links the weights. Removing the source tokenizer during inference therefore cannot activate that download branch. The snapshot lives with the resident model and is removed on eviction. The app prevents removal during capture/inference and awaits `unload()` before deleting model files, including while the model is idle.

`SpeechSegmenter` decides where every recording is cut, for every family. A frame of 20 ms is quiet below a tenth of the segment's loud level or below -60 dBFS. A segment closes at a pause of at least 0.2 seconds once it is long enough, but only if it already holds sound and the sound after the pause lasts 0.16 seconds, so a quiet lead-in or a key click after the last words never becomes a segment of its own. The cut falls 0.1 seconds before the resumed sound, so the pause stays with the words before it. With no such pause by 24 seconds it closes at the quietest 100 ms of the last 4 seconds; in a long silence that forced cut, or the end of the recording, can close a segment without sound, which is marked and never sent to a model (this replaces the old rule for exact digital silence, and means a stretch below -60 dBFS throughout is not transcribed). A file transcribed after Stop is cut with a 20-second minimum, close to the old 30-second windows; a recording transcribed while captured uses the family's live minimum (6 seconds for every family now) for both its live segments and its file pass. Each segment is mixed to mono, resampled to 16 kHz on its own, and given 0.5 seconds of digital silence on each side. The padding is a mitigation, not a fix, for models inventing sentences at a segment boundary: without it Cohere invented sentences for three Italian segments, and with it a reviewer still saw this on another Italian clip and with a 12-second minimum. It costs model time, from 2% for Whisper to 16% for Nemotron, and was slightly worse than no padding for some model and language pairs. Invented text on some segment boundaries remains a known limitation. Generation requests carry the caller's language in the family's form, or nil for detection, which only families with `detectsLanguage` accept. Segment texts are joined with spaces. `transcribe(audioURL:modelDirectory:family:language:)` returns the text with the model's own time summed over segments. It does not expose word timestamps or diarization.

`LiveTranscription` transcribes a recording while it is captured. The capture thread hands it 16-bit PCM; the segmenter cuts it, and closed segments with sound are transcribed in order with the model `prepare` loaded. A segment request never loads a model, so one evicted by memory pressure stays evicted until Stop. `finish` transcribes the recorded file with the same segmenter settings and the same model call, reusing a segment's text only where the file holds exactly the samples that were transcribed (compared by SHA-256 of the samples; each text's place comes from the file walk, so position is not part of the key). The result therefore always equals transcribing the file with those settings. An engine error, eviction or cancellation discards the live texts and tells the caller to clear its preview; a dropped or mismatched buffer, or more than four segments waiting, only means more is transcribed after Stop. Each finished recording logs how many segments were reused, and every discard logs why, under the `dev.amanuensis` subsystem at notice level.

Calling `cancel()` or cancelling the calling Swift task marks the job cancelled. The adapter checks before loading and between segments, and never returns text after cancellation is observed. An upstream synchronous model load or GPU decode already underway cannot be forcibly stopped. Cancellation therefore does not promise an immediate memory release or a fixed wall-clock deadline. The app should stop showing the cancelled recording immediately and avoid starting another local inference until the previous job exits.

`Package.resolved` records the graph used for package validation. The app's Xcode workspace must retain its own resolved graph. Build the shipping app with Xcode so MLX's Metal resources are compiled and copied; a successful command-line `swift build` alone does not establish runnable GPU inference.

The included package tests cover local-file preflight and the tokenizer snapshot without downloading model weights. The separate [speech smoke harness](../../BuildSupport/SpeechSmoke/README.md) has now loaded and transcribed with official Whisper tiny, the documented Parakeet v2 MLX conversion, and a Cohere 4-bit conversion, all with network access denied. Each exactly transcribed the same synthetic English sentence.

`SpeechLifecycle` exercises real-model preparation, repeated-call reuse, held preparation during recording, idle expiry, source replacement and missing files, cancellation during load, recovery, and explicit unload. The implementation benchmark now compares the production engine with retention disabled against the same engine prepared and retained, in addition to the original diagnostic duplicate. See the harness README for commands and results.

Validated on September 19, 2026 with Swift 6.3.3 on arm64: package compilation, five package tests, strict `swift-format` lint, whitespace checks, and the Xcode Release inference harness passed. Twelve-checkpoint Whisper coverage, Parakeet v3, broad accuracy, long recordings, cancellation latency, and the app's shipped resource layout still need their own checks. A passing short synthetic fixture is not a production-readiness claim.
