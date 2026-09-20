# Native model runtime integration plan

Researched September 19, 2026. This is a source-checked implementation proposal. No packages were installed, weights downloaded, builds run, or inference measured. The available validation machine is arm64 with 16 GiB RAM and Swift 6.3.3. The starter targets macOS 27 with Swift 5 language mode; these are existing settings, not established product minimums.

## Recommended first architecture

Evaluate `MLXAudioSTT` for Whisper, Parakeet, and Cohere; embed llama.cpp for the official S1-mini GGUF; use Apple's Speech framework through a separate adapter. Start with Apple Silicon and propose macOS 26 as the product minimum so the newer Apple recognizer is available. A lower OS floor needs an additional Apple fallback. This recommendation minimizes independent speech runtimes while keeping the mandatory cleanup artifact unchanged.

Keep application-owned interfaces small: `SpeechEngine.transcribe(recording, model, options)` and `CleanupEngine.clean(transcript, settings)`. Neither exposes MLX arrays, llama pointers, or provider dictionaries. A recording coordinator freezes mode/model choices, persists raw results, applies cleanup, and sends the final text to insertion. A separate model store owns acquisition, hashes, artifact compatibility, and readiness.

Run inference on a dedicated serial worker outside the main actor. Load one speech model, transcribe, release it and reclaim its cache before loading S1-mini initially. Measure before enabling warm residency. An `async` function alone does not move synchronous inference away from the UI. In particular, Whisper's inspected `generateStream` runs a synchronous decode inside its stream builder, without cancellation checks in that loop. Cancellation must suppress stale results immediately; prompt resource release remains a spike requirement. [Whisper source](https://github.com/Blaizzy/mlx-audio-swift/blob/01dec7c9bdce3088a6b6b7ab9f2e403458195efb/Sources/MLXAudioSTT/Models/Whisper/WhisperModel.swift)

## Dependencies and build contract

| Component | Verified source facts | Proposed pin/build |
| --- | --- | --- |
| MLX Audio Swift | Manifest requires Swift tools 6.2 and macOS 14. STT links Core, Codecs, VAD, MLXLLM, Transformers, and HuggingFace. README's Swift 5.9 guidance is stale. | Spike revision `01dec7c9bdce3088a6b6b7ab9f2e403458195efb`; tag `v0.1.3` also contains all three model directories. Link `MLXAudioSTT`, not the combined library. |
| Transitive MLX packages | Manifest permits MLX Swift from 0.30.6 and MLX Swift LM from 3.31.3, plus Transformers 1.1.6 and HuggingFace 0.8.1. These ranges are not tested resolutions. | Commit the resolved dependency graph after the build spike. Build through Xcode so Metal resources are present; archive/run outside Xcode too. |
| llama.cpp | Upstream script accepts `macos`, targets macOS 13.3, enables Metal, and generates an importable framework module. It disables common helpers and tools. | Evaluate release `v0.4.1`, commit `b29c606e28a01b1bc8c1351026a0fa6e616bf6c4`. Build `./build-xcframework.sh macos` in an isolated checkout with CMake/Xcode, then wrap the resulting XCFramework as an app-owned binary target. |
| Apple Speech | `SpeechAnalyzer`/`SpeechTranscriber` are available from macOS 26, with device, locale, and asset checks required. | SDK framework, no third-party package. Keep system asset management separate from downloadable model folders. |

Sources: [MLX manifest](https://github.com/Blaizzy/mlx-audio-swift/blob/01dec7c9bdce3088a6b6b7ab9f2e403458195efb/Package.swift), [release tree](https://github.com/Blaizzy/mlx-audio-swift/tree/v0.1.3/Sources/MLXAudioSTT/Models), [MLX build instructions](https://github.com/ml-explore/mlx-swift/blob/0.30.6/README.md#swiftpm), [llama release](https://github.com/ggml-org/llama.cpp/releases/tag/v0.4.1), [framework script](https://github.com/ggml-org/llama.cpp/blob/b29c606e28a01b1bc8c1351026a0fa6e616bf6c4/build-xcframework.sh), [Apple integration research](apple-speech-and-microphones.md).

The inspected llama release advertises no XCFramework asset. Do not invent a download URL. The MLX manifest also uses unsafe compiler flags; consumer-package compatibility belongs in the first build check.

## Model contracts

Catalog twelve distinct Whisper checkpoints: tiny/base/small/medium with and without `.en`, large-v1/v2/v3, and large-v3-turbo. The Swift runtime claims these families; each artifact still needs validation. Use complete compatible directories. Its `fromDirectory` loader can download missing tokenizers, so local-folder loading alone is not an offline guarantee. Validate all required files before loading and test with networking denied and empty external caches. [Whisper documentation](https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioSTT/Models/Whisper/README.md), [checkpoint scope](requested-offline-models.md)

Parakeet v2/v3 have explicit MLX conversions. Cohere's documented Swift example uses FP16; evaluate the independently published 4-bit conversion separately before choosing a 16 GiB default. Never infer memory use from download size. [Parakeet support](https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioSTT/Models/Parakeet/README.md), [Cohere support](https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioSTT/Models/CohereTranscribe/README.md)

Use the pinned official S1-mini Q4_K_M artifact from [availability research](s1-mini-availability.md). The author supplies an exact raw non-thinking prompt format, suitable for a small Swift renderer plus llama C API. Compare its tokens/output against the documented Jinja CLI invocation. Use greedy sampling, bounded input/output, and end-of-generation handling. Do not assume `llama_chat_apply_template` accepts arbitrary Jinja arguments. Its C API lacks that facility; abort callbacks are documented as CPU-only. Check cancellation between decoding steps. [Author instructions](https://huggingface.co/superwhisper/s1-mini-GGUF), [C API](https://github.com/ggml-org/llama.cpp/blob/master/include/llama.h)

## Spikes and fallback triggers

1. Build a separate minimal Xcode host with both runtimes. Verify signing, Metal resources, local import, and no UI blocking. Dependency or shader failure blocks adopting this graph.
2. Validate S1-mini first against corrections, names, negation, numbers, filler-only input, and long-input splitting. Preserve raw text on errors.
3. Run identical short, silent, noisy, boundary-crossing, and long fixtures through all required speech artifacts. Record cold/warm latency, peak memory, accuracy, cancellation, and offline behavior. Do not advertise an untested checkpoint as ready.
4. If MLX Whisper fails accuracy or cancellation requirements, evaluate WhisperKit or whisper.cpp. If Parakeet fails, evaluate FluidAudio. Retain MLX for Cohere unless a replacement is separately proven. If native cancellation cannot release work predictably, isolate inference in a helper process.

WhisperKit is Core ML and its current manifest uses Swift 5.10/macOS 13. FluidAudio uses Swift 6.0/macOS 14; its Swift 6.2 manifest can disable the otherwise bundled NeMo text-normalization binary. These alternatives add model formats and lifecycle work. Python MLX adds runtime distribution; Ollama adds a service dependency. Neither is the first shipping choice. [WhisperKit manifest](https://github.com/argmaxinc/argmax-oss-swift/blob/main/Package.swift), [FluidAudio manifest](https://github.com/FluidInference/FluidAudio/blob/main/Package%40swift-6.2.swift), [alternative runtime comparison](local-model-pipeline.md)
