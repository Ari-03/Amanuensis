import SwiftUI

/// First-run setup on Home: microphone, a speech model, and text insertion. Home shows it until
/// `hasCompletedSetup` is set, when every step is done or skipped, or when the user hides it.
struct SetupChecklistView: View {
    @Bindable var model: AppModel

    var body: some View {
        let checklist = model.setupChecklist
        SettingsCard {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Set up Amanuensis").font(.title3.weight(.semibold))
                    Text("Three steps before your first recording.").font(.callout).foregroundStyle(
                        .secondary)
                }
                Spacer()
                Button("Hide setup") { model.settings.hasCompletedSetup = true }.buttonStyle(.link)
            }
            microphoneStep(checklist.microphone)
            Divider()
            speechStep(checklist.speechBlocker)
            Divider()
            textInsertionStep(checklist)
        }
    }

    private func microphoneStep(_ access: MicrophoneAccess) -> some View {
        SetupStep(number: 1, title: "Microphone", state: access == .granted ? .done : .waiting) {
            switch access {
            case .granted: detail(model.microphoneName)
            case .notDetermined: detail("Amanuensis needs your microphone to hear you. macOS will ask.")
            case .denied:
                detail(
                    "Microphone access is off. Turn on Amanuensis in Privacy & Security, then come back here."
                )
            case .restricted:
                detail(
                    "Microphone access is managed by your organization or by Screen Time, so it cannot be turned on here."
                )
            }
        } actions: {
            switch access {
            case .granted, .restricted: EmptyView()
            case .notDetermined:
                Button("Allow") { Task { await model.requestMicrophoneAccess() } }
                    .buttonStyle(.borderedProminent)
            case .denied: Button("Open System Settings", action: model.openMicrophoneSettings)
            }
        }
    }

    private func speechStep(_ blocker: RecordingFailure?) -> some View {
        let speech = model.currentSpeechModel
        let mode = model.currentMode.name
        return SetupStep(number: 2, title: "A speech model", state: blocker == nil ? .done : .waiting) {
            if blocker == nil, let speech {
                detail("\(speech.name) is ready for \(mode).")
            } else if case .appleSpeechNotReady(let code) = blocker {
                let language = SpeechLanguage.name(of: code)
                detail(
                    "\(mode) uses Apple Speech in \(language), which macOS prepares on this Mac. Or download a local model."
                )
                if model.appleSpeech.isPreparing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Preparing Apple Speech…").font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    Button("Prepare Apple Speech for \(language)") {
                        Task { await model.prepareAppleSpeech(language: code) }
                    }
                    .disabled(model.phase.isBusy)
                }
                if let recommended = model.recommendedSpeech { recommendedRow(recommended) }
            } else if speech?.engine == .apple, case .unsupportedLanguage(_, let language) = blocker {
                // Apple Speech lacks this language; a local model that has it is the way forward.
                detail(
                    "Apple Speech can't transcribe \(language.name) on this Mac. Download a local model that can."
                )
                if let recommended = model.recommendedSpeech { recommendedRow(recommended) }
            } else if let speech, case .modelNotInstalled = blocker, speech.repository != nil {
                detail("\(mode) uses \(speech.name), which is not installed yet.")
                downloadRow(speech)
            } else {
                detail(blocker?.errorDescription ?? "Choose a speech model for \(mode).")
            }
            if case .unsupportedLanguage = blocker {
                Button("Change the language or model in Modes") {
                    model.modeToEdit = model.currentMode.id
                    model.selectedSection = .modes
                }
                .buttonStyle(.link).font(.callout)
            } else if blocker != nil {
                Button("Choose another model in Models") { model.selectedSection = .models }
                    .buttonStyle(.link).font(.callout)
            }
        } actions: {
            EmptyView()
        }
    }

    /// The local route: one model recommended for the mode's language that replaces Apple Speech in
    /// every mode still using it whose language it handles.
    @ViewBuilder private func recommendedRow(_ recommended: ModelDescriptor) -> some View {
        if model.library.installedModelIDs.contains(recommended.id) {
            HStack {
                detail(
                    "\(recommended.name) is installed. Modes on Apple Speech in a language it handles can switch to it."
                )
                Spacer()
                Button("Use \(recommended.name)") { Task { await model.downloadAndUseRecommendedSpeech() } }
            }
        } else {
            let progress = model.library.progress[recommended.id]
            ModelDownloadRow(
                descriptor: recommended, progress: progress,
                resumable: model.library.resumable(recommended.id),
                error: model.library.errors[recommended.id],
                downloadTitle: "Download and use",
                // A download started elsewhere, such as in Models, does not switch modes when it ends.
                note: progress == nil || model.isDownloadingRecommendedSpeech
                    ? "Modes on Apple Speech in a language it handles switch to it when the download finishes."
                    : nil,
                onDownload: { Task { await model.downloadAndUseRecommendedSpeech() } },
                onCancel: { model.library.cancelDownload(recommended.id) })
        }
    }

    private func downloadRow(_ descriptor: ModelDescriptor) -> some View {
        ModelDownloadRow(
            descriptor: descriptor, progress: model.library.progress[descriptor.id],
            resumable: model.library.resumable(descriptor.id), error: model.library.errors[descriptor.id],
            onDownload: { Task { await model.download(descriptor) } },
            onCancel: { model.library.cancelDownload(descriptor.id) })
    }

    private func textInsertionStep(_ checklist: SetupChecklist) -> some View {
        let state: SetupStepState =
            checklist.accessibilityGranted ? .done : checklist.textInsertionSkipped ? .skipped : .waiting
        return SetupStep(number: 3, title: "Text insertion", state: state) {
            switch state {
            case .done: detail("Text goes straight into the app you are using.")
            case .skipped: detail("Skipped. Results go to the clipboard, so press ⌘V to paste them.")
            case .waiting:
                detail(
                    "Allow Accessibility so text lands where you are typing. Without it, results go to the clipboard."
                )
            }
        } actions: {
            if state != .done {
                HStack(spacing: 8) {
                    if state == .waiting {
                        Button("Skip") { model.settings.skippedTextInsertionSetup = true }
                    }
                    Button("Allow", action: model.requestAccessibility).buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func detail(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

private enum SetupStepState { case waiting, done, skipped }

/// A numbered step whose badge turns into a checkmark when done.
private struct SetupStep<Detail: View, Actions: View>: View {
    let number: Int
    let title: String
    let state: SetupStepState
    @ViewBuilder var detail: Detail
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            badge.frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                detail
            }
            Spacer(minLength: 12)
            actions
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(title), \(state == .done ? "done" : state == .skipped ? "skipped" : "step \(number)")")
    }

    @ViewBuilder private var badge: some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
        case .skipped:
            Image(systemName: "arrow.uturn.forward.circle").font(.title2).foregroundStyle(.secondary)
        case .waiting:
            Text("\(number)").font(.callout.weight(.semibold)).foregroundStyle(.tint)
                .frame(width: 24, height: 24)
                .overlay(Circle().strokeBorder(.tint, lineWidth: 1.5))
        }
    }
}
