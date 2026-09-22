import SwiftUI

struct ConfigurationView: View {
    @Bindable var model: AppModel
    @State private var resetUsage = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ScreenHeader(
                    title: "Make yourself at home.",
                    subtitle: "Small preferences that make dictation feel familiar.")
                SectionCaption(title: "Appearance")
                SettingsCard {
                    Picker("Appearance", selection: $model.settings.appearance) {
                        ForEach(AppAppearance.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }.pickerStyle(.segmented)
                    Divider()
                    Text("Recording controls").font(.headline)
                    HStack(spacing: 12) {
                        ForEach(RecorderStyle.allCases, id: \.self) { style in
                            recorderPreview(style)
                        }
                    }
                    Toggle("Keep recording controls visible", isOn: $model.settings.alwaysShowRecorder)
                    if model.settings.recorderStyle != .hidden {
                        Divider()
                        HStack(spacing: 24) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Screen position").font(.headline)
                                Text("Choose a spot, or drag the recorder onto a highlighted position.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("Hover over the waveform to show recording controls.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            recorderPositionPicker
                        }
                    }
                }
                SectionCaption(title: "Keyboard shortcuts")
                SettingsCard {
                    shortcutRow("Toggle recording", subtitle: "Press once to start, again to finish.") {
                        ShortcutRecorder(
                            binding: $model.settings.toggleShortcut, onChange: model.saveConfiguration,
                            onEditing: { model.isEditingShortcut = $0 })
                    }
                    Divider()
                    shortcutRow("Push to talk", subtitle: "Hold to record. Release to finish.") {
                        OptionalShortcutRecorder(
                            binding: $model.settings.pushToTalkShortcut, onChange: model.saveConfiguration,
                            onEditing: { model.isEditingShortcut = $0 })
                    }
                    Divider()
                    shortcutRow("Change mode", subtitle: "Choose the mode for your next recording.") {
                        OptionalShortcutRecorder(
                            binding: $model.settings.modeShortcut, onChange: model.saveConfiguration,
                            onEditing: { model.isEditingShortcut = $0 })
                    }
                    Text("Shortcuts can use a key or just modifiers, such as ⌥⌘. Escape cancels a recording.")
                        .font(.caption).foregroundStyle(.secondary)
                    if usesModifierShortcut && !model.accessibilityGranted {
                        HStack {
                            Text("Allow Accessibility access to use modifier shortcuts in other apps.")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Enable shortcuts", action: model.requestAccessibility)
                        }
                    }
                }
                SectionCaption(title: "Processing and storage")
                SettingsCard {
                    Toggle("Require local processing", isOn: $model.settings.requireLocalProcessing)
                    Text("Block API transcription and cleanup. Model downloads remain available.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Picker("Keep audio recordings", selection: $model.settings.audioRetentionDays) {
                        Text("Do not keep").tag(-1)
                        Text("1 day").tag(1)
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("Until deleted").tag(0)
                    }
                    Picker("Keep transcripts", selection: $model.settings.textRetentionDays) {
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                        Text("Until deleted").tag(0)
                    }
                    Text(
                        "Deleting a recording removes its audio and transcript. Usage totals are kept separately."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                SectionCaption(title: "Application")
                SettingsCard {
                    Toggle("Launch at login", isOn: $model.settings.launchAtLogin)
                    Toggle(
                        "Choose modes automatically for apps", isOn: $model.settings.automaticModeSelection)
                    Toggle("Play recording sounds", isOn: $model.settings.playSoundEffects)
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Usage statistics")
                            Text("Reset words, speed, and dictation time. History is kept.").font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Reset…") { resetUsage = true }
                    }
                }
            }.padding(28).frame(maxWidth: 960).frame(maxWidth: .infinity)
        }

        .confirmationDialog(
            "Reset all usage statistics?", isPresented: $resetUsage, titleVisibility: .visible
        ) {
            Button("Reset statistics", role: .destructive, action: model.resetStatistics)
        }
    }

    private var usesModifierShortcut: Bool {
        ([model.settings.toggleShortcut, model.settings.pushToTalkShortcut, model.settings.modeShortcut]
            + model.modes.map(\.startShortcut))
            .contains { $0?.isModifierOnly == true }
    }

    private func shortcutRow<Content: View>(
        _ title: String, subtitle: String, @ViewBuilder control: () -> Content
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.medium)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            control()
        }
    }

    private func recorderPreview(_ style: RecorderStyle) -> some View {
        Button {
            model.settings.recorderStyle = style
            if style == .notch { model.settings.recorderPlacement = nil }
        } label: {
            VStack(spacing: 10) {
                ZStack(alignment: style == .notch ? .top : .center) {
                    RoundedRectangle(cornerRadius: 9).fill(.quaternary.opacity(0.5))
                    if style == .hidden {
                        Image(systemName: "eye.slash").foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: style == .notch ? 26 : 12) {
                            Image(systemName: "waveform")
                            RecorderWaveform(level: 0, active: false)
                                .scaleEffect(0.7).frame(width: 48, height: 16)
                        }
                        .font(.system(size: 11)).foregroundStyle(.white)
                        .padding(.horizontal, 11).padding(.vertical, 7)
                        .background(.black, in: RecorderSilhouette(style: style))
                    }
                }.frame(height: 58)
                Text(style.rawValue.capitalized).font(.caption.weight(.medium))
            }
            .padding(7).frame(maxWidth: .infinity)
            .background(
                model.settings.recorderStyle == style ? Color.accentColor.opacity(0.09) : .clear,
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12).strokeBorder(
                    model.settings.recorderStyle == style ? Color.accentColor : .clear, lineWidth: 2))
        }.buttonStyle(.plain).accessibilityLabel("\(style.rawValue) recorder")
            .accessibilityAddTraits(model.settings.recorderStyle == style ? .isSelected : [])
    }

    private var recorderPositionPicker: some View {
        VStack(spacing: 8) {
            ForEach(0..<5) { row in
                HStack(spacing: 10) {
                    ForEach(0..<5) { column in
                        if row == 0 || row == 4 || column == 0 || column == 4
                            || (row == 2 && column == 2)
                        {
                            positionButton(row: row, column: column)
                        } else {
                            Color.clear.frame(width: 26, height: 18)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary.opacity(0.25)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording controls screen position")
    }

    private func positionButton(row: Int, column: Int) -> some View {
        let current =
            model.settings.recorderPlacement
            ?? (model.settings.recorderStyle == .notch ? .top : .bottom)
        let x = Double(column) / 4
        let y = 1 - Double(row) / 4
        let selected = abs(current.x - x) < 0.01 && abs(current.y - y) < 0.01
        let vertical = ["Top", "Upper", "Middle", "Lower", "Bottom"][row]
        let horizontal = ["left", "left of center", "center", "right of center", "right"][column]
        let label = "\(vertical) \(horizontal)"
        return Button {
            model.settings.recorderPlacement = RecorderPlacement(
                x: x, y: y, displayID: current.displayID)
        } label: {
            Capsule()
                .fill(selected ? Color.accentColor : Color.secondary.opacity(0.25))
                .frame(width: 24, height: 7)
                .frame(width: 26, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
