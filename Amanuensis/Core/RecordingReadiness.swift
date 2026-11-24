import Foundation

/// Facts about this Mac that decide whether a mode can record. AppModel fills one from live state, so
/// recording validation and the "Needs …" markers wherever a mode is chosen give the same answer.
struct RecordingReadiness: Sendable {
    var requireLocalProcessing: Bool
    var installedModelIDs: Set<String>
    var connectedProviders: Set<ModelFamily>
    /// Language codes whose Apple Speech assets are installed.
    var appleSpeechReadyLanguages: Set<String>
    /// Language codes Apple Speech supports on this Mac. Nil until macOS has answered at launch.
    var appleSpeechLanguages: Set<String>?
    var cleanupHelperAvailable: Bool

    /// Installed for local models. For API models, a connected provider (a saved key, or a base URL
    /// for an OpenAI-compatible server) and a model ID. System models are always present.
    func isAvailable(_ model: ModelDescriptor) -> Bool {
        switch model.location {
        case .system: true
        case .cloud:
            connectedProviders.contains(model.engine)
                && model.apiModelID?.trimmingCharacters(in: .whitespaces).isEmpty == false
        case .local: installedModelIDs.contains(model.id)
        }
    }

    /// Whether this speech model can transcribe the language. Apple Speech asks macOS, which cannot
    /// detect a language; until macOS answers, its languages are not held against a mode.
    func canTranscribe(_ language: SpeechLanguage, with model: ModelDescriptor) -> Bool {
        guard model.engine == .apple else { return model.declares(language) }
        guard let code = language.languageCode else { return false }
        return appleSpeechLanguages?.contains(code) ?? true
    }

    /// What stops this one model from running in this language, or nil when it can. A language the
    /// speech model cannot handle comes first, because installing or preparing it would not help.
    func blocker(for model: ModelDescriptor, language: SpeechLanguage) -> RecordingFailure? {
        if model.purpose == .speech && !canTranscribe(language, with: model) {
            return .unsupportedLanguage(modelName: model.name, language: language)
        }
        return setupBlocker(for: model, language: language)
    }

    /// Where pickers and the Models screen file a model: by what it needs before it can run, leaving
    /// language support aside, so a model that cannot do the language still shows where it stands.
    func availability(of model: ModelDescriptor, language: SpeechLanguage) -> ModelAvailability {
        switch setupBlocker(for: model, language: language) {
        case nil: .ready
        case .modelNotInstalled: .needsDownload
        case let reason?: .needsSetup(reason)
        }
    }

    /// Everything `blocker(for:language:)` checks except language support: what a download, a key,
    /// server setup, Require local processing, Apple Speech assets or the cleanup helper would fix.
    private func setupBlocker(for model: ModelDescriptor, language: SpeechLanguage) -> RecordingFailure? {
        if requireLocalProcessing && !model.isLocal { return .blockedByLocalOnly(modelName: model.name) }
        if !isAvailable(model) {
            guard model.location == .cloud else { return .modelNotInstalled(model.name) }
            // A compatible server's key is optional; what it lacks is its address or a model ID.
            return model.engine == .openAICompatible
                ? .providerNotSetUp(provider: model.provider) : .apiKeyMissing(provider: model.provider)
        }
        if model.engine == .apple, let code = language.languageCode, !appleSpeechReadyLanguages.contains(code)
        {
            return .appleSpeechNotReady(language: code)
        }
        if model.engine == .s1mini && !cleanupHelperAvailable { return .cleanupHelperMissing }
        return nil
    }

    /// The first thing a recording with these choices still needs, or nil when it can start.
    /// A missing speech model means the mode names one the catalog no longer has; so does a nil
    /// `cleanup` while the mode still names a `cleanupModelID`. A cleanup model that does not know the
    /// language only earns a warning in the mode editor, and one that is not set up only a `CleanupGap`.
    func blocker(
        speech: ModelDescriptor?, cleanup: ModelDescriptor?, cleanupModelID: String?,
        language: SpeechLanguage,
        identifySpeakers: Bool
    ) -> RecordingFailure? {
        guard let speech else { return .speechModelMissing }
        if let failure = blocker(for: speech, language: language)
            ?? (cleanup == nil && cleanupModelID != nil ? .cleanupModelMissing : nil)
            ?? cleanup.flatMap({ cleanupGap(for: $0) == nil ? blocker(for: $0, language: language) : nil })
        {
            return failure
        }
        return identifySpeakers ? .speakerIdentificationUnavailable : nil
    }

