import Foundation

/// Model identities are separate from the pinned artifact used to run them.
/// Speech artifacts include their tokenizers so loading never needs a network fallback.
/// The rows live in `ModelCatalog.json`, bundled with the app and decoded once at launch. Where each
/// size and language list comes from is recorded in `docs/research/model-catalog-sources.md`.
enum ModelCatalog {
    /// A missing or unreadable catalog stops the app at launch with the reason, rather than showing an
    /// empty Models screen. The Core tests check the same file's invariants.
    static let models: [ModelDescriptor] = {
        do {
            guard let url = Bundle.main.url(forResource: "ModelCatalog", withExtension: "json") else {
                throw CocoaError(.fileNoSuchFile)
            }
            let models = try ModelDescriptor.catalog(from: Data(contentsOf: url))
            guard !models.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            return models
        } catch {
            fatalError("ModelCatalog.json is missing or invalid: \(error)")
        }
    }()

    /// The local speech model the setup checklist offers to download for a language: the first of these
    /// that can transcribe it. Parakeet V2 is the smallest fast choice for English.
    static func recommendedSpeech(for language: SpeechLanguage) -> ModelDescriptor? {
        ["parakeet-v2", "parakeet-v3", "whisper-large-v3-turbo"].lazy
            .compactMap { id in models.first { $0.id == id } }
            .first { $0.declares(language) }
    }
}
