import Foundation
import os

/// Shows in Console without extra settings: `log stream --predicate 'subsystem == "dev.amanuensis"'`.
/// Never logs transcript text.
let liveLog = Logger(subsystem: "dev.amanuensis", category: "live-transcription")

/// Transcribes a recording while it is captured. The capture thread hands it 16-bit PCM, which
/// `SpeechSegmenter` cuts; each closed segment is transcribed in order on the model
/// `LocalSpeechEngine.prepare` loaded. `finish` then transcribes the recorded file, which stays the source
/// of truth: it walks the file with the same segmenter and reuses a segment's text only where the file holds
/// exactly the samples that were transcribed. So the result always equals transcribing the file, and
/// anything that went wrong while recording only means more is transcribed after Stop.
///
/// Use: create before capture starts, pass `append` to the capture thread, call `begin` once preparation
/// has started, then `finish` after Stop, or `cancel` and `wait`.
public final class LiveTranscription: Sendable {
    /// Closed segments that may wait for the model. More means transcription fell behind, and the rest of
    /// the recording is left for after Stop.
    static let queueLimit = 4

    private let engine: LocalSpeechEngine
    private let modelDirectory: URL
    private let family: String
    private let language: String?
    private let minimumSeconds: Double
    private let onUpdate: @Sendable (Update) -> Void
    private let segments: AsyncStream<SpeechSegment>
    private let queue: AsyncStream<SpeechSegment>.Continuation
    private let state: OSAllocatedUnfairLock<State>

    private struct State {
        /// Nil once audio is no longer taken.
        var segmenter: SpeechSegmenter?
        var worker: Task<[Data: SegmentText], Never>?
        var cancelled = false
    }

    /// What the preview should show. Updates for one recording are sent in order, and nothing follows
    /// `discarded`.
    public enum Update: Sendable {
        /// Every segment's text so far, joined. Sent each time it grows.
        case committed(String)
        /// What was sent before no longer counts; the whole file will be transcribed after Stop.
        case discarded
    }

    /// `language` is as `LocalSpeechEngine.transcribe` takes it. `onUpdate` runs on no particular thread.
    public init(
        engine: LocalSpeechEngine, modelDirectory: URL, family: String, language: String?,
        sampleRate: Double, onUpdate: @escaping @Sendable (Update) -> Void
    ) {
        self.engine = engine
        self.modelDirectory = modelDirectory
        self.family = family
        self.language = language
        self.onUpdate = onUpdate
        minimumSeconds =
            (try? LocalSpeechFamily.named(family))?.liveMinimumSeconds ?? SpeechSegmenter.minimumSeconds
        (segments, queue) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(Self.queueLimit))
        state = OSAllocatedUnfairLock(
            initialState: State(
                segmenter: SpeechSegmenter(sampleRate: sampleRate, minimumSeconds: minimumSeconds)))
    }

    deinit { cancel() }

    /// Called on the capture thread. Never waits for transcription.
    public func append(pcm16 samples: UnsafeBufferPointer<Int16>) {
        let closed = state.withLockUnchecked { $0.segmenter?.append(pcm16: samples) ?? [] }
        for segment in closed {
            if case .dropped = queue.yield(segment) {
                liveLog.notice(
                    "Live transcription fell \(Self.queueLimit) segments behind; the rest waits for Stop")
                stopTakingAudio()
            }
        }
    }

    /// Starts transcribing closed segments once `preparation` has loaded the model. The runtime runs one
    /// request at a time, so a segment must not start while the model is still loading.
    public func begin(after preparation: Task<Void, Never>?) {
        // The worker holds no reference to self, so dropping this object cancels it in `deinit`.
        let (engine, modelDirectory, family, language) = (engine, modelDirectory, family, language)
        let (segments, queue, onUpdate, lock) = (segments, queue, onUpdate, state)
        state.withLock { state in
            guard state.worker == nil, !state.cancelled else { return }
            state.worker = Task {
                await preparation?.value
                var results: [Data: SegmentText] = [:]
                var committed = ""
                // A segment without sound gets no model call and no entry, here or in the file pass.
                for await segment in segments where segment.hasSound {
                    do {
                        let part = try await engine.transcribe(
                            segment: segment, modelDirectory: modelDirectory, family: family,
                            language: language)
                        results[segment.key] = part
                        guard !part.text.isEmpty else { continue }
                        committed = committed.isEmpty ? part.text : committed + " " + part.text
                        onUpdate(.committed(committed))
                    } catch {
                        // An engine error, eviction or cancellation discards everything transcribed live.
                        Self.stopTakingAudio(lock, queue)
                        if !(error is CancellationError) {
                            liveLog.notice(
                                "Live transcription discarded: \(error.localizedDescription, privacy: .public)"
                            )
                        }
                        onUpdate(.discarded)
                        return [:]
                    }
                }
                return results
            }
        }
    }

    /// Stops taking audio, waits for queued segments, and transcribes the recorded file, reusing what
    /// was transcribed live. Cancelling the calling task cancels the live work too.
    public func finish(audioURL: URL) async throws -> SpeechTranscript {
        stopTakingAudio()
        let known = await withTaskCancellationHandler {
            await state.withLock { $0.worker }?.value ?? [:]
        } onCancel: {
            cancel()
        }
        // With nothing to reuse, the file is cut for speed, as one never transcribed live would be.
        let transcript = try await engine.transcribe(
            audioURL: audioURL, modelDirectory: modelDirectory, family: family, language: language,
            minimumSeconds: known.isEmpty ? SpeechSegmenter.wholeFileMinimumSeconds : minimumSeconds,
            reusing: known)
        liveLog.notice(
            "Live transcription reused \(transcript.reused) of \(transcript.segments) segments")
        return transcript
    }

    /// Stops taking audio and transcribing. A segment the runtime is already decoding finishes first;
    /// `wait` returns once it has.
    public func cancel() {
        stopTakingAudio()
        state.withLock { state in
            state.cancelled = true
            state.worker?.cancel()
        }
    }

    public func wait() async {
        _ = await state.withLock { $0.worker }?.value
    }

    private func stopTakingAudio() { Self.stopTakingAudio(state, queue) }

    private static func stopTakingAudio(
        _ state: OSAllocatedUnfairLock<State>, _ queue: AsyncStream<SpeechSegment>.Continuation
    ) {
        state.withLock { $0.segmenter = nil }
        queue.finish()
    }
}
