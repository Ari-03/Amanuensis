import AVFoundation
import Foundation
import LocalSpeech
import MLX
import MLXAudioCore
@preconcurrency import MLXAudioSTT

/// Diagnostic duplicate of the production preprocessing and generation path. Never shipped in the app.
@main
struct SpeechBench {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard (4...7).contains(arguments.count), ["whisper", "parakeet", "cohere"].contains(arguments[1])
        else {
            throw BenchError.usage
        }
        let family = arguments[1]
        let directory = URL(fileURLWithPath: arguments[2])
        let audio = URL(fileURLWithPath: arguments[3])
        let repetitions = arguments.count > 4 ? Int(arguments[4]) ?? 0 : 3
        let cacheMB = arguments.count > 5 ? Int(arguments[5]) ?? -1 : 64
        guard (1...20).contains(repetitions), (0...4096).contains(cacheMB) else { throw BenchError.usage }
        var expected: String? = arguments.count > 6 ? arguments[6] : nil
        let audioFile = try AVAudioFile(forReading: audio)
        let audioSeconds = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        let engine = LocalSpeechEngine(retentionDuration: .zero)
        for iteration in 1...repetitions {
            let started = ContinuousClock.now
            let result = try await engine.transcribe(
                audioURL: audio, modelDirectory: directory, family: family)
            let elapsed = seconds(since: started)
            try validate(result, expected: &expected)
            try emit(
                Metric(
                    mode: "reload_each_request", family: family, iteration: iteration, cacheMB: 64,
                    audioSeconds: audioSeconds, totalSeconds: elapsed, characters: result.count))
        }
        // Exercise the shipped retention/preparation path before the original laboratory duplicate.
        let production = LocalSpeechEngine()
        let preparationStarted = ContinuousClock.now
        try await production.prepare(modelDirectory: directory, family: family)
        try emit(
            Metric(
                mode: "production_prepare", family: family, iteration: 0, cacheMB: 64,
                audioSeconds: audioSeconds, totalSeconds: seconds(since: preparationStarted)))
        for iteration in 1...repetitions {
            let started = ContinuousClock.now
            let text = try await production.transcribe(
                audioURL: audio, modelDirectory: directory, family: family)
            let elapsed = seconds(since: started)
            try validate(text, expected: &expected)
            try emit(
                Metric(
                    mode: "production_preloaded", family: family, iteration: iteration, cacheMB: 64,
                    audioSeconds: audioSeconds, totalSeconds: elapsed, characters: text.count))
        }
        await production.unload()
        let previousCache = Memory.cacheLimit
        Memory.cacheLimit = cacheMB * 1024 * 1024
        defer {
            Memory.clearCache()
            Memory.cacheLimit = previousCache
        }
        let snapshotStarted = ContinuousClock.now
        let snapshot = try snapshot(directory, family: family)
        defer { try? FileManager.default.removeItem(at: snapshot) }
        let snapshotSeconds = seconds(since: snapshotStarted)
        let loadStarted = ContinuousClock.now
        let model: any STTGenerationModel
        switch family {
        case "whisper": model = try await WhisperModel.fromDirectory(snapshot)
        case "parakeet": model = try ParakeetModel.fromDirectory(snapshot)
        default: model = try CohereTranscribeModel.fromDirectory(snapshot)
        }
        let loadSeconds = seconds(since: loadStarted)
        try emit(
            Metric(
                mode: "retained_setup", family: family, iteration: 0, cacheMB: cacheMB,
                audioSeconds: audioSeconds, totalSeconds: snapshotSeconds + loadSeconds,
                snapshotSeconds: snapshotSeconds, loadSeconds: loadSeconds))
        for iteration in 1...repetitions {
            let started = ContinuousClock.now
            let result = try generate(audio: audio, model: model)
            let elapsed = seconds(since: started)
            try validate(result.text, expected: &expected)
            try emit(
                Metric(
                    mode: "retained", family: family, iteration: iteration, cacheMB: cacheMB,
                    audioSeconds: audioSeconds, totalSeconds: elapsed,
                    preparationSeconds: result.preparationSeconds, generateSeconds: result.generateSeconds,
                    characters: result.text.count))
        }
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let components = start.duration(to: .now).components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private static func validate(_ text: String, expected: inout String?) throws {
        guard !text.isEmpty else { throw BenchError.emptyTranscript }
        if let expected, text != expected { throw BenchError.transcriptMismatch }
        expected = text
    }

