import Foundation

public enum LocalSpeechError: Error, LocalizedError, Sendable {
    case unsupportedFamily(String)
    case busy
    case invalidModelDirectory
    case missingModelFile(String)
    case invalidAudio

    public var errorDescription: String? {
        switch self {
        case .unsupportedFamily(let family):
            "Unsupported local speech model family: \(family)."
        case .busy:
            "A local transcription is already running."
        case .invalidModelDirectory:
            "Choose a local folder containing an MLX speech model."
        case .missingModelFile(let filename):
            "The local model is missing \(filename). Import a complete model folder; this operation will not download files."
        case .invalidAudio:
            "The recording has no readable audio or uses an unsupported audio format."
        }
    }
}

enum ModelFamily: String, Sendable {
    case whisper
    case parakeet
    case cohere

    init(validating value: String) throws {
        guard let family = Self(rawValue: value.lowercased()) else {
            throw LocalSpeechError.unsupportedFamily(value)
        }
        self = family
    }

    var requiredMetadata: [String] {
        switch self {
        case .whisper: ["config.json", "tokenizer.json", "tokenizer_config.json"]
        case .parakeet: ["config.json"]
        case .cohere: ["config.json", "tokenizer.model", "tokenizer_config.json"]
        }
    }
}
