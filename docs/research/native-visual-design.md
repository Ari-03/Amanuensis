# Native visual design

Research date: September 19, 2026. This note recommends a design direction for the existing product brief. Sizes, layouts, and timings below are proposed Amanuensis choices, not Apple requirements or implemented behavior.

## Direction

Make the transcript the strongest visual element. The main window should feel like a small Mac writing utility: readable text, a narrow sidebar, aligned controls, and enough density to compare models. Its personality can come from a considered app icon, spacing, and the recording interaction. Large welcome banners, gradients behind statistics, and repeated oversized cards would consume space without helping dictation.

Apple recommends resizable windows, comfortable density, menu commands, and keyboard operation for Mac apps. Its current materials guidance places Liquid Glass in navigation and controls, while advising against using it throughout content. Use native sidebar and toolbar treatments, with solid or standard-material content backgrounds. Do not put every transcript or model row on glass. [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/), [Materials](https://developer.apple.com/design/human-interface-guidelines/materials)

Two useful references beyond dictation apps are Things and Nova. Things documents hiding its sidebar for a slim window and extensive keyboard operation. Nova exposes separate light/dark theme choices and optional sidebar tools. Borrow the space-saving navigation and keyboard completeness; Amanuensis does not need an editor's theme marketplace or pane complexity. [Things sidebar](https://culturedcode.com/things/support/articles/3238254/), [Things shortcuts](https://culturedcode.com/things/support/articles/2785159/), [Nova settings](https://help.panic.com/nova/preferences/), [Nova window](https://help.panic.com/nova/window/)

## Proposed tokens

| Token | Starting value and use |
| --- | --- |
| Window | 1040 × 740 pt initially; minimum 760 × 560 pt; remember size and position |
| Sidebar | 200 pt ideal, 180–240 pt adjustable; native selection styling |
| Content inset | 24 pt; 16 pt at narrow widths |
| Spacing | 4, 8, 12, 16, 24, 32 pt; avoid one-off gaps |
| Type | System font; 22 pt page title, 15 pt section title, 13 pt controls, 12 pt metadata |
| Transcript | 15 pt with comfortable leading; selectable; support explicit text enlargement |
| Numbers | 26 pt Home statistics; monospaced digits for changing duration and progress |
| Rows | 32–36 pt compact lists; 44–52 pt rows containing a description; grow for larger text |
| Corners | Native controls keep native shape; 10 pt grouped content; capsules only for compact status/filter controls |
| Dividers | Semantic separator color, one physical pixel when custom drawing is necessary |
| Color | Semantic primary/secondary text, window/control backgrounds, system accent; semantic warning/error colors |

Apple's macOS typography defaults use 13 pt body text and recommend avoiding thin weights. macOS does not support Dynamic Type, so do not assume a SwiftUI text style alone provides user-controlled enlargement. Add View menu commands for transcript size and test layouts at 200% text. [Typography](https://developer.apple.com/design/human-interface-guidelines/typography?changes=lat_2_6), [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility?changes=latest_maj_6_3&language=objc)

Default appearance follows the system. Retain the requested System, Light, and Dark preference despite Apple's general advice against app-specific appearance settings. Use semantic colors instead of hard-coded white/black backgrounds; choose separate asset variants only for custom artwork. Test normal text at 4.5:1 contrast, including selected, disabled, and inactive-window states. [Dark Mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode), [Color](https://developer.apple.com/design/human-interface-guidelines/color?changes=_2_2)

## Screen composition

- Home: a quiet three-column statistics strip at the top. Below it, a recording action with directly editable shortcut, active mode, selected microphone, and explicit processing location. Create mode and Add vocabulary are simple secondary actions. Omit the marketing/news feed.
- Modes: a compact list with mode name, assigned apps, and speech/cleanup summaries. Selecting a mode opens its editor in the content pane. Show essential controls first; put recording behavior and insertion options in labeled disclosure sections.
- Models: a full-width table with search, Speech/Cleanup selection, and Local/API/Installed filters. Columns show model, provider, execution location, size, and state/action. Keep download progress in its row. Explain incompatibility in text, without decorative accuracy bars.
- History: a date-grouped list and transcript detail. At narrower widths, show one pane with a clear Back action. Give Result and Original equal, obvious access; put metadata below the transcript or behind an inspector. Copy remains visible.
- Vocabulary: editable rows with a Words/Replacements selector and an inline add field. Avoid a separate dialog for adding one word.
- Sound and Configuration: grouped native forms, consistent label alignment, short secondary explanations. Microphone drag handles also get Move up/down menu commands. Appearance tiles preview actual app treatments.

Use `NavigationSplitView` for the shell and its preferred column-width controls. Start with native `Table`, `List`, and `Form` behavior before overriding row drawing. [NavigationSplitView](https://developer.apple.com/documentation/swiftui/navigationsplitview), [Column widths](https://developer.apple.com/documentation/swiftui/navigationsplitviewvisibility), [Table](https://developer.apple.com/documentation/swiftui/table), [Form](https://developer.apple.com/documentation/swiftui/form)

## Interaction finish

Use native focus rings and SF Symbols with visible labels. A green dot cannot be the only indication that a model is local, a microphone is active, or a recording succeeded. Preserve selection and scroll position when editing a row. Keep primary actions reachable by keyboard and show shortcuts in menus.

Use native motion first. For custom changes, start with 120–180 ms fades; recording controls respond immediately, without waiting for animation. Animate measured microphone activity only during capture. With Reduce Motion enabled, replace expansion and repetitive movement with stable status text and restrained fades. Apple advises purposeful, brief motion and exposes the preference through SwiftUI. [Motion](https://developer.apple.com/design/human-interface-guidelines/motion?changes=l_9_3), [accessibilityReduceMotion](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion?changes=_3)

Validate the same real screens in light/dark, Increase Contrast, Reduce Transparency, Reduce Motion, VoiceOver, and keyboard-only operation. Include long model names, missing microphones, failed downloads, empty history, and a small window. These states will reveal more than a polished screenshot with ideal sample data.
