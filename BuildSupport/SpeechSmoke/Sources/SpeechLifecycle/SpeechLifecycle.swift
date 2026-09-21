import Foundation
import LocalSpeech

/// Real-model checks for residency, preparation ownership, invalidation and cancellation.
/// Run with an isolated TMPDIR and no network, using the same artifacts as SpeechSmoke.
@main
struct SpeechLifecycle {
    static func main() async throws {
        guard CommandLine.arguments.count == 4 else { throw CheckFailure("Expected family, model, audio") }
        let family = CommandLine.arguments[1]
        let original = URL(fileURLWithPath: CommandLine.arguments[2])
        let audio = URL(fileURLWithPath: CommandLine.arguments[3])
        let manager = FileManager.default
        let source = manager.temporaryDirectory.appendingPathComponent("lifecycle-source")
        try manager.createDirectory(at: source, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: source) }
        for file in try manager.contentsOfDirectory(at: original, includingPropertiesForKeys: nil) {
            let target = source.appendingPathComponent(file.lastPathComponent)
            if file.pathExtension == "safetensors" {
                try manager.createSymbolicLink(at: target, withDestinationURL: file)
            } else {
                try manager.copyItem(at: file, to: target)
            }
        }
        let initial = try snapshots()
        let engine = LocalSpeechEngine(retentionDuration: .milliseconds(100))
        try await engine.prepare(modelDirectory: source, family: family)
        let prepared = try snapshots().subtracting(initial)
        try require(prepared.count == 1, "Preparation must retain one metadata snapshot")
        try await Task.sleep(for: .milliseconds(250))
        try require(
            try snapshots().subtracting(initial) == prepared, "Recording preparation expired before use")
        let first = try await engine.transcribe(audioURL: audio, modelDirectory: source, family: family)
        try require(!first.isEmpty, "Empty transcript")
        let second = try await engine.transcribe(audioURL: audio, modelDirectory: source, family: family)
        try require(first == second, "Retained output differs")
        try require(try snapshots().subtracting(initial) == prepared, "Repeated call reloaded model")
        try await Task.sleep(for: .milliseconds(300))
        try require(try snapshots() == initial, "Idle expiry leaked resident snapshot")

        try await engine.prepare(modelDirectory: source, family: family)
        let beforeChange = try snapshots().subtracting(initial)
        let config = source.appendingPathComponent("config.json")
        var data = try Data(contentsOf: config)
        data.append(contentsOf: [32, 10])
        try data.write(to: config, options: .atomic)
        try await engine.prepare(modelDirectory: source, family: family)
        try require(
            try snapshots().subtracting(initial) != beforeChange, "Changed metadata reused stale model")
        try require(try snapshots().subtracting(initial).count == 1, "Replacement leaked old model snapshot")
        try manager.removeItem(at: config)
        do {
            _ = try await engine.transcribe(audioURL: audio, modelDirectory: source, family: family)
            throw CheckFailure("Missing metadata used cached model")
        } catch is LocalSpeechError {}
        try require(try snapshots() == initial, "Invalid source retained model")
        try data.write(to: config)

        // Observe creation before cancellation, exercising actual in-flight model loading.
        let loading = Task { try await engine.prepare(modelDirectory: source, family: family) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while try snapshots() == initial, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try require(try snapshots() != initial, "Load did not begin")
        engine.cancel()
        do {
            try await loading.value
            throw CheckFailure("Cancelled preparation returned success")
        } catch is CancellationError {}
        await engine.unload()
        try require(try snapshots() == initial, "Cancellation/unload leaked snapshot")
        try await engine.prepare(modelDirectory: source, family: family)
        let recovered = try await engine.transcribe(audioURL: audio, modelDirectory: source, family: family)
        try require(recovered == first, "Inference failed after cancellation")
        await engine.unload()
        try require(try snapshots() == initial, "Explicit unload leaked snapshot")
        print(
            "Speech lifecycle checks passed: reuse, held preparation, idle expiry, replacement, missing files, cancellation, recovery, unload."
        )
    }

    private static func snapshots() throws -> Set<String> {
        Set(
            try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
                .filter { $0.hasPrefix("Amanuensis-local-speech-") })
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure(message) }
    }

    private struct CheckFailure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}
