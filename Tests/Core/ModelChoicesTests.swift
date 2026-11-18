import Foundation
import Testing

@testable import AmanuensisCore

struct TranscriptionSpeedTests {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let english = Locale(identifier: "en_US")

    private func entry(
        _ id: String, seconds: Double?, audio: Double, at offset: TimeInterval, apiModelID: String? = nil,
        status: RecordingStatus = .complete
    ) -> RecordingEntry {
        var entry = RecordingEntry(mode: DictationMode.make(preset: .dictation))
        entry.status = status
        entry.createdAt = start.addingTimeInterval(offset)
        entry.duration = audio
        entry.transcriptionSeconds = seconds
        entry.speechSnapshot = ModelDescriptor(
            id: id, name: id, provider: "", purpose: .speech, location: .local, family: .whisper, summary: "",
            apiModelID: apiModelID)
        return entry
    }

    @Test func onlyTimedRecordingsLongEnoughToMeanSomethingCount() {
        let history = [
            entry("whisper-tiny", seconds: 1, audio: 10, at: 0),
            entry("whisper-tiny", seconds: nil, audio: 30, at: 10),  // saved before timing existed
            entry("whisper-tiny", seconds: 0.5, audio: 2, at: 20),  // too short
            entry("parakeet-v2", seconds: 2, audio: 20, at: 30),
            entry("whisper-tiny", seconds: 3, audio: 15, at: 40),
            entry("whisper-tiny", seconds: 4, audio: 20, at: 50, status: .noSpeech),
        ]
        let samples = TranscriptionSpeed.samples(in: history)
        #expect(samples["whisper-tiny"]?.map(\.seconds) == [3, 1])
        #expect(samples["parakeet-v2"]?.count == 1)
    }

    @Test func speedIsTotalTimeOverTotalAudioOfTheNewestRecordings() throws {
        // A 5 s clip took 1 s and a 55 s clip took 2 s: 3 s for 60 s of audio, so 1.5 s per 30 s.
        // A typical clip's rate would say 3.5 s, overstating what the short clip's padding cost.
        let history = [
            entry("whisper-tiny", seconds: 1, audio: 5, at: 0),
            entry("whisper-tiny", seconds: 2, audio: 55, at: 1),
        ]
        let samples = try #require(TranscriptionSpeed.samples(in: history)["whisper-tiny"])
        let speed = try #require(TranscriptionSpeed.secondsPer30(samples, installedAt: nil, apiModelID: nil))
        #expect(abs(speed - 1.5) < 0.000_1)
        // Only the newest ten count: twelve old slow ones followed by ten fast ones.
        let many =
            (0..<12).map { entry("m", seconds: 10, audio: 10, at: Double($0)) }
            + (12..<22).map { entry("m", seconds: 1, audio: 10, at: Double($0)) }
        let newest = try #require(
            TranscriptionSpeed.secondsPer30(
                TranscriptionSpeed.samples(in: many)["m"] ?? [], installedAt: nil, apiModelID: nil))
        #expect(abs(newest - 3) < 0.000_1)
    }

    @Test func aReinstalledModelOrAnotherAPIModelStartsWithoutAMeasurement() {
        let history = [
            entry("whisper-tiny", seconds: 1, audio: 10, at: 0),
            entry("openai-transcribe", seconds: 2, audio: 10, at: 0, apiModelID: "whisper-1"),
        ]
        let samples = TranscriptionSpeed.samples(in: history)
        let reinstalled = start.addingTimeInterval(5)
        #expect(
            TranscriptionSpeed.secondsPer30(
                samples["whisper-tiny"] ?? [], installedAt: reinstalled, apiModelID: nil)
                == nil)
        #expect(
            TranscriptionSpeed.secondsPer30(
                samples["whisper-tiny"] ?? [], installedAt: start, apiModelID: nil)
                == 3)
        #expect(
            TranscriptionSpeed.secondsPer30(
                samples["openai-transcribe"] ?? [], installedAt: nil, apiModelID: "gpt-transcribe") == nil)
        #expect(
            TranscriptionSpeed.secondsPer30(
                samples["openai-transcribe"] ?? [], installedAt: nil, apiModelID: "whisper-1") == 6)
    }

    @Test func labelsUseOneDecimalBelowTenSeconds() {
        #expect(
            TranscriptionSpeed.label(secondsPer30: 1.43, isAPI: false, locale: english)
                == "30 s of audio in 1.4 s on this Mac")
        #expect(
            TranscriptionSpeed.label(secondsPer30: 3.7, isAPI: true, locale: english)
                == "30 s of audio in 3.7 s, including network time")
        #expect(TranscriptionSpeed.format(0.04, locale: english) == "0.0 s")
        #expect(TranscriptionSpeed.format(9.96, locale: english) == "10 s")
        #expect(TranscriptionSpeed.format(14.4, locale: english) == "14 s")
    }

    @Test func historyRowsWithoutATimeDecodeAndRetriesStartUntimed() throws {
        // Written by 44d2cc9, before transcription was timed.
        let old = try JSONDecoder().decode(
            RecordingEntry.self, from: Data(FamilyCompatibilityTests.recording44.utf8))
        #expect(old.transcriptionSeconds == nil)
        var timed = old
        timed.transcriptionSeconds = 1.25
        let again = try JSONDecoder().decode(RecordingEntry.self, from: JSONEncoder().encode(timed))
        #expect(again.transcriptionSeconds == 1.25)
        #expect(timed.retryAttempt().transcriptionSeconds == nil)
    }
}

