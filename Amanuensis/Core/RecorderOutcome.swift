import Foundation

/// Failures the recorder pill can offer a fix for. Their messages are what the banner and History show.
enum RecordingFailure: LocalizedError, Equatable, Sendable {
    case modelNotInstalled(String)
    case apiKeyMissing(provider: String)
    case blockedByLocalOnly(modelName: String)
    case noMicrophone
    case appleSpeechNotReady

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled(let name): "Install \(name) from Models before recording."
        case .apiKeyMissing(let provider): "Add your \(provider) API key in Models first."
        case .blockedByLocalOnly(let name):
            "\(name) uses an API. Choose a local model or turn off Require local processing."
        case .noMicrophone: "No included microphone is connected and available."
        case .appleSpeechNotReady: "Apple Speech needs its English model. Open Models and choose Prepare."
        }
    }
}

/// What the recorder pill shows after a job ends. AppModel creates one from the job's typed cause.
/// Successes, notices, and warnings close on their own; failures stay until the user acts, dismisses,
/// or records again. A warning is a hint with an action, such as allowing automatic paste.
struct RecorderOutcome: Equatable, Sendable {
    enum Kind: Sendable { case success, notice, warning, failure }

    enum Action: Sendable {
        case allowPaste, pasteOriginal, openModels, openSettings, openSound, showInHistory

        var title: String {
            switch self {
            case .allowPaste: "Allow paste"
            case .pasteOriginal: "Paste original"
            case .openModels: "Open Models"
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
            case .failed(.modelNotInstalled(let name)): ("\(name) not installed", .failure, .openModels)
            case .failed(.apiKeyMissing(let provider)): ("\(provider) key missing", .failure, .openModels)
            case .failed(.blockedByLocalOnly): ("Blocked by local-only", .failure, .openSettings)
            case .failed(.noMicrophone): ("No microphone", .failure, .openSound)
            case .failed(.appleSpeechNotReady): ("Apple Speech not ready", .failure, .openModels)
            case .failed(nil): ("Couldn't finish", .failure, .showInHistory)
            }
        self.kind = kind
        self.recordingID = recordingID
        deadline = kind == .failure ? nil : time + Self.displayDuration
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
