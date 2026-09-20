# Amanuensis product brief

Captured from Aritra's two walkthroughs and fourteen Superwhisper/Spokenly screenshots on September 19, 2026. Aritra confirmed this pass should cover the product brief and research before any SwiftUI implementation. The app currently contains the default starter screen; this document describes intended behavior, not implemented features.

The later [implementation plan](implementation-plan.md) consolidates the proposed architecture, appearance, defaults, milestones, and acceptance gates. This brief remains the record of requested behavior; plan recommendations do not become completed features.

## Product direction

A native macOS dictation app that lets Aritra run compatible local models without an Amanuensis subscription, trial quota, or account requirement. Downloaded models must remain usable offline. A publisher's initial download access requirements are separate from runtime access and must be shown before acquisition. Supporting imported models means supporting their specific runtime and file format, not accepting every model file indiscriminately.

The first version operates in English. Do not add a language selector. Speech recognition turns audio into text. An optional language model cleans up that text according to the selected mode. These are separate model selections. Local operation is central, with optional bring-your-own-key APIs for transcription and cleanup.

Superwhisper is the initial interaction reference. Keep the clean sidebar and grouped controls, while making common actions direct. Research other apps before deciding the remaining interactions.

## Home

| Element | Requested behavior |
| --- | --- |
| Statistics | Show words per minute, total words, and time spent using the app. Omit apps used and estimated time saved. |
| Recording | Explain how to start recording and display the current toggle-recording shortcut. |
| Shortcut editing | Clicking the displayed shortcut enters shortcut capture. The same setting appears in Configuration and stays synchronized. |
| Modes | Provide a direct action to create a mode. |
| Vocabulary | Provide a direct action to add vocabulary. |

The reference has an All time filter. Whether Amanuensis needs other reporting periods remains open. Proposed metric definitions are total dictated words divided by total recording minutes for WPM, and cumulative recording duration for time spent. The latter needs confirmation because time with the app open is a different measure. Start with real empty states, not sample usage figures.

The phrase transcribed as "free to mode and active vocabulary" is interpreted as the screenshot's Create a mode and Add vocabulary actions.

## Modes

Provide Voice to text, Message, Mail, Notes, Meeting, and Custom presets. Let the user create, edit, select, and delete modes. The reference includes a tone control from casual to formal; include it in the proposed editor, pending the rest of the mode instructions.

| Setting | Requested behavior |
| --- | --- |
| Preset | Choose the purpose of the mode. |
| Speech model | Select the model that transcribes audio. |
| Cleanup model | Select an optional language model that formats the transcript for this mode. |
| Activate for apps | Associate applications with a mode so email and messaging can use different output styles automatically. |
| Mode shortcut | The reference supports starting a recording directly in a particular mode. Retain as a proposed feature. |
| Playback during recording | Offer keep playing, pause, lower volume, and mute where the implementation can support them. |
| System audio | Allow meeting capture to include computer audio. |
| Identify speakers | Desired if practical. Feasibility and model requirements remain open. |
| Capitalize on insertion | Optionally capitalize the beginning of inserted text. |
| Auto-paste | Control whether completed text is inserted into the destination. |
| Delete | Delete the mode. The screenshot's Delete this mode is separate from recording retention. |

The reference also matches websites. Application matching is explicitly requested; website matching is a possible extension that needs a separate feasibility decision.

Proposed behavior: choose the automatic mode from the destination app when recording starts and keep that choice for the recording. A direct mode shortcut takes precedence. Resolve multiple matching modes predictably and expose the chosen mode in the recording UI. Preserve meaning during cleanup; a cleanup error must leave the original transcript available.

## Vocabulary and replacements

Support two distinct entry types in the same section:

- Vocabulary words help the speech model recognize names, technical terms, and unusual spellings where the selected model supports hints.
- Replacements map a recognized word or phrase to the user's preferred output. For example, "super whisper" becomes "Superwhisper".

Allow adding, editing, and deleting entries. Vocabulary is a recognition hint, not a promise that a model will always recognize the word. Replacement matching needs explicit case and word-boundary rules. Do not silently replace a substring inside an unrelated word.

The walkthrough says TTS, but the intended operation here is speech-to-text. Text-to-speech is outside the stated scope.

## Configuration and recording indicator

| Group | Requested controls |
| --- | --- |
| Appearance | System, light, and dark themes are shown in the reference. |
| Recording window | Classic, mini, hidden, and a notch-style indicator; an always-show preference. |
| Shortcuts | Toggle recording, cancel recording, change mode, and push-to-talk. |
| Push-to-talk | Record while the shortcut is held; finish when released. |
| Mouse shortcut | Shown in the reference as tap to toggle or hold to record; proposed pending prioritization. |
| Updates | Check for updates and automatically check for updates. Whether updates also install automatically needs definition. |
| Startup | Launch on login. |
| Diagnostics | Error logging preference. |
| Retention | Choose how long recordings are retained. |
| Advanced | Additional application, model, storage, and text-insertion controls. |

