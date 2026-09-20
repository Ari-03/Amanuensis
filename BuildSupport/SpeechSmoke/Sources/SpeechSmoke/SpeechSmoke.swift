import Foundation
import LocalSpeech

@main
struct SpeechSmoke {
    static func main() async throws {
        guard CommandLine.arguments.count == 4 else {
            print("Usage: SpeechSmoke <whisper|parakeet|cohere> <model-directory> <audio-file>")
            throw SmokeError.invalidArguments
        }
        let engine = LocalSpeechEngine()
        let started = ContinuousClock.now
        let transcript = try await engine.transcribe(
            audioURL: URL(fileURLWithPath: CommandLine.arguments[3]),
            modelDirectory: URL(fileURLWithPath: CommandLine.arguments[2]),
            family: CommandLine.arguments[1]
        )
        print("TRANSCRIPT: \(transcript)")
        print("ELAPSED: \(started.duration(to: .now))")
        guard !transcript.isEmpty else { throw SmokeError.emptyTranscript }
    }

    enum SmokeError: Error {
        case invalidArguments
        case emptyTranscript
    }
}
