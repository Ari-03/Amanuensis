import CoreGraphics
import Foundation

/// The folder that holds the database, recordings, models, and helper jobs.
/// `AMANUENSIS_DATA_DIRECTORY` (an absolute path) replaces it so checks and proof runs never open real data.
enum AppDataDirectory {
    static let environmentKey = "AMANUENSIS_DATA_DIRECTORY"

    static func url(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        if let path = environment[environmentKey], !path.isEmpty {
            // A relative override must fail rather than fall back to the real folder.
            guard path.hasPrefix("/") else { throw OverrideError() }
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        return try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("Amanuensis", isDirectory: true)
    }

    struct OverrideError: LocalizedError {
        var errorDescription: String? { "\(AppDataDirectory.environmentKey) must be an absolute path." }
    }
}

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

/// The language a recording is transcribed in, or detection by the speech model. Saved as a BCP-47
/// language code such as "fr", or "auto" for detection.
enum SpeechLanguage: Hashable, Sendable, Codable {
    case automatic
    case code(String)

    static let english = SpeechLanguage.code("en")

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = value == "auto" ? .automatic : .code(value)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(languageCode ?? "auto")
    }

    /// The language code, or nil for detection.
    var languageCode: String? { if case .code(let code) = self { code } else { nil } }

    /// What pickers and messages call this choice, such as "French" or "Detect automatically".
    var name: String { languageCode.map(Self.name(of:)) ?? "Detect automatically" }

    /// The one source of language names, in the user's own language.
    static func name(of code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    /// Language codes sorted by their names, as every language picker lists them.
    static func sortedByName(_ codes: some Sequence<String>) -> [String] {
        codes.map { ($0, name(of: $0)) }
            .sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
            .map(\.0)
    }

    /// The Settings language a configuration starts with. A fresh install takes the Mac's preferred
    /// language when the app can transcribe it. Configuration saved before languages existed keeps
    /// English, which is what it dictated in, so an update never blocks a mode. Never detection, which
    /// is unreliable on a two-second utterance.
    static func initial(
        freshInstall: Bool, supported: Set<String>, preferredLanguages: [String] = Locale.preferredLanguages
    ) -> SpeechLanguage {
        guard freshInstall, let first = preferredLanguages.first,
            let macCode = Locale(identifier: first).language.languageCode?.identifier
        else { return .english }
        // macOS names Norwegian Bokmål and Filipino with codes the speech models list differently.
        let code = ["nb": "no", "fil": "tl"][macCode] ?? macCode
        return supported.contains(code) ? .code(code) : .english
    }
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
    /// Overrides the Settings language for this mode. Nil means "same as Settings", and is what
    /// configuration saved before languages existed decodes to.
    var language: SpeechLanguage? = nil

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

    /// The end of the live text, from a word start, short enough for the Mini preview's two lines.
    static func previewTail(of text: String, characters: Int = 90) -> String {
        guard text.count > characters else { return text }
        let tail = text.suffix(characters)
        if text[text.index(before: tail.startIndex)] == " " { return "…" + tail }
        guard let space = tail.firstIndex(of: " ") else { return "…" + tail }
        return "…" + tail[tail.index(after: space)...]
    }

    /// Where the Mini recorder's live text goes: centered on the pill, on the side facing the middle of
    /// the screen, so it never covers the pill and the pill never moves for it.
    static func previewFrame(size: CGSize, beside pill: CGRect, in bounds: CGRect) -> CGRect {
        let gap: CGFloat = 6
        let width = min(size.width, bounds.width)
        let y = pill.midY < bounds.midY ? pill.maxY + gap : pill.minY - gap - size.height
        let x = min(max(pill.midX - width / 2, bounds.minX), bounds.maxX - width)
        return CGRect(x: x, y: y, width: width, height: size.height)
    }
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
    /// Nil until changed, which means on. Optional so earlier saves still decode; read `showsLivePreview`.
    var livePreview: Bool? = nil
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
    /// Set by Skip on the setup checklist's text insertion step. Optional so earlier saves still decode.
    var skippedTextInsertionSetup: Bool? = nil
    /// Model IDs the user chose for API rows, by catalog row ID.
    var apiModelOverrides: [String: String] = [:]
    /// The OpenAI-compatible server's base URL as saved, normalized by `APIBaseURL` when it was entered
    /// and parsed through it again on every use. Its key is in the Keychain.
    var compatibleBaseURL: String? = nil
    /// The language modes use unless they set their own. Nil only in configuration saved before
    /// languages existed; AppModel replaces it with `SpeechLanguage.initial` at launch.
    var dictationLanguage: SpeechLanguage? = nil
    /// The Settings language, for every reader.
    var language: SpeechLanguage { dictationLanguage ?? .english }
    /// Whether the Mini recorder shows what a local model has transcribed so far while recording.
    var showsLivePreview: Bool {
        get { livePreview ?? true }
        set { livePreview = newValue }
    }
}

enum ModelPurpose: String, Codable, CaseIterable, Sendable { case speech, cleanup }
enum ModelLocation: String, Codable, Sendable { case local, system, cloud }
/// What runs a model: Apple Speech, the S1-mini helper, a cloud provider, or a local speech family that
/// LocalSpeech declares, such as "whisper". An open set, so the app names only the families it treats
/// specially, and a family added to LocalSpeech and the catalog needs nothing here.
struct ModelFamily: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String

