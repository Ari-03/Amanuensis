import Foundation
import LocalSpeech

/// The shape every speech engine shares. `AppModel.speechEngine(for:)` is the one place that decides
/// which engine runs a model: a recording's preparation, live transcription, transcription,
/// cancellation and the unload after it go through it. Removal, sleep and quit unload every engine in `AppModel.unloadModels()`.
@MainActor protocol SpeechEngine: AnyObject {
    /// Loads what transcription needs while the user is still speaking. Optional: transcription loads
    /// on demand and reports any error itself.
    func prepare(_ model: ModelDescriptor) async throws
    func transcription(
        audioURL: URL, model: ModelDescriptor, language: SpeechLanguage, vocabulary: [VocabularyEntry]
    ) async throws -> SpeechResult
    /// Starts transcribing a microphone recording while it is captured, for engines that can, or nil
    /// for engines that transcribe only after Stop. `onUpdate` runs on no particular thread. Start
    /// `prepare` before the returned object's `begin`.
    func liveTranscription(
        model: ModelDescriptor, language: SpeechLanguage,
        onUpdate: @escaping @Sendable (LiveTranscription.Update) -> Void
    ) -> LiveTranscription?
    /// Discards the running request without waiting for it.
    func cancel()
    /// Cancels and returns once the engine no longer holds model files, so they can be removed.
    func unload() async
}

/// A transcript, and the model's own time on the audio where the engine measures it: for local models,
/// summed over segments, including any transcribed while recording. Without it the caller times the
/// request, which is all an API or Apple Speech offers.
struct SpeechResult {
    let text: String
    let modelSeconds: Double?
}

/// Engines that keep nothing loaded need neither step, nor can they transcribe while recording.
extension SpeechEngine {
    func prepare(_ model: ModelDescriptor) async throws {}
    func liveTranscription(
        model: ModelDescriptor, language: SpeechLanguage,
        onUpdate: @escaping @Sendable (LiveTranscription.Update) -> Void
    ) -> LiveTranscription? { nil }
    func unload() async {}
}

/// Local MLX models from the library, in any family `LocalSpeechFamily` declares.
@MainActor final class LocalModelSpeech: SpeechEngine {
    private let engine = LocalSpeechEngine()
    private let library: ModelLibrary

    init(library: ModelLibrary) { self.library = library }

    func prepare(_ model: ModelDescriptor) async throws {
        guard let directory = library.localURL(for: model.id) else { return }
        try await engine.prepare(modelDirectory: directory, family: model.engine.rawValue)
    }

    func transcription(
        audioURL: URL, model: ModelDescriptor, language: SpeechLanguage, vocabulary: [VocabularyEntry]
    ) async throws -> SpeechResult {
        guard let directory = library.localURL(for: model.id) else {
            throw RecordingFailure.modelNotInstalled(model.name)
        }
        let transcript = try await engine.transcribe(
            audioURL: audioURL, modelDirectory: directory, family: model.engine.rawValue,
            language: language.languageCode)
        return SpeechResult(text: transcript.text, modelSeconds: transcript.seconds)
    }

    func liveTranscription(
        model: ModelDescriptor, language: SpeechLanguage,
        onUpdate: @escaping @Sendable (LiveTranscription.Update) -> Void
    ) -> LiveTranscription? {
        guard let directory = library.localURL(for: model.id) else { return nil }
        return LiveTranscription(
            engine: engine, modelDirectory: directory, family: model.engine.rawValue,
            language: language.languageCode, sampleRate: AudioCapture.sampleRate, onUpdate: onUpdate)
    }

    func cancel() { engine.cancel() }
    func unload() async { await engine.unload() }
}

/// Apple Speech needs no preparation while recording; its assets are prepared from Models.
extension AppleSpeechEngine: SpeechEngine {
    func transcription(
        audioURL: URL, model: ModelDescriptor, language: SpeechLanguage, vocabulary: [VocabularyEntry]
    ) async throws -> SpeechResult {
        // Readiness never lets Apple Speech record with detection, which it does not offer.
        guard let code = language.languageCode else {
            throw RecordingFailure.unsupportedLanguage(modelName: model.name, language: language)
        }
        return SpeechResult(text: try await transcribe(url: audioURL, language: code), modelSeconds: nil)
    }
}

/// API transcription keeps nothing loaded between requests.
extension CloudProviders: SpeechEngine {
    func transcription(
        audioURL: URL, model: ModelDescriptor, language: SpeechLanguage, vocabulary: [VocabularyEntry]
    ) async throws -> SpeechResult {
        let text = try await transcribe(
            audioURL: audioURL, model: model, language: language, vocabulary: vocabulary)
        return SpeechResult(text: text, modelSeconds: nil)
    }
}
