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

`Scripts/build.sh` builds the S1-mini helper when needed, builds the Release app for arm64, copies it to `artifacts/Amanuensis.app`, and verifies its ad-hoc signature. Dependency sources and build products are not committed. If the build reports a missing Metal compiler, install Xcode's Metal Toolchain component before retrying.

The verified development artifact is approximately 59 MB, excluding downloaded model files. On this development Mac, Whisper Tiny, Parakeet V2, Cohere Transcribe, and S1-mini are already imported into the app. Its saved configuration uses Parakeet V2 for speech. A fresh installation still defaults to Apple Speech as described below.

For development in Xcode, run `BuildSupport/S1Mini/build.sh` first, then open `Amanuensis.xcodeproj` and select the Amanuensis scheme. The build phase requires that helper. Swift Package Manager at the repository root builds the core test target, not the complete macOS app.

The current signing setup is for local use. Developer ID signing, notarization, and automatic updates are not configured.

## First recording

1. Open **Sound**, order your microphones, and disable inputs you never want selected.
2. Start with **Voice to text**, which uses Apple Speech without cleanup. Choose **Prepare speech recognition** on Home or **Prepare** beside Apple Speech in Models if English assets are missing. macOS may download them.
3. Open **Models** to download or import another supported speech model, then select it in Modes. Install **S1-mini by Superwhisper** before using the initial Message, Mail, Notes, or Meeting modes. Message uses casual cleanup, Mail uses polished cleanup, and Notes and Meeting use lists. Custom starts without cleanup. Meeting also captures system audio and keeps its output in History without auto-pasting.
4. Allow microphone access when macOS asks. Use **Enable text insertion** on Home to grant Accessibility access for insertion into other apps.
5. Focus a text field in another app and press **⌥⌘Space** to start. Press it again to finish. Escape cancels. The shortcut can be edited on Home or in Settings.

Completed transcripts appear in **History**, with Original and Result views. If insertion cannot safely complete, copy the result from History. Cleanup failure preserves the original transcript and does not automatically insert it.

Normal quit and system sleep preserve unfinished audio and text for recovery. Explicit Cancel discards the active recording.

**Require local processing** starts enabled. To use OpenAI or Groq transcription, or OpenAI or Claude cleanup, configure the provider in Models, select it in a mode, and turn off that restriction in Settings. Credentials are stored in macOS Keychain. Testing a provider queries model metadata; it does not upload audio or transcript text.

Meeting capture also needs the macOS screen/system-audio recording permission. Speaker identification is not implemented.

## Models and data

The local speech catalog contains twelve Whisper checkpoints, Parakeet V2/V3, and Cohere Transcribe. These use the bundled MLX speech runtime. Imports require the compatible weights and metadata described in [LocalSpeech](Packages/LocalSpeech/README.md); arbitrary `.pt`, whisper.cpp `.bin`, GGUF speech, and Core ML files are not interchangeable.

S1-mini uses its official pinned Q4_K_M GGUF through a bundled llama.cpp helper. It needs no Superwhisper installation or account. See [helper documentation](BuildSupport/S1Mini/README.md) for the model checksum, license, supported formatting, and limits.

Settings, history, model files, and recordings live under `~/Library/Application Support/Amanuensis/`. Default retention is seven days for audio and until deleted for transcripts. Usage totals survive history deletion and can be reset separately in Settings.

## Checks

```sh
Scripts/check.sh
swift test --package-path Packages/LocalSpeech
BuildSupport/S1Mini/smoke-test.sh /absolute/path/to/s1-mini-q4_k_m.gguf
```

`Scripts/check.sh` runs strict Swift formatting checks, nine TextRules tests, the real SQLite storage checks, ten network checks, and a whitespace check. These passed on the development Mac. The final command above runs real S1-mini inference and requires the model.

Real Whisper Tiny, Parakeet V2, and Cohere transcription also passed with network access denied on one short synthetic English sentence. A packaged-app smoke test covered Whisper Tiny through S1-mini, including bundled Metal resources. These checks do not establish microphone capture, cross-app insertion, broad model accuracy, or performance benchmarks.
