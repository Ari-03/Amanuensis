import AVFoundation
import Foundation
import Testing

@testable import LocalSpeech

private let rate = 16_000.0

/// Deterministic speech-like noise at roughly -16 dBFS, or a quieter copy of it.
private func noise(seconds: Double, amplitude: Float = 0.3, seed: UInt32 = 1) -> [Float] {
    var state = seed
    return (0..<Int(seconds * rate)).map { _ in
        state = state &* 1_664_525 &+ 1_013_904_223
        return (Float(state >> 8) / Float(1 << 24) * 2 - 1) * amplitude
    }
}

private func silence(seconds: Double) -> [Float] { Array(repeating: 0, count: Int(seconds * rate)) }

/// A quiet room, about -68 dBFS, as a microphone hears it between words.
private func room(seconds: Double, seed: UInt32 = 77) -> [Float] {
    noise(seconds: seconds, amplitude: 0.0007, seed: seed)
}

/// A key click: 40 ms, loud.
private func click() -> [Float] { noise(seconds: 0.04, amplitude: 0.5, seed: 3) }

private func segments(
    of samples: [Float], minimumSeconds: Double = SpeechSegmenter.minimumSeconds
) -> [SpeechSegment] {
    var segmenter = SpeechSegmenter(sampleRate: rate, minimumSeconds: minimumSeconds)
    return segmenter.append(samples) + [segmenter.finish()].compactMap { $0 }
}

/// Only the maximum's forced cut or the end of the recording may close a segment without sound.
private func expectSoundlessOnlyFromTheMaximum(_ result: [SpeechSegment]) {
    for segment in result.dropLast() where !segment.hasSound {
        #expect(
            Double(segment.samples.count)
                >= (SpeechSegmenter.maximumSeconds - SpeechSegmenter.searchSeconds) * rate,
            "a \(Double(segment.samples.count) / rate) s segment without sound at \(Double(segment.start) / rate) s"
        )
    }
}

/// Every sample lands in exactly one segment, in order, and no closed segment breaks the length limits.
private func expectCoverage(_ result: [SpeechSegment], of samples: [Float]) {
    #expect(result.flatMap(\.samples) == samples)
    var next = 0
    for segment in result {
        #expect(segment.start == next)
        next += segment.samples.count
    }
    for segment in result {
        #expect(Double(segment.samples.count) <= SpeechSegmenter.maximumSeconds * rate)
    }
    for segment in result.dropLast() {
        #expect(Double(segment.samples.count) >= SpeechSegmenter.minimumSeconds * rate)
    }
}

@Test func burstsSeparatedBySilenceAreCutInsideThePauses() {
    var samples: [Float] = []
    var pauses: [Range<Int>] = []
    for index in 0..<8 {
        samples += noise(seconds: 4, seed: UInt32(index + 1))
        pauses.append(samples.count..<(samples.count + Int(0.6 * rate)))
        // A quiet room rather than digital silence.
        samples += noise(seconds: 0.6, amplitude: 0.002, seed: 99)
    }
    let result = segments(of: samples)
    expectCoverage(result, of: samples)
    #expect(result.count > 2)
    for segment in result.dropFirst() {
        #expect(pauses.contains { $0.contains(segment.start) }, "cut at \(Double(segment.start) / rate) s")
    }
}

@Test func continuousSoundIsCutAtItsQuietestMomentBeforeTheMaximum() {
    var samples = noise(seconds: 60)
    // A softer 100 ms, not quiet enough to count as a pause, inside the search stretch.
    let dip = Int(21.5 * rate)
    for index in dip..<(dip + Int(0.1 * rate)) { samples[index] *= 0.4 }
    let result = segments(of: samples)
    expectCoverage(result, of: samples)
    let firstCut = result[1].start
    #expect(abs(firstCut - (dip + Int(0.05 * rate))) <= Int(0.02 * rate))
    // Later cuts have no dip to find and still stay inside the last stretch before the maximum.
    for segment in result.dropLast() {
        #expect(
            Double(segment.samples.count)
                >= (SpeechSegmenter.maximumSeconds - SpeechSegmenter.searchSeconds) * rate)
    }
}

@Test func aPauseEndingJustBeforeTheMinimumIsNotACut() {
    // Every cut this pause allows falls before 6 s, so the segment would be too short.
    let samples =
        noise(seconds: 5.4) + silence(seconds: 0.5) + noise(seconds: 4) + silence(seconds: 1)
        + noise(seconds: 2)
    let result = segments(of: samples)
    expectCoverage(result, of: samples)
    // The next pause, from 9.9 s, takes the cut instead.
    #expect(Double(result[1].start) / rate >= 9.9)
}

