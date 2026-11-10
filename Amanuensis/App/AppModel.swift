import AppKit
import Foundation
import LocalSpeech
import Observation
import ServiceManagement
import SwiftUI

/// The single recording owner shared by the window, shortcuts, menu bar, and floating recorder.
@MainActor @Observable
final class AppModel {
    var selectedSection: AppSection = .home
    var settings = AppSettings() { didSet { configurationChanged(previous: oldValue) } }
    var modes = DictationMode.initial
    var vocabulary: [VocabularyEntry] = []
    var microphones: [MicrophonePreference] = []
    var history: [RecordingEntry] = []
    var statistics = UsageStatistics()
    var phase: DictationPhase = .idle {
        didSet {
            if phase != oldValue { dismissCancellation() }
            // Any new work replaces the previous job's outcome.
            if phase.isBusy { recorderOutcome = nil }
            shortcuts.setRecordingActive(phase.isBusy)
            updateRecorder()
        }
    }
    var statusMessage = "Your voice, on your Mac."
    var errorMessage: String?
    /// How the last job ended, shown by the recorder pill until it expires or the user handles it.
    private(set) var recorderOutcome: RecorderOutcome? {
        didSet {
            guard recorderOutcome != oldValue else { return }
            if recorderOutcome?.action != .pasteOriginal { originalOffer = nil }
            scheduleOutcomeExpiry()
            updateRecorder()
        }
    }
    /// The History entry to select, so the recorder can open a specific recording.
    var selectedRecordingID: UUID?
    private(set) var accessibilityGranted = TextDelivery.isAccessibilityTrusted
    private(set) var microphoneAccess = AudioCapture.access
    /// True while the setup checklist's own download runs, which moves Apple Speech modes when it ends.
    private(set) var isDownloadingRecommendedSpeech = false
    var isMovingRecorder = false
    var isEditingShortcut = false
    private var cancellationConfirmation = CancellationConfirmation() {
        didSet { updateRecorder() }
    }
    var isCancellationPending: Bool { cancellationConfirmation.isPending }
    /// Providers with an API key in the Keychain. Refreshed whenever a key is saved or removed.
    private(set) var connectedProviders: Set<ModelFamily> = []
    let audio = AudioCapture()
    let meetingAudio = MeetingCapture()
    let appleSpeech = AppleSpeechEngine()
    let library: ModelLibrary
    let updater = AppUpdater()

    @ObservationIgnored private let store: LocalStore?
    @ObservationIgnored private let localSpeech = LocalSpeechEngine()
    @ObservationIgnored private let normalizer = S1MiniRunner()
    @ObservationIgnored private let delivery = TextDelivery()
    @ObservationIgnored private let shortcuts = GlobalShortcuts()
    @ObservationIgnored private let recorder = RecorderPanelController()
    @ObservationIgnored private let playback = PlaybackController()
    @ObservationIgnored private var cloud: CloudProviders!
    /// The bundled S1-mini helper, checked once for views. Recording validation checks it again.
    @ObservationIgnored private let cleanupHelperAvailable = S1MiniRunner.isAvailable
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var speechPreparation: Task<Void, Never>?
    @ObservationIgnored private var modelReleaseCount = 0
    @ObservationIgnored private var preservation: Task<Void, Never>?
    @ObservationIgnored private var activeID: UUID?
    @ObservationIgnored private var cancellingID: UUID?
    @ObservationIgnored private var activeEntry: RecordingEntry?
    @ObservationIgnored private var destination: InsertionTarget?
    @ObservationIgnored private var startupComplete = false
    @ObservationIgnored private var changingConfiguration = false
    @ObservationIgnored private var retentionTask: Task<Void, Never>?
    @ObservationIgnored private var cancellationExpiry: Task<Void, Never>?
    @ObservationIgnored private var outcomeExpiry: Task<Void, Never>?
    @ObservationIgnored private var recorderHovering = false
    /// Set by Skip during the cleanup await. Skip and the returning cleanup both run on the main actor,
    /// and Skip is accepted only while the phase is cleaning, which `process()` leaves without
    /// suspending once the await returns. So exactly one of them delivers.
    @ObservationIgnored private var cleanupSkipped = false
    /// A cleanup failure keeps its rule-applied raw text and the destination captured when recording
    /// began, until the user pastes it, dismisses the offer, or starts other work.
    @ObservationIgnored private var originalOffer:
        (id: UUID, text: String, app: String?, destination: InsertionTarget?)?

    var currentMode: DictationMode {
        if phase.isBusy, let activeEntry { return activeEntry.mode }
        return modes.first(where: { $0.id == settings.selectedModeID }) ?? modes.first
            ?? DictationMode(name: "Voice to text", preset: .dictation)
    }
    var appleSpeechReady: Bool { appleSpeech.isPrepared }
    var recordingDuration: Double {
        activeEntry?.mode.recordSystemAudio == true ? meetingAudio.duration : audio.duration
    }
    var recordingLevel: Double {
        activeEntry?.mode.recordSystemAudio == true ? meetingAudio.level : audio.level
    }

    var recordingSpectrum: [Double] {
        activeEntry?.mode.recordSystemAudio == true ? meetingAudio.spectrum : audio.spectrum
    }

    /// The newest History text, final if there is one, for the menu bar's Copy last transcript.
    /// History is loaded newest first.
    var lastTranscript: String? {
        history.first { !$0.finalText.isEmpty || !$0.rawText.isEmpty }
            .map { $0.finalText.isEmpty ? $0.rawText : $0.finalText }
    }

