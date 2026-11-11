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
        try await withModel(modelDirectory: modelDirectory, family: family, holds: true) {
            _, cancellation in
            try cancellation.check()
            return ()
        }
    }

    /// `language` is a BCP-47 language code such as "fr", or nil when the model should detect it.
    /// Each `LocalSpeechFamily` says whether it can detect and how its runtime takes the language. A
    /// family that cannot detect throws `languageRequired` for nil. Callers check that the checkpoint
    /// handles the language first: some runtimes silently substitute English for one they lack.
    ///
    /// The file is cut with `minimumSeconds`. The default suits a file nothing was transcribed from while
    /// recording, where short segments would only add model calls.
    public func transcribe(
        audioURL: URL, modelDirectory: URL, family: String, language: String?,
        minimumSeconds: Double = SpeechSegmenter.wholeFileMinimumSeconds
    ) async throws -> SpeechTranscript {
        try await transcribe(
            audioURL: audioURL, modelDirectory: modelDirectory, family: family, language: language,
            minimumSeconds: minimumSeconds, reusing: [:])
    }

    /// Transcribes the file segment by segment as `SpeechSegmenter` cuts it with `minimumSeconds`. A
    /// segment whose exact samples are in `known` takes that text instead of running the model again.
    func transcribe(
        audioURL: URL, modelDirectory: URL, family: String, language: String?, minimumSeconds: Double,
        reusing known: [Data: SegmentText]
    ) async throws -> SpeechTranscript {
        let request = try SpeechRequest(family: family, language: language)
        return try await withModel(modelDirectory: modelDirectory, family: family) { model, cancellation in
            try transcribeFile(
                audioURL: audioURL, model: model, request: request, minimumSeconds: minimumSeconds,
                known: known, cancellation: cancellation)
        }
    }

    /// Transcribes one segment cut while recording, with the model `prepare` loaded. Throws
    /// `modelNotLoaded` instead of loading, so memory pressure that evicted the model is not undone
    /// mid-recording, and keeps the model held like preparation does.
    func transcribe(segment: SpeechSegment, modelDirectory: URL, family: String, language: String?)
        async throws -> SegmentText
    {
        let request = try SpeechRequest(family: family, language: language)
        return try await withModel(modelDirectory: modelDirectory, family: family, loads: false, holds: true)
        { model, cancellation in
            try cancellation.check()
            return try request.transcribe(segment, model: model)
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

    /// `holds` keeps the model without starting the idle expiry, for preparation and recording.
    private func withModel<T>(
        modelDirectory: URL, family: String, loads: Bool = true, holds: Bool = false,
        operation: (any STTGenerationModel, CancellationFlag) throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let modelFamily = try LocalSpeechFamily.named(family)
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
            if resident != nil, !holds { scheduleExpiry() }
        }
        return try await withTaskCancellationHandler {
            try cancellation.check()
            let identity = try LocalModelIdentity(directory: modelDirectory, family: modelFamily)
            if resident?.identity != identity {
                guard loads else { throw LocalSpeechError.modelNotLoaded }
                resident = nil
                let files = try LocalModelFiles(source: modelDirectory, family: modelFamily)
                do {
                    let model = try await modelFamily.load(files.directory)
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

    private func transcribeFile(
        audioURL: URL, model: any STTGenerationModel, request: SpeechRequest, minimumSeconds: Double,
        known: [Data: SegmentText], cancellation: CancellationFlag
    ) throws -> SpeechTranscript {
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
        var segmenter = SpeechSegmenter(sampleRate: format.sampleRate, minimumSeconds: minimumSeconds)
        var result = SpeechTranscript(text: "", seconds: 0, segments: 0, reused: 0)
        func add(_ segment: SpeechSegment) throws {
            try cancellation.check()
            let reused = known.isEmpty || !segment.hasSound ? nil : known[segment.key]
            let part = try reused ?? request.transcribe(segment, model: model)
            try cancellation.check()
            result.add(part, reused: reused != nil)
        }
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
            for segment in segmenter.append(samples) { try add(segment) }
        }
        if let last = segmenter.finish() { try add(last) }
        try cancellation.check()
        return result
    }
}

/// What one transcription needs besides the model and audio, checked before the model is touched.
private struct SpeechRequest {
    let language: String?
    let maxTokens: Int?

    init(family name: String, language: String?) throws {
        let family = try LocalSpeechFamily.named(name)
        guard language != nil || family.detectsLanguage else {
            throw LocalSpeechError.languageRequired(family.displayName)
        }
        self.language = family.languageArgument(language)
        maxTokens = family.maxTokens
    }

    /// The one model call for a segment, whether it was cut while recording or from the file.
    func transcribe(_ segment: SpeechSegment, model: any STTGenerationModel) throws -> SegmentText {
        // Silence, digital or below -60 dBFS throughout, needs no model call, and models invent words for it.
        guard segment.hasSound else { return SegmentText(text: "", seconds: 0) }
        let started = ContinuousClock.now
        var samples = segment.samples
        if segment.sampleRate != 16_000 {
            samples = try resampleAudio(samples, from: Int(segment.sampleRate), to: 16_000)
        }
        // A cut can leave only 0.1 s of pause on each side. Padding lowers, but does not remove, the odds
        // that a model invents sentences there: Cohere did for three Italian segments without it and not
        // with 0.3 or 0.5 s, yet still did on another Italian clip and with 12-second segments. It costs
        // model time, from 2% for Whisper to 16% for Nemotron.
        let padding = [Float](repeating: 0, count: 8_000)
        samples = padding + samples + padding
        let parameters = STTGenerateParameters(
            maxTokens: maxTokens ?? min(model.defaultGenerationParameters.maxTokens, 1024),
            temperature: 0, language: language, chunkDuration: 30, minChunkDuration: 0.1
        )
        let text = autoreleasepool {
            model.generate(audio: MLXArray(samples), generationParameters: parameters).text
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return SegmentText(text: text, seconds: (ContinuousClock.now - started) / .seconds(1))
    }
}

/// One segment's text and the seconds the model spent on it.
struct SegmentText: Sendable {
    let text: String
    let seconds: Double
}

/// A recording's transcript. `seconds` is the model's time summed over every segment, including any
/// transcribed while recording, so it measures speed per second of audio rather than the wait after Stop.
public struct SpeechTranscript: Sendable, Equatable {
    public private(set) var text: String
    public private(set) var seconds: Double
    /// How many segments the recording had, and how many took their text from live transcription.
    public private(set) var segments: Int
    public private(set) var reused: Int

    mutating func add(_ part: SegmentText, reused wasReused: Bool) {
        if !part.text.isEmpty { text = text.isEmpty ? part.text : text + " " + part.text }
        seconds += part.seconds
        segments += 1
        if wasReused { reused += 1 }
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