@Test func aPauseAcrossTheMinimumCutsAtTheMinimumOrLater() {
    let samples = noise(seconds: 5.9) + silence(seconds: 0.5) + noise(seconds: 3)
    let result = segments(of: samples)
    expectCoverage(result, of: samples)
    #expect(result.count == 2)
    let cut = Double(result[1].start) / rate
    #expect(cut >= SpeechSegmenter.minimumSeconds && cut <= 6.4)
}

@Test func aShortPauseAtTheMaximumIsWhereTheCutFalls() {
    // 150 ms is shorter than a pause, so only the maximum's quietest-moment rule can find it.
    let samples = noise(seconds: 23.85) + silence(seconds: 0.15) + noise(seconds: 5)
    let result = segments(of: samples)
    expectCoverage(result, of: samples)
    let cut = Double(result[1].start) / rate
    #expect(cut >= 23.85 && cut <= 24)
}

@Test func aRecordingEndingInSilenceKeepsThatSilenceWithItsLastWords() {
    let samples = noise(seconds: 8) + silence(seconds: 0.5) + noise(seconds: 3) + silence(seconds: 1.5)
    let result = segments(of: samples)
    expectCoverage(result, of: samples)
    #expect(result.count == 2)
    #expect(result.allSatisfy { $0.samples.contains { abs($0) > 0.1 } })
    // The cut leaves the next words 100 ms of their pause.
    #expect(abs(Double(result[1].start) / rate - 8.4) < 0.02)
}

@Test func silenceOnlyIsCutIntoSegmentsThatCoverItAndHoldNoSound() {
    let samples = silence(seconds: 50)
    let result = segments(of: samples)
    expectCoverage(result, of: samples)
    #expect(result.allSatisfy { !$0.hasSound && $0.samples.allSatisfy { $0 == 0 } })
}

@Test func aQuietRoomOnlyHoldsNoSound() {
    let samples = room(seconds: 60)
    let result = segments(of: samples)
    expectCoverage(result, of: samples)
    #expect(result.count > 1)
    #expect(result.allSatisfy { !$0.hasSound })
}

@Test func aQuietLeadInStaysWithTheFirstWords() {
    // Eight seconds before the first word, longer than the minimum, then speech with pauses.
    var samples = room(seconds: 8)
    for index in 0..<4 {
        samples += noise(seconds: 4, seed: UInt32(index + 1)) + room(seconds: 0.5, seed: UInt32(index + 9))
    }
    let result = segments(of: samples)
    expectCoverage(result, of: samples)
    #expect(result.allSatisfy { $0.hasSound })
    // The first cut falls after the first words, not where they begin.
    #expect(Double(result[1].start) / rate > 12)
}

@Test func aClickAfterThePauseAtTheEndStaysWithTheLastWords() {
    let samples = noise(seconds: 18) + room(seconds: 0.8) + click() + room(seconds: 0.15)
    let result = segments(of: samples)
    expectCoverage(result, of: samples)
    #expect(result.count == 1)
    // A click followed by more speech is no different: the pause before it is still not a cut.
    let resumed = noise(seconds: 8) + room(seconds: 0.8) + click() + room(seconds: 0.5) + noise(seconds: 3)
    let cuts = segments(of: resumed)
    expectCoverage(cuts, of: resumed)
    #expect(cuts.allSatisfy { $0.hasSound })
    #expect(cuts.count == 2 && Double(cuts[1].start) / rate > 8.8)
}

@Test func aLongQuietGapNeverReachesAModelOnItsOwn() {
    let samples = noise(seconds: 10) + room(seconds: 30) + noise(seconds: 4, seed: 5)
    let result = segments(of: samples)
    expectCoverage(result, of: samples)
    expectSoundlessOnlyFromTheMaximum(result)
    // All the speech is in segments with sound; any segment without it is room only.
    for segment in result where !segment.hasSound {
        #expect(segment.samples.allSatisfy { abs($0) < 0.001 })
    }
    let loud = result.filter(\.hasSound).map { $0.samples.filter { abs($0) > 0.01 }.count }.reduce(0, +)
    #expect(loud == samples.filter { abs($0) > 0.01 }.count)
}

