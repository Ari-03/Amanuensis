# Desktop design references

Research checked September 19, 2026. "P3 code" is interpreted as **T3 Code**, supported by the workspace context, but Aritra has not explicitly confirmed that transcription. These references inform Amanuensis's native macOS interface; they do not select its implementation stack. The recommendations below are proposals.

## T3 Code

The official project links its desktop app, website, and source repository. I inspected its public desktop screenshot and source at commit `7445aa733ada33e45289e5aa5055f79142556513`. [Repository](https://github.com/pingdotgg/t3code), [official site](https://t3.codes/)

The screenshot has a narrow navigation column, a readable main working area, and an optional detail pane. Selection uses a quiet filled row. Most chrome is neutral; blue marks actions and green/red communicate changes. Secondary metadata sits beneath the primary label. A single composer remains visually dominant, with model choice placed alongside the action. These are observations of that screenshot, not a claim about every theme. [Desktop screenshot](https://t3.codes/_astro/app-desktop.BOCg1ktw.webp)

Its source makes compact geometry explicit: `0.5rem` control radius, `0.5rem` sidebar inset/gaps, `0.625rem` row inset, and a `52px` workspace toolbar. It uses system sans fonts and separate semantic tokens for canvas, raised content, selection, hover, focus, muted text, and status. These values are evidence of consistency, not dimensions Amanuensis must copy. [Layout and style tokens](https://github.com/pingdotgg/t3code/blob/7445aa733ada33e45289e5aa5055f79142556513/apps/web/src/index.css), [theme roles](https://github.com/pingdotgg/t3code/blob/7445aa733ada33e45289e5aa5055f79142556513/packages/shared/src/themePalettes.ts)

Focus behavior is deliberate: open palettes own their shortcuts, closing a palette restores composer focus, and a background terminal finishing startup does not steal focus from typing. [Keyboard focus](https://github.com/pingdotgg/t3code/blob/7445aa733ada33e45289e5aa5055f79142556513/docs/user/keyboard-focus.md)

For Amanuensis, use the sidebar for the requested sections and reserve a detail pane for a selected transcript or model. Keep recording controls visually dominant. A finished download must never move keyboard focus; opening a mode picker should own arrow/number navigation and restore focus when dismissed. Preserve the destination app independently of whichever utility panel is visible.

## Raycast

Raycast documents contextual action lists, shortcut labels beside actions, typing to filter, and inline hotkey capture that avoids a settings detour. Return runs a primary action; Escape closes the panel or returns from a submenu. [Action panel](https://manual.raycast.com/action-panel)

Borrow this for the compact mode switcher and Home shortcut editor. Show the selected mode, speech model, and cleanup model together. Clicking the recording shortcut should immediately show "Press your shortcut", with Cancel and Clear. Keep the main-window action search optional; a full command system is unnecessary for first dictation.

## Linear

Linear's redesign describes an L-shaped navigation frame, careful icon/label alignment, reduced chrome noise, and consistent content hierarchy. The team tested layouts across environments, light/dark appearances, and different view types. Their theme system also includes contrast as a first-class variable. [Official redesign account](https://linear.app/now/how-we-redesigned-the-linear-ui)

Apply that discipline to actual empty, loading, interrupted, and populated states. A tidy Home mockup is insufficient if a long model name, failed download, or empty history breaks the layout. Keep labels and values aligned across every settings group. Native semantic colors should carry the initial light, dark, and increased-contrast behavior.

## Proposed visual direction

Use system typography and SF Symbols, graphite and warm off-white backgrounds, restrained separators, and one muted blue accent for selection and actions. Reserve red for active recording or destructive actions, accompanied by text or an icon. Prefer compact rows and grouped settings over a dashboard full of oversized cards. The recording waveform is the distinctive visual element.

Start layout exploration at a 220-point sidebar, 28-point content margins, 13-point controls, and 15-point transcript text. These are design starting values to test, not measured competitor specifications. Let native controls establish minimum hit areas and keyboard behavior.

Home should answer "Can I dictate?" before showing statistics: active microphone, active mode, processing location, and an editable shortcut. History should make copying a recovered transcript easy. The library needs explicit installed, downloading, unavailable, and ready states; model provenance matters more than decorative performance bars.

The compact recorder should show microphone activity only while capturing audio. After release, replace the waveform with "Transcribing" and then "Cleaning up". Keep its position stable, and reveal completion, retry, or copy actions in place. A notch treatment can add personality after this behavior works in a floating panel.

Before accepting the direction, inspect Home, model library, history detail, mode editor, shortcut capture, and recording failure in both appearances. Test keyboard-only operation, long text, narrow windows, increased contrast, and reduced motion. The intended result is a quiet utility with obvious controls and recoverable failures.
