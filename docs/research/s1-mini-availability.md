# S1-mini standalone availability

Checked September 19, 2026. Local S1-mini cleanup is a required Amanuensis feature. Public standalone weights are available from Superwhisper itself, and their documented use includes integration in other apps. Availability is verified; Amanuensis integration and performance are not yet tested.

## Provenance and access

Superwhisper's August 19 launch post links directly to its Hugging Face release. It identifies S1-mini as the local cleanup model; S1-Voice and S1-Language are separate cloud products. [Official launch](https://superwhisper.com/blog/s1).

The official repositories publish original BF16 weights with tokenizer/configuration files, and GGUF conversions. Both public API responses reported `private: false` and `gated: false`. An unauthenticated request for the first four bytes of the pinned Q4_K_M file returned `GGUF`. This checked download access without downloading the full model or inspecting an installed Superwhisper app. [BF16 files](https://huggingface.co/superwhisper/s1-mini/tree/main), [GGUF files](https://huggingface.co/superwhisper/s1-mini-GGUF/tree/main), [BF16 metadata](https://huggingface.co/api/models/superwhisper/s1-mini?blobs=true), [GGUF metadata](https://huggingface.co/api/models/superwhisper/s1-mini-GGUF?blobs=true).

Verified GGUF artifact:

| Field | Value |
| --- | --- |
| Repository | `superwhisper/s1-mini-GGUF` |
| Inspected revision | `34add00a48a2e5d24e5a4ee5405a99620a3a240c` |
| Filename | `s1-mini-q4_k_m.gguf` |
| Size | 484,219,808 bytes, approximately 462 MiB or 484 MB |
| Published SHA-256 | `3b41ebe2502cbd03e811d5d16b022f5ab551eda58d62597d152f89535003c634` |

The hash comes from repository metadata; the full file has not been downloaded and hashed locally. [Pinned artifact](https://huggingface.co/superwhisper/s1-mini-GGUF/blob/34add00a48a2e5d24e5a4ee5405a99620a3a240c/s1-mini-q4_k_m.gguf).

The user's screenshot reports local English S1-mini, 462 MB, with an app lock. That is evidence of Superwhisper's interface, not proof of the asset's license, exact bytes, or runtime. The public release provides an independent acquisition path. Matching names and approximate size do not prove the installed app asset is byte-identical.

## License and runtime

The actual LICENSE contains Apache-2.0 terms plus an additional naming requirement: integrations and derivatives must continue to identify the model as `S1-mini` by `Superwhisper`, preserving capitalization. Preserve LICENSE and NOTICE, and mark modifications when redistributing changed files. Do not label the model simply Apache-2.0 while omitting the additional term. The NOTICE identifies its Qwen3-0.6B ancestry. [Pinned LICENSE](https://huggingface.co/superwhisper/s1-mini-GGUF/blob/34add00a48a2e5d24e5a4ee5405a99620a3a240c/LICENSE), [pinned NOTICE](https://huggingface.co/superwhisper/s1-mini-GGUF/blob/34add00a48a2e5d24e5a4ee5405a99620a3a240c/NOTICE).

Its configuration declares `Qwen3ForCausalLM`, BF16 weights, and 28 layers. [Official configuration](https://huggingface.co/superwhisper/s1-mini/blob/main/config.json). Superwhisper publishes Q4_K_M and F16 GGUF variants and documents llama.cpp, Ollama, and LM Studio execution, including loading an existing file. [Author GGUF guide](https://huggingface.co/superwhisper/s1-mini-GGUF).

Recommended first validation path: official Q4_K_M through llama.cpp. Its C/C++ implementation and local-file example provide a route to an embedded Swift wrapper, without making a separately installed service mandatory. This is an engineering proposal, not a tested Amanuensis integration. [llama.cpp](https://github.com/ggml-org/llama.cpp), [local-file inference example](https://github.com/ggml-org/llama.cpp/blob/master/examples/simple/simple.cpp).

No official Core ML or MLX distribution was found in the inspected Superwhisper repositories. That does not establish conversion is impossible. Those paths require separate compatibility and output checks. GGUF already avoids that uncertainty.

## Required integration behavior

The author describes an English transcript normalizer fine-tuned from Qwen3-0.6B, rather than a general instruction-following model. It requires the exact documented system prompt, then a control line and raw transcript. Valid control values are:

| Control | Values |
| --- | --- |
| Styling | `casual`, `semi-casual`, `semi-formal`, `formal` |
| Structure | `prose`, `lists` |
| Context | `general`, `email` |

Keep inputs near or below 1,000 tokens and split longer transcripts. Filler-only input may correctly produce empty output. These are author requirements; use the canonical prompt from the linked card during implementation. [Author model contract](https://huggingface.co/superwhisper/s1-mini).

For GGUF, set greedy decoding explicitly with temperature zero, and render the template with `enable_thinking: false`. The author warns that `--reasoning-budget 0` is not an equivalent substitute. Inherited sampling metadata and the default thinking template can produce incorrect or blank results. Ollama requires the documented non-thinking template. [Author runtime instructions](https://huggingface.co/superwhisper/s1-mini-GGUF#two-settings-that-matter).

The app launch post shows five tone positions, including balanced; the public model contract lists four. There is no verified balanced mapping in the inspected sources. Use the four documented values initially. [App tone description](https://superwhisper.com/blog/s1), [public control values](https://huggingface.co/superwhisper/s1-mini#the-control-line).

Proposed Amanuensis behavior: use S1-mini for supported cleanup settings; preserve raw transcription independently. Runtime errors, timeouts, or truncation must leave raw text recoverable. Treat empty completion as a distinct outcome so filler suppression does not become an error or automatically reinsert unwanted filler. General custom prompts and meeting summarization require another model capability.

Next step is an isolated offline smoke test using the pinned public artifact: verify its full hash, apply the exact author prompt/template, and check names, numbers, negation, corrections, email formatting, filler-only input, and long input. Measure load time, latency, and memory on the target Mac. Author benchmarks do not substitute for these checks. No full model download, inference, app-asset extraction, account access, or lock bypass occurred in this research pass.
