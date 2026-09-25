import SwiftUI

struct HomeView: View {
    @Bindable var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ScreenHeader(
                    title: "Make room for your words.",
                    subtitle: "Speak naturally. Keep your train of thought.")
                HStack(spacing: 0) {
                    metric("\(model.statistics.wordsPerMinute)", unit: "WPM", label: "Average speed")
                    Divider().frame(height: 40)
                    metric(model.statistics.words.formatted(), unit: "", label: "Words dictated")
                    Divider().frame(height: 40)
                    metric(
                        "\(Int(model.statistics.recordingSeconds / 60))", unit: "min", label: "Dictation time"
                    )
                }
                .padding(.vertical, 20)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 16))
                SettingsCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Menu {
                            Button("Automatic app modes", systemImage: "arrow.triangle.branch") {
                                model.settings.automaticModeSelection = true
                            }
                            Divider()
                            ForEach(model.modes) { mode in
                                Button(mode.name, systemImage: mode.symbol) {
                                    model.selectMode(mode.id)
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Label(model.currentMode.name, systemImage: model.currentMode.symbol)
                                    .font(.headline)
                                Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .disabled(model.phase.isBusy).accessibilityLabel("Change active mode")
                        Text(model.statusMessage).font(.callout).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 18) {
                        Button(action: model.toggleRecording) {
                            Label(
                                model.phase == .recording ? "Finish recording" : "Start recording",
                                systemImage: model.phase == .recording ? "stop.fill" : "mic.fill"
                            )
                            .font(.headline).padding(.horizontal, 10).padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.phase.isBusy && model.phase != .recording)
                        ShortcutRecorder(
                            binding: $model.settings.toggleShortcut, onChange: model.saveConfiguration,
                            onEditing: { model.isEditingShortcut = $0 })
                        Spacer()
                        if model.phase.isBusy {
                            Button("Cancel", action: model.cancelRecording).buttonStyle(.borderless)
                                .disabled(model.phase == .delivering)
                        }
                    }
                    AudioLevelView(level: model.recordingLevel, active: model.phase == .recording)
                    HStack {
                        Label(
                            model.microphoneName,
                            systemImage: "mic")
                        Spacer()
                        if model.phase == .recording {
                            Text(durationLabel(model.recordingDuration)).monospacedDigit()
                        } else {
                            Text("Click the shortcut to change it")
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                }
                if case .ready(let release) = model.updater.state, model.updater.postponed != release.version
                {
                    SettingsCard {
                        Label("Update ready", systemImage: "arrow.down.circle").font(.headline)
                        Text(
                            "Amanuensis \(release.version.description) has downloaded. Restart to finish updating."
                        )
                        .foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Button("Restart to update") { model.updater.installAndRelaunch() }
                                .buttonStyle(.borderedProminent).disabled(model.phase.isBusy)
                            if let notes = release.notesURL { Link("What's new", destination: notes) }
                            Button("Later") { model.updater.postponed = release.version }.buttonStyle(
                                .borderless)
                        }
                    }
                }
                if !model.appleSpeechReady && model.currentMode.speechModelID == "apple-speech" {
                    SettingsCard {
                        Label("Set up Apple speech", systemImage: "arrow.down.circle").font(.headline)
                        Text(
                            "Prepare English speech recognition on this Mac. macOS may need to download language assets."
                        )
                        .foregroundStyle(.secondary)
                        if model.appleSpeech.isPreparing {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Preparing speech recognition…").font(.callout).foregroundStyle(
                                    .secondary)
                            }
                        } else {
                            Button("Prepare speech recognition") { Task { await model.prepareAppleSpeech() } }
                                .disabled(model.phase.isBusy)
                        }
                    }
                }
                if !model.accessibilityGranted {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "keyboard").font(.title2).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Put words where you're working").font(.headline)
                            Text(
                                "Allow Accessibility access to insert text into other apps. You can always copy a result from History."
                            )
                            .foregroundStyle(.secondary)
                            Button("Enable text insertion", action: model.requestAccessibility).buttonStyle(
                                .link)
                        }
                    }.padding(4)
                }
                HStack(spacing: 16) {
                    quickLink(
                        "Shape your writing", subtitle: "Choose a mode for the moment.",
                        symbol: "slider.horizontal.3", section: .modes)
                    quickLink(
                        "Make it your vocabulary", subtitle: "Names, terms, and replacements.",
                        symbol: "text.book.closed", section: .vocabulary)
                }
            }.padding(28).frame(maxWidth: 960).frame(maxWidth: .infinity)
        }
    }

    private func metric(_ value: String, unit: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(unit).font(.callout).foregroundStyle(.secondary)
            }
            Text(label).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
    }

    private func quickLink(_ title: String, subtitle: String, symbol: String, section: AppSection)
        -> some View
    {
        Button {
            model.selectedSection = section
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol).font(.title3).foregroundStyle(.tint)
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain)
    }
}
