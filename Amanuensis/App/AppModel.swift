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
            shortcuts.setRecordingActive(phase.isBusy)
            updateRecorder()
        }
    }
    var statusMessage = "Your voice, on your Mac."
    var errorMessage: String?
    var isEditingShortcut = false
    let audio = AudioCapture()
    let meetingAudio = MeetingCapture()
    let appleSpeech = AppleSpeechEngine()
    let library: ModelLibrary

    @ObservationIgnored private let store: LocalStore?
    @ObservationIgnored private let localSpeech = LocalSpeechEngine()
    @ObservationIgnored private let normalizer = S1MiniRunner()
    @ObservationIgnored private let delivery = TextDelivery()
    @ObservationIgnored private let shortcuts = GlobalShortcuts()
    @ObservationIgnored private let recorder = RecorderPanelController()
    @ObservationIgnored private let playback = PlaybackController()
    @ObservationIgnored private var cloud: CloudProviders!
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var activeID: UUID?
    @ObservationIgnored private var cancellingID: UUID?
    @ObservationIgnored private var activeEntry: RecordingEntry?
    @ObservationIgnored private var destination: InsertionTarget?
    @ObservationIgnored private var startupComplete = false
    @ObservationIgnored private var changingConfiguration = false
    @ObservationIgnored private var retentionTask: Task<Void, Never>?

    var currentMode: DictationMode {
        if phase.isBusy, let activeEntry { return activeEntry.mode }
        return modes.first(where: { $0.id == settings.selectedModeID }) ?? modes.first
            ?? DictationMode(name: "Voice to text", preset: .dictation)
    }
    var accessibilityGranted: Bool { TextDelivery.isAccessibilityTrusted }
    var appleSpeechReady: Bool { appleSpeech.isPrepared }
    var recordingDuration: Double {
        activeEntry?.mode.recordSystemAudio == true ? meetingAudio.duration : audio.duration
    }
    var recordingLevel: Double {
        activeEntry?.mode.recordSystemAudio == true ? meetingAudio.level : audio.level
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
            vocabulary = saved.vocabulary
            microphones = saved.microphones
            history = opened.loadRecordings()
            statistics = opened.statistics()
        }
        cloud = CloudProviders(allowCloud: { [weak self] in self?.settings.requireLocalProcessing == false })
        audio.onInterruption = { [weak self] reason in self?.recordingInterrupted(reason) }
        meetingAudio.onInterruption = { [weak self] reason in self?.recordingInterrupted(reason) }
        startupComplete = true
        if let failure { errorMessage = "Could not open your local data: \(failure.localizedDescription)" }
        refreshMicrophones()
        configureShortcuts()
        enforceRetention()
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
            cancelRecording()
        } else if !phase.isBusy {
            beginRecording()
        }
    }

    private func beginRecording(mode override: DictationMode? = nil) {
        guard !phase.isBusy, activeID == nil, cancellingID == nil, !isEditingShortcut else { return }
        guard let store else {
            report(AppFailure("Local storage must be available before recording."))
            return
        }
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
                if chosen.recordSystemAudio {
                    try await meetingAudio.start(preferences: microphones, outputURL: url)
                } else {
                    try await audio.start(preferences: microphones, outputURL: url)
                }
                try ensureActive(id)
                phase = .recording
                statusMessage = "Listening in \(chosen.name)"
                shortcuts.setRecordingActive(true)
                if settings.playSoundEffects { NSSound(named: "Tink")?.play() }
            } catch {
                audio.cancel()
                meetingAudio.cancel()
                restorePlayback()
                guard activeID == id else { return }
                fail(entry, error: error)
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
                fail(activeEntry ?? entry, error: error)
            }
        }
    }

    func cancelRecording() {
        guard let id = activeID else { return }
        // The paste has already been posted. Finish clipboard restoration and preserve History.
        guard phase != .delivering else {
            statusMessage = "Finishing text insertion and restoring your clipboard…"
            return
        }
        let previousWork = work
        activeID = nil
        cancellingID = id
        previousWork?.cancel()
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
            finishCancelledJob(id)
        }
    }

    private func process(_ original: RecordingEntry, audioURL: URL, shouldDeliver: Bool) async throws {
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
                throw AppFailure("Install \(speech.name) first.")
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
            try complete(entry, message: "No speech detected. Nothing was inserted.")
            return
        }

        var selectedText = entry.rawText
        if let cleanup = entry.cleanupSnapshot {
            phase = .cleaning
            statusMessage = "Cleaning up with \(cleanup.name)…"
            entry.status = .cleaning
            try store?.upsertRecording(entry)
            do {
                if cleanup.location == .cloud {
                    selectedText = try await cloud.clean(
                        text: entry.rawText, model: cleanup, mode: entry.mode)
                } else if cleanup.family == .s1mini {
                    guard let path = library.localURL(for: cleanup.id) else {
                        throw AppFailure("Install S1-mini first.")
                    }
                    selectedText = try await normalizer.clean(
                        text: entry.rawText, modelURL: path, mode: entry.mode)
                } else {
                    throw AppFailure("This cleanup engine is not supported by this build.")
                }
                try ensureActive(id)
                entry.cleanedText = selectedText
                activeEntry = entry
            } catch {
                try ensureActive(id)
                entry.error = "Cleanup failed: \(error.localizedDescription)"
                entry.finalText = TextRules.apply(
                    entry.rawText, vocabulary: entry.vocabularySnapshot ?? [],
                    capitalize: entry.mode.capitalize)
                entry.status = .failed
                try complete(entry, message: "Cleanup failed. Your original transcript is saved in History.")
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
                entry, message: "Nothing to insert. The original transcript is available in History.")
            return
        }
        if shouldDeliver && entry.mode.autoPaste {
            phase = .delivering
            statusMessage = "Inserting your text…"
            let outcome = await delivery.deliver(text: entry.finalText, to: destination)
            try ensureActive(id)
            entry.deliveryMessage = outcome.message
        } else {
            entry.deliveryMessage = "Your transcript is ready to copy."
        }
        try complete(entry, message: entry.deliveryMessage ?? "Your transcript is ready.")
    }

    private func validate(_ entry: RecordingEntry) async throws {
        guard let speech = entry.speechSnapshot else {
            throw AppFailure("The selected speech model is missing.")
        }
        for model in [speech, entry.cleanupSnapshot].compactMap({ $0 }) {
            if settings.requireLocalProcessing && !model.isLocal {
                throw AppFailure(
                    "\(model.name) uses an API. Choose a local model or turn off Require local processing.")
            }
            if model.location == .local && library.localURL(for: model.id) == nil {
                throw AppFailure("Install \(model.name) from Models before recording.")
            }
            if model.location == .cloud, try CredentialStore.get(for: model.family) == nil {
                throw AppFailure("Add your \(model.provider) API key in Models first.")
            }
        }
        if speech.family == .apple, try await !appleSpeech.checkReadiness() {
            throw AppFailure("Apple Speech needs its English model. Open Models and choose Prepare.")
        }
        if entry.cleanupSnapshot?.family == .s1mini && !S1MiniRunner.isAvailable {
            throw AppFailure("S1-mini's helper is missing. Rebuild with Scripts/build.sh.")
        }
        if entry.cleanupSnapshot?.family == .ollama {
            throw AppFailure("Ollama is not connected in this build. Choose S1-mini for local cleanup.")
        }
        if entry.mode.identifySpeakers {
            throw AppFailure(
                "Speaker identification is not yet available. Turn it off to transcribe this recording.")
        }
    }

    private func complete(_ entry: RecordingEntry, message: String) throws {
        try store?.upsertRecording(entry)
        try store?.countIfNeeded(recording: entry)
        activeID = nil
        activeEntry = nil
        destination = nil
        library.inUseModelIDs = []
        shortcuts.setRecordingActive(false)
        phase = .complete
        statusMessage = message
        refreshHistory()
        enforceRetention()
    }

    private func fail(_ original: RecordingEntry, error: Error) {
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
                entry.status = .interrupted
                entry.error = reason
                try complete(entry, message: "\(reason) Captured audio is saved in History.")
                phase = .interrupted
            } catch {
                guard activeID == entry.id else { return }
                fail(entry, error: error)
            }
        }
    }

    func retryRecording(_ original: RecordingEntry) async {
        guard !phase.isBusy, activeID == nil, cancellingID == nil, let store else { return }
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
                fail(activeEntry ?? entry, error: error)
            }
        }
        work = task
        await task.value
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

    @discardableResult func createMode(preset: ModePreset) -> UUID {
        var mode = DictationMode.make(preset: preset)
        if preset == .custom { mode.name = "New mode" }
        modes.append(mode)
        saveConfiguration()
        return mode.id
    }

    func updateMode(_ mode: DictationMode) {
        guard let index = modes.firstIndex(where: { $0.id == mode.id }) else { return }
        let otherApps = Set(modes.filter { $0.id != mode.id }.flatMap(\.appBundleIDs))
        guard otherApps.isDisjoint(with: mode.appBundleIDs) else {
            report(AppFailure("An app can belong to only one automatic mode."))
            return
        }
        let changedShortcut = modes[index].startShortcut != mode.startShortcut
        modes[index] = mode
        if changedShortcut { configureShortcuts() }
        saveConfiguration()
    }

    func deleteMode(_ id: UUID) {
        guard modes.count > 1 else {
            report(AppFailure("Keep at least one mode."))
            return
        }
        modes.removeAll { $0.id == id }
        configureShortcuts()
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
            cancelRecording()
            return
        }
        do {
            try store?.deleteRecording(id: id)
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
    func requestAccessibility() { TextDelivery.requestAccessibility() }
    func saveAPIKey(_ key: String, provider: ModelFamily) throws {
        if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try CredentialStore.remove(for: provider)
        } else {
            try CredentialStore.set(key.trimmingCharacters(in: .whitespacesAndNewlines), for: provider)
        }
    }
    func validateAPI(provider: ModelFamily, modelID: String) async throws -> String {
        try await cloud.validate(provider: provider, modelID: modelID)
    }

    /// Sleep and normal quit preserve unfinished work; only explicit Cancel discards it.
    func preserveUnfinishedRecording() async {
        let previousWork = work
        if phase == .delivering {
            await previousWork?.value
            return
        }
        guard var entry = activeEntry, let id = activeID else { return }
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
        await previousWork?.value
        entry.status = .interrupted
        if entry.error == nil { entry.error = "Interrupted before completion. Retry from History." }
        if let store, store.audioURL(for: entry) == nil { entry.audioFileName = nil }
        do { try store?.upsertRecording(entry) } catch { errorMessage = error.localizedDescription }
        activeEntry = nil
        destination = nil
        cancellingID = nil
        library.inUseModelIDs = []
        phase = .interrupted
        statusMessage = "Unfinished work is saved in History."
        refreshHistory()
    }

    func shutdown() {
        cancelRecording()
        retentionTask?.cancel()
        delivery.restorePendingClipboard()
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
            configureShortcuts()
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

    private func configureShortcuts() {
        shortcuts.setBindings(
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
            onCancel: { [weak self] in self?.cancelRecording() },
            modeBindings: Dictionary(
                uniqueKeysWithValues: modes.compactMap { mode in
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
    }

    private func updateRecorder() {
        guard startupComplete else { return }
        if settings.recorderStyle != .hidden && (settings.alwaysShowRecorder || phase.isBusy) {
            recorder.show(content: AnyView(RecorderView(model: self)), style: settings.recorderStyle)
        } else {
            recorder.hide()
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