The recording indicator should visibly distinguish listening from transcription and cleanup. Aritra wants a Dynamic Island-like presentation around the MacBook notch. Research identifies a custom AppKit overlay as the proposed implementation, with a floating fallback for displays without a notch. Hardware behavior still needs testing. [macOS feasibility](research/macos-feasibility.md)

Use visual preview tiles when choosing recording appearance, following Spokenly's Panel and Notch examples. The phrase about an image at launch is interpreted as appreciation for these appearance previews; a separate launch illustration has not been specified.

Provide a compact recording toolbar that can switch modes and start or stop recording without opening the main window. Show the current shortcut in the start-recording tooltip. The screenshot's expand icon has an unknown purpose; a larger recorder showing transcript/status is a proposal, not a confirmed behavior. Mode changes while idle take effect immediately. Proposed behavior during a recording is to keep its current mode fixed and apply a newly selected mode to the next recording, with clear feedback.

The advanced-settings screenshot contains Dock visibility, recording on menu-bar click, close behavior, model warm duration, storage-folder location, clipboard preservation/history, paste-result preference, optional auto-send, and simulated keypress insertion. These are references for the next design pass, not blanket approval to implement every toggle. Agent integrations shown in the screenshot were not requested.

## Models library

Provide a searchable library with provider and execution-location filters, and distinguish speech models from cleanup models. Aritra explicitly wants a Local filter like Spokenly's highlighted filter buttons. Show download size, installed state, and whether the model runs on this Mac or through an API. Let users download, import compatible existing files, select, and remove local models. Model removal must explain which modes depend on it.

| Purpose | Required model or provider | Execution |
| --- | --- | --- |
| Speech recognition | All official Whisper model variants, including English variants where available | Local |
| Speech recognition | NVIDIA Parakeet | Local |
| Speech recognition | Cohere Transcribe | Local; this is explicitly required, not satisfied by a hosted Cohere integration |
| Speech recognition | Apple's speech recognition | On-device where supported, with OS-managed asset readiness shown |
| Speech recognition | OpenAI transcription models, including GPT-Transcribe | API using the user's key |
| Speech recognition | Groq-hosted transcription models | API using the user's key |
| Cleanup | S1-mini by Superwhisper | Local; must-have, not an optional substitute for another model |
| Cleanup | OpenAI text models | API using the user's key |
| Cleanup | Claude from Anthropic | API using the user's key; Aritra confirmed this provider explicitly |
| Cleanup | Additional local language models, potentially Llama through Ollama | Desired extension; exact runtime and models remain open |

"All Whisper models" means the official released family, not every community fine-tune or quantization. Keep individual versions and formats explicit in the catalog. Exact Parakeet variants, quantizations, download manifests, and minimum hardware still need selection. The requested S1-mini and Cohere local releases have public-source research in [S1-mini availability](research/s1-mini-availability.md) and [offline models](research/requested-offline-models.md).

S1-mini has official standalone GGUF weights and documented third-party integration. Preserve its required attribution as S1-mini by Superwhisper. Its supported tone/format controls are narrower than a general-purpose language model; custom prompts or meeting summaries must not be advertised as S1-mini capabilities. Cohere's official repository currently requires a download-access step, and independently published Mac conversions differ from the screenshot's packaged file. These are acquisition and integration details, not reasons to add a recurring local-use gate.

The model-list screenshot's speed/accuracy bars are a visual reference only. Do not invent comparable scores across models or repeat provider benchmarks as measured Amanuensis performance. Optional favorites can simplify a large catalog.

For APIs, use a provider configuration with a masked key field, model picker or explicit model ID, and Test and Save. Keep credentials in macOS Keychain, separate from preferences, history, logs, and exports. Tests must say what they validate and show actual errors for invalid credentials, unavailable models, connectivity, or provider limits. Do not upload a user's saved recording merely to test a connection. Local models need no API key, and users can skip API setup entirely.

OpenAI and Groq are the requested cloud speech providers. Groq is distinct from xAI's Grok. The other providers visible in Spokenly's screenshot are not automatically in scope. OpenAI and Claude are the confirmed cloud cleanup providers. The phrase "skip the API key" is interpreted as supplying a key for API use while allowing local-only setup to skip that step.

A Local library filter changes the list, not the execution of an already configured mode. Proposed additional control: Require local processing prevents both audio uploads and cloud cleanup, with no automatic cloud fallback. Setup downloads may still need internet. Label local speech plus API cleanup as mixed processing. Ollama must use a verified local model rather than treating any localhost endpoint as proof that inference stays on the Mac.

## Sound and microphone selection

Scan available audio input devices and show a persistent priority list with drag-to-reorder controls. Let the user explicitly exclude devices such as AirPods microphones while continuing to use the headphones for output. Lower priority alone is insufficient because an unwanted microphone could otherwise become the only available input.

At recording start, choose the highest-priority connected, enabled, usable microphone. Display the selected input and distinguish unavailable devices from excluded ones. Refresh when devices connect or disconnect, and offer a manual rescan. Save identity using persistent device identifiers rather than names or temporary enumeration order.

