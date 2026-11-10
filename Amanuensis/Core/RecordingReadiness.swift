import Foundation

/// Facts about this Mac that decide whether a mode can record. AppModel fills one from live state, so
/// recording validation and the "Needs …" markers wherever a mode is chosen give the same answer.
struct RecordingReadiness: Sendable {
    var requireLocalProcessing: Bool
    var installedModelIDs: Set<String>
    var connectedProviders: Set<ModelFamily>
    var appleSpeechReady: Bool
    var cleanupHelperAvailable: Bool

    /// Installed for local models, a saved key for API models. System models are always present.
    func isAvailable(_ model: ModelDescriptor) -> Bool {
        switch model.location {
        case .system: true
        case .cloud: connectedProviders.contains(model.family)
        case .local: installedModelIDs.contains(model.id)
        }
    }

    /// What stops this one model from running, or nil when it can.
    func blocker(for model: ModelDescriptor) -> RecordingFailure? {
        if model.family == .ollama { return .unsupportedCleanup(model.name) }
        if requireLocalProcessing && !model.isLocal { return .blockedByLocalOnly(modelName: model.name) }
        if !isAvailable(model) {
            return model.location == .cloud
                ? .apiKeyMissing(provider: model.provider) : .modelNotInstalled(model.name)
        }
        if model.family == .apple && !appleSpeechReady { return .appleSpeechNotReady }
        if model.family == .s1mini && !cleanupHelperAvailable { return .cleanupHelperMissing }
        return nil
    }

    /// The first thing a recording with these choices still needs, or nil when it can start.
    /// A missing speech model means the mode names one the catalog no longer has.
    func blocker(speech: ModelDescriptor?, cleanup: ModelDescriptor?, identifySpeakers: Bool)
        -> RecordingFailure?
    {
        guard let speech else { return .speechModelMissing }
        if let failure = blocker(for: speech) ?? cleanup.flatMap(blocker(for:)) { return failure }
        return identifySpeakers ? .speakerIdentificationUnavailable : nil
    }
}

/// The system microphone permission. Restricted means an organization or Screen Time manages it,
/// so the user cannot turn it on in Privacy & Security.
enum MicrophoneAccess: Sendable { case notDetermined, denied, restricted, granted }

/// The three first-run steps on Home. Setup is complete when the microphone is allowed, the current
/// mode's speech model can record, and text insertion is allowed or skipped.
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