    private static func emit(_ metric: Metric) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(metric))
        FileHandle.standardOutput.write(Data([10]))
    }

    /// Copy metadata and link weights, matching the local-only production snapshot policy.
    private static func snapshot(_ source: URL, family: String) throws -> URL {
        let manager = FileManager.default
        let required =
            switch family {
            case "whisper": ["config.json", "tokenizer.json", "tokenizer_config.json"]
            case "cohere": ["config.json", "tokenizer_config.json", "tokenizer.model"]
            default: ["config.json"]
            }
        let files = try manager.contentsOfDirectory(
            at: source, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        )
        .filter { file in
            let resolved = file.resolvingSymlinksInPath()
            guard let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else {
                return false
            }
            return values.isRegularFile == true && (values.fileSize ?? 0) > 0
                && manager.isReadableFile(atPath: resolved.path)
        }
        guard required.allSatisfy({ name in files.contains { $0.lastPathComponent == name } }),
            files.contains(where: { $0.pathExtension == "safetensors" })
        else { throw BenchError.incompleteModel }
        let destination = manager.temporaryDirectory.appendingPathComponent(
            "Amanuensis-bench-\(UUID().uuidString)")
        try manager.createDirectory(
            at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            for file in files {
                let target = destination.appendingPathComponent(file.lastPathComponent)
                if file.pathExtension == "safetensors" {
                    try manager.createSymbolicLink(
                        at: target, withDestinationURL: file.resolvingSymlinksInPath())
                } else if ["json", "model", "txt"].contains(file.pathExtension) {
                    try manager.copyItem(at: file.resolvingSymlinksInPath(), to: target)
                }
            }
            return destination
        } catch {
            try? manager.removeItem(at: destination)
            throw error
        }
    }

    /// Keep the 30-second PCM window, channel averaging, resampling and decode parameters in sync with LocalSpeechEngine.
    private static func generate(audio: URL, model: any STTGenerationModel) throws -> Generation {
        let started = ContinuousClock.now
        let file = try AVAudioFile(forReading: audio, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard file.length > 0, format.sampleRate.isFinite,
            (8_000...384_000).contains(format.sampleRate), (1...32).contains(format.channelCount),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate * 30))
        else { throw BenchError.invalidAudio }
        let parameters = STTGenerateParameters(
            maxTokens: min(model.defaultGenerationParameters.maxTokens, 1024),
            temperature: 0, language: "en", chunkDuration: 30, minChunkDuration: 0.1)
        var preparation = seconds(since: started)
        var generation = 0.0
        var parts: [String] = []
        while file.framePosition < file.length {
            let prepStarted = ContinuousClock.now
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            let frames = Int(buffer.frameLength)
            let channelCount = Int(format.channelCount)
            var samples = Array(repeating: Float.zero, count: frames)
            for channel in 0..<channelCount {
                for frame in 0..<frames { samples[frame] += channels[channel][frame] / Float(channelCount) }
            }
            guard samples.allSatisfy(\.isFinite) else { throw BenchError.invalidAudio }
            if samples.allSatisfy({ $0 == 0 }) {
                preparation += seconds(since: prepStarted)
                continue
            }
            if format.sampleRate != 16_000 {
                samples = try resampleAudio(samples, from: Int(format.sampleRate), to: 16_000)
            }
            preparation += seconds(since: prepStarted)
            let generationStarted = ContinuousClock.now
            let text = autoreleasepool {
                model.generate(audio: MLXArray(samples), generationParameters: parameters).text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            generation += seconds(since: generationStarted)
            if !text.isEmpty { parts.append(text) }
        }
        return Generation(
            text: parts.joined(separator: " "), preparationSeconds: preparation, generateSeconds: generation)
    }

    private struct Generation {
        let text: String
        let preparationSeconds: Double
        let generateSeconds: Double
    }

    private struct Metric: Encodable {
        let mode: String
        let family: String
        let iteration: Int
        let cacheMB: Int
        let audioSeconds: Double
        let totalSeconds: Double
        var snapshotSeconds: Double? = nil
        var loadSeconds: Double? = nil
        var preparationSeconds: Double? = nil
        var generateSeconds: Double? = nil
        var characters: Int? = nil
    }

    private enum BenchError: Error {
        case usage, emptyTranscript, transcriptMismatch, incompleteModel, invalidAudio
    }
}
