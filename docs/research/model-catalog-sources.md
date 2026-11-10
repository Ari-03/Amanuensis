# Model catalog sources

Checked November 10, 2026. `Amanuensis/Models/ModelCatalog.json` holds the catalog rows. JSON has no comments, so this note records where its sizes, language lists and detection flags come from.

## Download sizes

`byteCount` is the sum of the files the app downloads for the pinned revision. The files are the ones `ModelFiles.selectedFiles` in `Amanuensis/Models/ModelLibrary.swift` keeps (`LocalSpeechFamily.isModelFile` plus licence and README files), and the sizes are the `siblings[].size` values from `https://huggingface.co/api/models/<repository>/revision/<revision>?blobs=true`. Every response's `sha` matched the pinned revision.

| Row | Repository | Bytes |
| --- | --- | ---: |
| whisper-tiny | openai/whisper-tiny | 155,454,211 |
| whisper-tiny.en | openai/whisper-tiny.en | 155,013,603 |
| whisper-base | openai/whisper-base | 294,796,559 |
| whisper-base.en | openai/whisper-base.en | 294,355,250 |
| whisper-small | openai/whisper-small | 971,388,090 |
| whisper-small.en | openai/whisper-small.en | 970,945,764 |
| whisper-medium | openai/whisper-medium | 3,059,936,879 |
| whisper-medium.en | openai/whisper-medium.en | 3,059,494,025 |
| whisper-large-v1 | openai/whisper-large | 6,177,763,607 |
| whisper-large-v2 | openai/whisper-large-v2 | 6,177,762,453 |
| whisper-large-v3 | openai/whisper-large-v3 | 3,091,541,593 |
| whisper-large-v3-turbo | openai/whisper-large-v3-turbo | 1,622,464,535 |
| parakeet-v2 | mlx-community/parakeet-tdt-0.6b-v2 | 2,471,863,880 |
| parakeet-v3 | mlx-community/parakeet-tdt-0.6b-v3 | 2,509,042,622 |
| cohere-transcribe | beshkenadze/cohere-transcribe-03-2026-mlx-4bit | 1,505,850,601 |
| moonshine-tiny | moonshine-ai/moonshine-tiny @ `390624ed33d594443aa4aa221f5b9f283b545b5a` | 110,383,982 |
| moonshine-base | moonshine-ai/moonshine-base @ `7a73d8d55ac0ba2ef3ae761593f6784b51f96dcf` | 248,074,798 |
| qwen3-asr-0.6b | mlx-community/Qwen3-ASR-0.6B-4bit @ `313d850181767edf09f00a9c289becca70e58cd0` | 712,779,760 |
| nemotron-asr-0.6b | mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit @ `7279359e4481b5e9e185a318bd618e429c6d86cd` | 756,246,469 |
| s1-mini | superwhisper/s1-mini-GGUF | 484,246,654 |

## Language lists

Codes are BCP-47 language subtags.

