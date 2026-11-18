import SwiftUI

/// Connects one API row: the provider's key, an OpenAI-compatible server's base URL, and the model ID
/// the row calls. Providers that answer `GET /models` fill a picker beside the model field; the field
/// itself always stays, as the fallback when the list fails or is empty.
struct APIConfigurationSheet: View {
    @Bindable var model: AppModel
    let descriptor: ModelDescriptor
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @State private var baseURL: String
    @State private var modelID: String
    @State private var isTesting = false
    @State private var message: String?
    @State private var testSucceeded = false
    /// The fetched model list. Changing the address clears it, so it never describes another server.
    @State private var listing: Listing = .idle
    /// The newest list request. An older answer, such as a 401 for a key since corrected, is dropped.
    @State private var listRequest: UUID?

    private enum Listing {
        case idle, loading
        case loaded([String])
        case failed(String)
    }

    /// The entries start from settings here rather than on appear, so filling them is not an edit that
    /// clears the list.
    init(model: AppModel, descriptor: ModelDescriptor) {
        self.model = model
        self.descriptor = descriptor
        _modelID = State(
            initialValue: model.settings.apiModelOverrides[descriptor.id] ?? descriptor.apiModelID ?? "")
        let compatible = descriptor.engine == .openAICompatible
        _baseURL = State(initialValue: compatible ? model.settings.compatibleBaseURL ?? "" : "")
    }

