import AVFoundation
import Dispatch
import Foundation
import MLX
import MLXAudioCore
@preconcurrency import MLXAudioSTT
import os

/// Retains one validated local model between requests. GPU work remains globally serialized.
/// Cancellation discards results; an upstream load/decode already underway must finish first.
public actor LocalSpeechEngine {
    private nonisolated static let runtimeBusy = OSAllocatedUnfairLock(initialState: false)
    private nonisolated let executor = SpeechExecutor()
    private nonisolated let activeRequest = OSAllocatedUnfairLock<CancellationFlag?>(initialState: nil)
    private let retentionDuration: Duration
    private var resident: ResidentModel?
    private var expiry: Task<Void, Never>?
    private var pressure: (any DispatchSourceMemoryPressure)?
    private var requestActive = false
    private var unloadRequested = false
    private var unloadWaiters: [CheckedContinuation<Void, Never>] = []

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    /// Zero retention is useful for comparing reload-per-request behavior in the benchmark.
    public init(retentionDuration: Duration = .seconds(60)) {
        self.retentionDuration = max(.zero, retentionDuration)
    }

    deinit {
        expiry?.cancel()
        pressure?.cancel()
    }

    public nonisolated func cancel() {
        activeRequest.withLock { $0 }?.cancel()
    }

    /// Holds the prepared model until transcription or unload. Memory pressure may evict it.
    /// Call while recording, and await completion before starting transcription on this engine.
    public func prepare(modelDirectory: URL, family: String) async throws {
        try await withModel(modelDirectory: modelDirectory, family: family, preparing: true) {
            _, cancellation in
            try cancellation.check()
            return ()
        }
    }

    public func transcribe(audioURL: URL, modelDirectory: URL, family: String) async throws -> String {
        try await withModel(modelDirectory: modelDirectory, family: family) { model, cancellation in
            try transcribeWindows(audioURL: audioURL, model: model, cancellation: cancellation)
        }
    }

    /// Cancels active work and waits for it to relinquish the model before returning.
    /// Await this before removing model files or shutting down the inference owner.
    public func unload() async {
        expiry?.cancel()
        expiry = nil
        if requestActive {
            unloadRequested = true
            cancel()
            await withCheckedContinuation { unloadWaiters.append($0) }
        } else {
            releaseResident()
        }
    }

    private func withModel<T>(
        modelDirectory: URL, family: String, preparing: Bool = false,
        operation: (any STTGenerationModel, CancellationFlag) throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let modelFamily = try ModelFamily(validating: family)
        guard
            Self.runtimeBusy.withLock({ busy in
                if busy { return false }
                busy = true
                return true
            })
        else { throw LocalSpeechError.busy }
        requestActive = true
        expiry?.cancel()
        expiry = nil
        installPressureHandler()
        let cancellation = CancellationFlag()
        activeRequest.withLock { $0 = cancellation }
        let previousCacheLimit = Memory.cacheLimit
        Memory.cacheLimit = 64 * 1024 * 1024
        var succeeded = false
        defer {
            activeRequest.withLock { $0 = nil }
            requestActive = false
            if !succeeded || unloadRequested || retentionDuration == .zero {
                resident = nil
            }
            // Clear unused allocations, not the evaluated weights owned by the resident model.
            Memory.clearCache()
            Memory.cacheLimit = previousCacheLimit
            Self.runtimeBusy.withLock { $0 = false }
            unloadRequested = false
            let waiters = unloadWaiters
            unloadWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            if resident != nil, !preparing { scheduleExpiry() }
        }
        return try await withTaskCancellationHandler {
            try cancellation.check()
            let identity = try LocalModelIdentity(directory: modelDirectory, family: modelFamily)
            if resident?.identity != identity {
                resident = nil
                let files = try LocalModelFiles(source: modelDirectory, family: modelFamily)
                do {
                    let model: any STTGenerationModel
                    switch modelFamily {
                    case .whisper: model = try await WhisperModel.fromDirectory(files.directory)
                    case .parakeet: model = try ParakeetModel.fromDirectory(files.directory)
                    case .cohere: model = try CohereTranscribeModel.fromDirectory(files.directory)
                    }
                    try cancellation.check()
                    resident = ResidentModel(identity: identity, files: files, model: model)
                } catch {
                    files.remove()
                    throw error
                }
            }
            try cancellation.check()
            guard let resident else { throw LocalSpeechError.invalidModelDirectory }
            let result = try operation(resident.model, cancellation)
            try cancellation.check()
            succeeded = true
            return result
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func scheduleExpiry() {
        let delay = retentionDuration
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.expire()
        }
    }

    private func expire() {
        // A stale timer can reach the actor after the next request has begun.
        guard !Task.isCancelled, !requestActive else { return }
        releaseResident()
    }

    private func installPressureHandler() {
        guard pressure == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical])
        source.setEventHandler { [weak self] in
            Task { await self?.evictUnderPressure() }
        }
        pressure = source
        source.resume()
    }

    private func evictUnderPressure() {
        if requestActive {
            // Finish active dictation; only its retained resources should be evicted.
            unloadRequested = true
        } else {
            releaseResident()
        }
    }

    private func releaseResident() {
        resident = nil
        // Never mutate another engine's process-wide MLX cache policy during its request.
        guard
            Self.runtimeBusy.withLock({ busy in
                if busy { return false }
                busy = true
                return true
            })
        else { return }
        Memory.clearCache()
        Self.runtimeBusy.withLock { $0 = false }
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

private final class ResidentModel {
    let identity: LocalModelIdentity
    let files: LocalModelFiles
    let model: any STTGenerationModel

    init(identity: LocalModelIdentity, files: LocalModelFiles, model: any STTGenerationModel) {
        self.identity = identity
        self.files = files
        self.model = model
    }

    deinit { files.remove() }
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
