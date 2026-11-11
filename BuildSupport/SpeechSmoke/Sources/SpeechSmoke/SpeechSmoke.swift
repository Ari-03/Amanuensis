import Foundation
import LocalSpeech

@main
struct SpeechSmoke {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard (4...5).contains(arguments.count) else {
            let families = LocalSpeechFamily.all.map(\.name).joined(separator: "|")
            print("Usage: SpeechSmoke <\(families)> <model-directory> <audio-file> [language|auto]")
            throw SmokeError.invalidArguments
        }
        // English by default, as the app used before languages. "auto" asks the model to detect it.
        let language: String? = arguments.count == 5 ? (arguments[4] == "auto" ? nil : arguments[4]) : "en"
        let engine = LocalSpeechEngine()
        let started = ContinuousClock.now
        let transcript = try await engine.transcribe(
            audioURL: URL(fileURLWithPath: arguments[3]),
            modelDirectory: URL(fileURLWithPath: arguments[2]),
            family: arguments[1],
            language: language
        ).text
        print("LANGUAGE: \(language ?? "auto")")
        print("TRANSCRIPT: \(transcript)")
        print("ELAPSED: \(started.duration(to: .now))")
        guard !transcript.isEmpty else { throw SmokeError.emptyTranscript }
    }

    enum SmokeError: Error {
        case invalidArguments
        case emptyTranscript
    }
}
