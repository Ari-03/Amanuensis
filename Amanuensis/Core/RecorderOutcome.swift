import Foundation

/// Typed reasons a recording cannot start. Their messages are what the banner and History show, and
/// `shortReason` is the one short label, used by the recorder pill and by the marker beside a mode.
/// All but `noMicrophone` also come from `RecordingReadiness`, which marks modes that cannot record yet.
enum RecordingFailure: LocalizedError, Equatable, Sendable {
    case modelNotInstalled(String)
    case apiKeyMissing(provider: String)
    case blockedByLocalOnly(modelName: String)
    case noMicrophone
    /// Apple Speech's assets for this language code are not installed.
    case appleSpeechNotReady(language: String)
    case unsupportedLanguage(modelName: String, language: SpeechLanguage)
    case speechModelMissing
    case cleanupHelperMissing
    case unsupportedCleanup(String)
    case speakerIdentificationUnavailable

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled(let name): "Install \(name) from Models before recording."
        case .apiKeyMissing(let provider): "Add your \(provider) API key in Models first."
        case .blockedByLocalOnly(let name):
            "\(name) uses an API. Choose a local model or turn off Require local processing."
        case .noMicrophone: "No included microphone is connected and available."
        case .appleSpeechNotReady(let code):
            "Apple Speech needs its \(SpeechLanguage.name(of: code)) model. Open Models and choose Prepare."
        case .unsupportedLanguage(let name, .automatic):
            "\(name) can't detect the spoken language. Choose a language or another speech model for this mode."
        case .unsupportedLanguage(let name, let language):
            "\(name) can't transcribe \(language.name). Choose another language or speech model for this mode."
        case .speechModelMissing: "The selected speech model is missing."
        case .cleanupHelperMissing: "S1-mini's helper is missing. Rebuild with Scripts/build.sh."
        case .unsupportedCleanup(let name):
            "\(name) is not connected in this build. Choose S1-mini for local cleanup."
        case .speakerIdentificationUnavailable:
            "Speaker identification is not yet available. Turn it off to transcribe this recording."
        }
    }

    /// A short label such as "Needs S1-mini", for mode markers and the recorder pill.
    var shortReason: String {
        switch self {
        case .modelNotInstalled(let name): "Needs \(name)"
        case .apiKeyMissing(let provider): "Needs \(provider) key"
        case .blockedByLocalOnly: "Blocked by local-only"
        case .noMicrophone: "No microphone"
        case .appleSpeechNotReady: "Needs Apple Speech"
        case .unsupportedLanguage(let name, .automatic): "\(name) can't detect language"
        case .unsupportedLanguage(let name, let language): "\(name) can't do \(language.name)"
        case .speechModelMissing: "No speech model"
        case .cleanupHelperMissing: "Cleanup helper missing"
        case .unsupportedCleanup(let name): "\(name) unsupported"
        case .speakerIdentificationUnavailable: "Speakers unsupported"
        }
    }
}

/// What the recorder pill shows after a job ends. AppModel creates one from the job's typed cause.
/// Successes, notices, and warnings close on their own; failures stay until the user acts, dismisses,
/// or records again. A warning is a hint with an action, such as allowing automatic paste.
struct RecorderOutcome: Equatable, Sendable {
    enum Kind: Sendable { case success, notice, warning, failure }

    enum Action: Sendable {
        case allowPaste, pasteOriginal, openModels, openModes, openSettings, openSound, showInHistory

        var title: String {
            switch self {
            case .allowPaste: "Allow paste"
            case .pasteOriginal: "Paste original"
            case .openModels: "Open Models"
            case .openModes: "Open Modes"
            case .openSettings: "Open Settings"
            case .openSound: "Open Sound"
            case .showInHistory: "Show in History"
            }
        }
    }

    /// Why a job ended. `failed` carries the typed failure when there is one, and nil for anything else.
    enum Cause: Equatable, Sendable {
        case inserted(app: String?)
        case copied
        case needsAccessibility
        case savedToHistory
        case noSpeech
        case nothingToInsert
        case cleanupFailed
        case interrupted
        case failed(RecordingFailure?)
    }

    static let displayDuration: TimeInterval = 2
    /// Matches the recorder's hover collapse delay, so leaving the pill does not snap it shut.
    static let hoverGrace: TimeInterval = 0.25

    let label: String
    let kind: Kind
    let action: Action?
    /// The History entry this outcome describes.
    let recordingID: UUID?
    /// Monotonic close time for successes and notices. Failures have none.
    private(set) var deadline: TimeInterval?

    init(
        _ cause: Cause, recordingID: UUID?, at time: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        let kind: Kind
        (label, kind, action) =
            switch cause {
            case .inserted(let app): (app.map { "Inserted in \($0)" } ?? "Inserted", .success, nil)
            case .copied: ("Copied. Press ⌘V", .success, nil)
            case .needsAccessibility: ("Copied. Press ⌘V", .warning, .allowPaste)
            case .savedToHistory: ("Saved to History", .success, nil)
            case .noSpeech: ("No speech detected", .notice, nil)
            case .nothingToInsert: ("Nothing to insert", .notice, nil)
            case .cleanupFailed: ("Cleanup failed", .failure, .pasteOriginal)
            case .interrupted: ("Recording interrupted", .failure, .showInHistory)
            case .failed(let failure?): (failure.shortReason, .failure, Self.action(for: failure))
            case .failed(nil): ("Couldn't finish", .failure, .showInHistory)
            }
        self.kind = kind
        self.recordingID = recordingID
        deadline = kind == .failure ? nil : time + Self.displayDuration
    }

    /// Where the pill sends the user to fix a failure. Mode settings it cannot fix point to History,
    /// which keeps the full message.
    private static func action(for failure: RecordingFailure) -> Action {
        switch failure {
        case .modelNotInstalled, .apiKeyMissing, .appleSpeechNotReady: .openModels
        case .unsupportedLanguage: .openModes
        case .blockedByLocalOnly: .openSettings
        case .noMicrophone: .openSound
        case .speechModelMissing, .cleanupHelperMissing, .unsupportedCleanup,
            .speakerIdentificationUnavailable:
            .showInHistory
        }
    }

    /// AppModel skips this check while the pointer is on the pill, which holds the outcome open.
    func isExpired(at time: TimeInterval) -> Bool {
        guard let deadline else { return false }
        return time >= deadline
    }

    mutating func pointerLeft(at time: TimeInterval) {
        if let deadline { self.deadline = max(deadline, time + Self.hoverGrace) }
    }
}

extension RecorderLayout {
    /// The recorder style to show, or nil to hide the panel. Prompts that need room float as Mini,
    /// so Hidden and Notch still show cancellation and failures. Hidden shows nothing else.
    static func presentedStyle(
        saved: RecorderStyle, alwaysShow: Bool, busy: Bool, cancellationPending: Bool,
        outcome: RecorderOutcome?
    ) -> RecorderStyle? {
        if cancellationPending || outcome?.kind == .failure { return .mini }
        guard saved != .hidden, alwaysShow || busy || outcome != nil else { return nil }
        return saved
    }
}