/// The Models screen's filters and orders, over the bundled catalog.
struct ModelListOptionsTests {
    private let models: [ModelDescriptor]
    private let readiness = RecordingReadiness(
        requireLocalProcessing: true, installedModelIDs: ["whisper-tiny", "parakeet-v2", "s1-mini"],
        connectedProviders: [], appleSpeechReadyLanguages: ["en"], appleSpeechLanguages: ["en", "fr"],
        cleanupHelperAvailable: true)

    init() throws {
        models = try ModelDescriptor.catalog(from: Data(contentsOf: ModelCatalogTests.catalogURL))
    }

    private func ids(_ options: ModelListOptions, speeds: [String: Double] = [:]) -> [String] {
        options.apply(to: models, readiness: readiness, speeds: speeds).map(\.id)
    }

    @Test func purposeAndPlaceAreSeparateChoices() {
        #expect(ids(ModelListOptions(place: .installed)) == ["parakeet-v2", "whisper-tiny"])
        #expect(ids(ModelListOptions(purpose: .cleanup, place: .installed)) == ["s1-mini"])
        let onThisMac = ids(ModelListOptions(place: .onThisMac))
        #expect(onThisMac.first == "apple-speech")
        #expect(!onThisMac.contains("openai-transcribe"))
        #expect(
            ids(ModelListOptions(place: .api))
                == ["openai-transcribe", "groq-transcribe", "compatible-transcribe"])
        #expect(ids(ModelListOptions(search: "moonshine")) == ["moonshine-tiny", "moonshine-base"])
    }

    @Test func aLanguageKeepsOnlySpeechModelsThatTranscribeIt() {
        let french = ids(ModelListOptions(language: "fr"))
        #expect(french.contains("apple-speech"))  // macOS lists French on this Mac
        #expect(french.contains("whisper-tiny") && french.contains("parakeet-v3"))
        #expect(french.contains("openai-transcribe"))  // the provider decides
        #expect(!french.contains("whisper-tiny.en") && !french.contains("parakeet-v2"))
        #expect(!french.contains("moonshine-tiny"))
        let welsh = ids(ModelListOptions(language: "cy"))
        #expect(!welsh.contains("apple-speech") && welsh.contains("whisper-tiny"))
        // Cleanup ignores the language.
        #expect(ids(ModelListOptions(purpose: .cleanup, language: "fr")).contains("s1-mini"))
    }

    @Test func smallestFirstPutsUnsizedModelsLastInCatalogOrder() {
        let sorted = models.filter { $0.purpose == .speech }
        let order = ids(ModelListOptions(order: .smallest))
        #expect(order.count == sorted.count)
        let sizes = order.compactMap { id in models.first { $0.id == id }?.byteCount }
        #expect(sizes == sizes.sorted())
        #expect(order.prefix(2) == ["moonshine-tiny", "whisper-tiny.en"])
        #expect(
            Array(order.suffix(4))
                == ["apple-speech", "openai-transcribe", "groq-transcribe", "compatible-transcribe"])
    }

    @Test func fastestFirstOrdersMeasuredModelsAndKeepsTheRestInCatalogOrder() {
        let order = ids(
            ModelListOptions(place: .installed, order: .fastest),
            speeds: ["parakeet-v2": 0.8, "whisper-tiny": 2])
        #expect(order == ["parakeet-v2", "whisper-tiny"])
        let partly = ids(ModelListOptions(order: .fastest), speeds: ["moonshine-base": 1])
        #expect(partly.first == "moonshine-base")
        #expect(Array(partly.dropFirst().prefix(2)) == ["apple-speech", "parakeet-v2"])
    }
}

