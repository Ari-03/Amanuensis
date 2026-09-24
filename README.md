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

## DMG and automated builds

```sh
Scripts/package-dmg.sh
```

This builds the Release app and creates `artifacts/Amanuensis-<version>-<commit>-arm64.dmg` with an Applications shortcut and installation instructions. The script verifies the disk image, mounts it read-only, and checks the app and helper signatures before writing a SHA-256 checksum alongside it. Uncommitted changes add `-dirty` to the filename. To package an app you have already built, use `Scripts/package-dmg.sh --skip-build`; the filename uses the current checkout's revision, so rebuild first if the source has changed.

Open the DMG, drag Amanuensis to Applications, eject the disk, and launch the installed app. It requires Apple Silicon and macOS 26 or later. Downloaded models and your personal data are not included.

The [macOS workflow](.github/workflows/macos.yml) runs the existing checks and builds a DMG for every pull request to `main` and every push to `main`. It also supports manual runs from GitHub Actions. Download the DMG and checksum from the run's **Artifacts** section on the [Actions page](https://github.com/Ari-03/Amanuensis/actions/workflows/macos.yml). Artifacts expire after 30 days. These builds do not create GitHub Releases or update installed apps.

CI uses an Apple Silicon `macos-26` runner with Xcode 26.6, checks the Metal compiler, and installs Apple's Metal Toolchain component if needed. Swift dependencies use the committed `Package.resolved`; the helper source is pinned and checksum-verified. See GitHub's [runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md).

These are development builds with ad-hoc signatures. Developer ID signing and notarization are not configured, so macOS may block a downloaded copy. For a build you trust, follow [Apple's instructions for opening an app from an unidentified developer](https://support.apple.com/en-us/102445). Distribution without this warning requires an Apple Developer Program membership, a Developer ID Application certificate, and notarization credentials. See [Apple's notarization documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

The repository's `main` protection requires pull requests, the **Checks** and **Build DMG** jobs, an up-to-date branch, and resolved review conversations. It blocks force pushes and branch deletion and applies to administrators too. Required reviewer approvals stay at zero so a sole maintainer can merge their own PR after CI passes. GitHub stores these settings outside the repository, under **Settings → Branches**.

## First recording

1. Open **Sound**, order your microphones, and disable inputs you never want selected.
2. Start with **Voice to text**, which uses Apple Speech without cleanup. Choose **Prepare speech recognition** on Home or **Prepare** beside Apple Speech in Models if English assets are missing. macOS may download them.
3. Open **Models** to download or import another supported speech model, then select it in Modes. Install **S1-mini by Superwhisper** before using the initial Message, Mail, Notes, or Meeting modes. Message uses casual cleanup, Mail uses polished cleanup, and Notes and Meeting use lists. Custom starts without cleanup. Meeting also captures system audio and keeps its output in History without auto-pasting.
4. Allow microphone access when macOS asks. Use **Enable text insertion** on Home to grant Accessibility access for insertion into other apps.
5. Focus a text field in another app and press **⌥⌘Space** to start. Press it again to finish. Escape cancels. The shortcut can be edited on Home or in Settings.

Completed transcripts appear in **History**, with Original and Result views. If insertion cannot safely complete, copy the result from History. Cleanup failure preserves the original transcript and does not automatically insert it.

The recorder rests as a small bar and expands while recording or processing. Hover while idle to choose a mode or start recording with the microphone button. During recording, the bars show microphone frequencies from low on the left to high on the right. Louder sounds raise the bars, and silence returns them to dots. Processing labels display in full. **Mini** is a floating pill. Drag it, including across displays, to reveal 17 screen positions, then release to snap to the highlighted position. These positions are also available in **Settings → Appearance → Screen position**, which appears only for Mini. Its placement is saved. Top and bottom positions sit eight points inside the available screen edge and expand inward, clear of the menu bar and Dock.

Starting a recording moves the controls to the display containing the mouse pointer, keeping Mini's chosen position on that display. They stay there through recording and processing, even if the pointer moves elsewhere.

**Notch** stays inside the menu bar, beside the camera or centered when there is no camera cutout. Before the first recording, it uses the MacBook display or the primary display. Its controls expand horizontally within the menu bar. It ignores saved Mini positions and cannot be dragged. Switching styles preserves Mini's saved position.

Shortcuts can also use two or more modifier keys without a letter or space, such as **⌥⌘**. Press and release the combination to toggle recording. Modifier-only push-to-talk starts after a brief hold and finishes when a modifier is released. Typing another key cancels a modifier gesture. These shortcuts need Accessibility access to work in other apps; ordinary key shortcuts do not.

Automatic paste requires **System Settings → Privacy & Security → Accessibility → Amanuensis**. If permission is missing, the pill shows an orange warning with actions to open Accessibility settings or copy the last transcript. After granting access, focus your text field and start a new recording.

Grant access to the copy of Amanuensis you are running. Development builds use ad-hoc signing, so an older build's Accessibility entry may not authorize a freshly rebuilt copy. The app checks both Accessibility trust and permission to send the paste keystroke. Compatible editors can support replacing selected text even when replacing their entire value is unavailable.

Normal quit and system sleep preserve unfinished audio and text for recovery. Explicit Cancel discards the active recording.

**Require local processing** starts enabled. To use OpenAI or Groq transcription, or OpenAI or Claude cleanup, configure the provider in Models, select it in a mode, and turn off that restriction in Settings. Credentials are stored in macOS Keychain. Testing a provider queries model metadata; it does not upload audio or transcript text.

Meeting capture also needs the macOS screen/system-audio recording permission. Speaker identification is not implemented.

**Playback while recording** can lower or mute outputs with writable macOS volume controls, including devices that expose virtual main volume. Some display and digital audio outputs have no such control. If adjustment is unavailable, the error names the output so you can choose Keep playing or switch outputs. Playback restores when capture ends, while preserving volume changes you make during recording.

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
