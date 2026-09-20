# Validation and release plan

September 19, 2026. Proposed gates for [the product brief](../product-brief.md). No inference, app testing, or performance measurement has been performed in this research pass. The starter project cannot yet satisfy these gates.

The coordinator's read-only environment check found arm64, 16 GiB RAM, Xcode 26.6, and Swift 6.3.3. Its baseline build stopped before compilation because Xcode could not read project object version 110; the deployment target is also 27 against SDK 26.5. A temporary copy using project version 77 and deployment target 26.0 then built successfully with signing disabled. The repository remains unchanged. This validates a candidate starter-project compatibility fix, not signed insertion or runtime packages. Apple silicon with macOS 26+ remains a proposed support baseline.

## Prove the model pipeline first

Treat downloadable weights, compatible inference, and usable dictation as three separate claims. Verify an independently acquired artifact's full hash and accompanying tokenizer/configuration, pin the runtime revision, and run inference with networking disabled. Repeat after terminating the process so a warm cache does not hide missing files. Confirm cancellation releases resources and that a failed load leaves the previous working model selectable.

Start with one local speech engine and S1-mini by Superwhisper. Its author requires greedy decoding and a non-thinking template; it is a transcript normalizer with specific controls. Compare embedded output against the author's documented runtime configuration using identical inputs and settings. Check names, numbers, negation, corrections, list/email formatting, filler-only input, and chunk boundaries. Preserve every raw transcript. Empty cleanup can be valid and must not automatically restore unwanted filler. [Official S1-mini instructions](https://huggingface.co/superwhisper/s1-mini-GGUF)

Cohere's original checkpoint and a Mac conversion are separate artifacts. Compare the selected conversion against a working upstream reference on the same recordings. Investigate output differences before attributing them to quantization. Test sample-rate conversion, silence, long-audio chunking, timestamps where offered, and cancellation. A matching model name does not establish parity with Superwhisper's package. [Official Cohere model](https://huggingface.co/CohereLabs/cohere-transcribe-03-2026)

Each advertised Whisper checkpoint and Parakeet variant needs an offline smoke test on its exact shipped artifact. Apple recognition needs missing-assets, supported-English, and unavailable-device cases as well as successful inference. Keep a compatibility table of tested artifact, runtime, OS, hardware, and result. Do not mark an entire model family verified from one checkpoint. [Existing model inventory](requested-offline-models.md), [Apple availability requirements](apple-speech-and-microphones.md)

## Measure useful outcomes

Create a versioned corpus of consented or self-recorded English speech with human reference transcripts. Include short messages, punctuation, technical vocabulary, accents, hesitation, corrections, quiet speech, background noise, and silence. Keep a held-out portion; never tune prompts against every evaluation example.

Report raw-transcription word error rate as substitutions plus deletions plus insertions divided by reference words, with normalization rules stated. Score names, numbers, and negation separately. Evaluate cleanup for preserved meaning and appropriate formatting rather than expecting verbatim raw text. Retain adverse examples alongside aggregate results.

Measure key-down to capture-ready, key-release to raw transcript, cleanup duration, and key-release to successful insertion. Record cold and warm runs separately, p50/p95 latency, sample count, peak memory, model-load cost, and sustained-session behavior. Record Mac chip, RAM, OS, build, power mode, model hash, and audio duration with each result. Provider speed claims are not Amanuensis measurements.

Minimum supported hardware remains undecided. Establish numeric release budgets on the selected minimum Mac after the first spike; do not invent a universal latency promise now. Compare identical recordings before changing the default model. Use XCTest performance measurements for repeatable regressions and Instruments for diagnosis. [Apple performance testing](https://developer.apple.com/documentation/xcode/writing-and-running-performance-tests)

## Failure-focused checks

| Risk | Required observation |
| --- | --- |
| Push-to-talk | Repeated key-down does not restart capture; release finishes once; cancel, sleep, lost event, and permission denial cannot leave an invisible recording running. |
| Destination changes | Switching apps, windows, or text fields during processing cannot paste into the wrong destination. Recover through an explicit copy action. |
| Microphone loss | Unplug USB or disconnect Bluetooth while holding the shortcut. Preserve captured audio, report interruption, and never select an excluded device. |
| Invalid output | Distinguish no speech, valid empty cleanup, canceled work, runtime failure, timeout, and truncation. None produces fabricated success text. |
| Offline policy | A mixed mode cannot upload speech or text when local processing is required. Test actual transport attempts as well as policy logic. |
| Recovery | Relaunch after capture/processing interruption. Recover committed raw text and retained audio without duplicate insertion or history entries. |
| Retention | Audio expiry preserves retained text. Explicit transcript deletion removes search-index copies. Keys and transcript contents stay out of ordinary logs. |

## What to automate

Use Swift Testing for state transitions, mode precedence, exclusions/ranking, replacement boundaries, cancellation races, retention, and persisted history recovery. Inject failing providers and controlled clocks at actual system boundaries. Test observable outcomes rather than internal call sequences.

Use XCTest/XCUIAutomation for the keyboard-editing flow, synchronized settings, model selection, visible recording states, and accessible controls. Apple documents Swift Testing for unit tests and XCTest for UI automation. [Apple test targets](https://developer.apple.com/documentation/xcode/adding-tests-to-your-xcode-project)

Hardware sessions remain mandatory for global shortcuts, Bluetooth routing, input levels, permissions, focus-sensitive insertion, clipboard restoration, overlays across displays, and sleep/wake. A mocked microphone cannot prove these behaviors.

## Rollout gates

1. **Runtime spike.** A local speech engine plus S1-mini works independently and offline. Cohere and remaining requested families have recorded feasibility results and explicit unresolved issues.
2. **Personal daily-use build.** Complete record, stop, transcribe, cleanup, insert/copy, and reopen-history flow. All failure checks pass on the development Mac. No crashes, lost committed transcripts, excluded-input capture, or wrong-destination insertion in the scripted matrix. Measure latency before choosing defaults.
3. **Requested-feature beta.** Every required advertised model passes its own gate. Exercise real API providers with dedicated fixtures, denied/expired credentials, unavailable models, and network failures. Test the signed distribution build on a fresh account or Mac, including permissions, installation, relaunch, and an update that preserves data.
4. **Meeting extension.** Add system-audio permissions, dual-source synchronization, long-session memory limits, interruptions, speaker-label evaluation, and recovery before claiming meeting support. A working short dictation pipeline does not establish those capabilities.
