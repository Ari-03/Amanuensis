# MacWhisper research

Research date: 2026-09-19. Scope: first-party product pages and support documentation. No installed-app testing. These findings describe documented capabilities, not measured reliability.

## What is useful for Amanuensis

MacWhisper separates speech recognition from optional AI processing and supports local execution for both, provided the user chooses a local AI provider. Its strongest references for this project are app-specific prompts, explicit model capabilities, editable speaker labels, and replacement rules with whole-word matching.

## Verified behavior

| Area | Documented behavior | Source |
| --- | --- | --- |
| Local transcription | Downloads speech models such as Whisper or Parakeet, then processes audio locally. The privacy documentation includes speaker identification in local processing. | [Keeping transcriptions private](https://docs.macwhisper.com/article/52-keeping-transcriptions-private) |
| Cleanup and privacy | Cloud transcription sends audio to the selected provider. AI prompts send transcript text to an AI provider. Ollama and LM Studio are documented exceptions that can run the AI step locally. Selecting a local speech model alone does not establish that the whole workflow is offline. | [Keeping transcriptions private](https://docs.macwhisper.com/article/52-keeping-transcriptions-private) |
| Model management | The model manager filters by engine and downloads models. WhisperKit requires an M-series Mac. Download and initial preparation are separate steps; first preparation of larger models can take minutes. | [Switching to a WhisperKit model](https://docs.macwhisper.com/article/29-switching-to-a-whisperkit-model) |
| Dictation | A configurable keyboard shortcut transcribes speech directly into a text field. Home starts the guided setup. Custom prompts can clean grammar or change tone. System-wide dictation belongs to the direct-download app, not the Mac App Store edition. | [Dictation guide](https://docs.macwhisper.com/article/14-how-to-use-the-dictation-feature), [Edition differences](https://docs.macwhisper.com/article/40-macwhisper-whisper-transcription-difference) |
| App rules | Users associate running apps with saved dictation prompts. The documented picker requires an app to be running before adding it. The page establishes app matching, not website-domain matching. | [App-specific dictation prompts](https://docs.macwhisper.com/article/31-app-specific-dictation-prompts) |
| Floating recording | A separate Global workflow opens a floating microphone/transcription overlay. It offers auto-start, automatic clipboard copy, and an always-on-top setting. | [Global guide](https://docs.macwhisper.com/article/16-global) |
| Meetings and system audio | The product advertises audio capture from apps and meeting detection. The setup guide requires microphone and screen-recording permissions. Detection can notify the user to start recording; a manual start is also available. Finished recordings appear in history for transcription. | [Product page](https://www.macwhisper.com/), [Meeting recording guide](https://docs.macwhisper.com/article/30-record-meetings) |
| Speaker grouping | The guide documents WhisperKit locally and ElevenLabs/Deepgram remotely. Dictation assumes one speaker and does not support this feature. Users can rename and merge speakers, recolor labels, and reassign transcript segments. These are diarization labels, not verified personal identities. | [Speaker recognition guide](https://docs.macwhisper.com/article/32-automatic-speaker-recognition-in-macwhisper) |
| Replacements | Global rules replace text in future transcriptions. They support case-sensitive matching, whole-word matching, search, editing, deletion, and JSON import/export. Turning off whole-word matching also changes substrings. | [Find and replace](https://docs.macwhisper.com/article/37-find-and-replace-in-transcriptions) |
| History | Meeting recordings appear in app history. The current CLI can explicitly persist a transcript into normal history. These sources do not establish an automatic audio-retention period or separate retention controls for dictation audio and text. | [Meeting recording guide](https://docs.macwhisper.com/article/30-record-meetings), [CLI guide](https://docs.macwhisper.com/article/57-macwhisper-command-line-tool) |

## Gaps and source cautions

- Vocabulary biasing and replacement rules are different mechanisms. I found documentation for replacements, but no primary-source description of a custom-word dictionary passed into the recognition model. That does not prove the app lacks one.
- Retention periods, deletion guarantees, and whether every failed dictation preserves its original audio remain unverified in the reviewed documentation.
- The February 2025 dictation guide contains old provider setup instructions and says more providers are forthcoming. The product page now lists several providers and local AI support. Use the guide for interaction behavior, not a current provider catalog. [Dictation guide](https://docs.macwhisper.com/article/14-how-to-use-the-dictation-feature), [Product page](https://www.macwhisper.com/)
- The July 2025 meeting guide still describes remote attendees as one speaker and says automatic recognition is forthcoming. A separate speaker guide documents that feature as released. Its old wording is not evidence that meetings currently lack diarization. Exact support should be checked against the installed version and selected model. [Meeting guide](https://docs.macwhisper.com/article/30-record-meetings), [Speaker guide](https://docs.macwhisper.com/article/32-automatic-speaker-recognition-in-macwhisper)

## Product lessons, proposed rather than competitor claims

1. Show speech recognition and cleanup as separate model choices. Explain whether audio or text leaves the Mac next to each choice. An offline mode should reject cloud stages rather than silently switch providers.
2. Make model readiness explicit: downloading, preparing, ready, unsupported hardware, or failed. Show speaker-detection support on the model itself.
3. Keep app rules easy to inspect. Display the selected mode while recording so automatic switching has a visible result. Allow manual override.
4. Keep vocabulary hints separate from exact replacements. Default replacement matching to whole words and provide a preview before bulk changes.
5. Treat speaker grouping as editable output. A meeting workflow needs rename, merge, and correction tools if diarization ships.
6. Keep one recoverable history across dictation and meeting sessions. Offer separate retention settings for audio and text, and preserve raw text when optional cleanup fails.
7. Use one recording state model for the main window and floating indicator. Avoid creating separate recording workflows merely because the presentation differs.
