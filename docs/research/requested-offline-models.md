Cohere Transcribe, Whisper, and Parakeet offline support

Verified September 19, 2026, against model publishers, runtime maintainers, conversion authors, and Superwhisper's own documentation. No model weights were downloaded, no inference was run, and no local competitor application assets were inspected.

Cohere Transcribe is available for local offline use. The earlier classification as cloud-only was incorrect. Superwhisper's July 28 announcement explicitly describes a 1.3 GB local download and offline dictation. Its benchmark documentation identifies its implementation as MLX with 4-bit weights. The models page lists Cohere under on-device transcription with a Pro tier. That is an application entitlement, not evidence that the underlying model requires a hosted service. [Superwhisper announcement](https://superwhisper.com/blog/cohere), [runtime description](https://superwhisper.com/benchmarks/cohere-transcribe), [model catalog](https://superwhisper.com/models)

The upstream checkpoint is `CohereLabs/cohere-transcribe-03-2026`, a 2B-parameter Conformer encoder plus Transformer decoder, published under Apache 2.0. Cohere's model card recommends native Transformers support for offline inference and links Apple Silicon support through `mlx-audio`. English is one of 14 supported languages; the caller supplies the language. It has no built-in timestamps or speaker diarization. The card advises a noise gate or VAD to reduce hallucinations on nonspeech audio. [Official model card](https://huggingface.co/CohereLabs/cohere-transcribe-03-2026)

At review time, the official Hugging Face repository displayed a contact-sharing acceptance gate for file access. Once acquired through an authorized source, the documented local inference path does not depend on a Superwhisper license. This access step must be represented honestly if Amanuensis offers the upstream download. Community conversions have their own distribution pages and provenance. [Official download access notice and offline example](https://huggingface.co/CohereLabs/cohere-transcribe-03-2026)

Cohere's hosted API documentation also describes API and Model Vault deployment. Those are additional deployment options. They do not negate the downloadable checkpoint. Its 25 MB API file limit should not be copied into our offline design as an inherent model limit. [Cohere deployment documentation](https://docs.cohere.com/docs/transcribe)

| Candidate for independent Mac execution | Evidence | Boundary |
| --- | --- | --- |
| Python `mlx-audio` | Cohere links its implementation; the runtime maintainer merged Cohere support in PR 605. [Runtime implementation](https://github.com/Blaizzy/mlx-audio/pull/605) | An existing Apple Silicon route, but Python packaging would add a separate runtime to a native app. |
| Swift `MLXAudioSTT` | The runtime includes `CohereTranscribeModel`, an example loading `beshkenadze/cohere-transcribe-03-2026-mlx-fp16`, English generation parameters, and optional Silero VAD. [Cohere Swift documentation](https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioSTT/Models/CohereTranscribe/README.md) | Most direct candidate for our native Swift application. This research verified documentation, not build compatibility or real-device performance. |
| Community 4-bit conversion | `beshkenadze/cohere-transcribe-03-2026-mlx-4bit` publishes affine 4-bit weights with group size 64 and reports 1.51 GB. The author's card reports a small English parity check across Swift, Python MLX, and the official reference, plus a lexical regression on another sample. [Conversion card](https://huggingface.co/beshkenadze/cohere-transcribe-03-2026-mlx-4bit) | This is the converter's artifact and evaluation, not an official Cohere quantization or a full benchmark. It is not established as byte-identical to Superwhisper's 1.3 GB build. |

The Swift runtime is MIT-licensed and lists Whisper, Parakeet, and Cohere support within one speech-to-text package. That makes it worth evaluating before assuming three separate engines are necessary. Keep this as an implementation candidate until a pinned version passes our checks. [Runtime repository](https://github.com/Blaizzy/mlx-audio-swift)

Superwhisper's catalog currently labels Cohere as supporting 100+ languages, while Cohere's documentation says 14. Use the model publisher's value. For this app the distinction does not alter English-only behavior, but it shows why we should not populate model metadata by copying a competitor's table. [Superwhisper catalog](https://superwhisper.com/models), [Cohere model details](https://docs.cohere.com/docs/transcribe)

For "all official Whisper variants," OpenAI's actual checkpoint registry contains twelve distinct checkpoints:

| Family | Checkpoints |
| --- | --- |
| Tiny | `tiny`, `tiny.en` |
| Base | `base`, `base.en` |
| Small | `small`, `small.en` |
| Medium | `medium`, `medium.en` |
| Large | `large-v1`, `large-v2`, `large-v3` |
| Turbo | `large-v3-turbo` |

`large` aliases `large-v3`; `turbo` aliases `large-v3-turbo`. They should not produce duplicate downloads or separate model identities. OpenAI releases the code and weights under MIT. An English-only app can support the multilingual checkpoints while fixing transcription to English. [OpenAI checkpoint registry](https://github.com/openai/whisper/blob/main/whisper/__init__.py), [OpenAI license statement](https://github.com/openai/whisper#license)

The Swift runtime advertises all Whisper sizes and `.en` variants in Hugging Face and OpenAI/MLX layouts. Its documentation also says MLX mirrors may fetch a tokenizer from the corresponding OpenAI repository on demand. Amanuensis must acquire every required tokenizer/configuration file before calling a model offline-ready. Treat runtime format support separately from model identity; an original `.pt` file, whisper.cpp `.bin`, and MLX directory are not interchangeable imports. [Whisper Swift documentation](https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioSTT/Models/Whisper/README.md)

For the requested Parakeet scope, the two models matching the user's Superwhisper references are `nvidia/parakeet-tdt-0.6b-v2` and `nvidia/parakeet-tdt-0.6b-v3`. Both have 600 million parameters and CC BY 4.0 model licenses. V2 is English-only; V3 supports 25 European languages with automatic detection. V3 provides word and segment timestamps. These are transcription models, so timestamps do not establish speaker identification. [NVIDIA V2 card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2), [NVIDIA V3 card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)

The Swift package explicitly lists converted V2 and V3 models, along with several older TDT, CTC, and RNNT variants. We should name V2 and V3 in the initial requirement rather than silently interpreting "Parakeet" as every historical checkpoint. More variants can be catalog entries once their exact runtime formats are validated. [Parakeet Swift documentation](https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioSTT/Models/Parakeet/README.md)

Recommended implementation requirements:

- Include all twelve distinct official Whisper checkpoints, Parakeet TDT 0.6B V2/V3, and Cohere Transcribe 03-2026 in the offline support plan. Record quantization and conversion as artifact metadata beneath each model identity.
- Evaluate the existing Swift MLX Cohere implementation first. Pin the runtime revision and conversion revision, then test microphone recordings, long audio, silence, vocabulary-sensitive names, memory, cancellation, and offline loading with networking disabled.
- Support a complete local model directory import with its tokenizer and configuration. Validate against the selected backend and show a specific compatibility error. Do not require a cloud fallback when a local model fails.
- Keep model provenance and applicable license notices with downloaded artifacts. A user's right to run compatible local models must not expire with an app trial or account state.
- Do not promise parity with Superwhisper's size, speed, decoding behavior, or contextual vocabulary implementation from the model name alone. The independent implementation must earn its own performance claims.

Open questions are runtime validation and distribution details, not whether Cohere can run offline. The reviewed public sources do not establish the exact Superwhisper artifact hash, a supported export path from that app, or permission to redistribute that app's packaged files. Amanuensis can proceed with independently sourced public weights and runtimes.