    private var isCompatible: Bool { descriptor.engine == .openAICompatible }
    /// OpenAI, Groq and compatible servers share the OpenAI `/models` endpoint.
    private var canList: Bool { [.openAI, .groq, .openAICompatible].contains(descriptor.engine) }
    private var connected: Bool { model.connectedProviders.contains(descriptor.engine) }
    private var defaultModelID: String? { descriptor.apiModelID }
    private var trimmedModelID: String { modelID.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// The parsed base URL for a compatible server, or the problem with what is typed.
    private var server: Result<URL, APIBaseURL.Problem>? { isCompatible ? APIBaseURL.parse(baseURL) : nil }
    private var serverURL: URL? { try? server?.get() }
    /// A list can be asked for: a fixed host, or a compatible address that parses.
    private var canLoadList: Bool { !isCompatible || serverURL != nil }
    private var canSubmit: Bool {
        guard !isTesting, !trimmedModelID.isEmpty else { return false }
        return isCompatible ? serverURL != nil : connected || !apiKey.isEmpty
    }
    private var listedModels: [String] {
        if case .loaded(let ids) = listing { ids } else { [] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: isCompatible ? "server.rack" : "key.fill").font(.title2).foregroundStyle(
                    .tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(descriptor.name).font(.title2.weight(.semibold))
                    Text(descriptor.summary).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Form {
                if isCompatible {
                    TextField("Base URL", text: $baseURL, prompt: Text("https://api.example.com/v1"))
                        .autocorrectionDisabled()
                        .textContentType(.URL)
                }
                SecureField(
                    isCompatible ? "API key (optional)" : "\(descriptor.provider) API key", text: $apiKey,
                    prompt: Text(keyPrompt)
                )
                .textContentType(.password)
                LabeledContent("Model") {
                    HStack(spacing: 8) {
                        TextField("Model ID", text: $modelID, prompt: Text("Model ID"))
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing).labelsHidden()
                        // Before the list button, so that button never moves when this appears.
                        if let defaultModelID, trimmedModelID != defaultModelID {
                            Button("Use default") { modelID = defaultModelID }.buttonStyle(.link)
                                .help("Use \(defaultModelID)")
                        }
                        if canList { modelMenu }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: isCompatible ? 150 : 130)
            .disabled(isTesting)

            VStack(alignment: .leading, spacing: 6) {
                if case .failure(let problem)? = server, !baseURL.isEmpty {
                    Label(problem.message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if canList, let status = listStatus {
                    Text(status).foregroundStyle(.secondary)
                }
                Text(explanation).foregroundStyle(.secondary)
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)

            if let message {
                Label(message, systemImage: testSucceeded ? "checkmark.circle" : "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(testSucceeded ? Color.green : Color.orange)
                    .textSelection(.enabled)
            }

            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if connected {
                    Button(isCompatible ? "Remove server" : "Remove key", role: .destructive) { remove() }
                        .disabled(isTesting)
                }
                Spacer()
                if isTesting { ProgressView().controlSize(.small) }
                Button("Check model") { testConnection() }.disabled(!canSubmit)
                Button("Save") { saveAndClose() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding(28)
        .frame(width: 560)
        .interactiveDismissDisabled(isTesting)
        .onChange(of: baseURL) {
            listing = .idle
            listRequest = nil
        }
        .onAppear {
            // Only a saved key or address is used without asking; typed entries wait for Load.
            if canList && connected { loadModels() }
        }
    }

    /// Always in the same place. Its items are the fetched IDs, plus loading them again.
    private var modelMenu: some View {
        Menu {
            ForEach(listedModels, id: \.self) { id in
                Button(id) { modelID = id }
            }
            if !listedModels.isEmpty { Divider() }
            Button(listedModels.isEmpty ? "Load models from server" : "Reload list") { loadModels() }
                .disabled(!canLoadList)
        } label: {
            Image(systemName: "list.bullet")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose from the models the server lists")
        .accessibilityLabel("Choose a model")
    }

    private var keyPrompt: String {
        if isCompatible { return "Leave blank if the server needs none" }
        return connected ? "Leave blank to keep the saved key" : "Paste your API key"
    }

    private var explanation: String {
        if isCompatible {
            return
                "The key is stored in macOS Keychain and sent only to this address. Changing the address removes a saved key unless you enter one. A server on this Mac still counts as an API for Require local processing. Checking verifies the server lists the model; it does not test transcription or cleanup."
        }
        return
            "Keys are stored in macOS Keychain and shared by every \(descriptor.provider) model. Checking saves an entered key and verifies the model is available. It does not test transcription, cleanup, or billing access."
    }

    /// What the picker has for the current entries, or nil before anything was asked.
    private var listStatus: String? {
        switch listing {
        case .idle: nil
        case .loading: "Loading models…"
        case .loaded(let ids):
            ids.isEmpty
                ? "The server listed no models. Type the model ID."
                : "\(ids.count) models listed. Choose one with the list button or type an ID."
        case .failed(let reason): "Couldn't load models: \(reason) Type the model ID."
        }
    }

    private func loadModels() {
        guard canLoadList else { return }
        let request = UUID()
        listRequest = request
        listing = .loading
        let server = serverURL
        let key = apiKey
        Task {
            let result: Listing
            do {
                let ids = try await model.listAPIModels(provider: descriptor.engine, server: server, key: key)
                result = .loaded(ids)
            } catch {
                result = .failed(error.localizedDescription)
            }
            // Only the newest request still running may show its answer; an address change cleared it.
            if listRequest == request { listing = result }
        }
    }

    private func saveAndClose() {
        do {
            if isCompatible {
                guard let serverURL else { return }
                try model.saveCompatibleServer(serverURL, key: apiKey)
            } else {
                let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty { try model.saveAPIKey(key, provider: descriptor.engine) }
            }
            model.settings.apiModelOverrides[descriptor.id] = trimmedModelID
            model.saveConfiguration()
            apiKey = ""
            dismiss()
        } catch {
            testSucceeded = false
            message = error.localizedDescription
        }
    }

    private func remove() {
        do {
            if isCompatible {
                try model.removeCompatibleServer()
                baseURL = ""
                message = "The server address and its key were removed."
            } else {
                try model.removeAPIKey(provider: descriptor.engine)
                message = "The \(descriptor.provider) key was removed from your Keychain."
            }
            apiKey = ""
            listing = .idle
            listRequest = nil
            testSucceeded = true
        } catch {
            testSucceeded = false
            message = error.localizedDescription
        }
    }

    /// A compatible server is checked with the entries as typed, without saving them. Keyed providers
    /// keep their earlier behavior: an entered key is saved first, then checked, and the field is
    /// cleared only when the check succeeds.
    private func testConnection() {
        isTesting = true
        message = nil
        Task {
            defer { isTesting = false }
            do {
                let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                if !isCompatible && !key.isEmpty { try model.saveAPIKey(key, provider: descriptor.engine) }
                message = try await model.validateAPI(
                    provider: descriptor.engine, modelID: trimmedModelID, server: serverURL,
                    key: isCompatible ? key : "")
                testSucceeded = true
                if !isCompatible { apiKey = "" }
            } catch {
                testSucceeded = false
                message = error.localizedDescription
            }
        }
    }
}