    static let apple = ModelFamily(rawValue: "apple")
    static let s1mini = ModelFamily(rawValue: "s1mini")
    static let openAI = ModelFamily(rawValue: "openAI")
    static let groq = ModelFamily(rawValue: "groq")
    static let anthropic = ModelFamily(rawValue: "anthropic")
    /// Any server that speaks the OpenAI HTTP dialect at a base URL the user enters.
    static let openAICompatible = ModelFamily(rawValue: "openAICompatible")
    static let whisper = ModelFamily(rawValue: "whisper")
    static let parakeet = ModelFamily(rawValue: "parakeet")

    /// Every family releases up to 44d2cc9 can decode; see `ModelDescriptor.runtimeFamily`.
    static let readableByEarlierReleases: Set<String> = [
        "apple", "whisper", "parakeet", "cohere", "s1mini", "openAI", "groq", "anthropic", "ollama",
    ]
}

/// One catalog row, decoded from `ModelCatalog.json`. Recordings also keep a copy as their model
/// snapshot, so fields added later are optional: rows saved by earlier releases lack them.
struct ModelDescriptor: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var name: String
    var provider: String
    var purpose: ModelPurpose
    var location: ModelLocation
    /// The family as saved. Read `engine`, never this: for a family releases up to 44d2cc9 cannot
    /// decode, it holds the stand-in `ollama`.
    var family: ModelFamily
    /// The real family when `family` holds the stand-in. Those releases decode `family` as a closed
    /// enum and fail their whole History load on one unknown value; `ollama` is a value they know and
    /// refuse to run. Delete both fields' split, and `catalog(from:)`'s, once a release that cannot
    /// open this format no longer needs to open databases this build writes.
    var runtimeFamily: ModelFamily? = nil
    var summary: String
    /// The bytes a download fetches, from the publisher's metadata for the pinned revision.
    var byteCount: Int64? = nil
    var repository: String? = nil
    var revision: String? = nil
    var fileName: String? = nil
    var sha256: String? = nil
    var apiModelID: String? = nil
    var license: String = ""
    /// BCP-47 codes of the languages the model handles. Empty means the provider decides, or for
    /// Apple Speech, macOS. Nil only in snapshots saved before languages existed, which were English.
    var languages: [String]? = nil
    /// Whether the model can work out the spoken language on its own.
    var detectsLanguage: Bool? = nil
    var isLocal: Bool { location != .cloud }
    /// What runs this model.
    var engine: ModelFamily { runtimeFamily ?? family }

    /// "2.47 GB", the download size shown beside a model, or empty. `catalog(from:)` derives it from
    /// `byteCount`; the catalog file never sets it. It is still saved with snapshots because releases
    /// before `byteCount` require the key and could not open a History row written without it.
    var sizeLabel: String? = nil

    /// Decodes `ModelCatalog.json`. The app and the catalog tests both load it through here.
    static func catalog(from data: Data) throws -> [ModelDescriptor] {
        try JSONDecoder().decode([ModelDescriptor].self, from: data).map { row in
            var row = row
            row.sizeLabel = row.byteCount.map(formatBytes) ?? ""
            // The file names the real family; snapshots copied from this row must carry the stand-in.
            if !ModelFamily.readableByEarlierReleases.contains(row.family.rawValue) {
                row.runtimeFamily = row.family
                row.family = ModelFamily(rawValue: "ollama")
            }
            return row
        }
    }

    /// The one byte formatter for model sizes and download progress. Decimal units, like Finder.
    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// A History snapshot as a retry runs it. A model the catalog still has takes the catalog's family,
    /// which repairs a row an earlier release saved back without `runtimeFamily`. A local model runs
    /// only from a catalog row, so one the catalog no longer lists, such as the retired Ollama row,
    /// is missing (nil). API and system models otherwise run from the snapshot itself.
    func resolved(against catalog: [ModelDescriptor]) -> ModelDescriptor? {
        guard let row = catalog.first(where: { $0.id == id }) else { return location == .local ? nil : self }
        var snapshot = self
        snapshot.family = row.family
        snapshot.runtimeFamily = row.runtimeFamily
        return snapshot
    }

    /// The row as modes use it: an API model ID the user chose replaces the catalog's default.
    /// Compatible rows have no default, so they have a model ID only from here.
    func applying(_ apiModelOverrides: [String: String]) -> ModelDescriptor {
        guard let override = apiModelOverrides[id]?.trimmingCharacters(in: .whitespaces), !override.isEmpty
        else { return self }
        var model = self
        model.apiModelID = override
        return model
    }

    /// Whether the model's own language list covers this language. Apple Speech's real list comes from
    /// macOS at run time, so `RecordingReadiness.canTranscribe` asks the framework for it instead.
    func declares(_ language: SpeechLanguage) -> Bool {
        switch language {
        case .automatic: return detectsLanguage == true
        case .code(let code):
            guard let languages else { return code == "en" }
            return languages.isEmpty || languages.contains(code)
        }
    }
}

