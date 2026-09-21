import SwiftUI

struct SoundView: View {
    @Bindable var model: AppModel

    private var included: [MicrophonePreference] { model.microphones.filter(\.isEnabled) }
    private var excluded: [MicrophonePreference] { model.microphones.filter { !$0.isEnabled } }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ScreenHeader(
                title: "A clear place to start.",
                subtitle: "Choose the microphones you trust, in the order you prefer.")
            SettingsCard {
                HStack {
                    Label(model.microphoneName, systemImage: "mic.fill").font(.headline)
                    Spacer()
                    Text(model.phase == .recording ? "Recording" : "Input used for last recording")
                        .font(.caption).foregroundStyle(.secondary)
                }
                AudioLevelView(level: model.recordingLevel, active: model.phase == .recording)
            }
            HStack {
                SectionCaption(title: "Microphone priority")
                Button("Scan for devices", systemImage: "arrow.clockwise") { model.refreshMicrophones() }
            }
            if model.microphones.isEmpty {
                SettingsCard {
                    Text("No microphones found. Connect an input, then scan again.").foregroundStyle(
                        .secondary)
                }
            } else {
                List {
                    Section {
                        ForEach(Array(included.enumerated()), id: \.element.id) { index, microphone in
                            row(microphone, position: index + 1)
                        }
                        .onMove(perform: moveIncluded)
                        if included.isEmpty {
                            Text("Every microphone is excluded. Turn one on to record.")
                                .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
                        }
                    } header: {
                        sectionHeader("In use", detail: "Drag to reorder. The first available one records.")
                    }
                    if !excluded.isEmpty {
                        Section {
                            ForEach(excluded) { microphone in row(microphone, position: nil) }
                        } header: {
                            sectionHeader("Excluded", detail: "Never used, even as a fallback.")
                        }
                    }
                }
                .listStyle(.inset).scrollContentBackground(.hidden)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.06)))
                .animation(.snappy, value: model.microphones)
            }
            Text(
                "A disconnected microphone stops the current recording so you can recover what was captured."
            )
            .font(.callout).foregroundStyle(.secondary)
        }
        .padding(28).frame(maxWidth: 960).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { model.refreshMicrophones() }
    }

    private func sectionHeader(_ title: String, detail: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(detail).font(.caption).foregroundStyle(.tertiary)
        }
        .textCase(nil).padding(.vertical, 4)
    }

    private func row(_ microphone: MicrophonePreference, position: Int?) -> some View {
        let connected = model.audio.devices.contains { $0.id == microphone.id && $0.isConnected }
        return HStack(spacing: 12) {
            if let position {
                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text("\(position)").monospacedDigit().foregroundStyle(.tertiary).frame(width: 18)
            } else {
                Image(systemName: "mic.slash").foregroundStyle(.tertiary).frame(width: 40)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(microphone.name).fontWeight(.medium)
                    .foregroundStyle(position == nil ? .secondary : .primary)
                Text(connected ? (microphone.isEnabled ? "Available" : "Excluded") : "Disconnected")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(
                "Use",
                isOn: Binding(
                    get: { microphone.isEnabled },
                    set: { setEnabled(microphone.id, $0) })
            )
            .toggleStyle(.switch).labelsHidden().accessibilityLabel("Use \(microphone.name)")
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(position.map { "\(microphone.name), priority \($0)" } ?? microphone.name)
    }

    /// Reorders the in-use microphones; excluded ones keep their place after them.
    private func moveIncluded(from source: IndexSet, to destination: Int) {
        var ordered = included
        ordered.move(fromOffsets: source, toOffset: destination)
        model.microphones = ordered + excluded
        model.saveConfiguration()
    }

    /// A toggled microphone joins the end of its new group so the list order stays predictable.
    private func setEnabled(_ id: String, _ enabled: Bool) {
        guard var microphone = model.microphones.first(where: { $0.id == id }) else { return }
        microphone.isEnabled = enabled
        let remaining = model.microphones.filter { $0.id != id }
        withAnimation(.snappy) {
            model.microphones =
                enabled
                ? remaining.filter(\.isEnabled) + [microphone] + remaining.filter { !$0.isEnabled }
                : remaining + [microphone]
        }
        model.saveConfiguration()
    }
}
