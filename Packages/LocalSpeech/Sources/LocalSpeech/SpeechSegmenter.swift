import CryptoKit
import Foundation

/// Decides where a recording is cut for transcription, for every local family alike. Feed it samples as
/// they arrive and it returns each segment once it closes; `finish` returns the rest.
///
/// A segment closes at a pause once it is at least `minimumSeconds` long, but only when it already holds
/// sound and the sound after the pause lasts `confirmSeconds`, so a quiet lead-in or a key click after
/// the last words never becomes a segment of its own. The cut falls just before the resumed sound, so the
/// pause stays with the words before it. With no such pause by `maximumSeconds`, it closes at the
/// quietest moment of the last few seconds. Only that forced cut and the end of the recording can close
/// a segment that is silent throughout, which happens in long silences; such a segment is marked
/// `hasSound == false` and never reaches a model, like digital silence.
///
/// Two tests of loudness are kept apart on purpose. Where to cut uses a level relative to the segment,
/// so soft speech after loud speech can read as a pause. Whether a segment may be skipped uses only the
/// absolute floor, so soft speech is never dropped because louder speech came before it.
///
/// Decisions depend only on the samples, never on how they were chunked, so cutting a recording while it
/// is captured and cutting its file with the same `minimumSeconds` give the same segments.
public struct SpeechSegmenter: Sendable {
    /// For transcription while recording: short segments keep the wait after Stop short.
    public static let minimumSeconds = 6.0
    /// For transcribing a whole file, where short segments only add model calls. Close to the old
    /// 30-second windows, still cut at pauses.
    public static let wholeFileMinimumSeconds = 20.0
    /// Below the 30 seconds every family's window was sized for, such as Moonshine's token cap.
    public static let maximumSeconds = 24.0
    /// A pause is a run of quiet frames this long. Synthesized sentence breaks measured 0.22 to 0.40 s;
    /// gaps between words are shorter than this.
    static let pauseSeconds = 0.2
    /// How long sound must last after a pause, without a new pause, before the pause becomes a cut.
    static let confirmSeconds = 0.16
    /// How much of a pause the next segment keeps before its first sound, at most half the pause.
    static let leadSeconds = 0.1
    /// Without a pause, the cut goes at the quietest 100 ms of this last stretch before the maximum.
    static let searchSeconds = 4.0
    static let frameSeconds = 0.02
    /// A frame is quiet below a tenth of the segment's loud level (95th percentile frame), or below
    /// -60 dBFS whatever the level.
    static let quietRatio: Float = 0.1
    static let quietFloor: Float = 0.001

    public let sampleRate: Double
    private let frameLength: Int
    private let minimumFrames: Int
    private let maximumFrames: Int
    private let pauseFrames: Int
    private let confirmFrames: Int
    private let searchFrames: Int
    private let leadFrames: Int
    private let quietestFrames = 5
    /// Recording index of `pending[0]`.
    private var start = 0
    private var pending: [Float] = []
    /// RMS level of each complete frame in `pending`, the same values sorted, and whether each was sound.
    private var levels: [Float] = []
    private var sortedLevels: [Float] = []
    private var sounds: [Bool] = []
    /// Quiet frames at the end of `levels`.
    private var quietRun = 0
    /// A pause cut waiting for the sound after it to last, and how many sound frames followed so far.
    private var pendingCut: Int?
    private var confirmedFrames = 0

    /// `minimumSeconds` must be the same for a live recording and the file pass that reuses its texts.
    public init(sampleRate: Double, minimumSeconds: Double = Self.minimumSeconds) {
        self.sampleRate = sampleRate
        frameLength = max(1, Int((sampleRate * Self.frameSeconds).rounded()))
        minimumFrames = Int(min(minimumSeconds, Self.maximumSeconds) / Self.frameSeconds)
        maximumFrames = Int(Self.maximumSeconds / Self.frameSeconds)
        pauseFrames = Int(Self.pauseSeconds / Self.frameSeconds)
        confirmFrames = Int((Self.confirmSeconds / Self.frameSeconds).rounded())
        searchFrames = Int(Self.searchSeconds / Self.frameSeconds)
        leadFrames = Int(Self.leadSeconds / Self.frameSeconds)
    }

