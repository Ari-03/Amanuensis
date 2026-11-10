import Foundation

/// Speed measured on this Mac: how long each speech model took to transcribe recent recordings, from
/// `RecordingEntry.transcriptionSeconds`. The Models screen shows nothing until a model has a measurement
/// and never a number from anywhere else.
enum TranscriptionSpeed {
    /// Shorter recordings mostly measure fixed overhead, not speed.
    static let minimumAudioSeconds: Double = 5
    /// How many of a model's newest measurements count.
    static let recentCount = 10

    struct Sample: Equatable, Sendable {
        var recordedAt: Date
        var audioSeconds: Double
        var seconds: Double
        /// The API model that ran, for API rows, whose model ID the user can change.
        var apiModelID: String?
    }

    /// Measurements by speech model ID, newest first. AppModel rebuilds this when History changes, so
    /// views never walk History themselves.
    static func samples(in history: [RecordingEntry]) -> [String: [Sample]] {
        var samples: [String: [Sample]] = [:]
        for entry in history {
            // A recording that ended as no speech says nothing about how fast speech is transcribed.
            guard let seconds = entry.transcriptionSeconds, seconds > 0, entry.status != .noSpeech,
                entry.duration >= minimumAudioSeconds, let speech = entry.speechSnapshot
            else { continue }
            samples[speech.id, default: []].append(
                Sample(
                    recordedAt: entry.createdAt, audioSeconds: entry.duration, seconds: seconds,
                    apiModelID: speech.apiModelID))
        }
        return samples.mapValues { $0.sorted { $0.recordedAt > $1.recordedAt } }
    }

    /// Seconds the model takes for 30 s of audio: total transcription time over total audio across its
    /// newest measurements made with the same API model ID and, for a downloaded model, since its
    /// current files were installed. Totals rather than a typical clip's rate, because Whisper pads
    /// every window to 30 s and short clips would overstate it. Nil until there is one.
    static func secondsPer30(_ samples: [Sample], installedAt: Date?, apiModelID: String?) -> Double? {
        let counted = samples.lazy
            .filter { sample in
                sample.apiModelID == apiModelID && installedAt.map { sample.recordedAt >= $0 } != false
            }
            .prefix(recentCount)
        let audio = counted.reduce(0) { $0 + $1.audioSeconds }
        guard audio > 0 else { return nil }
        return counted.reduce(0) { $0 + $1.seconds } / audio * 30
    }

    /// "30 s of audio in 1.4 s on this Mac", or for an API model, whose time includes the upload and
    /// the provider, "30 s of audio in 3.7 s, including network time".
    static func label(secondsPer30 seconds: Double, isAPI: Bool, locale: Locale = .current) -> String {
        "30 s of audio in \(format(seconds, locale: locale))"
            + (isAPI ? ", including network time" : " on this Mac")
    }

    /// Seconds as the Models screen shows them: one decimal below ten seconds, whole seconds above.
    static func format(_ seconds: Double, locale: Locale = .current) -> String {
        let digits = seconds < 9.95 ? 1 : 0
        return seconds.formatted(.number.precision(.fractionLength(digits)).locale(locale)) + " s"
    }
}

extension SpeechLanguage {
    /// "can't do French", or "can't detect the language", beside a speech model that does not handle it.
    var unsupportedLabel: String { self == .automatic ? "can't detect the language" : "can't do \(name)" }
}

/// What the Models screen lists: one purpose, where models run, a language, a search and an order.
struct ModelListOptions: Equatable, Sendable {
    enum Place: String, CaseIterable, Sendable {
        case all = "All"
        case installed = "Installed"
        case onThisMac = "On this Mac"
        case api = "API"
    }

    enum Order: String, CaseIterable, Sendable {
        case catalog = "Catalog order"
        case smallest = "Smallest download"
        case fastest = "Fastest on this Mac"
    }

    var purpose: ModelPurpose = .speech
    var place: Place = .all
    /// A language code. Speech models that cannot transcribe it are left out; nil means any language.
    var language: String? = nil
    var search = ""
    var order: Order = .catalog

    /// The rows to show. `speeds` holds seconds per 30 s of audio for measured models. Models without a
    /// size or a measurement follow the others; ties keep catalog order.
    func apply(to models: [ModelDescriptor], readiness: RecordingReadiness, speeds: [String: Double])
        -> [ModelDescriptor]
    {
        let query = search.trimmingCharacters(in: .whitespaces)
        let shown = models.filter { model in
            guard model.purpose == purpose else { return false }
            let placed =
                switch place {
                case .all: true
                case .installed: readiness.installedModelIDs.contains(model.id)
                case .onThisMac: model.isLocal
                case .api: model.location == .cloud
                }
            guard placed else { return false }
            if purpose == .speech, let language, !readiness.canTranscribe(.code(language), with: model) {
                return false
            }
            return query.isEmpty || model.name.localizedCaseInsensitiveContains(query)
                || model.provider.localizedCaseInsensitiveContains(query)
        }
        let key: (ModelDescriptor) -> Double? =
            switch order {
            case .catalog: { _ in nil }
            case .smallest: { $0.byteCount.map(Double.init) }
            case .fastest: { speeds[$0.id] }
            }
        return shown.enumerated()
            .sorted { first, second in
                switch (key(first.element), key(second.element)) {
                case (let a?, let b?) where a != b: a < b
                case (.some, nil): true
                case (nil, .some): false
                default: first.offset < second.offset
                }
            }
            .map(\.element)
    }
}
