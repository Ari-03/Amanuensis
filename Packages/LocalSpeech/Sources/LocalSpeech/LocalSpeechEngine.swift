import AVFoundation
import Dispatch
import Foundation
import MLX
import MLXAudioCore
@preconcurrency import MLXAudioSTT
import os

/// Loads only complete local MLX folders. One call owns one model until it finishes.
/// Cancellation discards results and is checked between bounded audio windows; an
/// already executing upstream model load or GPU decode must finish before resources release.
public actor LocalSpeechEngine {
    private nonisolated static let runtimeBusy = OSAllocatedUnfairLock(initialState: false)
    private nonisolated let executor = SpeechExecutor()
    private nonisolated let activeRequest = OSAllocatedUnfairLock<CancellationFlag?>(initialState: nil)

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    public init() {}

    public nonisolated func cancel() {
        activeRequest.withLock { $0 }?.cancel()
    }

    public func transcribe(audioURL: URL, modelDirectory: URL, family: String) async throws -> String {
        try Task.checkCancellation()
        let modelFamily = try ModelFamily(validating: family)
        // MLX memory settings are process-wide. Keep jobs from separate engine instances serialized too.
        guard
            Self.runtimeBusy.withLock({ busy in
                if busy { return false }
                busy = true
                return true
            })
        else { throw LocalSpeechError.busy }
        let cancellation = CancellationFlag()
        activeRequest.withLock { $0 = cancellation }
        defer {
            activeRequest.withLock { $0 = nil }
            Self.runtimeBusy.withLock { $0 = false }
        }

        return try await withTaskCancellationHandler {
            try cancellation.check()
            let files = try LocalModelFiles(source: modelDirectory, family: modelFamily)
            defer { files.remove() }
            let previousCacheLimit = Memory.cacheLimit
            Memory.cacheLimit = 64 * 1024 * 1024
            defer {
                Memory.clearCache()
                Memory.cacheLimit = previousCacheLimit
            }

            // The nested call releases its model before the outer cache cleanup.
            return try await transcribeWithModel(
                audioURL: audioURL, files: files, family: modelFamily, cancellation: cancellation
            )
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func transcribeWithModel(
        audioURL: URL, files: LocalModelFiles, family: ModelFamily, cancellation: CancellationFlag
    ) async throws -> String {
        try cancellation.check()
        let model: any STTGenerationModel
        switch family {
        case .whisper:
            model = try await WhisperModel.fromDirectory(files.directory)
        case .parakeet:
            model = try ParakeetModel.fromDirectory(files.directory)
        case .cohere:
            model = try CohereTranscribeModel.fromDirectory(files.directory)
        }
        try cancellation.check()
        return try transcribeWindows(audioURL: audioURL, model: model, cancellation: cancellation)
    }

    private func transcribeWindows(
        audioURL: URL, model: any STTGenerationModel, cancellation: CancellationFlag
    ) throws -> String {
        guard audioURL.isFileURL else { throw LocalSpeechError.invalidAudio }
        let file = try AVAudioFile(forReading: audioURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard file.length > 0, format.sampleRate.isFinite,
            (8_000...384_000).contains(format.sampleRate), (1...32).contains(format.channelCount)
        else { throw LocalSpeechError.invalidAudio }

        let capacity = AVAudioFrameCount(format.sampleRate * 30)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw LocalSpeechError.invalidAudio
        }
        let parameters = STTGenerateParameters(
            maxTokens: min(model.defaultGenerationParameters.maxTokens, 1024),
            temperature: 0, language: "en", chunkDuration: 30, minChunkDuration: 0.1
        )
        var parts: [String] = []
        while file.framePosition < file.length {
            try cancellation.check()
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            let frames = Int(buffer.frameLength)
            let channelCount = Int(format.channelCount)
            var samples = Array(repeating: Float.zero, count: frames)
            for channel in 0..<channelCount {
                for frame in 0..<frames {
                    samples[frame] += channels[channel][frame] / Float(channelCount)
                }
            }
            guard samples.allSatisfy(\.isFinite) else { throw LocalSpeechError.invalidAudio }
            try cancellation.check()
            // Exact digital silence requires no model call and cannot produce hallucinated text.
            if samples.allSatisfy({ $0 == 0 }) { continue }
            if format.sampleRate != 16_000 {
                samples = try resampleAudio(samples, from: Int(format.sampleRate), to: 16_000)
            }
            let text = autoreleasepool {
                model.generate(audio: MLXArray(samples), generationParameters: parameters).text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            try cancellation.check()
            if !text.isEmpty { parts.append(text) }
        }
        try cancellation.check()
        return parts.joined(separator: " ")
    }
}

private final class CancellationFlag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    func cancel() {
        state.withLock { $0 = true }
    }

    func check() throws {
        if state.withLock({ $0 }) { throw CancellationError() }
        try Task.checkCancellation()
    }
}

private final class SpeechExecutor: SerialExecutor {
    private let queue = DispatchQueue(label: "dev.amanuensis.local-speech", qos: .userInitiated)

    func enqueue(_ job: consuming ExecutorJob) {
        let unownedJob = UnownedJob(job)
        let executor = asUnownedSerialExecutor()
        queue.async { unownedJob.runSynchronously(on: executor) }
    }
}