    /// Adds samples and returns the segments they closed, in order.
    public mutating func append(_ samples: some Sequence<Float>) -> [SpeechSegment] {
        pending.append(contentsOf: samples)
        var closed: [SpeechSegment] = []
        while pending.count >= (levels.count + 1) * frameLength {
            addFrame()
            if let frame = cutFrame() { closed.append(cut(at: frame)) }
        }
        return closed
    }

    /// Adds 16-bit PCM, scaled the way `AVAudioFile` reads 16-bit files as floats, so samples captured
    /// live equal the ones read back from the recorded file.
    public mutating func append(pcm16 samples: UnsafeBufferPointer<Int16>) -> [SpeechSegment] {
        append(samples.lazy.map { Float($0) / 32768 })
    }

    /// Returns what remains as the last segment, or nil when nothing does. A remainder shorter than a
    /// frame counts as sound only if the frames before it do.
    public mutating func finish() -> SpeechSegment? {
        guard !pending.isEmpty else { return nil }
        return cut(at: levels.count, samples: pending.count)
    }

    private mutating func addFrame() {
        let frame = pending[(levels.count * frameLength)..<((levels.count + 1) * frameLength)]
        let level = (frame.reduce(Float.zero) { $0 + $1 * $1 } / Float(frameLength)).squareRoot()
        levels.append(level)
        let index = sortedLevels.firstIndex { $0 > level } ?? sortedLevels.endIndex
        sortedLevels.insert(level, at: index)
        let loud = sortedLevels[Int(Double(levels.count - 1) * 0.95)]
        sounds.append(level > max(loud * Self.quietRatio, Self.quietFloor))
    }

    /// The frame to cut before, if the open segment should close now. Called once per new frame.
    private mutating func cutFrame() -> Int? {
        let count = levels.count
        let isSound = sounds[count - 1]
        let pause = isSound ? quietRun : 0
        quietRun = isSound ? 0 : quietRun + 1
        if count >= maximumFrames {
            // The quietest window wins; the earliest one on a tie.
            var best = count - searchFrames
            var bestEnergy = Float.infinity
            for first in (count - searchFrames)...(count - quietestFrames) {
                let energy = levels[first..<(first + quietestFrames)].reduce(0, +)
                if energy < bestEnergy {
                    best = first
                    bestEnergy = energy
                }
            }
            let cut = best + quietestFrames / 2
            quietRun = min(quietRun, count - cut)
            pendingCut = nil
            return cut
        }
        guard isSound else {
            // A new pause before the sound lasted: that sound was a blip, such as a click.
            if quietRun >= pauseFrames { pendingCut = nil }
            return nil
        }
        // Sound resumed after a pause: the cut goes just before it, if what it closes holds sound.
        let cut = count - 1 - min(leadFrames, pause / 2)
        if pause >= pauseFrames, cut >= minimumFrames, sounds[..<cut].contains(true) {
            pendingCut = cut
            confirmedFrames = 0
        }
        guard let pending = pendingCut else { return nil }
        confirmedFrames += 1
        guard confirmedFrames >= confirmFrames else { return nil }
        pendingCut = nil
        return pending
    }

    private mutating func cut(at frame: Int, samples: Int? = nil) -> SpeechSegment {
        let count = samples ?? frame * frameLength
        let segment = SpeechSegment(
            start: start, sampleRate: sampleRate, samples: Array(pending[..<count]),
            hasSound: levels[..<frame].contains { $0 > Self.quietFloor })
        pending.removeFirst(count)
        levels.removeFirst(frame)
        sounds.removeFirst(frame)
        sortedLevels = levels.sorted()
        start += count
        return segment
    }
}

/// A stretch of one recording, mono, at the recording's sample rate.
public struct SpeechSegment: Sendable, Equatable {
    /// Index of the first sample in the recording.
    public let start: Int
    public let sampleRate: Double
    public let samples: [Float]

    /// Whether any 20 ms frame rose above -60 dBFS. A segment without sound is never sent to a model.
    public let hasSound: Bool

    /// Identifies exactly these samples, so text transcribed while recording is reused only for audio the
    /// file holds unchanged. A model's text depends only on the samples, and the file pass places every
    /// text by its own walk through the file, so position needs no part in it. Hashes the samples;
    /// compute once.
    var key: Data { samples.withUnsafeBytes { Data(SHA256.hash(data: $0)) } }
}
