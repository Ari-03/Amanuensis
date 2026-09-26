import CoreGraphics
import Foundation

enum AppSection: String, CaseIterable, Identifiable, Sendable {
    case home = "Home"
    case modes = "Modes"
    case vocabulary = "Vocabulary"
    case models = "Models"
    case history = "History"
    case sound = "Sound"
    case configuration = "Settings"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .home: "house"
        case .modes: "slider.horizontal.3"
        case .vocabulary: "text.book.closed"
        case .models: "square.stack.3d.up"
        case .history: "clock.arrow.circlepath"
        case .sound: "waveform"
        case .configuration: "gearshape"
        }
    }
}

enum ModePreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case dictation = "Voice to text"
    case message = "Message"
    case mail = "Mail"
    case notes = "Notes"
    case meeting = "Meeting"
    case custom = "Custom"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .dictation: "mic"
        case .message: "bubble.left"
        case .mail: "envelope"
        case .notes: "note.text"
        case .meeting: "person.2"
        case .custom: "wand.and.stars"
        }
    }
}

enum CleanupTone: String, Codable, CaseIterable, Identifiable, Sendable {
    case casual
    case semiCasual = "semi-casual"
    case semiFormal = "semi-formal"
    case formal
    var id: String { rawValue }
    var label: String {
        switch self {
        case .casual: "Casual"
        case .semiCasual: "Conversational"
        case .semiFormal: "Polished"
        case .formal: "Formal"
        }
    }
}

enum PlaybackBehavior: String, Codable, CaseIterable, Sendable {
    case keepPlaying = "Keep playing"
    case pause = "Pause"
    case lower = "Lower volume"
    case mute = "Mute"
}

struct DictationMode: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var preset: ModePreset
    /// An icon chosen when the mode was created. Nil falls back to the preset's icon.
    var customSymbol: String? = nil
    var speechModelID: String = "apple-speech"
    var cleanupModelID: String? = nil
    var tone: CleanupTone = .semiFormal
    var useLists = false
    var customPrompt = ""
    var appBundleIDs: [String] = []
    var startShortcut: ShortcutBinding? = nil
    var autoPaste = true
    var capitalize = true
    var playback: PlaybackBehavior = .keepPlaying
    var recordSystemAudio = false
    var identifySpeakers = false

    var symbol: String { customSymbol ?? preset.symbol }

    static let initial: [DictationMode] = ModePreset.allCases.map { make(preset: $0) }

    /// Icons offered when creating a mode. Any SF Symbol name can still be stored.
    static let symbolChoices: [String] = [
        "mic", "bubble.left", "envelope", "note.text", "person.2", "wand.and.stars", "doc.text",
        "text.quote", "list.bullet", "terminal", "chevron.left.forwardslash.chevron.right", "briefcase",
        "graduationcap", "heart", "star", "bolt", "lightbulb", "book", "calendar", "checklist",
        "hammer", "paintbrush", "globe", "music.mic",
    ]

    /// Models that were renamed after modes could already reference them.
    static let legacyModelIDs: [String: String] = [
        "openai-mini-transcribe": "openai-transcribe", "groq-whisper": "groq-transcribe",
    ]

    /// Rewrites references to renamed models so saved modes keep working.
    mutating func migrateModelIDs() {
        speechModelID = Self.legacyModelIDs[speechModelID] ?? speechModelID
        if let cleanup = cleanupModelID { cleanupModelID = Self.legacyModelIDs[cleanup] ?? cleanup }
    }

    static func make(preset: ModePreset) -> DictationMode {
        var mode = DictationMode(name: preset == .custom ? "Custom" : preset.rawValue, preset: preset)
        switch preset {
        case .dictation, .custom: break
        case .message:
            mode.cleanupModelID = "s1-mini"
            mode.tone = .casual
        case .mail:
            mode.cleanupModelID = "s1-mini"
        case .notes:
            mode.cleanupModelID = "s1-mini"
            mode.useLists = true
        case .meeting:
            mode.cleanupModelID = "s1-mini"
            mode.useLists = true
            mode.recordSystemAudio = true
            mode.autoPaste = false
        }
        return mode
    }
}

struct VocabularyEntry: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var word: String
    var replacement: String? = nil
}

struct MicrophoneDevice: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var isConnected: Bool
}

struct MicrophonePreference: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var name: String
    var isEnabled: Bool = true
}

struct CapturedAudio: Sendable {
    var url: URL
    var duration: Double
}

struct ShortcutBinding: Codable, Equatable, Sendable {
    /// A missing key code represents a combination of modifier keys on their own.
    var keyCode: UInt32?
    var modifiers: UInt32
    var display: String
    var isModifierOnly: Bool { keyCode == nil }
    static let recording = ShortcutBinding(keyCode: 49, modifiers: 2304, display: "⌥⌘Space")
    static let mode = ShortcutBinding(keyCode: 40, modifiers: 2816, display: "⌥⇧⌘K")
}