/// Random mixtures of speech, quiet rooms, digital silence and clicks: a pause never closes a segment
/// without sound, and no loud audio is ever in a segment marked without sound.
@Test func aSegmentWithoutSoundIsOnlyEverClosedByTheMaximum() {
    var state: UInt32 = 12345
    func next(_ bound: UInt32) -> UInt32 {
        state = state &* 1_103_515_245 &+ 12345
        return (state >> 8) % bound
    }
    for trial in 0..<20 {
        var samples: [Float] = []
        while Double(samples.count) < 70 * rate {
            let seconds = Double(next(800) + 5) / 100
            switch next(5) {
            case 0, 1: samples += noise(seconds: seconds, seed: UInt32(trial) &+ next(1000))
            case 2: samples += room(seconds: seconds * 3, seed: next(1000))
            case 3: samples += silence(seconds: seconds)
            default: samples += click()
            }
        }
        let result = segments(of: samples)
        expectCoverage(result, of: samples)
        expectSoundlessOnlyFromTheMaximum(result)
        for segment in result where !segment.hasSound {
            #expect(segment.samples.allSatisfy { abs($0) < 0.01 }, "trial \(trial)")
        }
    }
}

@Test func wholeFilesAreCutIntoLongSegmentsStillAtPauses() {
    var samples: [Float] = []
    var pauses: [Range<Int>] = []
    for index in 0..<16 {
        samples += noise(seconds: 4, seed: UInt32(index + 1))
        pauses.append(samples.count..<(samples.count + Int(0.6 * rate)))
        samples += room(seconds: 0.6)
    }
    let result = segments(of: samples, minimumSeconds: SpeechSegmenter.wholeFileMinimumSeconds)
    #expect(result.flatMap(\.samples) == samples)
    #expect(result.count == 4)
    for segment in result.dropLast() {
        #expect(Double(segment.samples.count) >= SpeechSegmenter.wholeFileMinimumSeconds * rate)
    }
    for segment in result.dropFirst() {
        #expect(pauses.contains { $0.contains(segment.start) })
    }
}

@Test func chunkSizesDoNotChangeTheCuts() {
    let samples =
        noise(seconds: 9) + silence(seconds: 0.7) + noise(seconds: 30, seed: 7)
        + silence(seconds: 0.4) + noise(seconds: 3)
    let whole = segments(of: samples)
    var segmenter = SpeechSegmenter(sampleRate: rate)
    var chunked: [SpeechSegment] = []
    var position = 0
    var size = 1
    while position < samples.count {
        let end = min(samples.count, position + size)
        chunked += segmenter.append(samples[position..<end])
        position = end
        size = size * 7 % 4093 + 1
    }
    chunked += [segmenter.finish()].compactMap { $0 }
    #expect(chunked == whole)
    #expect(chunked.map(\.key) == whole.map(\.key))
}

@Test func keysIdentifyExactSamples() {
    let samples = noise(seconds: 2)
    var changed = samples
    changed[100] += 1 / 32768
    func segment(_ samples: [Float], at start: Int = 0) -> SpeechSegment {
        SpeechSegment(start: start, sampleRate: rate, samples: samples, hasSound: true)
    }
    #expect(segment(samples).key == segment(samples).key)
    #expect(segment(samples).key != segment(changed).key)
    // The key is the audio alone: the file pass places every text by its own walk through the file.
    #expect(segment(samples).key == segment(samples, at: 1).key)
}

/// Live capture hands over 16-bit PCM while the engine reads the WAV file as floats. The two must agree
/// sample for sample, or no live text could ever be reused.
@Test func capturedPCMMatchesTheRecordedFileReadAsFloats() throws {
    let pcm: [Int16] =
        (0..<Int(14 * rate)).map { index in
            index % 50_000 < 30_000 ? Int16(truncatingIfNeeded: index &* 7919) : 0
        } + [.min, .max, -1, 0, 1]
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
    ]
    do {
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: false)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(pcm.count)))
        buffer.frameLength = buffer.frameCapacity
        pcm.withUnsafeBufferPointer {
            buffer.int16ChannelData![0].update(from: $0.baseAddress!, count: pcm.count)
        }
        try file.write(from: buffer)
    }
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    let read = try #require(
        AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: read)
    let floats = Array(UnsafeBufferPointer(start: read.floatChannelData![0], count: Int(read.frameLength)))

    var live = SpeechSegmenter(sampleRate: rate)
    let fromPCM = pcm.withUnsafeBufferPointer { live.append(pcm16: $0) } + [live.finish()].compactMap { $0 }
    #expect(fromPCM.count > 1)
    #expect(fromPCM == segments(of: floats))
}

/// Soft words 30 dB below the speech before them read as a pause, but they are well above the floor,
/// so the segment a forced cut leaves them in must still be transcribed.
@Test func softWordsLeftByAForcedCutStillCountAsSound() {
    let samples = noise(seconds: 20) + noise(seconds: 4, amplitude: 0.01, seed: 5)
    let result = segments(of: samples)
    expectCoverage(result, of: samples)
    #expect(result.count == 2)
    #expect(result.map(\.hasSound) == [true, true])
}
