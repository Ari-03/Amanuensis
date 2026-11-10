import Foundation

public enum LocalSpeechError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedFamily(String)
    case busy
    case invalidModelDirectory
    case missingModelFile(String)
    case invalidAudio
    case unrecognizedConfiguration(String)
    case languageRequired(String)

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
        case .unrecognizedConfiguration(let family):
            "This folder does not contain a \(family) configuration."
        case .languageRequired(let family):
            "\(family) cannot detect the spoken language. Choose a language."
        }
    }
}
