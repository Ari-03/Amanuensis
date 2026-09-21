# Implementation status

Updated September 20, 2026. This document describes the current source and validation evidence. The [product brief](product-brief.md) remains the requested scope; the [implementation plan](implementation-plan.md) contains earlier proposed decisions.

## Current implementation

The starter has been replaced with a native SwiftUI app and AppKit recording controls. Home, Modes, Vocabulary, Models, History, Sound, and Settings are connected to shared application state. Home and Settings edit the same recording shortcut. The app also has a menu-bar menu and mini, panel, notch-positioned, and hidden recorder options.

One MainActor `AppModel` owns recording state, session identity, cancellation, and frozen mode/model/vocabulary choices. Its processing sequence is capture, transcription, optional cleanup, deterministic replacements, and insertion. Raw text is persisted before cleanup. Cleanup failure keeps the raw result in History without auto-inserting it. Empty cleanup output produces nothing to insert. Destination checks and copy recovery are implemented for unsuccessful insertion. Cancellation waits for teardown before another job can start, and normal application termination restores a temporarily changed clipboard. Normal quit and sleep preserve unfinished audio and text; explicit Cancel discards the active recording.

Initial modes all use Apple Speech. Voice to text and Custom start without cleanup. Message uses casual S1-mini cleanup, Mail uses polished S1-mini cleanup, and Notes and Meeting use S1-mini with lists. Meeting also enables system audio and disables auto-paste. These presets require installing S1-mini before recording; Apple Speech preparation is available on Home and Models.

The development Mac now has four managed model imports: Whisper Tiny, Parakeet V2, Cohere Transcribe, and S1-mini. Its saved configuration selects Parakeet V2 for speech in all modes while retaining the cleanup presets. This is local setup state; the repository's first-launch defaults remain Apple Speech.

| Area | Present in source | Remaining validation or limitation |
| --- | --- | --- |
| Microphones | Persistent priority list, explicit exclusions, device discovery, selected input, interruption handling | Real microphone permission, capture, reconnect, and device-loss behavior need live checks. |
| Recording controls | Editable global toggle shortcut, optional push-to-talk, mode shortcut, Escape cancellation, menu-bar and floating controls | Carbon shortcut checks passed. Cross-app shortcut conflicts, keyboard layouts, full-screen Spaces, and multiple displays need live checks. |
| Modes | Six initial presets, create/edit/delete, per-mode recording shortcuts, app associations, speech/cleanup selection, tone, lists, custom prompt, insertion settings | Website matching is absent. Automatic selection matches app bundle IDs. |
| Vocabulary | Persistent word hints and deterministic word/phrase replacements | Local speech adapters do not currently accept vocabulary hints. Cloud speech receives hints. Entries can be added or deleted; a dedicated edit action is absent. Replacement behavior has separate core tests. |
| Apple Speech | macOS SpeechTranscriber, English asset readiness and preparation, local transcription | Asset download and real recognition on this Mac remain unverified. |
| Downloadable local speech | MLX adapter for Whisper, Parakeet, and Cohere; twelve Whisper catalog entries plus pinned Parakeet/Cohere artifacts | Real inference passed for Whisper Tiny, Parakeet V2, and Cohere on one synthetic sentence. Other checkpoints, live audio, memory, and broader accuracy still need validation. |
| S1-mini | Official Q4_K_M weights, checksum validation, bundled llama.cpp helper, native caller, tone/list/email controls | Real helper inference and packaged Whisper-to-S1 processing passed. Live dictation through insertion still needs verification. |
| Cloud providers | OpenAI/Groq speech; OpenAI/Claude cleanup; Keychain credentials; explicit model IDs; provider tests; local-processing policy | Validated with mock responses only. No live provider request was made with an API key. |
| History | Search, Original/Result views, copy, retained-audio retry, deletion and interrupted-session recovery. Raw/cleaned/final text is stored separately. | Audio playback and a separate cleaned-before-replacements view are absent. Large-history responsiveness needs app testing. |
| Retention | Separate audio/text expiration, active-file leases, deletion tombstones, crash recovery | Database/file behavior has a standalone check program; this is not secure erasure against backups or filesystem snapshots. |
| Meeting capture | ScreenCaptureKit microphone/system-audio capture and mixing | Permissions, real mixed audio, cancellation, and device-loss behavior remain unverified. Diarization is absent. |
| Playback behavior | Keep playing, lower volume, and mute when the output device permits them; restoration avoids overwriting later user changes | Universal media pause/resume is absent. Controls depend on output hardware. |
| Settings | Appearance, recorder previews, local-processing restriction, retention, login launch, recording sounds, usage reset | No updater, diagnostic-log export, custom storage location, clipboard history, or mouse recording shortcut. |

## Decisions implemented differently from the plan

The app targets **macOS 26 and arm64**. It uses **Swift 6 language mode** and requires a **Swift 6.3 toolchain** because of the resolved MLX dependencies. App Sandbox is disabled for direct distribution. Current build scripts use ad-hoc signing; Developer ID signing, notarization, and release updates remain work to do.

