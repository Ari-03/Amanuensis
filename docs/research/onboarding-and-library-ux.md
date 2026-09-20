# Onboarding and model library

Researched September 19, 2026. These are proposed interactions for the [product brief](../product-brief.md), not implemented behavior. The aim is a successful first dictation with a clear explanation of which models run where.

## First launch, screen by screen

1. **Choose processing.** Open with "Dictate on your Mac" and a short microphone-to-text illustration. Offer "Set up local dictation" as the primary action and "Use my API keys" as a secondary route. No account, trial meter, or subscription step. Both routes lead to the same app. Save progress so closing setup does not restart it.
2. **Prepare a speech model.** Present one recommended local choice only after hardware and runtime validation establish a default. Show its actual download size, free-space requirement, and "Runs on this Mac." Keep "Browse all models" and "Import a compatible model" visible. Apple recognition can be offered when supported, but availability and installed assets must be checked first. Its files are system-managed, shared across apps, and may require installation. Do not show a fictitious removable download. [Apple asset management](https://developer.apple.com/documentation/speech/assetinventory)
3. **Add cleanup.** Offer S1-mini by Superwhisper, describing filler removal and formatting, with its separate download size. Also offer "Keep the raw transcript." Choosing raw transcription completes setup without losing access to S1-mini later. Show a static example explicitly labeled "Example" rather than an apparent live result. The actual model has four styling values, prose/list structure, and general/email context. It does not follow arbitrary prompts. [Author model contract](https://huggingface.co/superwhisper/s1-mini)
4. **Check the microphone.** Explain why access is needed, then request it from an "Enable microphone" action. After permission, show the selected input and a live level meter. "Choose microphones" opens ranking and exclusions. Never start recording on permission approval. A denial leaves instructions and a retry route; the library remains usable.
5. **Choose a shortcut and try it.** Capture a shortcut inline with conflict feedback. Hold-to-talk is optional here. A large practice field accepts a first recording and shows Listening, Transcribing, Cleaning up, and Done as actual stages. Retain the raw result. Request Accessibility when the user tries insertion into another app, with copy as a usable alternative. System-audio permission belongs to first meeting capture.
6. **Arrive at Home.** Show the real test result, zero or real statistics, current mode, processing location, microphone, and editable shortcut. Provide "Create a mode" and "Add vocabulary." Dismissed setup remains resumable from a small readiness notice, not a full-screen obstacle.

Downloads may continue while the user configures shortcuts. Recording stays unavailable until microphone access and a compatible speech model are ready. Optional cleanup failure can offer raw transcription explicitly.

## Model library

Use a compact native table with Speech and Cleanup tabs. Above it, place search and All, Installed, Local, and API filters. Provider filtering belongs in a secondary menu. The initial view prioritizes installed and recommended models; an expandable Whisper family exposes every supported official variant without filling the first screen.

Each row shows name, provider, execution location, actual storage size where applicable, readiness, and one action. Keep favorites optional. Do not use invented speed/accuracy bars. Details reveal supported capabilities, format, runtime, license, minimum hardware, version, and measured performance when available.

Use actionable states:

| State | Action or explanation |
| --- | --- |
| Available | Download; disclose any publisher acquisition step first |
| Downloading | Real bytes/progress, cancel; resume only when supported |
| Verifying | Validate integrity and runtime compatibility |
| Installed | Select for a mode; first-use preparation may still be needed |
| Ready | Compatible and usable by the current runtime |
| Unsupported | State the hardware, OS, or format mismatch |
| Failed | Specific failure and retry, with completed downloads preserved |

Import checks format and compatibility before changing a mode. Removing a model lists dependent modes and offers replacement; never leave their selectors silently pointing at missing files.

## API connection sheet

Offer OpenAI and Groq for speech, OpenAI and Anthropic for cleanup. The sheet contains provider, masked key, model selector or explicit ID, and Test and Save. Store secrets in Keychain. A test must report its scope, such as "Credentials accepted; transcription not tested." If verifying inference costs money, disclose the small synthetic request before running it. Never send saved recordings as a connection test. Distinguish invalid keys, inaccessible models, rate limits, and network errors. Local setup skips this sheet.

## Mode capabilities and processing policy

Mode editing shows "Speech → Cleanup → Insert" with the chosen models. Selecting S1-mini reveals four labeled tone positions and its supported structure/context controls. Custom instructions and meeting summaries require a capable general model. Retain incompatible settings when switching models, but explain that they are inactive. Preview changes using an explicit test action, keeping raw text inspectable.

The Local filter changes the catalog only. A separate "Require local processing" control checks both speech and cleanup before execution and prevents cloud fallback. Label local speech plus API cleanup "Audio stays local; transcript sent to [provider]." Downloads remain a separate network activity. Spokenly documents a stronger network-blocking mode with localhost exceptions; endpoint locality alone does not prove inference stays local. [Spokenly policy](https://spokenly.app/docs/local-only-mode)

## Acceptance checks

First-run testing must cover denied permissions, canceled downloads, insufficient disk space, unsupported imports, offline relaunch, cloud cleanup under local policy, and disconnected microphones. VoiceOver and keyboard users must complete setup, edit shortcuts, reorder microphones, and operate the model table without dragging.
