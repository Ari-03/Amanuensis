# Model catalog sources

Checked November 10, 2026; the rows added on November 23 are marked. `Amanuensis/Models/ModelCatalog.json` holds the catalog rows. JSON has no comments, so this note records where its sizes, language lists and detection flags come from.

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
| whisper-large-v3-turbo-8bit (November 23) | mlx-community/whisper-large-v3-turbo-asr-8bit @ `f0fca477e0a885ef4a61088d6cbbc8fc25e53268` | 868,346,887 |
| parakeet-v2 | mlx-community/parakeet-tdt-0.6b-v2 | 2,471,863,880 |
| parakeet-v3 | mlx-community/parakeet-tdt-0.6b-v3 | 2,509,042,622 |
| parakeet-ultra (November 23) | selcukkubur/parakeet-ultra-mlx @ `b554592c50b2a48471add2daa3d46fa9f00fef5e` | 1,254,941,238 |
| cohere-transcribe | beshkenadze/cohere-transcribe-03-2026-mlx-4bit | 1,505,850,601 |
| moonshine-tiny | moonshine-ai/moonshine-tiny @ `390624ed33d594443aa4aa221f5b9f283b545b5a` | 110,383,982 |
| moonshine-base | moonshine-ai/moonshine-base @ `7a73d8d55ac0ba2ef3ae761593f6784b51f96dcf` | 248,074,798 |
| qwen3-asr-0.6b | mlx-community/Qwen3-ASR-0.6B-4bit @ `313d850181767edf09f00a9c289becca70e58cd0` | 712,779,760 |
| qwen3-asr-1.7b (November 23) | mlx-community/Qwen3-ASR-1.7B-8bit @ `a8379a2e2f9e313c9292cdf1af4055ab56d50d55` | 2,467,857,511 |
| nemotron-asr-0.6b | mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit @ `7279359e4481b5e9e185a318bd618e429c6d86cd` | 756,246,469 |
| s1-mini | superwhisper/s1-mini-GGUF | 484,246,654 |

## Language lists

Codes are BCP-47 language subtags.