Storage uses **system SQLite3 directly**, through one `LocalStore`, rather than the plan's GRDB queue or the earlier architecture note's SwiftData model actor. It stores encoded records within SQLite transactions, owns audio-file deletion, and uses tombstones to reject late results after deletion. No GRDB or SwiftData dependency is used. Current database operations run on MainActor, so history scale should be measured before changing that ownership. Storage directories are private (0700). Startup discards abandoned `.meeting-UUID` channel fragments left by a crash; these unfinished fragments cannot currently be recovered as a meeting. Ordinary recordings and unrelated directories are preserved, with symlink safety covered by storage checks.

Usage totals count words in the **final completed dictation output**, using whitespace separation. This differs from the plan's raw-word proposal. Meeting mode, empty output, and failed processing are excluded. A content-free ledger prevents retry double-counting. History deletion retains these aggregates; Reset statistics clears totals while retaining the counted session IDs.

Ollama has a catalog descriptor but is hidden from selectors and rejected by recording validation. General local Llama cleanup is not connected. S1-mini is the current local cleanup implementation.

## Validation evidence

- The S1-mini helper ran real inference with the pinned official model on the development Apple Silicon Mac. Names, numeric correction, filler suppression, invalid controls, checksum rejection, and cancellation checks passed. See the [recorded helper results](../BuildSupport/S1Mini/README.md).
- The LocalSpeech package passed Swift 6.3.3 compilation, five local-file preflight/snapshot tests, and formatting checks. Subsequent standalone speech tests returned the exact synthetic English sentence with network access denied: Whisper Tiny in 2.88 seconds, Parakeet V2 in 5.38 seconds, and Cohere in 3.17 seconds. Each used the same 3.2-second recording. These single observations are not benchmarks or evidence of general accuracy.
- The packaged app's `--speech-smoke` test completed Whisper Tiny transcription followed by S1-mini cleanup under a sandbox rule denying network access. This exercised the bundled MLX Metal resources and helper. Managed imports of all four models also passed.
- After model retention was implemented, six LocalSpeech package tests, real Cohere lifecycle checks, persistent S1-mini equivalence checks, and runner failure/lifecycle checks passed. The rebuilt Release app passed signature verification and `Scripts/check-packaged-speech.sh` with two consecutive Cohere-to-S1 runs, identical output, network access denied, and clean shutdown. See the [performance measurements](research/transcription-performance.md).
- Cloud-provider validation used mock HTTP responses. Real authentication, billing limits, model availability, and transcription/cleanup output remain unverified.
- `Scripts/check.sh` passed strict Swift formatting, nine TextRules tests, real SQLite storage checks, ten network checks, and `git diff --check`. Separate Carbon shortcut checks also passed. These do not establish whole-app behavior.
- `Scripts/build.sh` completed the Release arm64 build successfully. Deep, strict signature verification passed for `artifacts/Amanuensis.app`, approximately 59 MB excluding model files. Xcode's Metal Toolchain is installed.
- The app launched as a normal process and created a GUI window. An earlier offscreen render was inspected. Capturing the live window failed because screen-recording permission was unavailable, so full visual interaction has not been verified.

Live microphone capture, system-audio permissions, Accessibility insertion into another app, and real provider requests remain untested. The new normal-quit/sleep recovery paths pass compilation and code checks but still need interruption testing with live capture.

## Build and test limitations

`Scripts/build.sh` requires full Xcode, its Metal Toolchain component, and CMake. It runs the Release arm64 Xcode build, whose bundle phase builds the S1 helper incrementally from source, creates `artifacts/Amanuensis.app`, and verifies its ad-hoc signature. The root Swift package covers core/storage test code and cannot replace that build.

The local speech adapter prepares the selected model while recording, retains it for up to 60 seconds after transcription, transcribes audio in windows of at most 30 seconds, and joins the output. Real Cohere lifecycle and short/medium latency checks passed; see the [performance investigation](research/transcription-performance.md). Boundary accuracy, long meetings, noisy speech, live Stop-to-paste latency, and memory under pressure still need broader tests. Cancellation suppresses output but cannot immediately stop an upstream synchronous MLX operation already running.

S1-mini reuses a verified model in a persistent helper, with a fresh context per request and a 60-second idle expiry. It accepts at most 1,000 transcript tokens. The native caller splits longer text at sentence/word boundaries and retries smaller chunks if the helper rejects an oversized chunk. Each chunk has a 120-second timeout, and startup removes stale job files from older versions. Real repeated-request equivalence and runner lifecycle checks passed. Meaning across chunk boundaries and live end-to-end cleanup latency still need testing. S1-mini's formatting controls do not provide general-purpose custom prompting or meeting summaries.

The notch recorder is a custom floating panel positioned below the camera cutout. It is not a macOS Dynamic Island integration. Hardware layout and focus behavior require checking on notched and external displays.
