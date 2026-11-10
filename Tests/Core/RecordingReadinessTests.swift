import Foundation
import Testing

@testable import AmanuensisCore

struct RecordingReadinessTests {
    private let apple = ModelDescriptor(
        id: "apple-speech", name: "Apple Speech", provider: "Apple", purpose: .speech, location: .system,
        family: .apple, summary: "")
    private let parakeet = ModelDescriptor(
        id: "parakeet-v2", name: "Parakeet TDT 0.6B V2", provider: "NVIDIA", purpose: .speech,
        location: .local, family: .parakeet, summary: "")
    private let s1mini = ModelDescriptor(
        id: "s1-mini", name: "S1-mini", provider: "Superwhisper", purpose: .cleanup, location: .local,
        family: .s1mini, summary: "")
    private let openAICleanup = ModelDescriptor(
        id: "openai-cleanup", name: "OpenAI Cleanup", provider: "OpenAI", purpose: .cleanup,
        location: .cloud, family: .openAI, summary: "", apiModelID: "gpt-4.1-mini")
    /// As the catalog has it: no model ID until the user picks one.
    private let compatibleSpeech = ModelDescriptor(
        id: "compatible-transcribe", name: "OpenAI-compatible Transcription", provider: "OpenAI-compatible",
        purpose: .speech, location: .cloud, family: .openAICompatible, summary: "", languages: [],
        detectsLanguage: true)

    /// A fresh install: nothing downloaded, no keys, Apple Speech assets missing, local-only on.
    private let fresh = RecordingReadiness(
        requireLocalProcessing: true, installedModelIDs: [], connectedProviders: [],
        appleSpeechReadyLanguages: [], appleSpeechLanguages: ["en", "fr"], cleanupHelperAvailable: true)

