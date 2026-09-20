# Native macOS feasibility

Research checked September 19, 2026. This is a feasibility assessment, not a claim that the integrations have been implemented or tested.

The repository starts with a SwiftUI hello-world app. Its Xcode project sets `MACOSX_DEPLOYMENT_TARGET = 27.0`, enables App Sandbox, and grants read-only access to user-selected files. The requested interface fits SwiftUI, with AppKit and Core Audio handling system integration. A lower deployment target should be an explicit product decision; none of the core interactions below inherently requires macOS 27. [Project settings](../../Amanuensis.xcodeproj/project.pbxproj), [current view](../../Amanuensis/ContentView.swift).

## Shortcuts and automatic modes

Use the maintained Swift package KeyboardShortcuts for ordinary configurable global key combinations. It supplies a SwiftUI recorder, persistence, and key-down/key-up events, supports sandboxed apps, and documents that its registration does not cause permission dialogs. The same named shortcut can appear on Home and Configuration. Toggle recording consumes one event; push-to-talk starts on key-down and stops on key-up. Do not retrigger on repeats. Modifier-only, Fn, Caps Lock, and mouse-button shortcuts need a separate investigation; the package explicitly excludes Caps Lock from its standard events. [KeyboardShortcuts repository](https://github.com/sindresorhus/KeyboardShortcuts).

For those special inputs, investigate a session event tap. Its creation can fail if the process lacks permission, and callbacks must be attached to a run loop. Check event-listening access separately from accessibility trust; avoid requesting broad input access for ordinary registered shortcuts. Handle lost key-up events, sleep, and permission changes so a held shortcut cannot leave recording running. These are proposed implementation safeguards. [Apple event taps](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:)), [listening access](https://developer.apple.com/documentation/coregraphics/cgpreflightlisteneventaccess()).

App-based modes are straightforward: `NSWorkspace.frontmostApplication` returns the app receiving key events, and supports observation. Map its bundle identifier to a mode. Proposed precedence is an explicit recording-mode shortcut, then an app rule, then the default mode. Freeze that selection when capture starts so changing apps during recording cannot silently change tone. Website matching is a separate browser integration; the foreground browser identifier does not identify its current tab. [Apple frontmost application](https://developer.apple.com/documentation/appkit/nsworkspace/frontmostapplication).

## Text insertion and clipboard restoration

Prototype insertion against real target apps early. A practical route copies the result to `NSPasteboard`, posts the paste keystroke, then restores the previous clipboard. Quartz exposes synthetic keyboard events, and the app can check accessibility trust before enabling cross-app automation. The signed app's sandbox configuration needs a real end-to-end spike; permission approval alone is not proof that every target field supports insertion. [Quartz Event Services](https://developer.apple.com/documentation/coregraphics/quartz-event-services), [accessibility trust](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions).

Restoration should preserve each readable pasteboard item's types and data, including rich content, rather than only its text. Record `changeCount` after writing our result and restore only if it remains unchanged, so a new copy action wins. Apple's counter tracks ownership changes. There is no paste-completion acknowledgment in that counter, so a fixed delay must be tested against slow apps and large text. Treat promised or unavailable pasteboard data as a restoration limitation. Always retain a copyable result if insertion fails. This restoration algorithm is a recommendation based on the documented counter, not an Apple-provided atomic paste operation. [Apple pasteboard change count](https://developer.apple.com/documentation/appkit/nspasteboard/changecount).

## Microphone and meeting audio

Microphone capture requires `NSMicrophoneUsageDescription` and explicit authorization. Check `AVCaptureDevice.authorizationStatus` before requesting access. Denial needs a visible recovery path. Request the sandbox's microphone capability when implementing capture. [Apple microphone authorization](https://developer.apple.com/documentation/bundleresources/requesting-authorization-for-media-capture-on-macos).

For meetings, evaluate two supported capture routes:

| Route | OS and permission | Consequence |
| --- | --- | --- |
| Core Audio process taps | Apple's sample requires macOS 14.2+. Add `NSAudioCaptureUsageDescription`; starting a tap-containing aggregate device prompts for system audio recording access. | Captures selected processes or groups without needing video output. A good candidate for an audio-only app. |
| ScreenCaptureKit | System-audio capture uses screen-capture authorization. Its macOS 15 generation adds a dedicated microphone output alongside system audio. | Separate microphone and system-audio callbacks simplify keeping the two sources distinct. |

The first route and its constraints are documented in [Apple's Core Audio tap sample](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps). The second is documented in [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) and [Apple's microphone capture walkthrough](https://developer.apple.com/videos/play/wwdc2024/10088/).

Keep microphone and system audio as separate timestamped streams until mixing or transcription. This is a design recommendation: local versus remote audio is useful provenance, but it does not distinguish two remote speakers in one meeting stream. Speaker identification remains a separate model capability to validate. Test device changes, Bluetooth sample-rate changes, echo, overlapping voices, sleep, and permission revocation before promising reliable meeting transcription.

## Playback during recording

Keep Playing is always a valid behavior. Pause should mean pausing supported players, with an explicit fallback. The APIs reviewed do not establish a universal pause command for every app, browser tab, notification, or meeting. If a player adapter uses Apple events, include `NSAppleEventsUsageDescription` and handle denied automation access. Resume only playback that Amanuensis successfully paused. [Apple events permission](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription).

Lower Volume and Mute can use writable Core Audio output-device properties where available. Query support and writability before offering them for the current device. Restore the previous setting only if the user has not changed it meanwhile, and handle output-device switches. This is a proposed device-control approach, not a guarantee for every audio output. [Apple property writability](https://developer.apple.com/documentation/coreaudio/audioobjectispropertysettable(_:_:_:)).

Core Audio taps can also mute captured processes' output, but that is distinct from pausing their media. Do not pause a meeting's remote audio when the meeting mode is supposed to capture it. [Apple tap mute behavior](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps).

## Recording indicator near the notch

Implement an Amanuensis-owned overlay using a borderless, nonactivating `NSPanel`; that style avoids activating the owning app. Position it using each display's `NSScreen.safeAreaInsets` and auxiliary top-left/top-right regions. Apple documents that the auxiliary region is absent when the top of a display is unobscured. [Apple panel style](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel), [screen geometry](https://developer.apple.com/documentation/appkit/nsscreen/auxiliarytopleftarea).

Call the setting "Near the notch" or "Top of screen." The reviewed Apple documentation provides no native MacBook Dynamic Island target for this use. Apple's Live Activities guidance describes paired-iPhone activities in the Mac menu bar, with clicks opening iPhone Mirroring. That is a different interaction from a native dictation meter. [Apple Live Activities platform guidance](https://developer.apple.com/design/human-interface-guidelines/live-activities).

Proposed fallback: use the same compact recording pill at the top center of the chosen external display when no notch is present. Keep a menu-bar recording state even when the overlay is hidden. Recalculate placement after display changes; verify Spaces, full-screen apps, menu-bar auto-hide, and reduced-motion settings on hardware. Never put essential controls inside the physical camera cutout.

## Login and updates

`SMAppService.mainApp.register()` provides launch at login on macOS 13+. Derive the toggle from service status rather than persisting a Boolean that can disagree with System Settings. [Apple SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice), [registration behavior](https://developer.apple.com/documentation/servicemanagement/smappservice/register()).

For direct distribution, Sparkle 2 supplies manual checks and automatic update management. Shipping requires a real HTTPS appcast and release artifacts, archive signatures, and app signing/notarization. Sandboxed integration additionally uses its Installer XPC service and documented entitlements. A prototype must not report "up to date" without reaching an actual feed. Store distribution would require a separate release/update design. [Sparkle setup](https://sparkle-project.org/documentation/), [sandbox integration](https://sparkle-project.org/documentation/sandboxing/).

The highest-value implementation spikes are signed cross-app paste, one working local dictation shortcut, and microphone plus system-audio capture. Those determine the practical permissions and distribution setup before polishing the full configuration screen.
