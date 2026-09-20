import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ModesView: View {
    @Bindable var model: AppModel
    @State private var selectedID: UUID?
    @State private var deleting = false

    private var selected: DictationMode? { model.modes.first { $0.id == selectedID } }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Modes").font(.title2.weight(.semibold))
                    Spacer()
                    Menu {
                        ForEach(ModePreset.allCases) { preset in
                            Button(preset.rawValue, systemImage: preset.symbol) {
                                selectedID = model.createMode(preset: preset)
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }.menuStyle(.borderlessButton).fixedSize()
                        .accessibilityLabel("Create mode")
                }.padding(.horizontal, 16).padding(.top, 24)
                List(model.modes, selection: $selectedID) { mode in
                    HStack(spacing: 10) {
                        Image(systemName: mode.preset.symbol).frame(width: 20).foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(mode.name).fontWeight(.medium)
                            Text(
                                ModelCatalog.models.first { $0.id == mode.speechModelID }?.name
                                    ?? mode.speechModelID
                            )
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 2)
                        if model.currentMode.id == mode.id {
                            Circle().fill(.green).frame(width: 6, height: 6).accessibilityLabel("Active mode")
                        }
                    }.padding(.vertical, 6).tag(mode.id)
                }.listStyle(.sidebar)
            }.frame(minWidth: 190, idealWidth: 210, maxWidth: 250)
            if let selected {
                editor(selected)
            } else {
                ContentUnavailableView(
                    "Make words fit the moment", systemImage: "slider.horizontal.3",
                    description: Text("Select a mode or create one for your workflow."))
            }
        }
        .onAppear { if selectedID == nil { selectedID = model.currentMode.id } }
    }

    private func editor(_ mode: DictationMode) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    ScreenHeader(title: mode.name, subtitle: "Your voice, with the right finishing touches.")
                    if model.currentMode.id != mode.id {
                        Button("Use mode") { model.selectMode(mode.id) }.buttonStyle(.borderedProminent)
                            .disabled(model.phase.isBusy)
                    } else {
                        Text("Active").font(.caption.weight(.medium)).foregroundStyle(.green)
                    }
                }
                SettingsCard {
                    TextField("Name", text: binding(mode, \.name)).textFieldStyle(.roundedBorder)
                    Picker("Preset", selection: binding(mode, \.preset)) {
                        ForEach(ModePreset.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Tone", selection: binding(mode, \.tone)) {
                        ForEach(CleanupTone.allCases) { Text($0.label).tag($0) }
                    }
                    .disabled(mode.cleanupModelID == nil)
                    Toggle("Format as a list", isOn: binding(mode, \.useLists))
                        .disabled(mode.cleanupModelID == nil)
                    if mode.cleanupModelID == nil {
                        Text("Choose a cleanup model below to apply tone and formatting.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                SettingsCard {
                    Picker("Speech model", selection: binding(mode, \.speechModelID)) {
                        ForEach(ModelCatalog.models.filter { $0.purpose == .speech }) { item in
                            Text(item.name + (item.isLocal ? "" : " · API")).tag(item.id)
                        }
                    }
                    Picker("Cleanup model", selection: binding(mode, \.cleanupModelID)) {
                        Text("None · Keep the transcript").tag(String?.none)
                        ForEach(ModelCatalog.models.filter { $0.purpose == .cleanup && $0.family != .ollama })
                        { item in
                            Text(item.name + (item.isLocal ? "" : " · API")).tag(Optional(item.id))
                        }
                    }
                    Text(
                        "Download local models or connect an API in Models. A model must be ready before recording."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    if mode.preset == .custom {
                        if ModelCatalog.models.first(where: { $0.id == mode.cleanupModelID })?.family
                            == .s1mini
                        {
                            Text(
                                "S1-mini uses tone, list formatting, and email context. Custom instructions require an OpenAI or Claude cleanup model."
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        } else if ModelCatalog.models.first(where: { $0.id == mode.cleanupModelID })?.location
                            == .cloud
                        {
                            Text("Cleanup instructions").font(.caption.weight(.medium))
                            TextEditor(text: binding(mode, \.customPrompt)).font(.body).frame(minHeight: 85)
                                .padding(6).overlay(
                                    RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                        } else {
                            Text("Choose an OpenAI or Claude cleanup model to add custom instructions.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                SettingsCard {
                    HStack {
                        Text("Activate for apps").font(.headline)
                        Spacer()
                        Button("Add app", systemImage: "plus") { addApplication(to: mode) }
                    }
                    if mode.appBundleIDs.isEmpty {
                        Text("Choose apps where this mode should activate automatically.").font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(mode.appBundleIDs, id: \.self) { appID in
                        HStack {
                            Text(applicationName(appID)).lineLimit(1)
                            Spacer()
                            Button {
                                var updated = mode
                                updated.appBundleIDs.removeAll { $0 == appID }
                                model.updateMode(updated)
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless).accessibilityLabel("Remove app rule for \(appID)")
                        }
                    }
                }
                SettingsCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Recording shortcut").font(.headline)
                            Text("Press to start or finish a recording in this mode.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        OptionalShortcutRecorder(
                            binding: binding(mode, \.startShortcut),
                            onChange: model.saveConfiguration,
                            onEditing: { model.isEditingShortcut = $0 }
                        )
                    }
                }
                SettingsCard {
                    DisclosureGroup("Recording and insertion") {
                        VStack(alignment: .leading, spacing: 16) {
                            Toggle("Capitalize the first word", isOn: binding(mode, \.capitalize))
                            Toggle("Paste into the active app", isOn: binding(mode, \.autoPaste))
                            Toggle("Include system audio", isOn: binding(mode, \.recordSystemAudio))
                            Text(
                                "System audio requires screen recording permission. Speaker identification is not available yet."
                            )
                            .font(.caption).foregroundStyle(.secondary)
                            Picker("Playback while recording", selection: binding(mode, \.playback)) {
                                ForEach([PlaybackBehavior.keepPlaying, .lower, .mute], id: \.self) {
                                    Text($0.rawValue).tag($0)
                                }
                            }
                            Text("Lower and mute require an output device with volume control.").font(
                                .caption
                            ).foregroundStyle(.secondary)
                        }.padding(.top, 14)
                    }
                }
                Button("Delete mode", role: .destructive) { deleting = true }.disabled(model.modes.count <= 1)
                    .confirmationDialog(
                        "Delete \(mode.name)?", isPresented: $deleting, titleVisibility: .visible
                    ) {
                        Button("Delete mode", role: .destructive) {
                            model.deleteMode(mode.id)
                            selectedID = model.modes.first?.id
                        }
                    }
            }.padding(24)
        }.frame(minWidth: 380)
    }

    private func binding<Value>(_ mode: DictationMode, _ keyPath: WritableKeyPath<DictationMode, Value>)
        -> Binding<Value>
    {
        Binding(
            get: { (model.modes.first { $0.id == mode.id } ?? mode)[keyPath: keyPath] },
            set: { value in
                var updated = model.modes.first { $0.id == mode.id } ?? mode
                updated[keyPath: keyPath] = value
                model.updateMode(updated)
            })
    }

    private func addApplication(to mode: DictationMode) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Add application"
        panel.message = "Use this mode when dictating into these apps."
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var updated = mode
        for url in panel.urls {
            guard let identifier = Bundle(url: url)?.bundleIdentifier else { continue }
            guard !model.modes.contains(where: { $0.id != mode.id && $0.appBundleIDs.contains(identifier) })
            else {
                model.errorMessage =
                    "This app is already assigned to another mode. Remove that assignment first."
                continue
            }
            if !updated.appBundleIDs.contains(identifier) { updated.appBundleIDs.append(identifier) }
        }
        model.updateMode(updated)
    }

    private func applicationName(_ identifier: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)?.deletingPathExtension()
            .lastPathComponent ?? identifier
    }
}