enum AppAppearance: String, Codable, CaseIterable, Sendable { case system, light, dark }
enum RecorderStyle: String, Codable, CaseIterable, Sendable {
    case mini, notch, hidden

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        // The former detail panel now uses the same compact controls as Mini.
        if value == "panel" {
            self = .mini
        } else if let style = Self(rawValue: value) {
            self = style
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown recorder style")
        }
    }
}

enum RecorderLayout {
    static let idleSize = CGSize(width: 36, height: 6)

    static func idleSize(for style: RecorderStyle) -> CGSize {
        style == .notch ? CGSize(width: 36, height: 28) : idleSize
    }

    static func activeSize(for style: RecorderStyle) -> CGSize {
        CGSize(width: 156, height: style == .notch ? 28 : 36)
    }

    /// Notch controls resize horizontally within the menu bar, beside the camera when present.
    static func notchFrame(
        width: CGFloat, screen: CGRect, menuBarHeight: CGFloat,
        leftCameraArea: CGRect?, rightCameraArea: CGRect?
    ) -> CGRect {
        let height = min(menuBarHeight, screen.height)
        let menuBar = CGRect(
            x: screen.minX, y: screen.maxY - height, width: screen.width, height: height)
        let cameraAreas = [rightCameraArea, leftCameraArea].compactMap { $0 }
            .map { $0.intersection(menuBar) }.filter { !$0.isEmpty && !$0.isNull }
        let gap: CGFloat = 6
        if let area = cameraAreas.first(where: { $0.width >= width + gap * 2 })
            ?? cameraAreas.max(by: { $0.width < $1.width })
        {
            let inset = min(gap, area.width / 4)
            let fittedWidth = min(width, area.width - inset * 2)
            let x =
                area.midX > screen.midX
                ? area.minX + inset : area.maxX - inset - fittedWidth
            return CGRect(x: x, y: area.minY, width: fittedWidth, height: area.height)
        }
        let fittedWidth = min(width, screen.width)
        return CGRect(
            x: screen.midX - fittedWidth / 2, y: menuBar.minY, width: fittedWidth, height: height)
    }

    // Keep horizontal centers stable on hover while top and bottom presets expand inward.
    static let anchorWidth: CGFloat = 300
}

/// Normalized positions keep the recorder aligned to the chosen screen edge as its size changes.
struct RecorderPlacement: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var displayID: UInt32? = nil

    static let bottom = RecorderPlacement(x: 0.5, y: 0)
    static let top = RecorderPlacement(x: 0.5, y: 1)

    static let presets: [RecorderPlacement] = (0..<5).flatMap { row in
        (0..<5).compactMap { column in
            guard row == 0 || row == 4 || column == 0 || column == 4 || (row == 2 && column == 2)
            else { return nil }
            return RecorderPlacement(x: Double(column) / 4, y: 1 - Double(row) / 4)
        }
    }

    static func nearestPreset(
        to point: CGPoint, size: CGSize, in bounds: CGRect, displayID: UInt32?
    ) -> RecorderPlacement {
        var nearest =
            presets.min { first, second in
                let a = first.frame(size: size, in: bounds)
                let b = second.frame(size: size, in: bounds)
                return hypot(a.midX - point.x, a.midY - point.y) < hypot(b.midX - point.x, b.midY - point.y)
            } ?? .bottom
        nearest.displayID = displayID
        return nearest
    }

    func frame(size: CGSize, in bounds: CGRect) -> CGRect {
        let width = min(size.width, bounds.width)
        let height = min(size.height, bounds.height)
        let anchors = anchorBounds(in: bounds, height: height)
        let centerX = anchors.minX + anchors.width * min(max(x, 0), 1)
        let centerY = anchors.minY + anchors.height * min(max(y, 0), 1)
        return CGRect(
            x: min(max(centerX - width / 2, bounds.minX), bounds.maxX - width),
            y: min(max(centerY - height / 2, bounds.minY), bounds.maxY - height),
            width: width, height: height)
    }

    private func anchorBounds(in bounds: CGRect, height: CGFloat) -> CGRect {
        bounds.insetBy(
            dx: min(RecorderLayout.anchorWidth, bounds.width) / 2,
            dy: min(height, bounds.height) / 2)
    }

    init(x: Double, y: Double, displayID: UInt32? = nil) {
        self.x = x
        self.y = y
        self.displayID = displayID
    }

    init(frame: CGRect, in bounds: CGRect, displayID: UInt32?) {
        self.init(x: 0.5, y: 0.5, displayID: displayID)
        let anchors = anchorBounds(in: bounds, height: frame.height)
        if anchors.width > 0 { x = min(max((frame.midX - anchors.minX) / anchors.width, 0), 1) }
        if anchors.height > 0 { y = min(max((frame.midY - anchors.minY) / anchors.height, 0), 1) }
    }
}

