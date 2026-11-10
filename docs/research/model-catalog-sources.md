# Model catalog sources

Checked November 10, 2026. `Amanuensis/Models/ModelCatalog.json` holds the catalog rows. JSON has no comments, so this note records where its sizes, language lists and detection flags come from.

## Download sizes

`byteCount` is the sum of the files the app downloads for the pinned revision. The files are the ones `ModelFiles.selectedFiles` in `Amanuensis/Models/ModelLibrary.swift` keeps, and the sizes are the `siblings[].size` values from `https://huggingface.co/api/models/<repository>/revision/<revision>?blobs=true`. Every response's `sha` matched the pinned revision.

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
| s1-mini | superwhisper/s1-mini-GGUF | 484,246,654 |

## Language lists

Codes are BCP-47 language subtags.

- **Multilingual Whisper checkpoints.** The language tokens (`<|xx|>`, at most three lowercase letters) in each checkpoint's `tokenizer_config.json` at its pinned revision. This is the table the MLX runtime's `WhisperTokenizer` reads. Each list matches the same checkpoint's `generation_config.json` `lang_to_id`. Tiny, base, small, medium, large (V1) and large-v2 have 99 languages. Large-v3 and large-v3-turbo add Cantonese (`yue`), for 100. Both agree with `LANGUAGES` in [openai/whisper `whisper/tokenizer.py`](https://github.com/openai/whisper/blob/main/whisper/tokenizer.py). Whisper writes Javanese as the retired code `jw`. The catalog stores `jv`, and `LocalSpeechEngine` maps it back.
- **Whisper `.en` checkpoints.** English only. Their tokenizers have no language tokens, and their generation configs say `is_multilingual: false`.
- **Parakeet TDT 0.6B V2.** English, per [NVIDIA's model card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) at `ae9ad07059c7c739ffaf932226a8fe64ae2620b0`.
- **Parakeet TDT 0.6B V3.** The 25 languages in [NVIDIA's model card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) metadata at `541d1f99c6b0c3cd0b11a95167540bb8edefd82b`. The mlx-community conversion repeats the same list. The card says the model "automatically detects the language of the audio".
- **Cohere Transcribe.** The 14 languages in [Cohere's model card](https://huggingface.co/CohereLabs/cohere-transcribe-03-2026) at `d552dadc2922ba6f6c1f994f8db904d52dcaf942`. The card says it "does not feature explicit, automatic language detection". The pinned MLX runtime maps the same 14 codes and silently uses English for any other code.
- **S1-mini (cleanup).** English, per the [S1-mini GGUF card](https://huggingface.co/superwhisper/s1-mini-GGUF) at the pinned revision: "The model covers English only."
- **Apple Speech.** No list in the catalog. The app asks `SpeechTranscriber.supportedLocales` at run time. Assets belong to the app that reserved them: `AssetInventory.maximumReservedLocales` is 5 on the development Mac, and a sixth `assetInstallationRequest` failed with `SFSpeechErrorDomain` code 11, "Too many allocated locales, 5 maximum", until a locale was released with `AssetInventory.release(reservedLocale:)`. On the development Mac (macOS 27.0) that returned 45 locales covering 24 language codes, plus `mul_IN`, which the app leaves out.
- **API rows.** No list. The provider decides. OpenAI's [speech-to-text guide](https://developers.openai.com/api/docs/guides/speech-to-text) says `gpt-transcribe` takes `languages[]` and older models take `language`. [Groq's API reference](https://console.groq.com/docs/speech-to-text) takes an ISO-639-1 `language`. Both detect the language when none is sent.

## Detection

`detectsLanguage` is true only for Parakeet V3 and the two API transcription rows.

The pinned `mlx-audio-swift` (`01dec7c`) README says that omitting the language lets Whisper auto-detect. Its code only drops the language token from the decoder prompt; it does not run Whisper's detection step. On November 10, 2026, Whisper Tiny with no language turned a 4-second synthesized French sentence into a line of dots, and the English fixture into "k". German, Spanish and Japanese clips came out close to their sources. Because of that, no Whisper row claims detection. Parakeet ignores the language parameter, and Apple Speech has no detection mode.