    /// What this cleanup model still needs, where a recording goes ahead without it. Nil when it can run,
    /// and when something else is wrong, such as Require local processing refusing an API: that blocks.
    func cleanupGap(for cleanup: ModelDescriptor) -> CleanupGap? {
        // Only Apple Speech's readiness depends on the language.
        CleanupGap(setupBlocker(for: cleanup, language: .automatic))
    }

    /// The modes a cleanup model would unlock, for setup's optional step.
    func modesAwaitingCleanup(
        _ modes: [DictationMode], cleanup: (DictationMode) -> ModelDescriptor?
    ) -> [DictationMode] {
        modes.filter { cleanup($0).flatMap(cleanupGap(for:)) != nil }
    }
}

/// Cleanup a mode asks for but that nobody has set up. Such a mode still records and delivers the plain
/// transcript, saying that cleanup was skipped. Nothing is sent anywhere instead.
enum CleanupGap: Equatable, Sendable {
    case notInstalled(String)
    case keyMissing(provider: String)
    case serverNotSetUp(provider: String)

    init?(_ failure: RecordingFailure?) {
        switch failure {
        case .modelNotInstalled(let name): self = .notInstalled(name)
        case .apiKeyMissing(let provider): self = .keyMissing(provider: provider)
        case .providerNotSetUp(let provider): self = .serverNotSetUp(provider: provider)
        default: return nil
        }
    }

    /// The short label beside a mode that records without its cleanup.
    var marker: String {
        switch self {
        case .notInstalled(let name): "Cleanup needs \(name)"
        case .keyMissing(let provider): "Cleanup needs \(provider) key"
        case .serverNotSetUp: "Cleanup needs server setup"
        }
    }

    /// What Home says under the mode before recording.
    var warning: String { "Records now, without cleanup: \(reason)." }
    /// What a recording made without its cleanup says afterwards, on Home and in History.
    var notice: String { "Cleanup was skipped because \(reason)." }

    private var reason: String {
        switch self {
        case .notInstalled(let name): "\(name) is not installed"
        case .keyMissing(let provider): "no \(provider) API key is saved"
        case .serverNotSetUp(let provider): "the \(provider) server is not set up"
        }
    }
}

/// What a model needs before a mode can record with it, as pickers and the Models screen group models.
enum ModelAvailability: Equatable, Sendable {
    case ready
    case needsDownload
    /// An API key, a server, Require local processing turned off, Apple Speech assets or the helper,
    /// with the reason recording would give.
    case needsSetup(RecordingFailure)
}

/// The system microphone permission. Restricted means an organization or Screen Time manages it,
/// so the user cannot turn it on in Privacy & Security.
enum MicrophoneAccess: Sendable { case notDetermined, denied, restricted, granted }

/// The three first-run steps on Home. Setup is complete when the microphone is allowed, the current
/// mode's speech model can record, and text insertion is allowed or skipped. The optional cleanup step
/// (`RecordingReadiness.modesAwaitingCleanup`) is not part of it.
struct SetupChecklist: Equatable, Sendable {
    var microphone: MicrophoneAccess
    /// Why the current mode's speech model cannot record yet, or nil when it can.
    var speechBlocker: RecordingFailure?
    var accessibilityGranted: Bool
    var textInsertionSkipped: Bool

    var isComplete: Bool {
        microphone == .granted && speechBlocker == nil && (accessibilityGranted || textInsertionSkipped)
    }

    /// People who recorded before the checklist existed have set up already and never see it.
    /// Only a recording that was transcribed counts. A first attempt that failed because setup was
    /// unfinished must not hide the checklist from the person who needs it.
    static func isImplied(by statistics: UsageStatistics, history: [RecordingEntry]) -> Bool {
        statistics.sessions > 0
            || history.contains { [.complete, .noSpeech, .empty].contains($0.status) }
    }
}