    @Test func freshInstallModesNeedAppleSpeechThenS1Mini() {
        #expect(
            fresh.blocker(
                speech: apple, cleanup: nil, cleanupModelID: nil, language: .english, identifySpeakers: false)
                == .appleSpeechNotReady(language: "en"))
        var prepared = fresh
        prepared.appleSpeechReadyLanguages = ["en"]
        #expect(
            prepared.blocker(
                speech: apple, cleanup: nil, cleanupModelID: nil, language: .english, identifySpeakers: false)
                == nil)
        let mail = prepared.blocker(
            speech: apple, cleanup: s1mini, cleanupModelID: s1mini.id, language: .english,
            identifySpeakers: false)
        #expect(mail == .modelNotInstalled("S1-mini"))
        #expect(mail?.shortReason == "Needs S1-mini")
        prepared.installedModelIDs = ["s1-mini"]
        #expect(
            prepared.blocker(
                speech: apple, cleanup: s1mini, cleanupModelID: s1mini.id, language: .english,
                identifySpeakers: false)
                == nil)
    }

    @Test func speechIsReportedBeforeCleanup() {
        #expect(
            fresh.blocker(
                speech: parakeet, cleanup: s1mini, cleanupModelID: s1mini.id, language: .english,
                identifySpeakers: false)
                == .modelNotInstalled("Parakeet TDT 0.6B V2"))
        #expect(
            fresh.blocker(
                speech: nil, cleanup: s1mini, cleanupModelID: s1mini.id, language: .english,
                identifySpeakers: false)
                == .speechModelMissing)
    }

    @Test func localOnlyBlocksAPIModelsBeforeTheirKeyIsChecked() {
        var readiness = fresh
        readiness.installedModelIDs = ["parakeet-v2"]
        #expect(
            readiness.blocker(
                speech: parakeet, cleanup: openAICleanup, cleanupModelID: openAICleanup.id,
                language: .english, identifySpeakers: false)
                == .blockedByLocalOnly(modelName: "OpenAI Cleanup"))
        readiness.requireLocalProcessing = false
        #expect(
            readiness.blocker(
                speech: parakeet, cleanup: openAICleanup, cleanupModelID: openAICleanup.id,
                language: .english, identifySpeakers: false)
                == .apiKeyMissing(provider: "OpenAI"))
        readiness.connectedProviders = [.openAI]
        #expect(
            readiness.blocker(
                speech: parakeet, cleanup: openAICleanup, cleanupModelID: openAICleanup.id,
                language: .english, identifySpeakers: false) == nil)
    }

    @Test func unsupportedEnginesAndSettingsBlockEvenWhenInstalled() {
        var readiness = fresh
        readiness.installedModelIDs = ["parakeet-v2", "s1-mini", "ollama-cleanup"]
        // A mode saved with the retired Ollama row names a cleanup model the catalog no longer has.
        let retired = readiness.blocker(
            speech: parakeet, cleanup: nil, cleanupModelID: "ollama-cleanup", language: .english,
            identifySpeakers: false)
        #expect(retired == .cleanupModelMissing)
        #expect(retired?.shortReason == "No cleanup model")
        #expect(
            readiness.blocker(
                speech: parakeet, cleanup: nil, cleanupModelID: nil, language: .english,
                identifySpeakers: true)
                == .speakerIdentificationUnavailable)
        readiness.cleanupHelperAvailable = false
        #expect(
            readiness.blocker(
                speech: parakeet, cleanup: s1mini, cleanupModelID: s1mini.id, language: .english,
                identifySpeakers: false)
                == .cleanupHelperMissing)
        #expect(
            readiness.blocker(
                speech: parakeet, cleanup: nil, cleanupModelID: nil, language: .english,
                identifySpeakers: false)
                == nil)
    }

    @Test func languagesTheSpeechModelCannotHandleBlockBeforeInstallation() {
        var cohere = parakeet
        cohere.name = "Cohere Transcribe"
        cohere.languages = ["en", "fr"]
        cohere.detectsLanguage = false
        let french = SpeechLanguage.code("fr")
        // Installing would not help, so the language is reported first.
        #expect(
            fresh.blocker(
                speech: cohere, cleanup: nil, cleanupModelID: nil, language: .code("sw"),
                identifySpeakers: false)
                == .unsupportedLanguage(modelName: "Cohere Transcribe", language: .code("sw")))
        #expect(
            fresh.blocker(
                speech: cohere, cleanup: nil, cleanupModelID: nil, language: french, identifySpeakers: false)
                == .modelNotInstalled("Cohere Transcribe"))
        #expect(
            fresh.blocker(
                speech: cohere, cleanup: nil, cleanupModelID: nil, language: .automatic,
                identifySpeakers: false)
                == .unsupportedLanguage(modelName: "Cohere Transcribe", language: .automatic))
        var detecting = cohere
        detecting.detectsLanguage = true
        #expect(fresh.canTranscribe(.automatic, with: detecting))
    }

    @Test func appleSpeechLanguagesComeFromMacOSAndAssetsArePerLanguage() {
        var readiness = fresh
        readiness.appleSpeechReadyLanguages = ["en"]
        #expect(
            readiness.blocker(
                speech: apple, cleanup: nil, cleanupModelID: nil, language: .english, identifySpeakers: false)
                == nil
        )
        #expect(
            readiness.blocker(
                speech: apple, cleanup: nil, cleanupModelID: nil, language: .code("fr"),
                identifySpeakers: false)
                == .appleSpeechNotReady(language: "fr"))
        #expect(
            readiness.blocker(
                speech: apple, cleanup: nil, cleanupModelID: nil, language: .code("sw"),
                identifySpeakers: false)
                == .unsupportedLanguage(modelName: "Apple Speech", language: .code("sw")))
        #expect(
            readiness.blocker(
                speech: apple, cleanup: nil, cleanupModelID: nil, language: .automatic,
                identifySpeakers: false)
                == .unsupportedLanguage(modelName: "Apple Speech", language: .automatic))
        // Before macOS answers at launch, no language is held against Apple Speech, only its assets.
        readiness.appleSpeechLanguages = nil
        #expect(
            readiness.blocker(
                speech: apple, cleanup: nil, cleanupModelID: nil, language: .code("sw"),
                identifySpeakers: false)
                == .appleSpeechNotReady(language: "sw"))
    }

    @Test func cleanupLanguagesOnlyWarnAndProvidersDecideForAPIModels() {
        var english = s1mini
        english.languages = ["en"]
        var readiness = fresh
        readiness.installedModelIDs = ["parakeet-v2", "s1-mini"]
        var multilingual = parakeet
        multilingual.languages = ["en", "fr"]
        #expect(!english.declares(.code("fr")))
        #expect(
            readiness.blocker(
                speech: multilingual, cleanup: english, cleanupModelID: english.id, language: .code("fr"),
                identifySpeakers: false)
                == nil)
        var api = openAICleanup
        api.purpose = .speech
        api.languages = []
        api.detectsLanguage = true
        #expect(readiness.canTranscribe(.code("sw"), with: api))
        #expect(readiness.canTranscribe(.automatic, with: api))
    }

    @Test func availabilityFollowsWhereTheModelRuns() {
        var readiness = fresh
        #expect(readiness.isAvailable(apple))
        #expect(!readiness.isAvailable(parakeet))
        #expect(!readiness.isAvailable(openAICleanup))
        readiness.installedModelIDs = ["parakeet-v2"]
        readiness.connectedProviders = [.openAI]
        #expect(readiness.isAvailable(parakeet))
        #expect(readiness.isAvailable(openAICleanup))
    }

    /// The server may be on this Mac, but nothing proves inference stays there, so it is an API.
    @Test func compatibleServersAreAPIsThatNeedAnAddressAndAModel() {
        var readiness = fresh
        readiness.connectedProviders = [.openAICompatible]
        var configured = compatibleSpeech
        configured.apiModelID = "whisper-1"
        #expect(
            readiness.blocker(
                speech: configured, cleanup: nil, cleanupModelID: nil, language: .english,
                identifySpeakers: false) == .blockedByLocalOnly(modelName: "OpenAI-compatible Transcription"))
        readiness.requireLocalProcessing = false
        #expect(
            readiness.blocker(
                speech: configured, cleanup: nil, cleanupModelID: nil, language: .automatic,
                identifySpeakers: false) == nil)
        // An address without a model ID for this purpose is not set up, and neither is no address.
        #expect(
            readiness.blocker(
                speech: compatibleSpeech, cleanup: nil, cleanupModelID: nil, language: .english,
                identifySpeakers: false) == .providerNotSetUp(provider: "OpenAI-compatible"))
        readiness.connectedProviders = []
        let missing = readiness.blocker(
            speech: configured, cleanup: nil, cleanupModelID: nil, language: .english, identifySpeakers: false
        )
        #expect(missing == .providerNotSetUp(provider: "OpenAI-compatible"))
        #expect(missing?.shortReason == "Needs server setup")
    }
}