struct AppSettings: Codable, Equatable, Sendable {
    var appearance: AppAppearance = .system
    var recorderStyle: RecorderStyle = .mini
    var recorderPlacement: RecorderPlacement? = nil
    var alwaysShowRecorder = true
    var requireLocalProcessing = true
    var toggleShortcut: ShortcutBinding = .recording
    var pushToTalkShortcut: ShortcutBinding? = nil
    var modeShortcut: ShortcutBinding? = .mode
    var audioRetentionDays: Int = 7
    var textRetentionDays: Int = 0
    var launchAtLogin = false
    var errorLogging = false
    var playSoundEffects = false
    var automaticModeSelection = true
    var selectedModeID: UUID? = nil
    var hasCompletedSetup = false
    var apiModelOverrides: [String: String] = [:]
}

enum ModelPurpose: String, Codable, CaseIterable, Sendable { case speech, cleanup }
enum ModelLocation: String, Codable, Sendable { case local, system, cloud }
enum ModelFamily: String, Codable, Sendable {
    case apple, whisper, parakeet, cohere, s1mini, openAI, groq, anthropic, ollama
}

struct ModelDescriptor: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var name: String
    var provider: String
    var purpose: ModelPurpose
    var location: ModelLocation
    var family: ModelFamily
    var summary: String
    var sizeLabel: String = ""
    var repository: String? = nil
    var revision: String? = nil
    var fileName: String? = nil
    var sha256: String? = nil
    var apiModelID: String? = nil
    var license: String = ""
    var isLocal: Bool { location != .cloud }
}

struct ModelInstallation: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var directory: String
    var installedAt: Date = Date()
    var byteCount: Int64 = 0
    var revision: String? = nil
}

struct DownloadProgress: Equatable, Sendable {
    var fraction: Double
    var label: String
}

enum RecordingStatus: String, Codable, Sendable {
    case recording, transcribing, cleaning, complete, interrupted, failed, noSpeech, empty
}

struct RecordingEntry: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var duration: Double = 0
    var mode: DictationMode
    var rawText: String = ""
    var cleanedText: String? = nil
    var finalText: String = ""
    var status: RecordingStatus = .recording
    var error: String? = nil
    var audioFileName: String? = nil
    var destinationApp: String? = nil
    var deliveryMessage: String? = nil
    var countedInStatistics = false
    var speechSnapshot: ModelDescriptor? = nil
    var cleanupSnapshot: ModelDescriptor? = nil
    var vocabularySnapshot: [VocabularyEntry]? = nil
    /// The first captured recording in a retry chain, used to count its speech only once.
    var parentRecordingID: UUID? = nil
    var preview: String {
        if !finalText.isEmpty { return finalText }
        if !rawText.isEmpty { return rawText }
        return error ?? (status == .noSpeech ? "No speech detected" : status.rawValue.capitalized)
    }

    func retryAttempt(at date: Date = Date()) -> RecordingEntry {
        var attempt = self
        attempt.id = UUID()
        attempt.parentRecordingID = parentRecordingID ?? id
        attempt.createdAt = date
        attempt.audioFileName = "\(attempt.id.uuidString).wav"
        attempt.rawText = ""
        attempt.cleanedText = nil
        attempt.finalText = ""
        attempt.error = nil
        attempt.destinationApp = nil
        attempt.deliveryMessage = nil
        attempt.countedInStatistics = false
        attempt.status = .transcribing
        return attempt
    }
}

struct UsageStatistics: Codable, Equatable, Sendable {
    var words: Int = 0
    var recordingSeconds: Double = 0
    var sessions: Int = 0
    var wordsPerMinute: Int {
        recordingSeconds > 0 ? Int((Double(words) / recordingSeconds * 60).rounded()) : 0
    }
}

struct SavedConfiguration: Codable, Sendable {
    var settings = AppSettings()
    var modes = DictationMode.initial
    var vocabulary: [VocabularyEntry] = []
    var microphones: [MicrophonePreference] = []
}

enum DictationPhase: String, Sendable {
    case idle = "Ready"
    case preparing = "Getting ready"
    case recording = "Listening"
    case transcribing = "Transcribing"
    case cleaning = "Cleaning up"
    case delivering = "Inserting"
    case complete = "Done"
    case failed = "Needs attention"
    case interrupted = "Recording interrupted"
    var isBusy: Bool { [.preparing, .recording, .transcribing, .cleaning, .delivering].contains(self) }
}

/// A destructive cancel needs a second press within a short window, measured with monotonic time.
struct CancellationConfirmation {
    static let timeout: TimeInterval = 5
    private var deadline: TimeInterval?
    var isPending: Bool { deadline != nil }

    mutating func request(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        if let deadline, time < deadline {
            dismiss()
            return true
        }
        deadline = time + Self.timeout
        return false
    }

    mutating func dismiss() { deadline = nil }
}