- **Multilingual Whisper checkpoints.** The language tokens (`<|xx|>`, at most three lowercase letters) in each checkpoint's `tokenizer_config.json` at its pinned revision. This is the table the MLX runtime's `WhisperTokenizer` reads. Each list matches the same checkpoint's `generation_config.json` `lang_to_id`. Tiny, base, small, medium, large (V1) and large-v2 have 99 languages. Large-v3 and large-v3-turbo add Cantonese (`yue`), for 100. Both agree with `LANGUAGES` in [openai/whisper `whisper/tokenizer.py`](https://github.com/openai/whisper/blob/main/whisper/tokenizer.py). Whisper writes Javanese as the retired code `jw`. The catalog stores `jv`, and `LocalSpeechEngine` maps it back.
- **Whisper `.en` checkpoints.** English only. Their tokenizers have no language tokens, and their generation configs say `is_multilingual: false`.
- **Parakeet TDT 0.6B V2.** English, per [NVIDIA's model card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) at `ae9ad07059c7c739ffaf932226a8fe64ae2620b0`.
- **Parakeet TDT 0.6B V3.** The 25 languages in [NVIDIA's model card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) metadata at `541d1f99c6b0c3cd0b11a95167540bb8edefd82b`. The mlx-community conversion repeats the same list. The card says the model "automatically detects the language of the audio".
- **Parakeet Ultra.** The same 25 languages, in [Moondream's card](https://huggingface.co/moondream/parakeet-ultra) metadata at `73175eb7aeb0d82f1e2a6b53b3aabc10a90bcd0b`, which says the languages and tokenizer are V3's. Licence CC BY 4.0 (card metadata, repeated by the conversion's card); it requires crediting Moondream and NVIDIA.
- **Whisper large-v3-turbo 8-bit.** The 100 languages of large-v3-turbo: its `tokenizer_config.json`, `tokenizer.json` and `generation_config.json` are byte-identical to the pinned OpenAI ones. The conversion's card states no licence; the weights are OpenAI's (see below), whose card says MIT.
- **Qwen3-ASR 1.7B.** The same 30 `support_languages` as the 0.6B row. Licence Apache 2.0 (card metadata of the conversion and of `Qwen/Qwen3-ASR-1.7B`).
- **Cohere Transcribe.** The 14 languages in [Cohere's model card](https://huggingface.co/CohereLabs/cohere-transcribe-03-2026) at `d552dadc2922ba6f6c1f994f8db904d52dcaf942`. The card says it "does not feature explicit, automatic language detection". The pinned MLX runtime maps the same 14 codes and silently uses English for any other code.
- **Moonshine Tiny and Base.** English, per the `language` metadata of both cards at the pinned revisions. Licence MIT (card metadata). The runtime takes no language.
- **Qwen3-ASR 0.6B.** The 30 names in the checkpoint's `config.json` `support_languages` (identical in the 4-bit and 8-bit conversions), as codes. Filipino is stored as `tl`, the code the catalog already uses for it. `LocalSpeechFamily` passes the runtime the English name of the code, which matches all 30 names. Licence Apache 2.0 (card metadata).
- **Nemotron 3.5 ASR 0.6B.** The 35 languages in the conversion card's metadata. Its `config.json` prompt table also names regional variants; `LocalSpeechFamily` maps the six card languages that appear there only with a region (ja, zh, vi, he, th, mt) to that entry. An unknown key silently selects the `auto` prompt, so Japanese ran as detection until `ja` was mapped; `LocalSpeechFamily` now keeps the pinned table's keys and a LocalSpeech test checks every catalog language lands on one. Given the English fixture with Japanese or Korean chosen, the model now returns nothing, while `auto` returns the English sentence, which shows the choice reaches the prompt. Licence: the conversion card at the pinned revision names the [NVIDIA Open Model License](https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/), which states "Models are commercially usable." NVIDIA relicensed the upstream `nvidia/nemotron-3.5-asr-streaming-0.6b` repository to OpenMDW-1.1 on June 5, 2026, after that card was written. Both licences permit commercial use.
- **S1-mini (cleanup).** English, per the [S1-mini GGUF card](https://huggingface.co/superwhisper/s1-mini-GGUF) at the pinned revision: "The model covers English only."
- **Apple Speech.** No list in the catalog. The app asks `SpeechTranscriber.supportedLocales` at run time. Assets belong to the app that reserved them: `AssetInventory.maximumReservedLocales` is 5 on the development Mac, and a sixth `assetInstallationRequest` failed with `SFSpeechErrorDomain` code 11, "Too many allocated locales, 5 maximum", until a locale was released with `AssetInventory.release(reservedLocale:)`. On the development Mac (macOS 27.0) that returned 45 locales covering 24 language codes, plus `mul_IN`, which the app leaves out.
- **API rows.** No list. The provider decides. OpenAI's [speech-to-text guide](https://developers.openai.com/api/docs/guides/speech-to-text) says `gpt-transcribe` takes `languages[]` and older models take `language`. [Groq's API reference](https://console.groq.com/docs/speech-to-text) takes an ISO-639-1 `language`. Both detect the language when none is sent.

## Summaries

Each row's `summary` states what the model is, who made it, and whether it is English-only or multilingual, from the publisher's card at the pinned revision, checked November 10, 2026. Nothing in a summary describes accuracy or speed; the Models screen shows only speed measured on this Mac.

- **Whisper.** Parameter counts (tiny 39M, base 74M, small 244M, medium 769M, large, large-v2 and large-v3 1550M, large-v3-turbo 809M) and the English-only `.en` checkpoints come from the checkpoint table in each OpenAI card. The large-v2 card says it was "trained for 2.5x more epochs" than large; the large-v3 card says 1 million hours of weakly labeled and 4 million hours of pseudo-labeled audio; the large-v3-turbo card says decoding layers were "reduced from 32 to 4". Cantonese in large-v3 is the `yue` token listed above.
- **Parakeet.** NVIDIA's cards: "600-million-parameter", English with punctuation and capitalization for V2, and V3 "expanding language support from English to 25 European languages".
- **Moonshine.** The cards' table: tiny 27M and base 61M, English-only.
- **Qwen3-ASR.** The conversion's card names the base model `Qwen/Qwen3-ASR-0.6B`. "0.6B" is the model's name, not a parameter count: the hub's safetensors metadata for that repository (at `5eb144179a02acc5e5ba31e748d22b0cf3e303b0`) reports 938,008,576 parameters. So the summary names the model and states no count.
- **Nemotron.** The conversion's card names the base model `nvidia/nemotron-3.5-asr-streaming-0.6b` and calls it "NVIDIA's 600M-parameter cache-aware streaming" model.

- **November 23 rows.** Moondream's card calls Parakeet Ultra "a post-trained version of parakeet-tdt-0.6b-v3". The 8-bit Whisper's size is compared with the row it stands beside. As with 0.6B, "1.7B" is the model's name: the hub's safetensors metadata for `Qwen/Qwen3-ASR-1.7B` reports 2,349,217,408 parameters.

## Conversions compared with their publishers' weights

November 23, 2026. The three rows added that day are conversions, so each was compared tensor by tensor with the publisher's own file.

- **Parakeet Ultra** (`selcukkubur/parakeet-ultra-mlx`, one person's repository, two commits on September 22, 2026) against `moondream/parakeet-ultra` @ `73175eb7aeb0d82f1e2a6b53b3aabc10a90bcd0b`, SHA-256 `c9608f36d0ab956c14bfcc525479b0746b3b42a56f6949ec85c14eb7466717dc`. All 697 tensors equal the official ones bit for bit once the official F16 and F32 values are rounded to bf16, renamed, and transposed for MLX (two LSTM biases are the sum of the official pair). The pinned loader casts every Parakeet weight to bf16 anyway, so nothing more is lost. The 30 official tensors left out are 24 BatchNorm counters and the 6 of a voice-activity head the runtime does not have. `config.json` is byte-identical to the Parakeet V3 row's, and its 8,192 vocabulary entries equal the official `tokenizer.json`. Moondream's own file cannot ship: it is a Transformers `ParakeetForTDT` export that the pinned loader, and the Parakeet family's configuration check, do not read. The remaining risk of the individual's repository is that it disappears, which would stop new downloads; the pinned revision and SHA-256 rule out changed weights.
- **Whisper large-v3-turbo 8-bit** against `openai/whisper-large-v3-turbo` @ `41f01f3fe87f28c78e2fbf8b568835947dd65ed9`. Quantizing OpenAI's tensors with MLX on the GPU (8 bits, group size 64) gives all 233 quantized tensors bit for bit, with their scales and biases, and the other 353 are equal. The one OpenAI tensor left out is the encoder's sinusoidal position table, which the runtime computes. So the missing licence on the card does not matter: these are OpenAI's MIT weights.
- **Qwen3-ASR 1.7B 8-bit** against `Qwen/Qwen3-ASR-1.7B` @ `7278e1e70fe206f11671096ffdd38061171dd6e5`. All 197 quantized tensors are reproduced bit for bit the same way, and the other 510 are equal. The one left out is the output head, which the text model shares with its embedding.

## Rows added November 23, 2026

Each row was downloaded through `ModelLibrary` into a scratch folder, which passed its checks with exactly the bytes above, and transcribed from that folder by `SpeechSmoke` with network denied. The comparisons used `SpeechStream` on the same Apple M1 with 16 GiB, network denied, in whole-file mode (after Stop) and, where named, live cuts, one process per run. Other builds and simulators were running, so treat times as rough. Every comparison used the same fixtures, but some models ran in separate batches, including the 0.6B and 1.7B 8-bit LibriSpeech runs. Errors are word errors, or character errors for Chinese, Japanese and Korean, after lowercasing and dropping punctuation, against text whose numbers were not normalized. Time is the model's own, per 30 seconds of audio. Peak is the process's memory footprint.

Fixtures: LibriSpeech test-clean, eight speakers, 111 to 126 s of continuous reading each (Whisper: three); the same speakers in four two-person dialogues of about 115 s; FLEURS test, 15 people's sentences per language joined with 0.8 s pauses at one peak level (154 to 264 s; Parakeet en, de, fr, es; Qwen also zh, ja, ko; Whisper en, es, ja); and **synthetic** macOS `say` speech, the same FLEURS text in one voice (96 to 156 s; Parakeet en, de, fr, es; Qwen also zh, ja, ko; Whisper de, ja).

| Model | LibriSpeech | Dialogues | FLEURS | Synthetic long | Time per 30 s | Peak GB |
| --- | --: | --: | --: | --: | --: | --: |
| parakeet-v3 | 4.3% | 5.3% | 6.8% | 3.5% | 0.8 s | 3.88 |
| **parakeet-ultra** | 1.9% | 2.9% | 6.5% | 2.7% | 0.8 s | 1.80 |
| qwen3-asr-0.6b | 2.6% | 4.4% | 10.0% | 7.7% | 2.2 to 2.9 s | 1.68 |
| Qwen3-ASR 1.7B 4-bit (not shipped) | 1.2% | not run | 7.2% | 11.2% | 4.9 to 6.5 s | 2.74 |
| **qwen3-asr-1.7b** (8-bit) | 1.6% | 2.8% | 5.6% | 3.5% | 6.1 to 7.8 s | 3.60 |
| whisper-large-v3-turbo | 2.0% | 4.7% | 29.1% | 2.3% | 7.5 to 9.4 s | 2.96 |
| **whisper-large-v3-turbo-8bit** | 2.0% | 4.7% | 5.9% | 2.3% | 4.1 to 4.8 s | 2.22 |

- **Parakeet Ultra** was at least as accurate as V3 in the total of every group, though V3 was ahead on some clips (LibriSpeech 2094 and 3575, one dialogue, FLEURS French). V3's LibriSpeech total includes one passage lost in speaker 1320, which Ultra kept; live cuts kept it in both (1.2% each). On the FLEURS clips at their original levels, which differ by up to 50 dB between sentences, Ukrainian was 4.9% against 5.9% and Latvian 20.8% against 27.4%. Peak memory is 2.1 GB lower, probably because V3's F32 file is read in full before the cast to bf16. With no language, the synthetic German, French, Spanish, Italian, Russian and Polish clips and the FLEURS Ukrainian and Latvian ones came back in their language.
- **Qwen3-ASR 1.7B** was more accurate than 0.6B in every group and every FLEURS language, most in Japanese (5.0% against 14.0%), but takes about 2.8 times as long and twice the memory. With no language it returned English, German, French, Spanish, Italian, Russian, Polish, Chinese, Japanese, Korean, Hindi and Cantonese synthetic clips in their language; Cantonese came back in simplified characters, which the 35.6% error measured for both sizes mostly counts.
- **Whisper large-v3-turbo 8-bit** gave the same text as the full-precision row on 29 of 35 clip runs, in fourteen languages with the language given. The FLEURS gap is one Spanish segment where the full-precision row repeated a phrase until its token limit and the 8-bit row did not; at the clips' original levels both repeated it. Like every Whisper row it does not detect, and `SpeechSmoke` with `auto` refuses to run it.
- **Live cuts** (fed at full speed): every run's text equalled the file pass with the same cuts, for all three rows and their neighbours.

Joining quiet and loud clips is a limit of every model here, not only the new ones. With FLEURS English at its original levels (-14 to -64 dBFS) Whisper turbo in both forms and Qwen3-ASR 1.7B dropped whole quiet sentences beside loud ones, 1.7B more than 0.6B (14.7% against 5.1%, and 36.9% against 6.5% with live cuts). Raised to one level the same sentences came back (6.1% against 6.5%, live 4.8% against 6.5%), and alone, at their original level, 1.7B was as accurate as 0.6B or better on 28 of 30 English and Korean sentences. `SpeechSegmenter` does not send a whole segment to any model unless some 20 ms frame in it rises above -60 dBFS RMS; a quieter sentence still reaches the model when it shares a segment with louder speech.

## Detection

`detectsLanguage` is true only for Parakeet V3 and Ultra, Qwen3-ASR, Nemotron 3.5 ASR and the API transcription rows. The OpenAI-compatible row leaves detection to the server, like the other API rows.

Measured on November 10, 2026 with `BuildSupport/SpeechSmoke` and network denied, after downloading each model through `ModelLibrary`. Qwen3-ASR with no language returned the source sentence for Chinese, Japanese, French and English fixtures. Nemotron with no language (its `auto` prompt) did the same for English, French, German, Japanese and Spanish. Moonshine checkpoints are English only. `LocalSpeechEngine` now refuses to run a family that cannot detect without a language, and a LocalSpeech test checks that no catalog row claims detection its family lacks. Parakeet V3, Parakeet Ultra and Qwen3-ASR 1.7B detection was measured on November 23; see the section above.

The pinned `mlx-audio-swift` (`01dec7c`) README says that omitting the language lets Whisper auto-detect. Its code only drops the language token from the decoder prompt; it does not run Whisper's detection step. On November 10, 2026, Whisper Tiny with no language turned a 4-second synthesized French sentence into a line of dots, and the English fixture into "k". German, Spanish and Japanese clips came out close to their sources. Because of that, no Whisper row claims detection. Parakeet ignores the language parameter, and Apple Speech has no detection mode.

## Families tried and not added

- **Canary 1B V2** (`Mediform/canary-1b-v2-mlx-q8`, CC BY 4.0). It transcribed short clips well, but not full windows. On dense speech it silently dropped a whole sentence inside a 30-second window: German (62 s fixture, one 13-word sentence lost) and Spanish (47 s, "los representantes de los trabajadores exigieron" lost). Raising its 200-token limit to 1000 changed nothing; a limit of 20 truncated, which shows the setting reached the runtime, so the token cap was not the cause. The same audio in 25-second windows came out whole, but 20-second windows produced repetition loops in Spanish ("de la empresa de la empresa…") and a repeated sentence in French. Because whether a window loses or invents speech depends on where its boundaries fall, it was removed. It also translates when the spoken language differs from the chosen one: French audio with English chosen came back in English.
- **Qwen3-ASR 1.7B 4-bit** (`mlx-community/Qwen3-ASR-1.7B-4bit` @ `78a389c776a5483b2d0d4ea5494e11012e0d6159`, 1.61 GB, Apache 2.0). Tried on November 23 as the smaller form of the 1.7B row, which is 8-bit because of it. With no language it turned four sentences of one synthetic Korean voice into English (42.3% character error against 1.8% for 8-bit and 7.5% for 0.6B), and on FLEURS Korean at its original levels it invented an English sentence and repeated it to the token limit (681% against 2.6% for 8-bit and 5.8% for 0.6B). It was also worse than 8-bit on the FLEURS clips in every language, though slightly better on LibriSpeech (1.2% against 1.6%).
- **SenseVoice Small** (`mlx-community/SenseVoiceSmall`). Its FunASR licence says the model "is provided for reference and learning purposes only".
- **Voxtral Realtime, Granite Speech, GLM-ASR, FireRedASR2, LasrCTC, MossTranscribeDiarize, Wav2Vec2.** Not tried in this batch.

## Generation limits

`LocalSpeechEngine` reads audio in 30-second windows. Each window may generate the runtime's default number of tokens, capped at 1024, unless the family entry sets `maxTokens`. Moonshine's runtime default is 200. A 30-second window of the number-heavy English fixture read at 380 words a minute lost "asked for a detailed risk assessment by the" at 200 and came out whole at 400, so Moonshine uses 400. At 180 and 280 words a minute the output was the same at 200 and 1000.
