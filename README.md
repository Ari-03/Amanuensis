# Amanuensis

A native macOS dictation app with local speech recognition, optional transcript cleanup, and your own API keys. Compatible downloaded models have no subscription or usage quota.

The Release app builds and its ad-hoc signature verifies. Packaged Whisper-to-S1-mini processing passed with network access denied. This remains a development build: live microphone capture, system audio, cross-app insertion, and real API calls still need validation. See [implementation status](docs/implementation-status.md) for the evidence and remaining work.

## Build and run

Requirements:

- An Apple Silicon Mac running macOS 26 or later.
- Full Xcode with a Swift 6.3 or newer toolchain and the Metal Toolchain component installed. The app uses Swift 6 language mode.
- CMake for building the bundled S1-mini helper.
- Internet access for the initial dependency fetch and model downloads.

From the repository root:

```sh
xcodebuild -version
xcrun swift --version
cmake --version
Scripts/build.sh
open artifacts/Amanuensis.app
```

`Scripts/build.sh` builds the Release app for arm64, copies it to `artifacts/Amanuensis.app`, and verifies its ad-hoc signature. Dependency sources and build products are not committed. If the build reports a missing Metal compiler, install Xcode's Metal Toolchain component before retrying.

The verified development artifact is approximately 59 MB, excluding downloaded model files. On this development Mac, Whisper Tiny, Parakeet V2, Cohere Transcribe, and S1-mini are already imported into the app. Its saved configuration uses Parakeet V2 for speech. A fresh installation still defaults to Apple Speech as described below.

For development in Xcode, open `Amanuensis.xcodeproj`, select the Amanuensis scheme, and build or run. The build phase fetches the pinned llama.cpp source and builds the S1-mini helper automatically, then reuses CMake's incremental build cache. No generated helper binary needs to be copied between checkouts. CMake installed through Homebrew or its standard macOS app is found even when Xcode is launched from Finder. The first helper build needs internet access and takes longer. Swift Package Manager at the repository root builds the core test target, not the complete macOS app.

The current signing setup is for local use. Developer ID signing, notarization, and automatic updates are not configured.

## First recording

1. Open **Sound**, order your microphones, and disable inputs you never want selected.
2. Start with **Voice to text**, which uses Apple Speech without cleanup. Choose **Prepare speech recognition** on Home or **Prepare** beside Apple Speech in Models if English assets are missing. macOS may download them.
3. Open **Models** to download or import another supported speech model, then select it in Modes. Install **S1-mini by Superwhisper** before using the initial Message, Mail, Notes, or Meeting modes. Message uses casual cleanup, Mail uses polished cleanup, and Notes and Meeting use lists. Custom starts without cleanup. Meeting also captures system audio and keeps its output in History without auto-pasting.
4. Allow microphone access when macOS asks. Use **Enable text insertion** on Home to grant Accessibility access for insertion into other apps.
5. Focus a text field in another app and press **⌥⌘Space** to start. Press it again to finish. Escape cancels. The shortcut can be edited on Home or in Settings.

Completed transcripts appear in **History**, with Original and Result views. If insertion cannot safely complete, copy the result from History. Cleanup failure preserves the original transcript and does not automatically insert it.

The floating recorder shrinks to a 36 × 6 point bar while idle. Hover to expand the controls around the same center and choose a mode or start recording. Drag anywhere on the pill, including across displays, to reveal 17 screen positions. Release to snap to the highlighted position. The same positions are available in **Settings → Appearance → Screen position**. Placement is saved, with room for the controls to open within the usable screen area. Mini replaces the former Panel style.

Automatic paste requires **System Settings → Privacy & Security → Accessibility → Amanuensis**. If permission is missing, the pill shows an orange warning with actions to open Accessibility settings or copy the last transcript. After granting access, focus your text field and start a new recording.

Normal quit and system sleep preserve unfinished audio and text for recovery. Explicit Cancel discards the active recording.

**Require local processing** starts enabled. To use OpenAI or Groq transcription, or OpenAI or Claude cleanup, configure the provider in Models, select it in a mode, and turn off that restriction in Settings. Credentials are stored in macOS Keychain. Testing a provider queries model metadata; it does not upload audio or transcript text.

Meeting capture also needs the macOS screen/system-audio recording permission. Speaker identification is not implemented.

## Models and data

The local speech catalog contains twelve Whisper checkpoints, Parakeet V2/V3, and Cohere Transcribe. These use the bundled MLX speech runtime. Imports require the compatible weights and metadata described in [LocalSpeech](Packages/LocalSpeech/README.md); arbitrary `.pt`, whisper.cpp `.bin`, GGUF speech, and Core ML files are not interchangeable.

S1-mini uses its official pinned Q4_K_M GGUF through a bundled llama.cpp helper. It needs no Superwhisper installation or account. See [helper documentation](BuildSupport/S1Mini/README.md) for the model checksum, license, supported formatting, and limits.

Local speech models prepare while recording and stay loaded for up to 60 seconds after transcription. S1-mini reuses one helper across cleanup chunks and recordings, with a fresh inference context for each request and the same idle expiry. Memory pressure, cancellation, model removal, sleep, and quit release retained resources. The [performance investigation](docs/research/transcription-performance.md) records measurements and validation.

Settings, history, model files, and recordings live under `~/Library/Application Support/Amanuensis/`. Default retention is seven days for audio and until deleted for transcripts. Usage totals survive history deletion and can be reset separately in Settings.

## Checks

```sh
Scripts/check.sh
Scripts/check-recorder.sh
swift test --package-path Packages/LocalSpeech
BuildSupport/S1Mini/smoke-test.sh /absolute/path/to/s1-mini-q4_k_m.gguf
```

`Scripts/check.sh` runs strict Swift formatting, core tests, SQLite storage checks, network checks, shortcuts, playback, paste-permission checks, helper isolation, and a whitespace check. `Scripts/check-recorder.sh` requires a macOS desktop session and checks native resizing, drag targets, snapping, and permission recovery without posting global input. The final command above runs real S1-mini inference and requires the model.

Real Whisper Tiny, Parakeet V2, and Cohere transcription also passed with network access denied on one short synthetic English sentence. A packaged-app smoke test covered Whisper Tiny through S1-mini, including bundled Metal resources. These checks do not establish microphone capture, cross-app insertion, broad model accuracy, or performance benchmarks.
