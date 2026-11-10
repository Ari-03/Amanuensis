import Foundation
import LocalSpeech

/// The shape every speech engine shares. `AppModel.speechEngine(for:)` is the one place that decides
/// which engine runs a model: a recording's preparation, transcription, cancellation and the unload
/// after it go through it. Removal, sleep and quit unload every engine in `AppModel.unloadModels()`.
@MainActor protocol SpeechEngine: AnyObject {
    /// Loads what transcription needs while the user is still speaking. Optional: transcription loads
    /// on demand and reports any error itself.
    func prepare(_ model: ModelDescriptor) async throws
    func transcribe(
        audioURL: URL, model: ModelDescriptor, language: SpeechLanguage, vocabulary: [VocabularyEntry]
    ) async throws -> String
    /// Discards the running request without waiting for it.
    func cancel()
    /// Cancels and returns once the engine no longer holds model files, so they can be removed.
    func unload() async
}

/// Engines that keep nothing loaded need neither step.
extension SpeechEngine {
    func prepare(_ model: ModelDescriptor) async throws {}
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

    func transcribe(
        audioURL: URL, model: ModelDescriptor, language: SpeechLanguage, vocabulary: [VocabularyEntry]
    ) async throws -> String {
        guard let directory = library.localURL(for: model.id) else {
            throw RecordingFailure.modelNotInstalled(model.name)
        }
        return try await engine.transcribe(
            audioURL: audioURL, modelDirectory: directory, family: model.engine.rawValue,
            language: language.languageCode)
    }

    func cancel() { engine.cancel() }
    func unload() async { await engine.unload() }
}

/// Apple Speech needs no preparation while recording; its assets are prepared from Models.
extension AppleSpeechEngine: SpeechEngine {
    func transcribe(
        audioURL: URL, model: ModelDescriptor, language: SpeechLanguage, vocabulary: [VocabularyEntry]
    ) async throws -> String {
        // Readiness never lets Apple Speech record with detection, which it does not offer.
        guard let code = language.languageCode else {
            throw RecordingFailure.unsupportedLanguage(modelName: model.name, language: language)
        }
        return try await transcribe(url: audioURL, language: code)
    }
}

/// API transcription keeps nothing loaded between requests.
extension CloudProviders: SpeechEngine {}
