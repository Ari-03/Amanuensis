import AppKit
import Foundation
import LocalSpeech

/// Verifies the shipped Metal resources and helper using a supplied audio fixture, never a microphone.
@MainActor
enum SmokeLaunch {
    static func runIfRequested() async {
        let arguments = CommandLine.arguments
        guard arguments.count == 7, arguments[1] == "--speech-smoke" else { return }
        let output = URL(fileURLWithPath: arguments[6])
        let engine = LocalSpeechEngine()
        let normalizer = S1MiniRunner()
        do {
            try await engine.prepare(
                modelDirectory: URL(fileURLWithPath: arguments[3]), family: arguments[4])
            let speech = try await engine.transcribe(
                audioURL: URL(fileURLWithPath: arguments[2]),
                modelDirectory: URL(fileURLWithPath: arguments[3]), family: arguments[4])
            let cleaned = try await normalizer.clean(
                text: speech, modelURL: URL(fileURLWithPath: arguments[5]),
                mode: DictationMode.make(preset: .message))
            let repeated = try await engine.transcribe(
                audioURL: URL(fileURLWithPath: arguments[2]),
                modelDirectory: URL(fileURLWithPath: arguments[3]), family: arguments[4])
            let repeatedCleanup = try await normalizer.clean(
                text: repeated, modelURL: URL(fileURLWithPath: arguments[5]),
                mode: DictationMode.make(preset: .message))
            guard speech == repeated, cleaned == repeatedCleanup else { throw SmokeError.changedOutput }
            let result = ["status": "success", "transcript": speech, "cleaned": cleaned]
            try JSONEncoder().encode(result).write(to: output, options: .atomic)
        } catch {
            try? JSONEncoder().encode(["status": "error", "error": error.localizedDescription])
                .write(to: output, options: .atomic)
        }
        await engine.unload()
        await normalizer.unload()
        ApplicationDelegate.requestTermination()
    }

    private enum SmokeError: Error { case changedOutput }
}
