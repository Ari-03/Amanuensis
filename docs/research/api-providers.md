# API providers and local cleanup services

Checked September 19, 2026 against provider documentation. This pass specifies integrations and their boundaries; it does not use API keys or make inference requests. Aritra confirmed OpenAI and Claude for cloud cleanup. Speech APIs are OpenAI and Groq.

| Provider | Requested use | Verified interface and model selection |
| --- | --- | --- |
| OpenAI | Speech-to-text | The file transcription API documents `gpt-transcribe`, matching the supplied screenshot. Earlier GPT-4o transcription variants are also documented. Keep the selected model ID explicit and adapt supported parameters per model. [GPT-Transcribe](https://developers.openai.com/api/docs/models/gpt-transcribe), [file transcription](https://developers.openai.com/api/docs/guides/speech-to-text) |
| Groq | Speech-to-text | Its OpenAI-compatible `/openai/v1/audio/transcriptions` endpoint documents `whisper-large-v3` and `whisper-large-v3-turbo`. These are hosted requests even though Whisper weights can also run locally. [Groq speech API](https://console.groq.com/docs/speech-to-text) |
| OpenAI | Cleanup | Responses supports text generation with a selected model and instructions. It is the recommended API for new text-generation applications. Do not assume every model supports identical sampling or output parameters. [Text generation](https://developers.openai.com/api/docs/guides/text) |
| Anthropic | Claude cleanup | Messages accepts the selected model and input messages. The Models API lists available models and capabilities. Use Anthropic's own adapter, not an assumption that its request format matches OpenAI's. [Messages](https://platform.claude.com/docs/en/api/messages/create), [Models](https://platform.claude.com/docs/en/api/models/list) |
| Ollama | Optional additional local cleanup models | Ollama can run local models and also cloud models. Its FAQ documents disabling cloud with `disable_ollama_cloud` or `OLLAMA_NO_CLOUD=1`. A localhost address alone does not establish offline inference. [Ollama FAQ](https://docs.ollama.com/faq) |

The screenshot identifies `gpt-transcribe`, which current official documentation confirms. Do not replace it with a guessed GPT-4o identifier. Groq is the speech API provider in the other screenshot; xAI Grok is not requested.

Proposed provider setup:

1. Choose a provider and the stage it serves. A mode selects speech and cleanup independently.
2. Enter a masked API key and select a compatible model, with a model-ID field for an explicitly supported newer model.
3. Test the credentials and selected-model access. Explain if a check only verifies authentication, since listing models is not proof that an audio or cleanup request will succeed. A sample inference test should explicitly describe its small test input and potential provider charge.
4. Save credentials in macOS Keychain and nonsecret model settings in preferences. Keep keys out of logs, history, exports, screenshots, and diagnostic bundles.

The proposed UI should distinguish missing key, unsupported model, denied model access, network failure, and rate limit. Preserve successful raw transcription when cleanup fails. Do not silently change provider or model, retry chargeable operations indefinitely, or upload historical recordings for a connection test. These are Amanuensis behavior recommendations, not provider guarantees.

Cloud transcription sends audio; cloud cleanup sends transcript text. A mode can therefore be local, cloud, or mixed. The Local library filter should only filter catalog rows. A separate Require local processing control should reject cloud stages before recording starts and again before any request. For a user-managed Ollama service, require local model selection and verified local-only configuration before showing a strict offline guarantee.

Generic local cleanup through Ollama is a useful extension. S1-mini is a separate mandatory integration with its own prompt contract and public weights, documented in [S1-mini availability](s1-mini-availability.md). Its inclusion must not depend on the user configuring a cloud API.

Remaining implementation checks are provider-specific file limits, chunking, streaming, cancellation, model access, cleanup output validation, and credential persistence in the signed Mac app. No default cloud cleanup model is chosen in this brief.
