import AppKit
import SwiftUI

/// The catalog, one purpose at a time, narrowed by where models run, a language and a search, in catalog,
/// size or measured speed order. Each row states facts that differ between models and offers what can
/// be done with it now: download, connect, try, or use in a mode.
struct ModelsView: View {
    @Bindable var model: AppModel
    @State private var options = ModelListOptions()
    @State private var selectedAPI: ModelDescriptor?
    @State private var pendingRemoval: ModelDescriptor?
    @State private var operationError: String?
    /// Built when Apple Speech's languages arrive rather than on every render: sorting language names
    /// is slow, and download progress renders this screen several times a second.
    @State private var languageCodes: [String] = []
    @State private var languageBadges: [String: (title: String, help: String)] = [:]

    var body: some View {
        let readiness = model.readiness
        let models = model.catalogModels(for: options.purpose)
        let speeds = models.reduce(into: [String: Double]()) { speeds, item in
            speeds[item.id] = model.secondsPer30(item)
        }
        let rows = options.apply(to: models, readiness: readiness, speeds: speeds)
        let usedBy = modeNames()
        VStack(alignment: .leading, spacing: 16) {
            ScreenHeader(title: "Models", subtitle: "Choose what listens. Choose what edits.")

            HStack {
                Picker("Purpose", selection: $options.purpose) {
                    Text("Speech").tag(ModelPurpose.speech)
                    Text("Cleanup").tag(ModelPurpose.cleanup)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                Text(
                    rows.count == models.count
                        ? "\(models.count) models" : "\(rows.count) of \(models.count) models"
                )
                .font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search models or providers", text: $options.search)
                    .textFieldStyle(.plain)
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

            // One line when the window is wide enough, else the menus go under the chips.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    placeChips
                    Spacer(minLength: 12)
                    listMenus
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) { placeChips }
                    HStack(spacing: 6) { listMenus }
                }
            }
            .font(.callout)

            if model.settings.requireLocalProcessing {
                HStack(spacing: 10) {
                    Image(systemName: "lock.shield").foregroundStyle(.tint)
                    Text("Local processing is on.")
                        .fontWeight(.medium)
                    Text("API models won't be used for dictation.")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .font(.callout)
                .padding(12)
                .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }

            if let operationError {
                HStack(alignment: .top) {
                    Label(operationError, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button {
                        self.operationError = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss error")
                }
                .font(.callout)
            }

            if rows.isEmpty {
                ContentUnavailableView(
                    "No models match", systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Change the filters or the search.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { descriptor in
                            modelRow(
                                descriptor, readiness: readiness, usedBy: usedBy[descriptor.id] ?? [],
                                speed: speeds[descriptor.id])
                            Divider().padding(.leading, 62)
                        }
                    }
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
                }
            }

            Text(
                "Downloaded models stay available without a subscription. Model downloads require an internet connection."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .onChange(of: model.appleSpeech.locales, initial: true) {
            languageCodes = model.languageChoices(for: nil)
            languageBadges = model.library.models.reduce(into: [:]) { badges, item in
                badges[item.id] = languageBadge(item)
            }
        }
        .sheet(item: $selectedAPI) { descriptor in
            APIConfigurationSheet(model: model, descriptor: descriptor)
        }
        .alert(
            "Remove downloaded model?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
            Button("Remove", role: .destructive) {
                if let descriptor = pendingRemoval {
                    Task {
                        do { try await model.removeModel(descriptor) } catch {
                            operationError = error.localizedDescription
                        }
                    }
                }
                pendingRemoval = nil
            }
        } message: {
            Text(
                "\(pendingRemoval?.name ?? "This model") will need to be downloaded or imported again before modes using it can run. Existing transcripts are kept."
            )
        }
    }

    private var placeChips: some View {
        ForEach(ModelListOptions.Place.allCases, id: \.self) { place in
            FilterChip(title: place.rawValue, isOn: options.place == place) { options.place = place }
        }
    }

    /// The language filter, for speech only, and the order.
    @ViewBuilder private var listMenus: some View {
        if options.purpose == .speech {
            Picker("Language", selection: $options.language) {
                Text("Any language").tag(String?.none)
                Divider()
                ForEach(languageCodes, id: \.self) { code in
                    Text(SpeechLanguage.name(of: code)).tag(Optional(code))
                }
            }
            .fixedSize()
        }
        Picker("Sort", selection: $options.order) {
            ForEach(ModelListOptions.Order.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .fixedSize()
    }

    /// Mode names by the model IDs they use, for "Used by".
    private func modeNames() -> [String: [String]] {
        model.modes.reduce(into: [:]) { names, mode in
            for id in Set([mode.speechModelID, mode.cleanupModelID].compactMap { $0 }) {
                names[id, default: []].append(mode.name)
            }
        }
    }

    /// "English", "25 languages" with the names as help, or who decides when the catalog has no list.
    private func languageBadge(_ descriptor: ModelDescriptor) -> (title: String, help: String) {
        let codes =
            descriptor.engine == .apple
            ? model.appleSpeech.locales.map { Array($0.keys) } : descriptor.languages
        guard let codes else {
            return ("macOS languages", "macOS decides which languages Apple Speech transcribes on this Mac.")
        }
        if codes.isEmpty {
            return ("Provider's languages", "The provider decides which languages this model handles.")
        }
        let names = SpeechLanguage.sortedByName(codes).map(SpeechLanguage.name(of:))
        let list = names.formatted(.list(type: .and))
        return codes.count == 1 ? (list, list) : ("\(codes.count) languages", list)
    }

    private func modelRow(
        _ descriptor: ModelDescriptor, readiness: RecordingReadiness, usedBy: [String], speed: Double?
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: descriptor.purpose == .speech ? "waveform" : "text.badge.checkmark")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(descriptor.purpose == .speech ? Color.accentColor : Color.purple)
                .frame(width: 34, height: 38)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(descriptor.name).font(.system(size: 14, weight: .semibold))
                    if let badge = languageBadges[descriptor.id] {
                        Text(badge.title)
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                            .help(badge.help)
                    }
                    Spacer(minLength: 8)
                    status(descriptor)
                }
                Text(descriptor.summary)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Text(descriptor.provider)
                    Label(
                        descriptor.isLocal ? "On this Mac" : "API",
                        systemImage: descriptor.isLocal ? "desktopcomputer" : "cloud")
                    if let size = descriptor.sizeLabel, !size.isEmpty { Text(size) }
                    if descriptor.location == .cloud, let chosen = descriptor.apiModelID {
                        Text(chosen).font(.system(.caption, design: .monospaced))
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                actions(descriptor, readiness: readiness)
                    .padding(.top, 2)
                // Everything that comes and goes sits below the buttons: Used by after the first
                // assignment, speed after the first measurement, progress and the Try it result. So none
                // of them moves a button under the pointer.
                if !usedBy.isEmpty {
                    Label(
                        "Used by \(usedBy.formatted(.list(type: .and)))", systemImage: "slider.horizontal.3"
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                if let speed {
                    Label(
                        TranscriptionSpeed.label(secondsPer30: speed, isAPI: descriptor.location == .cloud),
                        systemImage: "stopwatch"
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                if descriptor.location == .local {
                    ModelDownloadStatus(
                        name: descriptor.name, progress: model.library.progress[descriptor.id],
                        resumable: model.library.resumable(descriptor.id),
                        error: model.library.errors[descriptor.id],
                        onCancel: { model.library.cancelDownload(descriptor.id) })
                }
                trialResult(descriptor)
            }
        }
        .padding(16)
    }

    /// The state on the right of a row's name: installed with its options, connected, or ready.
    @ViewBuilder private func status(_ descriptor: ModelDescriptor) -> some View {
        switch descriptor.location {
        case .local where model.library.installedModelIDs.contains(descriptor.id):
            HStack(spacing: 8) {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
                Menu {
                    Button("Show in Finder") {
                        if let url = model.library.localURL(for: descriptor.id) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                    Button("Remove model", role: .destructive) { pendingRemoval = descriptor }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 20)
                .accessibilityLabel("Options for \(descriptor.name)")
            }
        case .cloud
        where model.connectedProviders.contains(descriptor.engine) && descriptor.apiModelID != nil:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .system where !model.appleSpeech.readyLanguages.isEmpty:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
                .help(
                    "Prepared for "
                        + SpeechLanguage.sortedByName(model.appleSpeech.readyLanguages)
                        .map(SpeechLanguage.name(of:)).formatted(.list(type: .and)))
        default:
            EmptyView()
        }
    }

    /// What can be done with the model now, else what it needs: a download, a connection or preparation.
    /// Try it records in the Settings language, so it needs the model ready for that language. Use in
    /// mode appears when the model is ready for it, or when some mode's own language makes it ready, such
    /// as Apple Speech prepared for an English mode while Settings is French; its items judge each mode.
    @ViewBuilder
    private func actions(_ descriptor: ModelDescriptor, readiness: RecordingReadiness) -> some View {
        let language = model.settings.language
        let ready = readiness.availability(of: descriptor, language: language) == .ready
        let usable =
            ready
            || model.modes.contains {
                readiness.blocker(for: descriptor, language: model.language(for: $0)) == nil
            }
        HStack(spacing: 8) {
            switch descriptor.location {
            case .local where !model.library.installedModelIDs.contains(descriptor.id):
                downloadButtons(descriptor)
            case .cloud:
                let connected =
                    model.connectedProviders.contains(descriptor.engine) && descriptor.apiModelID != nil
                Button(connected ? "Configure" : "Connect") { selectedAPI = descriptor }
            case .system:
                appleSpeechPreparation()
            default:
                EmptyView()
            }
            if ready && descriptor.purpose == .speech {
                let blocker = readiness.blocker(for: descriptor, language: language)
                Button("Try it", systemImage: "mic") { model.tryModel(descriptor) }
                    .disabled(model.phase.isBusy || blocker != nil)
                    .help(
                        blocker?.errorDescription
                            ?? "Record a short test in \(language.name) with no cleanup or paste.")
            }
            if usable {
                Menu("Use in mode") {
                    UseInModeItems(model: model, descriptor: descriptor, readiness: readiness)
                }
                .fixedSize()
            }
        }
        .controlSize(.small)
    }

    /// Download or Retry, which stays in place, disabled, while the download runs; Cancel sits with the
    /// progress below. The chevron imports a copy from disk instead.
    @ViewBuilder private func downloadButtons(_ descriptor: ModelDescriptor) -> some View {
        let progress = model.library.progress[descriptor.id]
        // Retry only continues kept bytes; a failed import must not turn into a download offer.
        let retry = model.library.resumable(descriptor.id) != nil
        Button(retry ? "Retry" : "Download", systemImage: "arrow.down") {
            operationError = nil
            // Failures show under the row, from the library, like every other download row.
            Task { await model.download(descriptor) }
        }
        .disabled(progress != nil)
        Menu {
            Button("Import existing model…") { importModel(descriptor) }
        } label: {
            Image(systemName: "chevron.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 18)
        .disabled(progress != nil)
        .accessibilityLabel("Import \(descriptor.name)")
    }

    /// Apple Speech's assets are per language. Offer the languages modes record in that still need them.
    @ViewBuilder private func appleSpeechPreparation() -> some View {
        if let preparing = model.appleSpeech.preparingLanguage {
            ProgressView().controlSize(.small)
            Text("Preparing \(SpeechLanguage.name(of: preparing))").font(.caption).foregroundStyle(.secondary)
        } else if let needed = model.appleSpeechLanguagesToPrepare.first {
            Button("Prepare \(SpeechLanguage.name(of: needed))") {
                Task { await model.prepareAppleSpeech(language: needed) }
            }
            .disabled(model.phase.isBusy)
            .help("Download \(SpeechLanguage.name(of: needed)) speech assets through macOS")
        }
    }

    /// The model's Try it run: its phase with Stop while it records, then the transcript and how long
    /// transcription took, read from the History entry.
    @ViewBuilder private func trialResult(_ descriptor: ModelDescriptor) -> some View {
        if let trial = model.trial, trial.modelID == descriptor.id {
            if model.isTrialRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("\(model.phase.rawValue)…").font(.caption).foregroundStyle(.secondary)
                    if model.phase == .recording {
                        Button("Stop") { model.stopRecording() }.controlSize(.small)
                    }
                }
            } else if let entry = model.history.first(where: { $0.id == trial.recordingID }) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        switch entry.status {
                        case .complete, .empty:
                            Text("“\(entry.preview)”").font(.callout).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        case .noSpeech:
                            Text("No speech detected.").font(.callout).foregroundStyle(.secondary)
                        default:
                            Label(entry.error ?? "Couldn't finish.", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let seconds = entry.transcriptionSeconds {
                            Text(
                                "Transcribed \(TranscriptionSpeed.format(entry.duration)) of audio in \(TranscriptionSpeed.format(seconds))."
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    Button {
                        model.dismissTrial()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Dismiss test result")
                }
                .padding(10)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func importModel(_ descriptor: ModelDescriptor) {
        let panel = NSOpenPanel()
        panel.title = "Import \(descriptor.name)"
        panel.message =
            descriptor.engine == .s1mini
            ? "Choose the official S1-mini Q4_K_M GGUF file. Amanuensis keeps its own copy."
            : "Choose a complete supported model folder, including weights and tokenizer. Amanuensis keeps its own copy."
        panel.canChooseFiles = descriptor.engine == .s1mini
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        operationError = nil
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do { try await model.library.importModel(descriptor, from: url) } catch {
                if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                    operationError = error.localizedDescription
                }
            }
        }
    }
}

/// The modes a ready model can be assigned to, for its Use in mode menu. A mode whose language the
/// model cannot handle, or for which it is not ready, is listed with the reason and cannot be chosen,
/// so the menu never creates a mode that cannot record.
struct UseInModeItems: View {
    let model: AppModel
    let descriptor: ModelDescriptor
    let readiness: RecordingReadiness

    var body: some View {
        ForEach(model.modes) { mode in
            let language = model.language(for: mode)
            let current = descriptor.purpose == .speech ? mode.speechModelID : mode.cleanupModelID
            if current == descriptor.id {
                Button(mode.name, systemImage: "checkmark") {}
            } else if let blocker = readiness.blocker(for: descriptor, language: language) {
                let reason: String =
                    if case .unsupportedLanguage = blocker { language.unsupportedLabel } else {
                        blocker.shortReason
                    }
                Button("\(mode.name) · \(reason)") {}.disabled(true)
            } else {
                Button(mode.name) { model.use(descriptor, in: mode.id) }
            }
        }
    }
}

/// One choice in a row of filters, filled while it is selected.
private struct FilterChip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 10).padding(.vertical, 4)
                .foregroundStyle(isOn ? Color.accentColor : Color.primary)
                .background(
                    isOn ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08), in: Capsule()
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