    var microphoneName: String {
        if phase == .recording {
            return activeEntry?.mode.recordSystemAudio == true
                ? meetingAudio.selectedDeviceName : audio.selectedDeviceName
        }
        let available = audio.devices.filter(\.isConnected)
        for preference in microphones where preference.isEnabled {
            if let device = available.first(where: { $0.id == preference.id }) { return device.name }
        }
        return microphones.isEmpty
            ? (available.first?.name ?? "No microphone connected") : "No enabled microphone connected"
    }

    init() {
        var failure: Error?
        let opened: LocalStore?
        do { opened = try LocalStore() } catch {
            opened = nil
            failure = error
        }
        store = opened
        let fallbackRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AmanuensisUnavailable")
        library = ModelLibrary(
            rootURL: opened?.modelsURL ?? fallbackRoot,
            installations: opened?.installations() ?? []
        ) { [weak opened] installations in
            do { try opened?.saveInstallations(installations) } catch {
                NotificationCenter.default.post(
                    name: .amanuensisStorageError, object: error.localizedDescription)
            }
        }
        if let opened {
            let saved = opened.loadConfiguration()
            settings = saved.settings
            modes = saved.modes.isEmpty ? DictationMode.initial : saved.modes
            for index in modes.indices { modes[index].migrateModelIDs() }
            for (old, new) in DictationMode.legacyModelIDs {
                if let override = settings.apiModelOverrides.removeValue(forKey: old) {
                    settings.apiModelOverrides[new] = settings.apiModelOverrides[new] ?? override
                }
            }
            vocabulary = saved.vocabulary
            microphones = saved.microphones
            history = opened.loadRecordings()
            statistics = opened.statistics()
        }
        // refreshMicrophones() below saves the configuration, including this.
        if !settings.hasCompletedSetup && SetupChecklist.isImplied(by: statistics, history: history) {
            settings.hasCompletedSetup = true
        }
        cloud = CloudProviders(allowCloud: { [weak self] in self?.settings.requireLocalProcessing == false })
        audio.onInterruption = { [weak self] reason in self?.recordingInterrupted(reason) }
        meetingAudio.onInterruption = { [weak self] reason in self?.recordingInterrupted(reason) }
        recorder.onPlacementChanged = { [weak self] in self?.settings.recorderPlacement = $0 }
        recorder.onDraggingChanged = { [weak self] in self?.isMovingRecorder = $0 }
        startupComplete = true
        if let failure { errorMessage = "Could not open your local data: \(failure.localizedDescription)" }
        refreshMicrophones()
        refreshConnectedProviders()
        configureShortcuts()
        enforceRetention()
        // Smoke runs exercise bundled models offline and must not reach GitHub or replace the bundle.
        if !CommandLine.arguments.contains("--speech-smoke") { updater.startAutomaticChecks() }
        Task { [weak self] in
            guard let self else { return }
            _ = try? await appleSpeech.checkReadiness()
            updateRecorder()
        }
        retentionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self?.enforceRetention()
            }
        }
    }

    func toggleRecording() {
        if phase == .recording {
            stopRecording()
        } else if phase == .preparing {
            requestCancelRecording()
        } else if !phase.isBusy {
            beginRecording()
        }
    }

    private func beginRecording(mode override: DictationMode? = nil) {
        guard !phase.isBusy, activeID == nil, cancellingID == nil, !isEditingShortcut, modelReleaseCount == 0
        else {
            return
        }
        // An attempted start ends the previous job's outcome, even when the start is refused below.
        recorderOutcome = nil
        guard !updater.isInstalling else {
            report(AppFailure("Amanuensis is installing an update and will restart in a moment."))
            return
        }
        guard let store else {
            report(AppFailure("Local storage must be available before recording."))
            return
        }
        recorder.followDisplay(containing: NSEvent.mouseLocation)
        refreshAccessibility()
        let frontmost = NSWorkspace.shared.frontmostApplication
        let chosen: DictationMode
        if let override {
            chosen = override
        } else if settings.automaticModeSelection, let appID = frontmost?.bundleIdentifier,
            let automatic = modes.first(where: { $0.appBundleIDs.contains(appID) })
        {
            chosen = automatic
        } else {
            chosen = currentMode
        }
        let id = UUID()
        var entry = RecordingEntry(id: id, mode: chosen)
        entry.audioFileName = "\(id.uuidString).wav"
        entry.destinationApp = frontmost?.localizedName
        entry.speechSnapshot = effectiveModel(chosen.speechModelID)
        entry.cleanupSnapshot = chosen.cleanupModelID.flatMap(effectiveModel)
        entry.vocabularySnapshot = vocabulary
        activeID = id
        activeEntry = entry
        destination = delivery.captureDestination()
        phase = .preparing
        statusMessage = "Checking microphone and models…"
        errorMessage = nil
        work = Task { [weak self] in
            guard let self else { return }
            do {
                try await validate(entry)
                try ensureActive(id)
                library.inUseModelIDs = Set([chosen.speechModelID, chosen.cleanupModelID].compactMap { $0 })
                try store.upsertRecording(entry)
                refreshHistory()
                try playback.begin(chosen.playback)
                let url = store.recordingsURL.appendingPathComponent(entry.audioFileName!)
                // Starting may show the system microphone prompt.
                defer { microphoneAccess = AudioCapture.access }
                if chosen.recordSystemAudio {
                    try await meetingAudio.start(preferences: microphones, outputURL: url)
                } else {
                    try await audio.start(preferences: microphones, outputURL: url)
                }
                try ensureActive(id)
                prepareSpeechWhileRecording(entry)
                phase = .recording
                statusMessage = "Listening in \(chosen.name)"
                shortcuts.setRecordingActive(true)
                if settings.playSoundEffects { NSSound(named: "Tink")?.play() }
            } catch {
                audio.cancel()
                meetingAudio.cancel()
                restorePlayback()
                guard activeID == id else { return }
                await fail(entry, error: error)
            }
        }
    }

    func stopRecording() {
        guard phase == .recording, let entry = activeEntry, activeID == entry.id else { return }
        let id = entry.id
        phase = .transcribing
        statusMessage = "Saving your recording…"
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let captured: CapturedAudio
                if entry.mode.recordSystemAudio {
                    captured = try await meetingAudio.stop()
                } else {
                    captured = try await audio.stop()
                }
                restorePlayback()
                try ensureActive(id)
                var updated = entry
                updated.duration = captured.duration
                updated.status = .transcribing
                activeEntry = updated
                try store?.upsertRecording(updated)
                try await process(updated, audioURL: captured.url, shouldDeliver: true)
            } catch {
                restorePlayback()
                guard activeID == id else { return }
                await fail(activeEntry ?? entry, error: error)
            }
        }
    }

    /// User cancellation is separate from teardown, which must never wait for confirmation.
    func requestCancelRecording() {
        guard activeID != nil, phase.isBusy, phase != .delivering else { return }
        if cancellationConfirmation.request() {
            cancelRecording()
            return
        }
        cancellationExpiry?.cancel()
        cancellationExpiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(CancellationConfirmation.timeout)) } catch { return }
            self?.dismissCancellation()
        }
    }

    func dismissCancellation() {
        cancellationExpiry?.cancel()
        cancellationExpiry = nil
        if isCancellationPending { cancellationConfirmation.dismiss() }
    }

    private func cancelRecording() {
        dismissCancellation()
        guard let id = activeID else { return }
        // The paste has already been posted. Finish delivery and preserve History.
        guard phase != .delivering else {
            statusMessage = "Finishing text insertion…"
            return
        }
        let previousWork = work
        activeID = nil
        cancellingID = id
        previousWork?.cancel()
        let previousPreparation = speechPreparation
        previousPreparation?.cancel()
        speechPreparation = nil
        audio.cancel()
        meetingAudio.cancel()
        appleSpeech.cancel()
        localSpeech.cancel()
        normalizer.cancel()
        cloud.cancel()
        restorePlayback()
        do { try store?.deleteRecording(id: id) } catch { errorMessage = error.localizedDescription }
        activeEntry = nil
        destination = nil
        phase = .preparing
        statusMessage = "Stopping the current operation…"
        refreshHistory()
        Task { [weak self] in
            guard let self else { return }
            await audio.cancelAndWait()
            await meetingAudio.cancelAndWait()
            await previousWork?.value
            await previousPreparation?.value
            await localSpeech.unload()
            await normalizer.unload()
            finishCancelledJob(id)
        }
    }

    private func prepareSpeechWhileRecording(_ entry: RecordingEntry) {
        guard let speech = entry.speechSnapshot, speech.location == .local,
            [.whisper, .parakeet, .cohere].contains(speech.family),
            let directory = library.localURL(for: speech.id)
        else { return }
        speechPreparation = Task { [localSpeech] in
            // Preparation is optional. The transcription call will report/retry a load error.
            try? await localSpeech.prepare(modelDirectory: directory, family: speech.family.rawValue)
        }
    }

    private func stopSpeechPreparation() async {
        let preparation = speechPreparation
        speechPreparation = nil
        preparation?.cancel()
        await preparation?.value
    }

    /// File removal waits until both runtimes have relinquished their mapped weights.
    func removeModel(_ descriptor: ModelDescriptor) async throws {
        guard !phase.isBusy, modelReleaseCount == 0 else {
            throw AppFailure("Finish the current operation before removing a model.")
        }
        modelReleaseCount += 1
        defer { modelReleaseCount -= 1 }
        await stopSpeechPreparation()
        await localSpeech.unload()
        await normalizer.unload()
        try library.remove(descriptor)
    }

    private func process(_ original: RecordingEntry, audioURL: URL, shouldDeliver: Bool) async throws {
        await speechPreparation?.value
        speechPreparation = nil
        try ensureActive(original.id)
        var entry = original
        let id = entry.id
        guard let speech = entry.speechSnapshot ?? effectiveModel(entry.mode.speechModelID) else {
            throw AppFailure("Choose a speech model in this mode's settings.")
        }
        statusMessage = "Transcribing with \(speech.name)…"
        phase = .transcribing
        let raw: String
        if speech.location == .cloud {
            raw = try await cloud.transcribe(
                audioURL: audioURL, model: speech,
                vocabulary: entry.vocabularySnapshot ?? [])
        } else if speech.family == .apple {
            raw = try await appleSpeech.transcribe(url: audioURL)
        } else {
            guard let directory = library.localURL(for: speech.id) else {
                throw RecordingFailure.modelNotInstalled(speech.name)
            }
            raw = try await localSpeech.transcribe(
                audioURL: audioURL, modelDirectory: directory, family: speech.family.rawValue)
        }
        try ensureActive(id)
        entry.rawText = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        activeEntry = entry
        try store?.upsertRecording(entry)
        refreshHistory()
        if entry.rawText.isEmpty {
            entry.status = .noSpeech
            try complete(entry, message: "No speech detected. Nothing was inserted.", outcome: .noSpeech)
            return
        }

        var selectedText = entry.rawText
        if let cleanup = entry.cleanupSnapshot {
            phase = .cleaning
            statusMessage = "Cleaning up with \(cleanup.name)…"
            entry.status = .cleaning
            try store?.upsertRecording(entry)
            cleanupSkipped = false
            let result: Result<String, any Error>
            do { result = .success(try await clean(entry.rawText, with: cleanup, mode: entry.mode)) } catch {
                result = .failure(error)
            }
            // Skip wins even if the model finished; its cancellation error is ignored.
            let skipped = cleanupSkipped
            cleanupSkipped = false
            try ensureActive(id)
            switch (skipped, result) {
            case (true, _):
                entry.cleanupSkipped = true
            case (false, .success(let cleaned)):
                selectedText = cleaned
                entry.cleanedText = cleaned
                activeEntry = entry
            case (false, .failure(let error)):
                entry.error = "Cleanup failed: \(error.localizedDescription)"
                entry.finalText = TextRules.apply(
                    entry.rawText, vocabulary: entry.vocabularySnapshot ?? [],
                    capitalize: entry.mode.capitalize)
                entry.status = .failed
                originalOffer = (id, entry.finalText, entry.destinationApp, destination)
                try complete(
                    entry, message: "Cleanup failed. Your original transcript is saved in History.",
                    outcome: .cleanupFailed)
                return
            }
        }
        try ensureActive(id)
        entry.finalText = TextRules.apply(
            selectedText, vocabulary: entry.vocabularySnapshot ?? [], capitalize: entry.mode.capitalize)
        entry.status = entry.finalText.isEmpty ? .empty : .complete
        activeEntry = entry
        try store?.upsertRecording(entry)
        if entry.finalText.isEmpty {
            try complete(
                entry, message: "Nothing to insert. The original transcript is available in History.",
                outcome: .nothingToInsert)
            return
        }
        let outcome: RecorderOutcome.Cause
        if shouldDeliver && entry.mode.autoPaste {
            phase = .delivering
            statusMessage = "Inserting your text…"
            let delivered = await delivery.deliver(text: entry.finalText, to: destination)
            try ensureActive(id)
            refreshAccessibility()
            entry.deliveryMessage = delivered.message
            outcome = cause(of: delivered, app: entry.destinationApp)
        } else {
            entry.deliveryMessage = "Your transcript is ready to copy."
            outcome = .savedToHistory
        }
        try complete(entry, message: entry.deliveryMessage ?? "Your transcript is ready.", outcome: outcome)
    }

    private func clean(_ text: String, with cleanup: ModelDescriptor, mode: DictationMode) async throws
        -> String
    {
        if cleanup.location == .cloud {
            return try await cloud.clean(text: text, model: cleanup, mode: mode)
        }
        guard cleanup.family == .s1mini else {
            throw AppFailure("This cleanup engine is not supported by this build.")
        }
        guard let path = library.localURL(for: cleanup.id) else {
            throw AppFailure("Install S1-mini first.")
        }
        return try await normalizer.clean(text: text, modelURL: path, mode: mode)
    }

    private func cause(of delivered: DeliveryOutcome, app: String?) -> RecorderOutcome.Cause {
        switch delivered {
        case .commandPosted: .inserted(app: app)
        case .copied: .copied
        case .accessibilityRequired: .needsAccessibility
        // Held text may not be on the clipboard, so point to History instead.
        case .held: .failed(nil)
        }
    }

    /// Ends cleanup early and finishes as if the mode had no cleanup model.
    func skipCleanup() {
        guard phase == .cleaning, activeID != nil, !cleanupSkipped else { return }
        cleanupSkipped = true
        statusMessage = "Skipping cleanup…"
        normalizer.cancel()
        cloud.cancel()
    }

    /// Uses the same rules as the mode markers, after rechecking what they cache: model folders on disk,
    /// Apple Speech assets, and the Keychain for the API models this recording uses. A Keychain error
    /// is thrown as itself rather than reported as a missing key.
    private func validate(_ entry: RecordingEntry) async throws {
        if entry.speechSnapshot?.family == .apple { try await appleSpeech.checkReadiness() }
        library.refreshInstalledModels()
        var facts = readiness
        facts.cleanupHelperAvailable = S1MiniRunner.isAvailable
        if !settings.requireLocalProcessing {
            for model in [entry.speechSnapshot, entry.cleanupSnapshot].compactMap({ $0 })
            where model.location == .cloud {
                if try CredentialStore.get(for: model.family) == nil {
                    facts.connectedProviders.remove(model.family)
                } else {
                    facts.connectedProviders.insert(model.family)
                }
            }
        }
        if let failure = facts.blocker(
            speech: entry.speechSnapshot, cleanup: entry.cleanupSnapshot,
            identifySpeakers: entry.mode.identifySpeakers)
        {
            throw failure
        }
    }

    /// What decides whether a mode can record, from state kept in memory, so views can read it freely.
    var readiness: RecordingReadiness {
        RecordingReadiness(
            requireLocalProcessing: settings.requireLocalProcessing,
            installedModelIDs: library.installedModelIDs, connectedProviders: connectedProviders,
            appleSpeechReady: appleSpeech.isPrepared, cleanupHelperAvailable: cleanupHelperAvailable)
    }

    /// Why each mode cannot record yet. Modes that can record are absent. Views read it once per render.
    var modeBlockers: [UUID: RecordingFailure] {
        let readiness = readiness
        return modes.reduce(into: [:]) { blockers, mode in
            blockers[mode.id] = readiness.blocker(
                speech: effectiveModel(mode.speechModelID),
                cleanup: mode.cleanupModelID.flatMap(effectiveModel),
                identifySpeakers: mode.identifySpeakers)
        }
    }

    /// The current mode's speech model, or nil if the catalog no longer has it.
    var currentSpeechModel: ModelDescriptor? { effectiveModel(currentMode.speechModelID) }

    var setupChecklist: SetupChecklist {
        SetupChecklist(
            microphone: microphoneAccess,
            speechBlocker: readiness.blocker(
                speech: currentSpeechModel, cleanup: nil, identifySpeakers: false),
            accessibilityGranted: accessibilityGranted,
            textInsertionSkipped: settings.skippedTextInsertionSetup == true)
    }

    private func complete(_ entry: RecordingEntry, message: String, outcome: RecorderOutcome.Cause) throws {
        try store?.upsertRecording(entry)
        try store?.countIfNeeded(recording: entry)
        activeID = nil
        activeEntry = nil
        destination = nil
        library.inUseModelIDs = []
        shortcuts.setRecordingActive(false)
        // Showing the outcome while the phase is still busy lets the pill change in place instead of
        // hiding, when controls are not kept visible, and reappearing at idle size.
        showOutcome(outcome, for: entry.id)
        phase = .complete
        statusMessage = message
        refreshHistory()
        enforceRetention()
    }

    private func fail(_ original: RecordingEntry, error: Error) async {
        await stopSpeechPreparation()
        await localSpeech.unload()
        guard activeID == original.id else { return }
        var entry = original
        entry.status = .failed
        entry.error = error.localizedDescription
        if entry.finalText.isEmpty { entry.finalText = entry.rawText }
        do { try store?.upsertRecording(entry) } catch { errorMessage = error.localizedDescription }
        activeID = nil
        activeEntry = nil
        destination = nil
        library.inUseModelIDs = []
        shortcuts.setRecordingActive(false)
        showOutcome(.failed(error as? RecordingFailure), for: entry.id)
        phase = .failed
        statusMessage = entry.error ?? "Recording could not finish."
        errorMessage = entry.error
        refreshHistory()
    }

    private func finishCancelledJob(_ id: UUID) {
        guard cancellingID == id else { return }
        cancellingID = nil
        library.inUseModelIDs = []
        phase = .idle
        statusMessage = "Canceled."
        refreshHistory()
    }

    private func ensureActive(_ id: UUID) throws {
        try Task.checkCancellation()
        guard activeID == id else { throw CancellationError() }
    }

    private func recordingInterrupted(_ reason: String) {
        guard phase == .recording, let original = activeEntry else { return }
        phase = .transcribing
        statusMessage = "Preserving captured audio…"
        restorePlayback()
        work = Task { [weak self] in
            guard let self else { return }
            var entry = original
            do {
                let captured: CapturedAudio
                if entry.mode.recordSystemAudio {
                    captured = try await meetingAudio.stop()
                } else {
                    captured = try await audio.stop()
                }
                try ensureActive(entry.id)
                entry.duration = captured.duration
                await stopSpeechPreparation()
                await localSpeech.unload()
                try ensureActive(entry.id)
                entry.status = .interrupted
                entry.error = reason
                try complete(
                    entry, message: "\(reason) Captured audio is saved in History.", outcome: .interrupted)
                phase = .interrupted
            } catch {
                guard activeID == entry.id else { return }
                await fail(entry, error: error)
            }
        }
    }

    func retryRecording(_ original: RecordingEntry) async {
        guard !phase.isBusy, activeID == nil, cancellingID == nil, modelReleaseCount == 0, let store else {
            return
        }
        guard !updater.isInstalling else {
            report(AppFailure("Amanuensis is installing an update and will restart in a moment."))
            return
        }
        guard let sourceURL = store.acquireAudioLease(for: original) else {
            report(AppFailure("The audio has expired or is unavailable."))
            return
        }
        var entry = original.retryAttempt()
        entry.speechSnapshot = original.speechSnapshot ?? effectiveModel(original.mode.speechModelID)
        entry.cleanupSnapshot =
            original.cleanupSnapshot ?? original.mode.cleanupModelID.flatMap(effectiveModel)
        let id = entry.id
        let attemptURL = store.recordingsURL.appendingPathComponent("\(id.uuidString).wav")
        activeID = entry.id
        activeEntry = entry
        destination = nil
        phase = .preparing
        statusMessage = "Checking the original recording settings…"
        errorMessage = nil
        let task = Task { [weak self] in
            guard let self else {
                try? store.releaseAudioLease(for: original)
                return
            }
            defer {
                do { try store.releaseAudioLease(for: original) } catch {
                    errorMessage = "Could not finish audio cleanup: \(error.localizedDescription)"
                }
                refreshHistory()
            }
            do {
                try store.upsertRecording(entry)
                refreshHistory()
                // Each attempt owns its audio. Deleting either entry cannot invalidate the other.
                try await Task.detached(priority: .utility) {
                    try FileManager.default.copyItem(at: sourceURL, to: attemptURL)
                }.value
                try ensureActive(id)
                try await validate(entry)
                try ensureActive(id)
                library.inUseModelIDs = Set(
                    [entry.mode.speechModelID, entry.mode.cleanupModelID].compactMap { $0 })
                try await process(entry, audioURL: attemptURL, shouldDeliver: false)
            } catch {
                guard activeID == id else {
                    // A file copy can finish after cancellation has already removed its database row.
                    try? FileManager.default.removeItem(at: attemptURL)
                    return
                }
                await fail(activeEntry ?? entry, error: error)
            }
        }
        work = task
        await task.value
    }

    func requestMicrophoneAccess() async {
        _ = await AudioCapture.requestAccess()
        microphoneAccess = AudioCapture.access
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        {
            NSWorkspace.shared.open(url)
        }
    }

    /// Starts a catalog download from a setup or mode row. Progress and errors stay on `library`,
    /// so every row showing this model shows the same download.
    @discardableResult func download(_ descriptor: ModelDescriptor) async -> Bool {
        do {
            try await library.install(descriptor)
            return true
        } catch { return false }
    }

    /// The setup checklist's local route: download the recommended model if needed, then move every
    /// mode still on Apple Speech to it. Cancel or failure leaves the modes alone.
    func downloadAndUseRecommendedSpeech() async {
        let recommended = ModelCatalog.recommendedSpeech
        // Recheck the disk first, so modes never move to a model whose files were removed outside the app.
        library.refreshInstalledModels()
        if !library.installedModelIDs.contains(recommended.id) {
            guard !isDownloadingRecommendedSpeech else { return }
            isDownloadingRecommendedSpeech = true
            defer { isDownloadingRecommendedSpeech = false }
            guard await download(recommended) else { return }
        }
        for index in modes.indices where modes[index].speechModelID == "apple-speech" {
            modes[index].speechModelID = recommended.id
        }
        saveConfiguration()
    }

    func prepareAppleSpeech() async {
        do {
            statusMessage = "Preparing Apple's English speech model…"
            try await appleSpeech.prepare()
            statusMessage = "Apple Speech is ready on this Mac."
        } catch { report(error) }
    }

    func selectMode(_ id: UUID) {
        settings.selectedModeID = id
        settings.automaticModeSelection = false
    }

    /// New modes start from a blank template that reuses the current speech model.
    @discardableResult func createMode(name: String, symbol: String) -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var mode = DictationMode(name: trimmed.isEmpty ? "New mode" : trimmed, preset: .custom)
        mode.customSymbol = symbol
        mode.speechModelID = currentMode.speechModelID
        modes.append(mode)
        saveConfiguration()
        return mode.id
    }

    /// Models a mode can pick right now: installed local models, Apple Speech, and API models with a key.
    /// The mode's current choice is included even when it is not ready so the picker never goes blank.
    func availableModels(for purpose: ModelPurpose, including currentID: String?) -> [ModelDescriptor] {
        let readiness = readiness
        return library.models.filter { descriptor in
            guard descriptor.purpose == purpose, descriptor.family != .ollama else { return false }
            return descriptor.id == currentID || readiness.isAvailable(descriptor)
        }
    }

    func updateMode(_ mode: DictationMode) {
        guard let index = modes.firstIndex(where: { $0.id == mode.id }) else { return }
        let otherApps = Set(modes.filter { $0.id != mode.id }.flatMap(\.appBundleIDs))
        guard otherApps.isDisjoint(with: mode.appBundleIDs) else {
            report(AppFailure("An app can belong to only one automatic mode."))
            return
        }
        var proposed = modes
        proposed[index] = mode
        if modes[index].startShortcut != mode.startShortcut,
            !configureShortcuts(modes: proposed)
        {
            return
        }
        modes = proposed
        saveConfiguration()
    }

    func deleteMode(_ id: UUID) {
        guard modes.count > 1 else {
            report(AppFailure("Keep at least one mode."))
            return
        }
        let proposed = modes.filter { $0.id != id }
        guard configureShortcuts(modes: proposed) else { return }
        modes = proposed
        if settings.selectedModeID == id { settings.selectedModeID = modes.first?.id }
        saveConfiguration()
    }

    func addVocabulary(word: String, replacement: String?) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard
            !vocabulary.contains(where: { $0.word.localizedCaseInsensitiveCompare(trimmed) == .orderedSame })
        else {
            report(AppFailure("That word or phrase is already in your vocabulary."))
            return
        }
        let normalized = replacement?.trimmingCharacters(in: .whitespacesAndNewlines)
        vocabulary.append(
            VocabularyEntry(word: trimmed, replacement: normalized?.isEmpty == false ? normalized : nil))
        saveConfiguration()
    }
    func removeVocabulary(_ id: UUID) {
        vocabulary.removeAll { $0.id == id }
        saveConfiguration()
    }

    func refreshMicrophones() {
        audio.refreshDevices()
        for device in audio.devices where !microphones.contains(where: { $0.id == device.id }) {
            microphones.append(MicrophonePreference(id: device.id, name: device.name))
        }
        saveConfiguration()
    }

    func saveConfiguration() {
        guard startupComplete, let store else { return }
        do {
            try store.saveConfiguration(
                SavedConfiguration(
                    settings: settings, modes: modes, vocabulary: vocabulary, microphones: microphones))
        } catch { errorMessage = "Could not save settings: \(error.localizedDescription)" }
    }

    func deleteRecording(_ id: UUID) {
        if activeID == id {
            // History already confirmed deletion in its destructive-action alert.
            cancelRecording()
            return
        }
        do {
            try store?.deleteRecording(id: id)
            // A deleted recording's outcome must not offer its text; this also drops a Paste original offer.
            if recorderOutcome?.recordingID == id { recorderOutcome = nil }
            refreshHistory()
        } catch { report(error) }
    }
    func copyText(_ text: String) { if delivery.copy(text: text) { statusMessage = "Copied to clipboard." } }
    func resetStatistics() {
        do {
            try store?.resetStatistics()
            refreshHistory()
        } catch { report(error) }
    }
    /// Picks up permission and Apple Speech changes made in System Settings while the app was inactive.
    func refreshPermissions() {
        refreshAccessibility()
        microphoneAccess = AudioCapture.access
        Task { _ = try? await appleSpeech.checkReadiness() }
    }

    func refreshAccessibility() {
        accessibilityGranted = TextDelivery.isAccessibilityTrusted
        if accessibilityGranted && recorderOutcome?.action == .allowPaste { recorderOutcome = nil }
    }

    private func showOutcome(_ cause: RecorderOutcome.Cause, for id: UUID) {
        let outcome = RecorderOutcome(cause, recordingID: id)
        recorderOutcome = outcome
        if outcome.kind == .failure || outcome.kind == .warning {
            AccessibilityNotification.Announcement(outcome.label).post()
        }
    }

    func dismissOutcome() { recorderOutcome = nil }

    /// Runs the pill's action button and ends its outcome. Paste original ends it only once delivery
    /// starts; if another job is running, the offer stays.
    func performOutcomeAction() {
        guard let outcome = recorderOutcome, let action = outcome.action else { return }
        switch action {
        case .allowPaste: requestAccessibility()
        case .pasteOriginal: pasteOriginal()
        case .openModels: showMainWindow(.models)
        case .openSettings: showMainWindow(.configuration)
        case .openSound: showMainWindow(.sound)
        case .showInHistory:
            selectedRecordingID = outcome.recordingID
            showMainWindow(.history)
        }
        if action != .pasteOriginal { recorderOutcome = nil }
    }

    func showMainWindow(_ section: AppSection) {
        selectedSection = section
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { !($0 is NSPanel) }?.makeKeyAndOrderFront(nil)
    }

    /// Delivers a failed cleanup's original text to the destination captured when recording began.
    /// Delivery rechecks focus and falls back to the clipboard, then History records what happened.
    private func pasteOriginal() {
        guard let offer = originalOffer, !phase.isBusy, activeID == nil, cancellingID == nil else { return }
        phase = .delivering
        statusMessage = "Inserting your original transcript…"
        work = Task { [weak self] in
            guard let self else { return }
            let delivered = await delivery.deliver(text: offer.text, to: offer.destination)
            refreshAccessibility()
            if var entry = history.first(where: { $0.id == offer.id }) {
                entry.deliveryMessage = delivered.message
                do { try store?.upsertRecording(entry) } catch { errorMessage = error.localizedDescription }
                refreshHistory()
            }
            showOutcome(cause(of: delivered, app: offer.app), for: offer.id)
            phase = .complete
            statusMessage = delivered.message
        }
    }

    func setRecorderHovering(_ hovering: Bool) {
        recorderHovering = hovering
        guard !hovering else { return }
        recorderOutcome?.pointerLeft(at: ProcessInfo.processInfo.systemUptime)
        // The expiry check stops while the pointer is on the pill, so restart it even if the deadline held.
        scheduleOutcomeExpiry()
    }

    /// Closes a success or notice at its deadline. If the pointer is on the pill then, leaving it
    /// moves the deadline, which schedules a new check.
    private func scheduleOutcomeExpiry() {
        outcomeExpiry?.cancel()
        guard let deadline = recorderOutcome?.deadline else { return }
        outcomeExpiry = Task { [weak self] in
            while true {
                guard let self, let outcome = recorderOutcome, !recorderHovering else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if outcome.isExpired(at: now) {
                    recorderOutcome = nil
                    return
                }
                // The suspending clock matches systemUptime, which also pauses while the Mac sleeps.
                do { try await Task.sleep(for: .seconds(deadline - now), clock: .suspending) } catch {
                    return
                }
            }
        }
    }

    func requestAccessibility() {
        TextDelivery.requestAccessibility()
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        {
            NSWorkspace.shared.open(url)
        }
        refreshAccessibility()
    }
    func saveAPIKey(_ key: String, provider: ModelFamily) throws {
        defer { refreshConnectedProviders() }
        if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try CredentialStore.remove(for: provider)
        } else {
            try CredentialStore.set(key.trimmingCharacters(in: .whitespacesAndNewlines), for: provider)
        }
    }
    func removeAPIKey(provider: ModelFamily) throws {
        defer { refreshConnectedProviders() }
        try CredentialStore.remove(for: provider)
    }
    private func refreshConnectedProviders() {
        connectedProviders = Set(
            [ModelFamily.openAI, .groq, .anthropic].filter { (try? CredentialStore.get(for: $0)) != nil })
    }
    func validateAPI(provider: ModelFamily, modelID: String) async throws -> String {
        try await cloud.validate(provider: provider, modelID: modelID)
    }

    /// Sleep and normal quit preserve unfinished work; only explicit Cancel discards it.
    func preserveUnfinishedRecording() async {
        if let preservation {
            await preservation.value
            return
        }
        let task = Task { await self.preserveAndUnload() }
        preservation = task
        await task.value
        preservation = nil
    }

    private func preserveAndUnload() async {
        modelReleaseCount += 1
        defer { modelReleaseCount -= 1 }
        let previousWork = work
        if phase == .delivering {
            await previousWork?.value
            await localSpeech.unload()
            await normalizer.unload()
            return
        }
        guard var entry = activeEntry, let id = activeID else {
            await stopSpeechPreparation()
            await localSpeech.unload()
            await normalizer.unload()
            return
        }
        let wasRecording = phase == .recording
        activeID = nil
        cancellingID = id
        phase = .preparing
        statusMessage = "Saving unfinished work…"
        previousWork?.cancel()
        appleSpeech.cancel()
        localSpeech.cancel()
        normalizer.cancel()
        cloud.cancel()
        restorePlayback()
        if wasRecording {
            do {
                let captured: CapturedAudio
                if entry.mode.recordSystemAudio {
                    captured = try await meetingAudio.stop()
                } else {
                    captured = try await audio.stop()
                }
                entry.duration = captured.duration
            } catch { entry.error = error.localizedDescription }
        } else {
            await audio.cancelAndWait()
            await meetingAudio.cancelAndWait()
        }
        await stopSpeechPreparation()
        await previousWork?.value
        await localSpeech.unload()
        await normalizer.unload()
        entry.status = .interrupted
        if entry.error == nil { entry.error = "Interrupted before completion. Retry from History." }
        if let store, store.audioURL(for: entry) == nil { entry.audioFileName = nil }
        do { try store?.upsertRecording(entry) } catch { errorMessage = error.localizedDescription }
        activeEntry = nil
        destination = nil
        cancellingID = nil
        library.inUseModelIDs = []
        showOutcome(.interrupted, for: entry.id)
        phase = .interrupted
        statusMessage = "Unfinished work is saved in History."
        refreshHistory()
    }

    func shutdown() {
        cancelRecording()
        retentionTask?.cancel()
        restorePlayback()
        recorder.hide()
    }

    private func effectiveModel(_ id: String) -> ModelDescriptor? {
        guard var model = library.models.first(where: { $0.id == id }) else { return nil }
        if let override = settings.apiModelOverrides[id],
            !override.trimmingCharacters(in: .whitespaces).isEmpty
        {
            model.apiModelID = override.trimmingCharacters(in: .whitespaces)
        }
        return model
    }

    private func configurationChanged(previous: AppSettings) {
        guard startupComplete, !changingConfiguration else { return }
        changingConfiguration = true
        defer { changingConfiguration = false }
        if settings.requireLocalProcessing && !previous.requireLocalProcessing { cloud.cancel() }
        if settings.toggleShortcut != previous.toggleShortcut
            || settings.pushToTalkShortcut != previous.pushToTalkShortcut
            || settings.modeShortcut != previous.modeShortcut
        {
            if !configureShortcuts() {
                settings.toggleShortcut = previous.toggleShortcut
                settings.pushToTalkShortcut = previous.pushToTalkShortcut
                settings.modeShortcut = previous.modeShortcut
            }
        }
        if settings.launchAtLogin != previous.launchAtLogin {
            do {
                if settings.launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                settings.launchAtLogin = previous.launchAtLogin
                errorMessage = error.localizedDescription
            }
        }
        saveConfiguration()
        updateRecorder()
        enforceRetention()
    }

    @discardableResult
    private func configureShortcuts(modes proposedModes: [DictationMode]? = nil) -> Bool {
        let succeeded = shortcuts.setBindings(
            toggle: settings.toggleShortcut, pushToTalk: settings.pushToTalkShortcut,
            changeMode: settings.modeShortcut,
            onToggle: { [weak self] in
                guard let self, !isEditingShortcut else { return }
                toggleRecording()
            },
            onPushToTalk: { [weak self] down in
                guard let self, !isEditingShortcut else { return }
                if down {
                    if !phase.isBusy { beginRecording() }
                } else if phase == .preparing {
                    cancelRecording()
                } else if phase == .recording {
                    stopRecording()
                }
            },
            onChangeMode: { [weak self] in
                guard let self, !isEditingShortcut, !modes.isEmpty else { return }
                let index = modes.firstIndex(where: { $0.id == settings.selectedModeID }) ?? 0
                selectMode(modes[(index + 1) % modes.count].id)
            },
            onCancel: { [weak self] in self?.requestCancelRecording() },
            modeBindings: Dictionary(
                uniqueKeysWithValues: (proposedModes ?? modes).compactMap { mode in
                    mode.startShortcut.map { (mode.id, $0) }
                }),
            onModeRecording: { [weak self] id in
                guard let self, !isEditingShortcut else { return }
                if phase == .recording {
                    stopRecording()
                } else if !phase.isBusy, let mode = modes.first(where: { $0.id == id }) {
                    beginRecording(mode: mode)
                }
            },
            onInterruption: { [weak self] in Task { await self?.preserveUnfinishedRecording() } })
        if !shortcuts.registrationErrors.isEmpty {
            errorMessage = shortcuts.registrationErrors.joined(separator: "\n")
        }
        return succeeded
    }

    func resizeRecorder(to size: CGSize) {
        recorder.resize(to: size)
    }

    func moveRecorder(translation: CGSize) { recorder.updateDrag(translation: translation) }
    func finishMovingRecorder() { recorder.finishDrag(at: NSEvent.mouseLocation) }
    func cancelMovingRecorder() { recorder.cancelDrag() }

    private func updateRecorder() {
        guard startupComplete else { return }
        if let style = RecorderLayout.presentedStyle(
            saved: settings.recorderStyle, alwaysShow: settings.alwaysShowRecorder, busy: phase.isBusy,
            cancellationPending: isCancellationPending, outcome: recorderOutcome)
        {
            recorder.show(
                content: AnyView(RecorderView(model: self)), style: style,
                placement: settings.recorderPlacement)
        } else {
            recorder.hide()
            // A hidden panel reports no hover exit, so a stale hover must not hold the next outcome open.
            recorderHovering = false
        }
    }

    private func refreshHistory() {
        history = store?.loadRecordings() ?? []
        statistics = store?.statistics() ?? UsageStatistics()
    }
    private func enforceRetention() {
        do {
            try store?.enforceRetention(settings: settings, activeIDs: Set([activeID].compactMap { $0 }))
            refreshHistory()
        } catch { errorMessage = "Could not apply retention: \(error.localizedDescription)" }
    }
    private func restorePlayback() {
        playback.end()
        if let failure = playback.restorationError { errorMessage = failure }
    }

    private func report(_ error: Error) {
        errorMessage = error.localizedDescription
        if activeID == nil && cancellingID == nil && !phase.isBusy {
            statusMessage = error.localizedDescription
            phase = .failed
        }
    }
}

private struct AppFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension Notification.Name {
    static let amanuensisStorageError = Notification.Name("AmanuensisStorageError")
}