/// Pickers and the Models screen file models with `availability`; recording uses `blocker`. Both must
/// agree, or a picker would offer a "ready" model that recording then refuses.
struct ModelAvailabilityTests {
    private let models: [ModelDescriptor]

    init() throws {
        models = try ModelDescriptor.catalog(from: Data(contentsOf: ModelCatalogTests.catalogURL))
            .map { $0.applying(["compatible-transcribe": "whisper-1"]) }
    }

    @Test func readyAndAbleToTranscribeIsExactlyNoBlocker() {
        let states = [
            RecordingReadiness(
                requireLocalProcessing: true, installedModelIDs: [], connectedProviders: [],
                appleSpeechReadyLanguages: [], appleSpeechLanguages: ["en", "fr"],
                cleanupHelperAvailable: true),
            RecordingReadiness(
                requireLocalProcessing: false,
                installedModelIDs: ["whisper-tiny.en", "s1-mini", "qwen3-asr-0.6b"],
                connectedProviders: [.openAI, .openAICompatible], appleSpeechReadyLanguages: ["fr"],
                appleSpeechLanguages: ["en", "fr"], cleanupHelperAvailable: false),
            RecordingReadiness(
                requireLocalProcessing: true, installedModelIDs: ["parakeet-v3"], connectedProviders: [.groq],
                appleSpeechReadyLanguages: ["en"], appleSpeechLanguages: nil, cleanupHelperAvailable: true),
        ]
        for readiness in states {
            for language in [SpeechLanguage.english, .code("fr"), .code("ja"), .automatic] {
                for model in models {
                    let fits = model.purpose == .cleanup || readiness.canTranscribe(language, with: model)
                    let ready = readiness.availability(of: model, language: language) == .ready
                    #expect(
                        (ready && fits) == (readiness.blocker(for: model, language: language) == nil),
                        "\(model.id) in \(language.name)")
                }
            }
        }
    }

    @Test func sectionsFollowWhatTheModelStillNeeds() {
        let readiness = RecordingReadiness(
            requireLocalProcessing: true, installedModelIDs: ["whisper-tiny.en"],
            connectedProviders: [.openAI],
            appleSpeechReadyLanguages: ["en"], appleSpeechLanguages: ["en", "fr"],
            cleanupHelperAvailable: true)
        func availability(_ id: String, _ language: SpeechLanguage = .english) -> ModelAvailability? {
            models.first { $0.id == id }.map { readiness.availability(of: $0, language: language) }
        }
        #expect(availability("whisper-tiny.en") == .ready)
        // Still filed as ready in French, where the picker marks it as unable to transcribe.
        #expect(availability("whisper-tiny.en", .code("fr")) == .ready)
        #expect(availability("parakeet-v2") == .needsDownload)
        #expect(availability("s1-mini") == .needsDownload)
        // Require local processing is on.
        #expect(
            availability("openai-transcribe")
                == .needsSetup(.blockedByLocalOnly(modelName: "OpenAI Transcription")))
        #expect(availability("apple-speech") == .ready)
        // French assets are missing.
        #expect(
            availability("apple-speech", .code("fr")) == .needsSetup(.appleSpeechNotReady(language: "fr")))
    }
}
