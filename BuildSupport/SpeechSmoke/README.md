# Local speech smoke harness

This executable loads an existing model folder through the same `LocalSpeechEngine` used by the app. It accepts a family, model directory, and audio file. It prints the transcript and elapsed time, and fails for errors or empty output. It never downloads models or records a microphone.

Build on the selected Xcode installation with its Metal toolchain installed:

```sh
cd BuildSupport/SpeechSmoke
xcrun xcodebuild -scheme SpeechSmoke \
  -destination 'platform=macOS,arch=arm64' -configuration Release \
  -derivedDataPath /tmp/amanuensis-speech-smoke-derived \
  -skipPackagePluginValidation -skipMacroValidation -jobs 4 \
  build CODE_SIGNING_ALLOWED=NO
```

If Xcode reports a missing Metal toolchain, obtain Apple's component with `xcrun xcodebuild -downloadComponent MetalToolchain`. The package validation flags permit command-line builds of the pinned dependency plugins and macros. They do not disable app sandboxing or macOS security settings.

Create a synthetic English fixture without recording or playing microphone audio:

```sh
say -v Samantha -o /tmp/amanuensis-smoke-input.aiff \
  'Please send the meeting notes to Sarah by Thursday afternoon.'
```

Run in a process sandbox that denies network access:

```sh
sandbox-exec -p '(version 1) (allow default) (deny network*)' \
  /tmp/amanuensis-speech-smoke-derived/Build/Products/Release/SpeechSmoke \
  whisper /tmp/amanuensis-smoke-whisper /tmp/amanuensis-smoke-input.aiff
```

Use `parakeet` or `cohere` with a corresponding complete local folder for the other adapters. Run models sequentially on the 16 GiB development Mac. The sandbox command is a development check, not the app's deployment architecture.

## Pinned smoke artifacts

These are independently downloaded public artifacts, not files from Superwhisper. The temporary model files are excluded from the repository.

| Family | Source and revision | Weight size | Published SHA-256 |
| --- | --- | --- | --- |
| Whisper tiny | [openai/whisper-tiny](https://huggingface.co/openai/whisper-tiny/tree/169d4a4341b33bc18d8881c4b69c2e104e1cc0af), `169d4a4341b33bc18d8881c4b69c2e104e1cc0af` | 151,061,672 bytes | `7ebd0e69e78190ffe1438491fa05cc1f5c1aa3a4c4db3bc1723adbb551ea2395` |
| Parakeet TDT 0.6B v2 | [mlx-community conversion](https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v2/tree/8ae155301e23d820d82aa60d24817c900e69e487), `8ae155301e23d820d82aa60d24817c900e69e487` | 2,471,559,904 bytes | `b958c37a6baa6874a279108755c8f2818e27bf647d72d54800a234a421341dfe` |
| Cohere Transcribe 03-2026 4-bit | [beshkenadze conversion](https://huggingface.co/beshkenadze/cohere-transcribe-03-2026-mlx-4bit/tree/104bc4391b5b1a12b040859793d7148525e1a08c), `104bc4391b5b1a12b040859793d7148525e1a08c` | 1,505,114,042 bytes | `5284ab5b678da720da092604323c7ce82cffe544e42b2da95064fbc85e281609` |

Whisper additionally uses its pinned tokenizer/configuration JSON files, vocabulary, and merges. Parakeet needs its pinned `config.json`. Cohere needs its pinned `config.json`, `tokenizer_config.json`, and `tokenizer.model`.

One synthetic sentence can prove artifact loading and basic execution. It cannot establish accuracy across accents, microphone quality, long recordings, chunk boundaries, every Whisper checkpoint, or general production readiness.

## Results, September 19, 2026

Built successfully with Xcode in Release after installing Apple's Metal Toolchain 17F109. The host uses arm64, 16 GiB RAM, and Swift 6.3.3. Each model ran in a separate process with network access denied by the sandbox profile above. All three returned this exact transcript:

> Please send the meeting notes to Sarah by Thursday afternoon.

| Model | Engine load plus transcription | Peak process memory footprint reported by `/usr/bin/time -l` | Exit |
| --- | --- | --- | --- |
| Whisper tiny | 2.882 seconds | 331,891,624 bytes | 0 |
| Parakeet TDT 0.6B v2 | 5.380 seconds | 3,832,270,040 bytes | 0 |
| Cohere Transcribe 03-2026 4-bit | 3.166 seconds | 1,807,992,752 bytes | 0 |

The fixture is 3.202 seconds of synthesized Samantha speech, originally mono 22,050 Hz. The engine read and resampled it to 16 kHz. All weight hashes matched the values above. The runtime adapter required no changes after these inference checks. The harness entry file was renamed from `main.swift` to `SpeechSmoke.swift` because Xcode otherwise treated its `@main` declaration as a second entry point.

These are single-run smoke measurements, including model loading. Filesystem caches and other development activity were uncontrolled. They are not comparative product benchmarks or a complete accounting of GPU memory. All three processes reported zero swaps. Temporary result logs are `/tmp/amanuensis-smoke-whisper-result.log`, `/tmp/amanuensis-smoke-parakeet-result.log`, and `/tmp/amanuensis-smoke-cohere-result.log`.