struct SetupChecklistTests {
    @Test func completesWhenMicrophoneAndSpeechAreReadyAndInsertionIsAllowedOrSkipped() {
        var checklist = SetupChecklist(
            microphone: .granted, speechBlocker: nil, accessibilityGranted: false, textInsertionSkipped: false
        )
        #expect(!checklist.isComplete)
        checklist.textInsertionSkipped = true
        #expect(checklist.isComplete)
        checklist.textInsertionSkipped = false
        checklist.accessibilityGranted = true
        #expect(checklist.isComplete)
        for microphone in [MicrophoneAccess.notDetermined, .denied, .restricted] {
            var waiting = checklist
            waiting.microphone = microphone
            #expect(!waiting.isComplete)
        }
        checklist.speechBlocker = .appleSpeechNotReady(language: "en")
        #expect(!checklist.isComplete)
    }

    @Test func onlyTranscribedRecordingsImplySetup() {
        func entry(_ status: RecordingStatus) -> RecordingEntry {
            var entry = RecordingEntry(mode: DictationMode.make(preset: .dictation))
            entry.status = status
            return entry
        }
        #expect(!SetupChecklist.isImplied(by: UsageStatistics(), history: []))
        // A first try before setup was finished fails validation or the microphone prompt.
        #expect(
            !SetupChecklist.isImplied(by: UsageStatistics(), history: [entry(.failed), entry(.interrupted)]))
        #expect(SetupChecklist.isImplied(by: UsageStatistics(), history: [entry(.failed), entry(.complete)]))
        #expect(SetupChecklist.isImplied(by: UsageStatistics(), history: [entry(.noSpeech)]))
        // History may have been deleted while usage totals remain.
        #expect(SetupChecklist.isImplied(by: UsageStatistics(sessions: 1), history: []))
    }
}

struct DownloadProgressTests {
    @Test func downloadsCountBytesWithTheModelSizeFormatter() {
        let progress = DownloadProgress(
            stage: .downloading, completedBytes: 1_190_000_000, totalBytes: 2_470_000_000)
        #expect(progress.label == "1.19 GB of 2.47 GB")
        #expect(abs((progress.fraction ?? 0) - 1.19 / 2.47) < 0.0001)
        // The total reads exactly like the catalog size shown beside the model.
        let model = ModelDescriptor(
            id: "whisper-tiny", name: "Whisper tiny", provider: "OpenAI", purpose: .speech, location: .local,
            family: .whisper, summary: "", byteCount: 151_061_672)
        let small = DownloadProgress(stage: .downloading, completedBytes: 12_400_000, totalBytes: 151_061_672)
        #expect(small.label == "12.4 MB of \(ModelDescriptor.formatBytes(model.byteCount ?? 0))")
        #expect(DownloadProgress(stage: .downloading).label == "Downloading")
    }

    @Test func overshootIsClampedAndUnknownSizesAreIndeterminate() {
        let overshoot = DownloadProgress(stage: .downloading, completedBytes: 2_000, totalBytes: 1_000)
        #expect(overshoot.fraction == 1)
        #expect(overshoot.label == "1 KB of 1 KB")
        #expect(DownloadProgress(stage: .checking).fraction == nil)
        #expect(DownloadProgress(stage: .importing).fraction == nil)
        #expect(DownloadProgress(stage: .downloading).fraction == nil)
        #expect(DownloadProgress(stage: .validating, completedBytes: 5, totalBytes: 5).fraction == 1)
    }
}