- **Multilingual Whisper checkpoints.** The language tokens (`<|xx|>`, at most three lowercase letters) in each checkpoint's `tokenizer_config.json` at its pinned revision. This is the table the MLX runtime's `WhisperTokenizer` reads. Each list matches the same checkpoint's `generation_config.json` `lang_to_id`. Tiny, base, small, medium, large (V1) and large-v2 have 99 languages. Large-v3 and large-v3-turbo add Cantonese (`yue`), for 100. Both agree with `LANGUAGES` in [openai/whisper `whisper/tokenizer.py`](https://github.com/openai/whisper/blob/main/whisper/tokenizer.py). Whisper writes Javanese as the retired code `jw`. The catalog stores `jv`, and `LocalSpeechEngine` maps it back.
- **Whisper `.en` checkpoints.** English only. Their tokenizers have no language tokens, and their generation configs say `is_multilingual: false`.
- **Parakeet TDT 0.6B V2.** English, per [NVIDIA's model card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) at `ae9ad07059c7c739ffaf932226a8fe64ae2620b0`.
- **Parakeet TDT 0.6B V3.** The 25 languages in [NVIDIA's model card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) metadata at `541d1f99c6b0c3cd0b11a95167540bb8edefd82b`. The mlx-community conversion repeats the same list. The card says the model "automatically detects the language of the audio".
- **Cohere Transcribe.** The 14 languages in [Cohere's model card](https://huggingface.co/CohereLabs/cohere-transcribe-03-2026) at `d552dadc2922ba6f6c1f994f8db904d52dcaf942`. The card says it "does not feature explicit, automatic language detection". The pinned MLX runtime maps the same 14 codes and silently uses English for any other code.
- **Moonshine Tiny and Base.** English, per the `language` metadata of both cards at the pinned revisions. Licence MIT (card metadata). The runtime takes no language.
- **Qwen3-ASR 0.6B.** The 30 names in the checkpoint's `config.json` `support_languages` (identical in the 4-bit and 8-bit conversions), as codes. Filipino is stored as `tl`, the code the catalog already uses for it. `LocalSpeechFamily` passes the runtime the English name of the code, which matches all 30 names. Licence Apache 2.0 (card metadata).
- **Nemotron 3.5 ASR 0.6B.** The 35 languages in the conversion card's metadata. Its `config.json` prompt table also names regional variants; `LocalSpeechFamily` maps the six card languages that appear there only with a region (ja, zh, vi, he, th, mt) to that entry. An unknown key silently selects the `auto` prompt, so Japanese ran as detection until `ja` was mapped; `LocalSpeechFamily` now keeps the pinned table's keys and a LocalSpeech test checks every catalog language lands on one. Given the English fixture with Japanese or Korean chosen, the model now returns nothing, while `auto` returns the English sentence, which shows the choice reaches the prompt. Licence: the conversion card at the pinned revision names the [NVIDIA Open Model License](https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/), which states "Models are commercially usable." NVIDIA relicensed the upstream `nvidia/nemotron-3.5-asr-streaming-0.6b` repository to OpenMDW-1.1 on June 5, 2026, after that card was written. Both licences permit commercial use.
- **S1-mini (cleanup).** English, per the [S1-mini GGUF card](https://huggingface.co/superwhisper/s1-mini-GGUF) at the pinned revision: "The model covers English only."
- **Apple Speech.** No list in the catalog. The app asks `SpeechTranscriber.supportedLocales` at run time. Assets belong to the app that reserved them: `AssetInventory.maximumReservedLocales` is 5 on the development Mac, and a sixth `assetInstallationRequest` failed with `SFSpeechErrorDomain` code 11, "Too many allocated locales, 5 maximum", until a locale was released with `AssetInventory.release(reservedLocale:)`. On the development Mac (macOS 27.0) that returned 45 locales covering 24 language codes, plus `mul_IN`, which the app leaves out.
- **API rows.** No list. The provider decides. OpenAI's [speech-to-text guide](https://developers.openai.com/api/docs/guides/speech-to-text) says `gpt-transcribe` takes `languages[]` and older models take `language`. [Groq's API reference](https://console.groq.com/docs/speech-to-text) takes an ISO-639-1 `language`. Both detect the language when none is sent.

## Detection

`detectsLanguage` is true only for Parakeet V3, Qwen3-ASR, Nemotron 3.5 ASR and the API transcription rows. The OpenAI-compatible row leaves detection to the server, like the other API rows.

Measured on November 10, 2026 with `BuildSupport/SpeechSmoke` and network denied, after downloading each model through `ModelLibrary`. Qwen3-ASR with no language returned the source sentence for Chinese, Japanese, French and English fixtures. Nemotron with no language (its `auto` prompt) did the same for English, French, German, Japanese and Spanish. Moonshine checkpoints are English only. `LocalSpeechEngine` now refuses to run a family that cannot detect without a language, and a LocalSpeech test checks that no catalog row claims detection its family lacks.

The pinned `mlx-audio-swift` (`01dec7c`) README says that omitting the language lets Whisper auto-detect. Its code only drops the language token from the decoder prompt; it does not run Whisper's detection step. On November 10, 2026, Whisper Tiny with no language turned a 4-second synthesized French sentence into a line of dots, and the English fixture into "k". German, Spanish and Japanese clips came out close to their sources. Because of that, no Whisper row claims detection. Parakeet ignores the language parameter, and Apple Speech has no detection mode.

## Families tried and not added

- **Canary 1B V2** (`Mediform/canary-1b-v2-mlx-q8`, CC BY 4.0). It transcribed short clips well, but not full windows. On dense speech it silently dropped a whole sentence inside a 30-second window: German (62 s fixture, one 13-word sentence lost) and Spanish (47 s, "los representantes de los trabajadores exigieron" lost). Raising its 200-token limit to 1000 changed nothing; a limit of 20 truncated, which shows the setting reached the runtime, so the token cap was not the cause. The same audio in 25-second windows came out whole, but 20-second windows produced repetition loops in Spanish ("de la empresa de la empresa…") and a repeated sentence in French. Because whether a window loses or invents speech depends on where its boundaries fall, it was removed. It also translates when the spoken language differs from the chosen one: French audio with English chosen came back in English.
- **SenseVoice Small** (`mlx-community/SenseVoiceSmall`). Its FunASR licence says the model "is provided for reference and learning purposes only".
- **Voxtral Realtime, Granite Speech, GLM-ASR, FireRedASR2, LasrCTC, MossTranscribeDiarize, Wav2Vec2.** Not tried in this batch.

## Generation limits

`LocalSpeechEngine` reads audio in 30-second windows. Each window may generate the runtime's default number of tokens, capped at 1024, unless the family entry sets `maxTokens`. Moonshine's runtime default is 200. A 30-second window of the number-heavy English fixture read at 380 words a minute lost "asked for a detailed risk assessment by the" at 200 and came out whole at 400, so Moonshine uses 400. At 180 and 280 words a minute the output was the same at 200 and 1000.
