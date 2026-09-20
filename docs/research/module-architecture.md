# Native module architecture

Proposed September 19, 2026, from the [product brief](../product-brief.md). This is a design recommendation. No runtime or performance claim below has been validated by running the app.

Consolidation note: the [implementation plan](../implementation-plan.md) selects GRDB instead of this note's SwiftData alternative, cancels preparation on push-to-talk release, and adds an explicit manual-mode override before app matching. Follow those resolved decisions when implementing. The module ownership recommendations below still apply.

Keep one application target initially. Group files by ownership. Extract packages only when runtime bindings or build constraints require them. The valuable seams are where speech and cleanup implementations actually vary.

## Recording ownership

`@MainActor @Observable DictationSession` exposes `start(intent:)`, `finish()`, `cancel()`, and read-only state. Home, global shortcuts, menu bar, and the recorder all call this same interface. It owns one session identity, destination handle, recording task, and frozen configuration. Views never advance recording stages themselves.

State follows `idle → preparing → recording → transcribing → cleaning → delivering → completed`, with explicit interrupted, failed, and canceled outcomes. Cleaning is optional. State carries stage-specific information instead of unrelated booleans. `finish()` during preparation records a pending stop, preventing push-to-talk release from being lost. Repeated key-down and repeated finish calls are harmless. Initial scope permits one active session; history retry must wait or report busy.

At start, capture the destination and resolve explicit mode shortcut, application association, then selected default. Freeze models, tone, vocabulary, replacements, insertion preferences, and input-device choice. Persist a pending history record before inference. Ordinary settings edits affect the next session. Privacy restrictions take effect immediately.

After every suspension, verify session identity before publishing state or causing another effect. Cancellation requests stop capture and inference, restores playback, and prevents delivery. Noncooperative inference may finish later; discard that result and keep its runtime resources occupied until execution actually ends. Cleanup failure retains raw text. An intentionally empty cleanup result is distinct from failure.

## Module interfaces

| Module | Small interface and hidden implementation |
| --- | --- |
| `AudioCapture` | `start(selection:)`, `finish()`, `cancel()`, and metering/interruption events. Owns device observation, permission checks, capture configuration, audio files, and playback restoration. The callback uses bounded buffering; disk work and inference stay outside it. |
| `SpeechRuntime` | `transcribe(audio:options:) async throws → Transcript`. Adapters cover Whisper, Parakeet, Cohere, Apple, OpenAI, and Groq. Options express English and vocabulary intent. Unsupported hints are reported as capabilities. |
| `CleanupRuntime` | `clean(text:format:) async throws → CleanupResult`. Adapters cover S1-mini, OpenAI, Claude, and later local extensions. Validate supported formatting before recording. General custom prompts must not become an implied S1-mini capability. |
| `ModelLibrary` | Catalog, `install`, `import`, `remove`, and runtime acquisition. Owns checksums, compatible assets, resumable download state, attribution, installed revisions, and explicit in-use leases. Mode deletion and model removal remain different operations. |
| `CloudAccess` | Executes approved provider requests. Owns Keychain lookup, request cancellation, policy checks, credential redaction, and bounded response handling. Download requests use a separate path. |
| `TextDelivery` | Capture destination, then `deliver(text:destination:) → DeliveryResult`. Owns Accessibility and clipboard handling. Revalidate focus immediately before insertion; uncertain destination means recoverable copy action. Never silently paste into a newly focused app. |
| `LocalStore` | Save settings, record stage results, query history, and expire/delete records. One SwiftData model actor owns persisted records and returns immutable values. Keep raw, cleaned, and final text distinct. |

These are modules with concrete implementations, except the two runtime protocols. Add test adapters where cancellation, insertion, or device failures need simulation. Do not introduce a protocol for every type, a generic pipeline engine, or one repository per screen.

## Processing and persistence rules

`ProcessingPlan` validates the frozen mode against installed model capabilities and current privacy policy before microphone activation. A local-library filter has no execution effect. Require local processing rejects remote speech and remote cleanup independently. `CloudAccess` checks the current policy again at request dispatch. Enabling local-only cancels outstanding cloud tasks and blocks subsequent sends; it cannot retract data already transmitted. Never infer locality solely from an endpoint's hostname.

`TextRules` is a pure function over the chosen raw or cleaned result and frozen replacements. Apply longest matching whole phrases once, then insertion capitalization. Preserve original outputs for comparison. A failed insertion never reruns cleanup automatically.

Store modes, vocabulary, microphone rankings, and history in the same local database. Use persistent device identifiers. Use UserDefaults for appearance and window preferences, Keychain for secrets, and Application Support for audio and model assets. A bounded in-memory settings snapshot feeds editors; writes commit through `LocalStore` before becoming durable UI state.

Retention has independent audio and transcript deadlines. Deletion marks records pending removal, removes managed files, then completes the database change. Startup reconciles interrupted deletion and orphan files. Active session files have leases and cannot expire underneath processing. Deleting history prevents late tasks from recreating it. Metrics derive from retained aggregate events with an explicit deletion policy, never count retries twice.

## Concurrency choices

The starter enables MainActor default isolation and approachable concurrency, with Swift language mode 5.0. Enable strict concurrency checking early. UI state stays MainActor-isolated. Pass Sendable value snapshots across isolation domains; keep model contexts, native pointers, and capture buffers with their owner. Swift's actor isolation protects mutable state, but suspension permits interleaving. Explicit session identities and resource leases are still necessary. [Swift concurrency](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html)

Run synchronous native inference on a dedicated serial worker behind its adapter. An async method alone does not guarantee appropriate execution. Use a custom executor only if a runtime requires it; keep this detail private. [Custom actor executors](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0392-custom-actor-executors.md)

Observation drives view updates; it does not replace isolation. SwiftData's model actor confines database access. [Observation](https://developer.apple.com/documentation/observation), [ModelActor](https://developer.apple.com/documentation/swiftdata/modelactor)

## Proposed files

```text
Amanuensis/
  App/              AmanuensisApp.swift, AppComposition.swift
  Dictation/        DictationSession.swift, ProcessingPlan.swift, TextRules.swift
  Audio/            AudioCapture.swift, MicrophoneSelection.swift
  Models/           ModelLibrary.swift, ModelManifest.swift
  Inference/        SpeechRuntime.swift, CleanupRuntime.swift
    Adapters/       Whisper.swift, Parakeet.swift, Cohere.swift, AppleSpeech.swift
                    S1Mini.swift, OpenAISpeech.swift, GroqSpeech.swift
                    OpenAICleanup.swift, ClaudeCleanup.swift
  Platform/         TextDelivery.swift, ShortcutController.swift, RecorderPanel.swift
  Network/          CloudAccess.swift, CredentialStore.swift
  Storage/          LocalStore.swift, Records.swift, Retention.swift
  Views/            Home.swift, Modes.swift, Vocabulary.swift, Configuration.swift
                    Sound.swift, Models.swift, History.swift, Recorder.swift
AmanuensisTests/     DictationSessionTests.swift, TextRulesTests.swift
                    LocalPolicyTests.swift, RetentionTests.swift
```
