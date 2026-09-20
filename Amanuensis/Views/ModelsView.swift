import AppKit
import SwiftUI

struct ModelsView: View {
    @Bindable var model: AppModel
    @State private var query = ""
    @State private var filter: LibraryFilter = .all
    @State private var selectedAPI: ModelDescriptor?
    @State private var pendingRemoval: ModelDescriptor?
    @State private var operationError: String?
    @State private var whisperExpanded = false

    private enum LibraryFilter: String, CaseIterable {
        case all = "All models"
        case local = "Local"
        case installed = "Installed"
        case api = "API"
        case speech = "Speech"
        case cleanup = "Cleanup"
    }

    private var filteredModels: [ModelDescriptor] {
        model.library.models.filter { descriptor in
            guard descriptor.family != .ollama else { return false }
            let matchesFilter =
                switch filter {
                case .all: true
                case .local: descriptor.isLocal
                case .installed: model.library.localURL(for: descriptor.id) != nil
                case .api: descriptor.location == .cloud
                case .speech: descriptor.purpose == .speech
                case .cleanup: descriptor.purpose == .cleanup
                }
            return matchesFilter
                && (query.isEmpty
                    || descriptor.name.localizedCaseInsensitiveContains(query)
                    || descriptor.provider.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ScreenHeader(title: "Models", subtitle: "Choose what listens. Choose what edits.")

            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search models or providers", text: $query)
                        .textFieldStyle(.plain)
                }
                .padding(11)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                if let api = model.library.models.first(where: { $0.location == .cloud }) {
                    Button {
                        selectedAPI = api
                    } label: {
                        Label("API settings", systemImage: "key")
                    }
                    .controlSize(.large)
                }
            }

            HStack {
                Picker("Filter models", selection: $filter) {
                    ForEach(LibraryFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented).labelsHidden()
                .frame(maxWidth: 490)
                Spacer()
                Text("\(filteredModels.count) models")
                    .font(.caption).foregroundStyle(.secondary)
            }

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

            if filteredModels.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredModels) { descriptor in
                            if descriptor.family == .whisper {
                                if descriptor.id == filteredModels.first(where: { $0.family == .whisper })?.id
                                {
                                    DisclosureGroup(
                                        isExpanded: Binding(
                                            get: { whisperExpanded || !query.isEmpty },
                                            set: { whisperExpanded = $0 }
                                        )
                                    ) {
                                        ForEach(filteredModels.filter { $0.family == .whisper }) { variant in
                                            modelRow(variant)
                                            Divider()
                                        }
                                    } label: {
                                        HStack(spacing: 14) {
                                            Image(systemName: "waveform").font(.title3).foregroundStyle(.tint)
                                                .frame(width: 34)
                                            VStack(alignment: .leading, spacing: 5) {
                                                Text("Whisper").font(.headline)
                                                Text(
                                                    "Choose a size and an English or multilingual checkpoint."
                                                )
                                                .font(.caption).foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            Text(
                                                "\(filteredModels.filter { $0.family == .whisper }.count) variants"
                                            )
                                            .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(16)
                                    Divider().padding(.leading, 62)
                                }
                            } else {
                                modelRow(descriptor)
                                Divider().padding(.leading, 62)
                            }
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
        .sheet(item: $selectedAPI) { descriptor in
            APIConfigurationSheet(model: model, initialDescriptor: descriptor)
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
                    do { try model.library.remove(descriptor) } catch {
                        operationError = error.localizedDescription
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

    private func modelRow(_ descriptor: ModelDescriptor) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: descriptor.purpose == .speech ? "waveform" : "text.badge.checkmark")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(descriptor.purpose == .speech ? Color.accentColor : Color.purple)
                .frame(width: 34, height: 38)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Text(descriptor.name).font(.system(size: 14, weight: .semibold))
                    Text(descriptor.purpose == .speech ? "SPEECH" : "CLEANUP")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 3)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                }
                Text(descriptor.summary)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Text(descriptor.provider)
                    Label(
                        descriptor.isLocal ? "On this Mac" : "API",
                        systemImage: descriptor.isLocal ? "desktopcomputer" : "cloud")
                    if !descriptor.sizeLabel.isEmpty { Text(descriptor.sizeLabel) }
                }
                .font(.caption).foregroundStyle(.tertiary)
                if let progress = model.library.progress[descriptor.id] {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                    Text(progress.label).font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.library.errors[descriptor.id] {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            modelActions(descriptor)
                .frame(minWidth: 102, alignment: .trailing)
                .padding(.top, 3)
        }
        .padding(16)
    }

    @ViewBuilder
    private func modelActions(_ descriptor: ModelDescriptor) -> some View {
        if descriptor.location == .cloud {
            Button("Configure") { selectedAPI = descriptor }
        } else if descriptor.location == .system {
            if model.appleSpeech.isPreparing {
                ProgressView().controlSize(.small)
                    .help("Preparing English speech assets")
            } else if model.appleSpeechReady {
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            } else {
                Button("Prepare") { Task { await model.prepareAppleSpeech() } }
                    .disabled(model.phase.isBusy)
                    .help("Download English speech assets through macOS")
            }
        } else if descriptor.family == .ollama {
            Text("Local server")
                .font(.caption).foregroundStyle(.secondary)
        } else if model.library.progress[descriptor.id] != nil {
            Button("Cancel") { model.library.cancelDownload(descriptor.id) }
        } else if model.library.localURL(for: descriptor.id) != nil {
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
                .frame(width: 20)
                .accessibilityLabel("Options for \(descriptor.name)")
            }
        } else {
            HStack(spacing: 5) {
                Button {
                    operationError = nil
                    Task {
                        do { try await model.library.install(descriptor) } catch {
                            if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                                operationError = error.localizedDescription
                            }
                        }
                    }
                } label: {
                    Label("Get", systemImage: "arrow.down")
                }
                Menu {
                    Button("Import existing model…") { importModel(descriptor) }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 18)
                .accessibilityLabel("Import \(descriptor.name)")
            }
        }
    }

    private func importModel(_ descriptor: ModelDescriptor) {
        let panel = NSOpenPanel()
        panel.title = "Import \(descriptor.name)"
        panel.message =
            descriptor.family == .s1mini
            ? "Choose the official S1-mini Q4_K_M GGUF file. Amanuensis keeps its own copy."
            : "Choose a complete supported model folder, including weights and tokenizer. Amanuensis keeps its own copy."
        panel.canChooseFiles = descriptor.family == .s1mini
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

private struct APIConfigurationSheet: View {
    @Bindable var model: AppModel
    let initialDescriptor: ModelDescriptor
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID = ""
    @State private var apiKey = ""
    @State private var modelID = ""
    @State private var isTesting = false
    @State private var message: String?
    @State private var testSucceeded = false

    private var apiModels: [ModelDescriptor] {
        model.library.models.filter { $0.location == .cloud }
    }

    private var selected: ModelDescriptor {
        apiModels.first { $0.id == selectedID } ?? initialDescriptor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Image(systemName: "key.fill").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connect a provider").font(.title2.weight(.semibold))
                    Text("Use your own API key and choose the model.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            Form {
                Picker("Model", selection: $selectedID) {
                    ForEach(apiModels) { descriptor in
                        Text("\(descriptor.provider) · \(descriptor.name)").tag(descriptor.id)
                    }
                }
                SecureField("API key", text: $apiKey, prompt: Text("Leave blank to keep the saved key"))
                    .textContentType(.password)
                TextField("API model ID", text: $modelID)
                    .autocorrectionDisabled()
            }
            .formStyle(.grouped)
            .frame(height: 180)
            .disabled(isTesting)

            Text(
                "Keys are stored in macOS Keychain and shared by this provider's models. Checking saves an entered key and verifies model availability. It does not test transcription, cleanup, or billing access."
            )
            .font(.caption).foregroundStyle(.secondary)
            if let message {
                Label(message, systemImage: testSucceeded ? "checkmark.circle" : "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(testSucceeded ? Color.green : Color.orange)
                    .textSelection(.enabled)
            }

            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if isTesting { ProgressView().controlSize(.small) }
                Button("Check model") { testConnection() }
                    .disabled(isTesting || modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Save") { saveAndClose() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isTesting || modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(28)
        .frame(width: 550)
        .interactiveDismissDisabled(isTesting)
        .onAppear {
            selectedID = initialDescriptor.id
            loadModelID()
        }
        .onChange(of: selectedID) {
            apiKey = ""
            message = nil
            loadModelID()
        }
    }

    private func loadModelID() {
        modelID = model.settings.apiModelOverrides[selected.id] ?? selected.apiModelID ?? selected.id
    }

    private func saveKey() throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { try model.saveAPIKey(key, provider: selected.family) }
    }

    private func saveAndClose() {
        do {
            try saveKey()
            model.settings.apiModelOverrides[selected.id] = modelID.trimmingCharacters(
                in: .whitespacesAndNewlines)
            model.saveConfiguration()
            apiKey = ""
            dismiss()
        } catch {
            testSucceeded = false
            message = error.localizedDescription
        }
    }

    private func testConnection() {
        isTesting = true
        message = nil
        Task {
            defer { isTesting = false }
            do {
                try saveKey()
                message = try await model.validateAPI(
                    provider: selected.family,
                    modelID: modelID.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                testSucceeded = true
                apiKey = ""
            } catch {
                testSucceeded = false
                message = error.localizedDescription
            }
        }
    }
}