Proposed behavior: preserve the user's ranking when a device disconnects and returns. A newly connected higher-priority device should affect the next recording, without interrupting the current one. If the current microphone disappears mid-recording, preserve audio already captured and show an interruption; transparent continuation on another device needs a separate tested design. If every available input is excluded, explain why recording cannot start instead of silently using one.

Sound effects and trackpad feedback appear in Spokenly's screenshot and remain optional design references. Playback pause/lower/mute behavior is already requested in mode settings. [Apple speech and microphone research](research/apple-speech-and-microphones.md)

## History

Keep a local history so the user can revisit transcriptions. Follow the reference's searchable list, grouped by date, with transcript previews and a detail view. Preserve the raw transcription and, when used, the cleaned result so the user can inspect changes and copy either version.

Proposed entry details include timestamp, recording duration, mode, speech model, cleanup model, processing location, and completion/error status. Audio playback and retry are available only while the audio still exists under the recording-retention setting. Text history and audio retention are separate controls; deleting audio must not silently remove a retained transcript. Explicitly deleted transcripts must not survive in search indexes or other app-managed history copies.

Empty recordings and recognition failures should appear as statuses rather than fabricated transcript text. Model-specific valid empty cleanup output, such as removal of filler-only speech, needs separate handling from an error. Preserve the raw result in either case. Do not automatically send old history to a cloud model.

## Remaining product decisions

The requested sections are now covered. Before implementation, resolve the minimum Mac hardware and OS, exact model packages, default speech/cleanup choices, recording and transcript retention defaults, the meaning of Home's time-spent statistic, and the expanded recorder's purpose. The current priority is to prove the requested local models can run independently, then validate microphone selection and reliable insertion.

## Proposed implementation sequence

1. Validate a compatible local speech model and the required S1-mini cleanup outside Superwhisper, then check the Cohere/Parakeet runtime choices. Measure startup, memory, and offline behavior before committing to defaults.
2. Build native navigation and persistent Home, Modes, Vocabulary, Configuration, Sound, Models library, and History settings. Use zero-state statistics and clearly identify unfinished capabilities.
3. Complete dictation with microphone priorities, global shortcuts, local transcription and cleanup, the compact recording controls, and insertion or copy fallback.
4. Add the remaining requested model adapters, API configuration, deterministic replacements, per-app mode selection, and history/retention behavior.
5. Extend meeting capture, speaker labels, notch presentation, and distribution/update support after their technical checks.

This sequence is a recommendation, not a reduction of the requested feature set or authorization to start implementation in this research pass. Required model families are now specified; exact runtime packages and the minimum supported macOS version remain undecided. The starter Xcode project currently targets macOS 27.0 and enables App Sandbox.

## Checks for the eventual implementation

- An installed compatible local speech model works offline with no trial meter or paid entitlement check.
- The requested Whisper family, Parakeet, Cohere Transcribe, Apple recognition, and S1-mini each have a tested integration or an explicit unresolved compatibility issue. A cloud replacement does not satisfy a requested local integration.
- S1-mini cleanup works from independently obtained public weights without a Superwhisper installation or subscription.
- A Local filter shows local models; the separate proposed Require local processing setting prevents cloud speech and cleanup calls.
- OpenAI and Groq transcription and OpenAI/Claude cleanup accept the user's provider credentials and chosen supported model. Invalid credentials and unavailable models produce useful errors.
- Excluded microphones are never automatically selected. Rankings survive device removal, reconnection, and relaunch, and the active microphone is visible.
- Updating the recording shortcut on Home immediately updates Configuration, and vice versa. Conflicting shortcuts produce a useful error.
- A recording can be started, stopped, or canceled without opening the main window. Push-to-talk responds to release and ignores repeated key-down events.
- Modes keep their own model and formatting preferences. Switching apps during processing does not paste into an unintended destination.
- Vocabulary words and replacement pairs survive relaunch. Replacements do not cascade unpredictably or damage unrelated words.
- Failed cleanup does not destroy the original transcript. Failed insertion leaves an explicit copy action.
- Recording indication accurately reflects microphone and processing state, including permission failures.
- Deleting a mode and deleting recordings are separate actions. Audio and transcript retention are defined separately before implementation.
- WPM, word totals, and recorded duration derive from actual completed recordings with a documented counting rule.
- History survives relaunch, supports search and copy, and honors separate audio/text retention settings.
- Compact controls allow recording and mode selection without the main window. An expand action ships only with a defined purpose.

## Research notes

Parallel research covers Handy and VoiceInk, MacWhisper, Wispr Flow and Willow, Spokenly references, macOS integration, local speech/cleanup runtimes, the requested offline releases, and API providers. Findings are saved under `docs/research/`. Recommendations in those notes remain proposals until incorporated into this brief. Supplied screenshots are interaction references; credentials and unrelated transcript contents are not copied into these documents.
