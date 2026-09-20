# Apple speech recognition and microphone priorities

Checked September 19, 2026 against Apple documentation, the installed macOS SDK, and Spokenly's public documentation. Recommendations below have not been tested in an implementation.

## Apple recognizer choice

Use `SpeechAnalyzer` with a `SpeechTranscriber` module as the first native Apple option on macOS 26 and later. Apple introduced this API for live, conversational, distant, and long-form speech, and describes its recognition as on-device. Availability still depends on hardware and capabilities. Check `SpeechTranscriber.isAvailable` and resolve an English locale through `supportedLocale(equivalentTo:)` before creating a session. Do not infer support solely from the OS version or the presence of Apple Intelligence. [Apple introduction](https://developer.apple.com/videos/play/wwdc2025/277/), [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber), [runtime availability](https://developer.apple.com/documentation/speech/speechtranscriber/isavailable).

The installed SDK and Apple's documentation metadata both mark `SpeechAnalyzer`, `SpeechTranscriber`, and `DictationTranscriber` as available from macOS 26.0. The project initially targets macOS 27, so this route does not require raising its target. A later decision to support older macOS versions needs a fallback. [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer), [project settings](../../Amanuensis.xcodeproj/project.pbxproj).

| Path | Appropriate use | Offline requirement |
| --- | --- | --- |
| `SpeechAnalyzer` plus `SpeechTranscriber` | Preferred Apple option on supported macOS 26+ hardware; live dictation and longer recordings. | Verify device and English support, then prepare required assets. |
| `SpeechAnalyzer` plus `DictationTranscriber` | macOS 26+ fallback when the newer model is unavailable. Apple describes compatibility with older devices. | Uses the system's on-device dictation models and excludes locales that the older recognizer only supports over the network. Check locale and asset readiness. |
| `SFSpeechRecognizer` | Compatibility path for older macOS versions, if needed. Its on-device request option is available from macOS 10.15. | Require `supportsOnDeviceRecognition == true` and set `requiresOnDeviceRecognition = true` on every request. Otherwise mark this path unavailable in local-only execution. |

Sources for the fallback behavior are [DictationTranscriber](https://developer.apple.com/documentation/speech/dictationtranscriber), [on-device support](https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition), and [required on-device execution](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition). A valid `SFSpeechRecognizer` instance does not itself prove that recognition is available. Its documented service limits also make it a weaker default for meeting transcription. [SFSpeechRecognizer](https://developer.apple.com/documentation/speech/sfspeechrecognizer).

For the modern path, `AssetInventory` checks readiness, obtains an installation request, and downloads the required model assets. The system owns, shares, retains, and updates these assets. Downloads may already be satisfied by another app, but do not assume the assets are permanently present. Display "Needs download," progress, "Ready on this Mac," and a retryable error as real states. Reserve the needed English locale and release it when no longer required. Amanuensis cannot treat Apple's assets like an arbitrary user-managed model file. [Apple asset management](https://developer.apple.com/documentation/speech/assetinventory).

Apple explicitly says the speech-server authorization flow applies to `SFSpeechRecognizer`; `SpeechAnalyzer` transcriber modules do not send voice audio to Apple's servers. Microphone authorization still applies to live capture. Keep these two permissions distinct. [Apple speech authorization](https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition), [microphone authorization](https://developer.apple.com/documentation/bundleresources/requesting-authorization-for-media-capture-on-macos).

## Microphone list and selection

Use `AVCaptureDevice.DiscoverySession` filtered to audio devices to enumerate inputs. For a modern macOS target, `.microphone` is the microphone device type. Read the session's `devices`, observe list changes, and provide a Scan Again action that refreshes the displayed inventory. Discovery results describe available devices; Amanuensis must apply the user's priority order itself. [Discovery sessions](https://developer.apple.com/documentation/avfoundation/avcapturedevice/discoverysession), [microphone device type](https://developer.apple.com/documentation/avfoundation/avcapturedevice/devicetype-swift.struct/microphone).

Persist each preference by `AVCaptureDevice.uniqueID`. Apple documents persistence across connections, disconnections, app restarts, and system reboots on one system. Use `localizedName` for display, never as the identity. Retain absent devices in the preference list as "Disconnected" so their rank and exclusion survive unplugging. [Stable device identifiers](https://developer.apple.com/documentation/avfoundation/avcapturedevice/uniqueid).

Proposed list behavior:

1. Drag rows to reorder priorities, with keyboard-accessible Move Up and Move Down actions.
2. Give each device an Include toggle. Excluding the user's AirPods input stores its device identifier in the excluded set; it does not disable AirPods playback or change the Mac's system-wide default input.
3. At recording start, choose the highest-ranked connected, included device that can successfully open. Show its name beside the recording state.
4. When idle, select a newly connected higher-priority device. During recording, keep the working device until the recording ends, unless that device disappears or fails.
5. If the active device is lost, preserve recorded audio, stop capture, and show an interruption. Select the next eligible input for a new recording. Continuation within the same recording is a possible extension after timestamp and format-transition testing, with a visible "Microphone changed" indication. Do not silently use an excluded device.

These are product recommendations, not behavior supplied automatically by AVFoundation. Explicit per-device exclusion is more dependable than guessing whether every device named "AirPods" belongs to the same headset. New devices can appear as unranked until the user includes them, which prevents an unfamiliar Bluetooth input from taking over.

Build the capture input from the chosen `AVCaptureDevice` using `AVCaptureDeviceInput`, check `canAddInput`, and add it to `AVCaptureSession`. Batch input changes inside `beginConfiguration` and `commitConfiguration`, on a serialized capture execution context. Session startup can block and should not run on the main UI queue. Observe device connections/disconnections and capture failures. Audio format conversion and timestamp handling must be reconfigured when the selected input changes. [Apple capture sessions](https://developer.apple.com/documentation/avfoundation/avcapturesession), [device notifications](https://developer.apple.com/documentation/avfoundation/avcapturedevice).

A seamless transition between microphones remains unverified. Test built-in microphones, USB inputs, Bluetooth headsets, reconnects, and device changes during a held recording shortcut. For the first implementation, an honest interruption with preserved audio is preferable to silently dropping speech.

## Spokenly reference and the meaning of local-only

Spokenly's official docs show a dictation-model library, per-mode transcription choices, and a separate Local Only Mode. The latter is documented as blocking external network activity while allowing localhost services. Its public documentation and full-text documentation index did not establish microphone drag ordering, exclusions, or exact hot-plug behavior during this check. Treat that portion of the user's walkthrough as the requested interaction, without claiming independent verification of Spokenly's implementation. [Spokenly introduction](https://spokenly.app/docs), [mode settings](https://spokenly.app/docs/modes), [Local Only Mode](https://spokenly.app/docs/local-only-mode), [documentation index](https://spokenly.app/llms-full.txt).

Keep the following controls distinct in Amanuensis:

| Control | Meaning |
| --- | --- |
| Show local models only | A library display filter. It changes which rows are visible. |
| Process on this Mac | An execution policy. Both transcription and optional text cleanup must use permitted local providers, with no automatic cloud fallback. |
| Block external app connections, if offered | A stronger network policy covering model downloads, updates, diagnostics, sync, and provider traffic, with explicitly defined exceptions. |

The policy should be checked again when executing a mode, since a library filter does not invalidate an already selected cloud model or cloud cleanup provider. Missing local assets should result in "Download required" or a supported local fallback, never an undisclosed upload. Model acquisition requires a separate permitted download step. Apple's system-managed asset downloads and updates also mean that on-device recognition must not be advertised as a guarantee that the entire Mac performs no network activity.

If localhost model servers are allowed, label them separately from bundled local engines. A local endpoint can itself proxy to a remote service; Amanuensis cannot prove otherwise from the endpoint address. These execution and labeling rules are proposed product requirements, not claims about Spokenly's implementation.
