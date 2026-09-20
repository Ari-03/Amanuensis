import SwiftUI

struct SoundView: View {
    @Bindable var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ScreenHeader(
                    title: "A clear place to start.",
                    subtitle: "Choose the microphones you trust, in the order you prefer.")
                SettingsCard {
                    HStack {
                        Label(
                            model.microphoneName,
                            systemImage: "mic.fill"
                        ).font(.headline)
                        Spacer()
                        Text(model.phase == .recording ? "Recording" : "Input used for last recording").font(
                            .caption
                        ).foregroundStyle(.secondary)
                    }
                    AudioLevelView(level: model.recordingLevel, active: model.phase == .recording)
                }
                HStack {
                    SectionCaption(title: "Microphone priority")
                    Button("Scan for devices", systemImage: "arrow.clockwise") { model.refreshMicrophones() }
                }
                SettingsCard {
                    if model.microphones.isEmpty {
                        Text("No microphones found. Connect an input, then scan again.").foregroundStyle(
                            .secondary)
                    }
                    ForEach(Array(model.microphones.enumerated()), id: \.element.id) { index, microphone in
                        HStack(spacing: 12) {
                            Text("\(index + 1)").monospacedDigit().foregroundStyle(.tertiary).frame(width: 18)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(microphone.name).fontWeight(.medium)
                                Text(
                                    model.audio.devices.contains(where: {
                                        $0.id == microphone.id && $0.isConnected
                                    }) ? (microphone.isEnabled ? "Available" : "Excluded") : "Disconnected"
                                )
                                .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                move(index, by: -1)
                            } label: {
                                Image(systemName: "chevron.up")
                            }
                            .disabled(index == 0).accessibilityLabel("Move \(microphone.name) up")
                            Button {
                                move(index, by: 1)
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .disabled(index == model.microphones.count - 1).accessibilityLabel(
                                "Move \(microphone.name) down")
                            Toggle(
                                "Use",
                                isOn: Binding(
                                    get: { microphone.isEnabled },
                                    set: { enabled in
                                        guard
                                            let item = model.microphones.firstIndex(where: {
                                                $0.id == microphone.id
                                            })
                                        else { return }
                                        model.microphones[item].isEnabled = enabled
                                        model.saveConfiguration()
                                    })
                            ).toggleStyle(.switch).labelsHidden().accessibilityLabel("Use \(microphone.name)")
                        }
                        if index != model.microphones.count - 1 { Divider() }
                    }
                }
                Text(
                    "The first available included microphone is used for the next recording. Excluded microphones are never used as a fallback. A disconnected microphone stops the current recording so you can recover what was captured."
                )
                .font(.callout).foregroundStyle(.secondary)
            }.padding(28).frame(maxWidth: 960).frame(maxWidth: .infinity)
        }.onAppear { model.refreshMicrophones() }
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard model.microphones.indices.contains(target) else { return }
        model.microphones.swapAt(index, target)
        model.saveConfiguration()
    }
}
