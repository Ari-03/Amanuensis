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
        do {
            let speech = try await LocalSpeechEngine().transcribe(
                audioURL: URL(fileURLWithPath: arguments[2]),
                modelDirectory: URL(fileURLWithPath: arguments[3]), family: arguments[4])
            let cleaned = try await S1MiniRunner().clean(
                text: speech, modelURL: URL(fileURLWithPath: arguments[5]),
                mode: DictationMode.make(preset: .message))
            let result = ["status": "success", "transcript": speech, "cleaned": cleaned]
            try JSONEncoder().encode(result).write(to: output, options: .atomic)
        } catch {
            try? JSONEncoder().encode(["status": "error", "error": error.localizedDescription])
                .write(to: output, options: .atomic)
        }
        NSApp.terminate(nil)
    }
}