struct ModelInstallation: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var directory: String
    var installedAt: Date = Date()
    var byteCount: Int64 = 0
    var revision: String? = nil
}

/// One model operation's progress. Downloads count bytes across all of the model's files.
struct DownloadProgress: Equatable, Sendable {
    enum Stage: Sendable { case checking, downloading, validating, importing }

    var stage: Stage
    var completedBytes: Int64 = 0
    var totalBytes: Int64 = 0

    /// Nil while there is no byte count, which progress bars show as indeterminate.
    var fraction: Double? {
        guard stage == .downloading || stage == .validating, totalBytes > 0 else { return nil }
        return min(1, Double(max(0, completedBytes)) / Double(totalBytes))
    }

    var label: String {
        switch stage {
        case .checking: "Checking download"
        case .downloading:
            totalBytes > 0
                ? "\(ModelDescriptor.formatBytes(min(max(0, completedBytes), totalBytes))) of \(ModelDescriptor.formatBytes(totalBytes))"
                : "Downloading"
        case .validating: "Validating model"
        case .importing: "Importing model"
        }
    }
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
    /// True when the user pressed Skip during cleanup. Optional so rows saved before it existed still decode.
    var cleanupSkipped: Bool? = nil
    /// The language resolved when recording started, so a retry transcribes the same way.
    /// Nil in rows saved before languages existed; `transcriptionLanguage` reads those as English.
    var language: SpeechLanguage? = nil
    /// How long the speech model took to transcribe the audio. For local models it is the model's own
    /// time summed over every segment, including any transcribed while recording, and leaves out reading
    /// the file and loading the model, so it is time per second of audio rather than the wait after Stop.
    /// For Apple Speech and APIs it is the request's wall time. Set when transcription succeeds; nil in
    /// rows saved before it existed. `TranscriptionSpeed` reads it.
    var transcriptionSeconds: Double? = nil
    var transcriptionLanguage: SpeechLanguage { language ?? .english }
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
        attempt.transcriptionSeconds = nil
        attempt.cleanedText = nil
        attempt.cleanupSkipped = nil
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
