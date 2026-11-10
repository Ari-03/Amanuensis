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
        location: .cloud, family: .openAI, summary: "")
    private let ollama = ModelDescriptor(
        id: "ollama-cleanup", name: "Ollama", provider: "Local server", purpose: .cleanup, location: .local,
        family: .ollama, summary: "")

    /// A fresh install: nothing downloaded, no keys, Apple Speech assets missing, local-only on.
    private let fresh = RecordingReadiness(
        requireLocalProcessing: true, installedModelIDs: [], connectedProviders: [], appleSpeechReady: false,
        cleanupHelperAvailable: true)

    @Test func freshInstallModesNeedAppleSpeechThenS1Mini() {
        #expect(fresh.blocker(speech: apple, cleanup: nil, identifySpeakers: false) == .appleSpeechNotReady)
        var prepared = fresh
        prepared.appleSpeechReady = true
        #expect(prepared.blocker(speech: apple, cleanup: nil, identifySpeakers: false) == nil)
        let mail = prepared.blocker(speech: apple, cleanup: s1mini, identifySpeakers: false)
        #expect(mail == .modelNotInstalled("S1-mini"))
        #expect(mail?.shortReason == "Needs S1-mini")
        prepared.installedModelIDs = ["s1-mini"]
        #expect(prepared.blocker(speech: apple, cleanup: s1mini, identifySpeakers: false) == nil)
    }

    @Test func speechIsReportedBeforeCleanup() {
        #expect(
            fresh.blocker(speech: parakeet, cleanup: s1mini, identifySpeakers: false)
                == .modelNotInstalled("Parakeet TDT 0.6B V2"))
        #expect(fresh.blocker(speech: nil, cleanup: s1mini, identifySpeakers: false) == .speechModelMissing)
    }

    @Test func localOnlyBlocksAPIModelsBeforeTheirKeyIsChecked() {
        var readiness = fresh
        readiness.installedModelIDs = ["parakeet-v2"]
        #expect(
            readiness.blocker(speech: parakeet, cleanup: openAICleanup, identifySpeakers: false)
                == .blockedByLocalOnly(modelName: "OpenAI Cleanup"))
        readiness.requireLocalProcessing = false
        #expect(
            readiness.blocker(speech: parakeet, cleanup: openAICleanup, identifySpeakers: false)
                == .apiKeyMissing(provider: "OpenAI"))
        readiness.connectedProviders = [.openAI]
        #expect(readiness.blocker(speech: parakeet, cleanup: openAICleanup, identifySpeakers: false) == nil)
    }

    @Test func unsupportedEnginesAndSettingsBlockEvenWhenInstalled() {
        var readiness = fresh
        readiness.installedModelIDs = ["parakeet-v2", "s1-mini", "ollama-cleanup"]
        #expect(
            readiness.blocker(speech: parakeet, cleanup: ollama, identifySpeakers: false)
                == .unsupportedCleanup("Ollama"))
        #expect(
            readiness.blocker(speech: parakeet, cleanup: nil, identifySpeakers: true)
                == .speakerIdentificationUnavailable)
        readiness.cleanupHelperAvailable = false
        #expect(
            readiness.blocker(speech: parakeet, cleanup: s1mini, identifySpeakers: false)
                == .cleanupHelperMissing)
        #expect(readiness.blocker(speech: parakeet, cleanup: nil, identifySpeakers: false) == nil)
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
        checklist.speechBlocker = .appleSpeechNotReady
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
    @Test func downloadsCountBytesInTheTotalsUnit() {
        let progress = DownloadProgress(
            stage: .downloading, completedBytes: 1_190_000_000, totalBytes: 2_470_000_000)
        #expect(progress.label == "1.19 of 2.47 GB")
        #expect(abs((progress.fraction ?? 0) - 1.19 / 2.47) < 0.0001)
        #expect(DownloadProgress.byteLabel(completed: 12_400_000, total: 151_000_000) == "12 of 151 MB")
        #expect(DownloadProgress.byteLabel(completed: 0, total: 0) == "Downloading")
    }

    @Test func overshootIsClampedAndUnknownSizesAreIndeterminate() {
        let overshoot = DownloadProgress(stage: .downloading, completedBytes: 2_000, totalBytes: 1_000)
        #expect(overshoot.fraction == 1)
        #expect(overshoot.label == "1 of 1 KB")
        #expect(DownloadProgress(stage: .checking).fraction == nil)
        #expect(DownloadProgress(stage: .importing).fraction == nil)
        #expect(DownloadProgress(stage: .downloading).fraction == nil)
        #expect(DownloadProgress(stage: .validating, completedBytes: 5, totalBytes: 5).fraction == 1)
    }
}
