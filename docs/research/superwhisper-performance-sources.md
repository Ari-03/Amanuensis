# Superwhisper performance comparison

Researched September 20, 2026 from official Superwhisper documentation and model cards. This is a source comparison, not an independent benchmark of Superwhisper. Amanuensis references describe the implementation inspected during this investigation.

## What explains a gap with the same model name

The most concrete differences are model lifetime and runtime selection. Superwhisper documents keeping speech models loaded between dictations. It also uses a different inference engine from Amanuensis for Whisper and Parakeet. Matching the checkpoint name does not match startup cost, numerical precision, hardware execution, or the amount of work left after recording stops.

| Area | Verified Superwhisper behavior | Amanuensis baseline | Implication |
| --- | --- | --- | --- |
| Speech model lifetime | Voice Model Active Duration ranges from 10 seconds to 1 hour. Longer durations retain loaded models. [Performance guide](https://superwhisper.com/docs/common-issues/performance-tips) | LocalSpeechEngine loads a model per request and clears MLX allocation cache afterward. [Engine](../../Packages/LocalSpeech/Sources/LocalSpeech/LocalSpeechEngine.swift) | Repeated dictations pay initialization again in Amanuensis. |
| Preparation during recording | Version 2.17.2, August 6, 2026, added Cohere preloading at recording start. [Changelog](https://superwhisper.com/changelog) | The speech adapter accepts a finished audio file and loads inside transcribe. [Engine](../../Packages/LocalSpeech/Sources/LocalSpeech/LocalSpeechEngine.swift) | Loading earlier can remove model preparation from the wait after stopping. It does not make decoding itself faster. |
| Parakeet | Argmax WhisperKit SDK; long recordings process in parallel. [Voice models](https://superwhisper.com/docs/models/voice) | MLX Audio Swift, sequential windows of at most 30 seconds. [Engine](../../Packages/LocalSpeech/Sources/LocalSpeech/LocalSpeechEngine.swift) | Runtime and scheduling differ even when both selections say Parakeet V2/V3. |
| Whisper | whisper.cpp. [Voice models](https://superwhisper.com/docs/models/voice) | MLX Audio Swift. [Engine](../../Packages/LocalSpeech/Sources/LocalSpeech/LocalSpeechEngine.swift) | A runtime benchmark is necessary before assuming equal throughput. |
| Cohere | Local MLX at 4-bit precision. [Cohere benchmark](https://superwhisper.com/benchmarks/cohere-transcribe) | MLX Audio Swift; the existing smoke test uses a Cohere 4-bit conversion. [Package notes](../../Packages/LocalSpeech/README.md) | This is a closer runtime-family match, but the exact implementation, artifact, and generation settings still need comparison. |
| Cleanup | A language model is optional and follows speech recognition. [Model overview](https://superwhisper.com/models) | S1-mini helper starts a process and cold-loads its model for every request. [Helper notes](../../BuildSupport/S1Mini/README.md) | Compare the same cleanup setting. A speech-only run omits an entire model stage. |

These are architectural explanations, not a measured allocation of the user's observed delay.

## Streaming and silence

Superwhisper's realtime guide documents live previews for Nova cloud models and local Parakeet Realtime. It does not establish that the final transcript always reuses incremental work or avoids a final full-recording pass. We should therefore treat streaming as verified earlier feedback, with any reduction in final stop-to-paste latency requiring a separate measurement. [Realtime guide](https://superwhisper.com/docs/common-issues/realtime)

The changelog records skipping short silent clips in 2.17.2 and enabling silence removal by default in 2.18.3 on September 3, 2026. Amanuensis' inspected speech adapter skips only exact digital silence within its audio windows. Normal microphone noise does not meet that condition. An acoustic speech detector may reduce unnecessary model work, but boundary accuracy needs testing. [Changelog](https://superwhisper.com/changelog), [Amanuensis engine](../../Packages/LocalSpeech/Sources/LocalSpeech/LocalSpeechEngine.swift)

## What the published numbers establish

Superwhisper reports the following speech results, updated September 3, 2026. These are vendor measurements and do not establish Amanuensis' speed on this machine.

| Speech model | Hardware | Published response time | Source |
| --- | --- | --- | --- |
| Cohere Transcribe | M4 | 0.45 seconds, macro average across 8 datasets | [Cohere results](https://superwhisper.com/benchmarks/cohere-transcribe) |
| Cohere Transcribe | M4 Max | 0.18 seconds, macro average across 3 datasets | [Cohere results](https://superwhisper.com/benchmarks/cohere-transcribe) |
| Parakeet V2 | M4 | 0.06 seconds, macro average across 8 datasets | [Parakeet V2 results](https://superwhisper.com/benchmarks/parakeet-v2) |

The stated method measures response after speech ends on 8 to 15 second clips, taking medians within runs. Local models run through the actual app. Throughput is a separate metric, expressed as audio duration divided by processing duration. The published method does not provide enough detail here to reproduce model warmth, inclusion of model loading, or insertion confirmation. It also does not establish S1-mini cleanup latency. Treat these numbers as leads for investigation, not directly comparable stop-to-paste targets. [Benchmark method](https://superwhisper.com/docs/models/benchmarks), [Leaderboard method](https://superwhisper.com/benchmarks)

## S1-mini settings worth preserving

The official model card specifies the exact system prompt and control line, thinking disabled, greedy decoding, approximately 1,000 input tokens per pass, and a generation ceiling of `1.3 * input_tokens + 32`. These are already represented in Amanuensis' helper. Changing that prompt or enabling reasoning is not a supported latency optimization. [S1-mini model card](https://huggingface.co/superwhisper/s1-mini), [Helper implementation](../../BuildSupport/S1Mini/main.cpp)

The official GGUF card recommends Q4_K_M and explicitly warns that inherited sampling metadata does not express the required greedy setting. Amanuensis pins this quantization and calls a greedy sampler. Its helper requests GPU offload with `n_gpu_layers = 99`; attributing its delay to deliberately CPU-only inference would be incorrect. [GGUF card](https://huggingface.co/superwhisper/s1-mini-GGUF), [Helper implementation](../../BuildSupport/S1Mini/main.cpp)

The public sources checked do not specify Superwhisper's S1-mini process lifetime, prompt cache, GPU layer count, context allocation, or per-request checksum policy. A persistent Amanuensis helper is a proposed optimization based on our own cold-load behavior, not a claim about undocumented Superwhisper internals.

## Recommended comparison

Use identical recordings, hardware, checkpoint revision, precision, language, and cleanup controls. Separate the first request after launch, another request while resident, and a request after the idle unload interval. Measure recording-stop to raw transcript, raw transcript to cleaned result, and cleaned result to successful insertion. Superwhisper exposes voice and AI processing durations in History, which can help identify the stage to compare. [Performance guide](https://superwhisper.com/docs/common-issues/performance-tips)

Instrument Amanuensis model validation, loading, audio conversion, speech decode, cleanup process start, cleanup model load, prompt processing, token generation, and insertion. Those spans will distinguish fixed setup cost from duration-dependent inference. Capture median and tail latency over short, medium, and long recordings, plus memory use and transcription accuracy.

Prioritize retaining initialized models and preparing them during recording. After measuring that change, compare Parakeet's existing MLX backend with WhisperKit and Whisper's existing backend with whisper.cpp. Streaming and acoustic silence removal deserve separate experiments because each can change transcript boundaries and output quality.
