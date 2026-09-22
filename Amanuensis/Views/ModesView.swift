import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ModesView: View {
    @Bindable var model: AppModel
    @State private var selectedID: UUID?
    @State private var deleting = false
    @State private var creating = false
    @State private var choosingApps = false
    @State private var choosingSymbol = false

    private var selected: DictationMode? { model.modes.first { $0.id == selectedID } }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Modes").font(.title2.weight(.semibold))
                    Button {
                        creating = true
                    } label: {
                        Label("Create mode", systemImage: "plus").frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                }
                .padding(16).padding(.top, 8)
                List(model.modes, selection: $selectedID) { mode in
                    HStack(spacing: 10) {
                        Image(systemName: mode.symbol).frame(width: 20).foregroundStyle(.tint)
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
                        .listRowSeparator(.hidden)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }.frame(minWidth: 200, idealWidth: 220, maxWidth: 260)
                .background(Color(nsColor: .windowBackgroundColor))
            if let selected {
                editor(selected)
            } else {
                ContentUnavailableView(
                    "Make words fit the moment", systemImage: "slider.horizontal.3",
                    description: Text("Select a mode or create one for your workflow."))
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { if selectedID == nil { selectedID = model.currentMode.id } }
        .sheet(isPresented: $creating) {
            CreateModeSheet { name, symbol in
                selectedID = model.createMode(name: name, symbol: symbol)
            }
        }
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
                    HStack(spacing: 10) {
                        Button {
                            choosingSymbol = true
                        } label: {
                            Image(systemName: mode.symbol).font(.title3).frame(width: 34, height: 30)
                        }
                        .help("Change icon").accessibilityLabel("Change icon")
                        .popover(isPresented: $choosingSymbol) {
                            SymbolGrid(
                                selection: binding(mode, \.customSymbol).optional(default: mode.symbol)
                            )
                            .padding(16)
                        }
                        TextField("Name", text: binding(mode, \.name)).textFieldStyle(.roundedBorder)
                    }
                    Picker("Preset", selection: binding(mode, \.preset)) {
                        ForEach(ModePreset.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Text("The preset tells the cleanup model what kind of writing to shape.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    ToneSlider(tone: binding(mode, \.tone)).disabled(mode.cleanupModelID == nil)
                    Toggle("Turn spoken lists into bullet points", isOn: binding(mode, \.useLists))
                        .disabled(mode.cleanupModelID == nil)
                    Text(
                        mode.cleanupModelID == nil
                            ? "Choose a cleanup model below to apply tone and list formatting."
                            : "When you enumerate items, the cleanup model writes them as a list instead of a paragraph."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                SettingsCard {
                    modelPicker(
                        "Speech model", purpose: .speech,
                        selection: binding(mode, \.speechModelID).map(
                            to: { Optional($0) }, from: { $0 ?? "apple-speech" }),
                        allowNone: false)
                    modelPicker(
                        "Cleanup model", purpose: .cleanup, selection: binding(mode, \.cleanupModelID),
                        allowNone: true)
                    HStack(spacing: 6) {
                        Text("Only ready models are listed.").font(.caption).foregroundStyle(.secondary)
                        Button("Get more in Models") { model.selectedSection = .models }
                            .buttonStyle(.link).font(.caption)
                    }
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
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Activate for apps").font(.headline)
                            Text("Recording in one of these apps switches to this mode automatically.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Choose apps…", systemImage: "plus") { choosingApps = true }
                    }
                    .sheet(isPresented: $choosingApps) { AppPickerSheet(model: model, modeID: mode.id) }
                    if !mode.appBundleIDs.isEmpty {
                        Divider()
                        ForEach(mode.appBundleIDs, id: \.self) { appID in
                            HStack(spacing: 10) {
                                InstalledApp.icon(for: appID).resizable().frame(width: 22, height: 22)
                                Text(InstalledApp.name(for: appID)).lineLimit(1)
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
                        if !model.settings.automaticModeSelection {
                            HStack(spacing: 6) {
                                Text("Automatic mode selection is off, so these rules are paused.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("Turn on") { model.settings.automaticModeSelection = true }
                                    .buttonStyle(.link).font(.caption)
                            }
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
                    Text("Recording and insertion").font(.headline)
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
                    Text(
                        "Lower and mute use your output's macOS volume control. Some display and digital audio outputs do not support it."
                    )
                    .font(.caption).foregroundStyle(.secondary)
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

    /// Lists models that are ready to use, plus the current choice if it stopped being ready.
    private func modelPicker(
        _ title: String, purpose: ModelPurpose, selection: Binding<String?>, allowNone: Bool
    ) -> some View {
        let choices = model.availableModels(for: purpose, including: selection.wrappedValue)
        let current = choices.first { $0.id == selection.wrappedValue }
        return VStack(alignment: .leading, spacing: 6) {
            Picker(title, selection: selection) {
                if allowNone { Text("None · Keep the transcript").tag(String?.none) }
                ForEach(choices) { item in
                    Text(item.name + (item.location == .cloud ? " · API" : "")).tag(Optional(item.id))
                }
            }
            if let current, !model.isReady(current) {
                Label(
                    current.location == .cloud
                        ? "\(current.name) needs a \(current.provider) API key. Connect it in Models before recording."
                        : "\(current.name) is not installed. Download it in Models before recording.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption).foregroundStyle(.orange)
            } else if current?.family == .apple, !model.appleSpeechReady {
                Label("Apple Speech needs preparing in Models.", systemImage: "arrow.down.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
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
}

extension Binding {
    /// Views a binding through a pair of conversions.
    fileprivate func map<Other>(to: @escaping (Value) -> Other, from: @escaping (Other) -> Value)
        -> Binding<Other>
    {
        Binding<Other>(get: { to(wrappedValue) }, set: { wrappedValue = from($0) })
    }
}

extension Binding {
    /// Presents an optional as a non-optional value for pickers that always show something.
    fileprivate func optional<Wrapped>(default fallback: Wrapped) -> Binding<Wrapped>
    where Value == Wrapped? {
        Binding<Wrapped>(get: { wrappedValue ?? fallback }, set: { wrappedValue = $0 })
    }
}

/// Four tone stops from casual to formal, shown as a slider with the current stop highlighted.
struct ToneSlider: View {
    @Binding var tone: CleanupTone
    private let tones = CleanupTone.allCases

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Tone")
                Spacer()
                Text(tone.label).font(.callout.weight(.medium)).foregroundStyle(.tint)
            }
            Slider(
                value: Binding(
                    get: { Double(tones.firstIndex(of: tone) ?? 0) },
                    set: { tone = tones[Int($0.rounded())] }
                ),
                in: 0...Double(tones.count - 1), step: 1
            )
            .accessibilityLabel("Tone").accessibilityValue(tone.label)
            HStack {
                ForEach(tones) { stop in
                    Text(stop.label).font(.caption)
                        .foregroundStyle(stop == tone ? Color.primary : .secondary)
                        .frame(maxWidth: .infinity, alignment: alignment(for: stop))
                }
            }
        }
    }

    private func alignment(for stop: CleanupTone) -> Alignment {
        switch tones.firstIndex(of: stop) {
        case 0: .leading
        case tones.count - 1: .trailing
        default: .center
        }
    }
}

/// Icons a mode can use. Selection is stored as an SF Symbol name.
struct SymbolGrid: View {
    @Binding var selection: String
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(38), spacing: 6), count: 8), spacing: 6) {
            ForEach(DictationMode.symbolChoices, id: \.self) { symbol in
                Button {
                    selection = symbol
                } label: {
                    Image(systemName: symbol).font(.title3).frame(width: 38, height: 34)
                        .background(
                            selection == symbol ? Color.accentColor.opacity(0.18) : .clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8).strokeBorder(
                                selection == symbol ? Color.accentColor : .clear))
                }
                .buttonStyle(.plain).accessibilityLabel(symbol)
                .accessibilityAddTraits(selection == symbol ? .isSelected : [])
            }
        }
    }
}

private struct CreateModeSheet: View {
    var onCreate: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var symbol = "wand.and.stars"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Create a mode").font(.title2.weight(.semibold))
                Text("Name it for the moment it serves. You can choose models and apps next.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.title2).foregroundStyle(.tint).frame(width: 34)
                TextField("Mode name", text: $name).textFieldStyle(.roundedBorder).controlSize(.large)
                    .onSubmit(create)
            }
            SymbolGrid(selection: $symbol)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create mode", action: create).buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(28).frame(width: 420)
    }

    private func create() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onCreate(name, symbol)
        dismiss()
    }
}

/// An application on this Mac that a mode can activate for.
struct InstalledApp: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let path: String

    static func icon(for bundleID: String) -> Image {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return Image(systemName: "app.dashed")
        }
        return Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
    }

    static func name(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        return FileManager.default.displayName(atPath: url.path)
    }

    /// Apps in the usual folders plus anything currently running, without duplicates.
    static func scan() -> [InstalledApp] {
        let fileManager = FileManager.default
        var roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        roots.append(fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications"))
        var found: [String: InstalledApp] = [:]
        func add(_ url: URL) {
            guard url.pathExtension == "app", let identifier = Bundle(url: url)?.bundleIdentifier,
                found[identifier] == nil, identifier != Bundle.main.bundleIdentifier
            else { return }
            found[identifier] = InstalledApp(
                id: identifier, name: fileManager.displayName(atPath: url.path), path: url.path)
        }
        for root in roots {
            let items =
                (try? fileManager.contentsOfDirectory(
                    at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles))
                ?? []
            for item in items {
                if item.pathExtension == "app" {
                    add(item)
                } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    for nested
                        in (try? fileManager.contentsOfDirectory(
                            at: item, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
                    {
                        add(nested)
                    }
                }
            }
        }
        for running in NSWorkspace.shared.runningApplications where running.activationPolicy == .regular {
            if let url = running.bundleURL { add(url) }
        }
        return found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Picks the apps that switch to a mode. Apps assigned to another mode are shown but cannot be chosen.
private struct AppPickerSheet: View {
    @Bindable var model: AppModel
    let modeID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var apps: [InstalledApp] = []
    @State private var query = ""
    @State private var chosen: [String] = []
    @State private var loaded = false

    private var mode: DictationMode? { model.modes.first { $0.id == modeID } }
    private var takenElsewhere: [String: String] {
        var taken: [String: String] = [:]
        for other in model.modes where other.id != modeID {
            for appID in other.appBundleIDs { taken[appID] = other.name }
        }
        return taken
    }
    private var visible: [InstalledApp] {
        query.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Activate for apps").font(.title2.weight(.semibold))
                Text("Choose the apps where \(mode?.name ?? "this mode") should take over.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search apps", text: $query).textFieldStyle(.plain)
            }
            .padding(9).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
            if !loaded {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }.frame(maxHeight: .infinity)
            } else {
                List(visible) { app in
                    let owner = takenElsewhere[app.id]
                    let isChosen = chosen.contains(app.id)
                    Button {
                        if isChosen { chosen.removeAll { $0 == app.id } } else { chosen.append(app.id) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable()
                                .frame(width: 26, height: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name).lineLimit(1)
                                if let owner {
                                    Text("Used by \(owner)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isChosen ? Color.accentColor : Color.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(owner != nil)
                    .accessibilityAddTraits(isChosen ? .isSelected : [])
                }
                .listStyle(.inset).scrollContentBackground(.hidden)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Other…") { chooseFromDisk() }.help("Choose an app that is not listed")
                Spacer()
                Text("\(chosen.count) selected").font(.caption).foregroundStyle(.secondary)
                Button("Done") {
                    if var updated = mode {
                        updated.appBundleIDs = chosen
                        model.updateMode(updated)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 480, height: 540)
        .task {
            chosen = mode?.appBundleIDs ?? []
            apps = await Task.detached(priority: .userInitiated) { InstalledApp.scan() }.value
            loaded = true
        }
    }

    /// Apps outside the scanned folders can still be picked from anywhere on disk.
    private func chooseFromDisk() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Choose"
        panel.message = "Choose apps that should switch to this mode."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let identifier = Bundle(url: url)?.bundleIdentifier else { continue }
            if !apps.contains(where: { $0.id == identifier }) {
                apps.append(
                    InstalledApp(
                        id: identifier, name: FileManager.default.displayName(atPath: url.path),
                        path: url.path))
                apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
            if takenElsewhere[identifier] == nil, !chosen.contains(identifier) { chosen.append(identifier) }
        }
        query = ""
    }
}
