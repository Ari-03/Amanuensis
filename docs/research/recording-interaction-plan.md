# Recording interaction plan

Checked September 19, 2026. Proposed behavior for the [product brief](../product-brief.md), not implemented or hardware-tested. This plan defines one recording lifecycle shared by shortcuts, the menu bar, Home, and recorder controls.

## One session, one destination

At start, capture the destination app and focused editable element, then resolve the mode. Precedence is direct mode shortcut, deliberate manual selection, matching app rule, default mode. A manual selection remains active until the user returns to Automatic. Disallow duplicate app rules initially rather than inventing invisible priorities.

Freeze mode settings, speech/cleanup models, vocabulary, replacement rules, microphone, and processing policy for that session. Edits apply next time. A new policy that forbids network processing cancels pending cloud work immediately. Mode switching during capture displays “Next recording: Mail.” Show the current mode beside the microphone indicator.

The recorder must not activate Amanuensis during ordinary use. Apple's `nonactivatingPanel` explicitly supports panels that do not activate their app. App activation notifications can invalidate the captured destination, but app identity alone cannot establish that the same text field remains focused. Delegate element validation and insertion to the insertion service. If focus moved, preserve the result and offer Copy or explicit insertion after the user selects a destination. [Apple panel style](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel), [workspace notifications](https://developer.apple.com/documentation/appkit/nsworkspace/didactivateapplicationnotification).

## State transitions

| State | Event | Next state and visible result |
| --- | --- | --- |
| Idle | Toggle press / push-to-talk down | Preparing. Capture destination and configuration; check permission, model readiness, and eligible microphone. |
| Preparing | Capture actually starts | Recording. Show live level, elapsed time, active input, and Stop. Start cue only now. |
| Preparing | Push-to-talk released / Cancel | Canceled, then Idle. Never begin delayed recording after release. |
| Preparing | Permission/model/input unavailable | Needs attention. Explain the specific missing prerequisite; do not upload or switch models. |
| Recording | Toggle press / push-to-talk released / Stop | Transcribing. Close audio input and restore app-controlled playback changes. |
| Recording | Cancel | Canceled. Close input, discard this session's audio and text, restore playback. |
| Recording | Input lost / sleep / capture failure | Interrupted. Preserve captured audio under retention policy; offer Transcribe captured audio or Discard. |
| Transcribing | Nonempty final transcript | Cleaning when configured; otherwise Ready. Save raw text before cleanup. |
| Transcribing | Valid no-speech result | No speech detected. No cleanup or insertion. Retain a status entry according to history preferences. |
| Cleaning | Nonempty valid completion | Ready. Keep raw and cleaned text separately. |
| Cleaning | Valid empty completion | Nothing to insert. Keep raw text; do not paste filler back automatically. |
| Transcribing / Cleaning | Error or timeout | Failed. Offer an appropriate retry or raw-text recovery; retain available evidence. |
| Transcribing / Cleaning | Cancel | Canceled. Invalidate the job; late callbacks cannot save or paste results. |
| Ready | Valid destination and auto-paste enabled | Inserting, then Delivered only after the insertion service reports its supported success condition. |
| Ready | Destination changed / auto-paste off / insertion fails | Result available. Show Copy and details; no automatic refocus. |

Busy states reject a second start with a short explanation. Do not queue surprise recordings. Every asynchronous event carries the session identifier. A canceled or superseded identifier cannot advance state.

## Shortcut contract

Toggle responds once per physical press. Push-to-talk starts on down and stops on release, ignoring key repeat. A release received during preparation cancels preparation. Modifier loss, app suspension, sleep, and missing key-up detection must stop or interrupt capture rather than leave a microphone running indefinitely. Cancel applies only while a session is active; do not consume Escape system-wide while idle.

The same named shortcut setting powers Home and Configuration. Detect duplicate assignments; capture mode suppresses recording commands until shortcut editing finishes. Initially support ordinary key combinations. Modifier-only, Fn, and mouse shortcuts require separate event and permission testing, as noted in [macOS feasibility](macos-feasibility.md).

## Recorder controls

Mini and near-notch presentations share the same state and commands. Idle offers mode selection, Record, and Expand. Capture offers Stop and Cancel with visible elapsed time; processing offers status and Cancel. A small success indication may dismiss itself; errors and held results remain discoverable through the menu bar.

Expand opens a larger recorder containing the selected mode/input, status, partial transcript when supported, and final raw/cleaned views with Copy. Partial text is labeled provisional and never auto-pasted. Expanding must preserve capture and destination. Editing or keyboard navigation may take focus; that explicitly invalidates automatic insertion. This gives the screenshot's ambiguous expand action a useful purpose without creating another recording mode.

Place controls outside the camera cutout, with a floating fallback on external displays. Hidden-overlay preference retains a menu-bar recording indicator. Verify full-screen apps, Spaces, display changes, and menu-bar auto-hide on hardware.

## Accessibility and verification

Use labeled buttons, keyboard traversal, a textual state, and VoiceOver announcements only for state changes. Never convey recording solely through color, sound, or an animated waveform. Reduced motion removes pulsing and expanding transitions; keep a static recording symbol and elapsed time. Observe changes to Apple's accessibility display setting. [Apple reduced motion API](https://developer.apple.com/documentation/appkit/nsworkspace/accessibilitydisplayshouldreducemotion).

Acceptance tests must cover:

- Key repeat, rapid toggle, release during model load, lost key-up, and cancellation during every asynchronous stage.
- App/control changes during recording and processing; no unintended insertion.
- New microphone arrival, active microphone removal, and all inputs excluded.
- Mode edits mid-recording and cloud policy changes before dispatch.
- Empty audio, ASR failure, filler-only S1-mini success, cleanup failure, and canceled late completion. Empty S1-mini output is documented behavior, not automatically an error. [Author contract](https://huggingface.co/superwhisper/s1-mini).
- VoiceOver, reduced motion, hidden overlay, multiple screens, sleep/wake, and playback restoration after success, interruption, or cancel.
