import AVFoundation
import Foundation
import Testing

@testable import AmanuensisCore

struct AudioSpectrumTests {
    @Test func pausedCaptureExpiresAndResumesWithoutOldPartialSamples() {
        let analyzer = AudioSpectrum()
        let samples = tone(frequency: 500, amplitude: 0.1)
        samples.withUnsafeBufferPointer { analyzer.append($0, sampleRate: 48_000, at: 10) }
        #expect(analyzer.snapshot(at: 10.1).max()! > 0)
        #expect(analyzer.snapshot(at: 10.3) == AudioSpectrum.silence)
        // A pause also discards incomplete windows, including when no meter tick occurs in the gap.
        Array(samples.prefix(1000)).withUnsafeBufferPointer {
            analyzer.append($0, sampleRate: 48_000, at: 11)
        }
        Array(repeating: Float(0), count: 1048).withUnsafeBufferPointer {
            analyzer.append($0, sampleRate: 48_000, at: 12)
        }
        #expect(analyzer.snapshot(at: 12) == AudioSpectrum.silence)
        samples.withUnsafeBufferPointer { analyzer.append($0, sampleRate: 48_000, at: 12.1) }
        #expect(analyzer.snapshot(at: 12.1).max()! > 0)
    }

    @Test func captureBuffersReachTheSpectrumInBothPCMLayouts() throws {
        for interleaved in [true, false] {
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: interleaved)!
            let analyzer = AudioSpectrum()
            let sample = try captureBuffer(format: format)
            analyzer.append(sample)
            let bands = analyzer.snapshot()
            #expect(loudestBand(bands) == 9)
            #expect(bands[9] > 0.5)
        }
    }

    @Test func unsupportedAndInvalidCaptureBuffersDoNotCreateBars() throws {
        let analyzer = AudioSpectrum()
        for format in [
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: true)!,
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!,
        ] {
            analyzer.append(try captureBuffer(format: format))
            #expect(analyzer.snapshot() == AudioSpectrum.silence)
        }
        let sample = try captureBuffer(
            format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!)
        CMSampleBufferInvalidate(sample)
        analyzer.append(sample)
        #expect(analyzer.snapshot() == AudioSpectrum.silence)
    }

    @Test func frequenciesMoveAcrossTheDisplay() {
        for rate in [16_000.0, 44_100, 48_000] {
            let low = spectrum(frequency: 180, amplitude: 0.1, sampleRate: rate)
            let high = spectrum(frequency: 3_000, amplitude: 0.1, sampleRate: rate)
            #expect(loudestBand(low) <= 2)
            #expect(loudestBand(high) >= 9)
            #expect(low[2] > high[2])
            #expect(high[9] > low[9])
        }
    }

    @Test func louderSpeechRaisesBarsWithoutNormalizingAwayVolume() {
        let quiet = spectrum(frequency: 1_000, amplitude: 0.01)
        let loud = spectrum(frequency: 1_000, amplitude: 0.1)
        #expect(quiet.max()! > 0.25)
        #expect(loud.max()! > quiet.max()! + 0.3)
        #expect(loud.allSatisfy { (0...1).contains($0) })
    }

    @Test func silenceAndDCStayFlatAndResetClearsPartialAudio() {
        let analyzer = AudioSpectrum()
        feed(tone(frequency: 500, amplitude: 0.1), to: analyzer)
        #expect(analyzer.snapshot().max()! > 0)
        feed(Array(repeating: 0, count: 4096), to: analyzer)
        #expect(analyzer.snapshot() == AudioSpectrum.silence)
        feed(Array(repeating: 0.2, count: 4096), to: analyzer)
        #expect(analyzer.snapshot() == AudioSpectrum.silence)
        feed(Array(repeating: 0.5, count: 1000), to: analyzer)
        analyzer.reset()
        feed(Array(repeating: 0, count: 4096), to: analyzer)
        #expect(analyzer.snapshot() == AudioSpectrum.silence)
    }

    @Test func arbitraryCaptureChunksProduceTheSameSpectrum() {
        let samples = tone(frequency: 700, amplitude: 0.1)
        let whole = AudioSpectrum()
        feed(samples, to: whole)
        let chunked = AudioSpectrum()
        for start in stride(from: 0, to: samples.count, by: 137) {
            feed(Array(samples[start..<min(samples.count, start + 137)]), to: chunked)
        }
        #expect(chunked.snapshot() == whole.snapshot())
    }

    @Test func multipleTonesRemainVisibleAndInvalidSamplesStayFinite() {
        let low = tone(frequency: 180, amplitude: 0.05)
        let high = tone(frequency: 3_000, amplitude: 0.05)
        let analyzer = AudioSpectrum()
        feed(zip(low, high).map(+), to: analyzer)
        #expect(analyzer.snapshot()[2] > 0.4)
        #expect(analyzer.snapshot()[9] > 0.4)
        feed(Array(repeating: .nan, count: 4096), to: analyzer)
        #expect(analyzer.snapshot() == AudioSpectrum.silence)
    }

    private func spectrum(frequency: Double, amplitude: Double, sampleRate: Double = 48_000) -> [Double] {
        let analyzer = AudioSpectrum()
        feed(
            tone(frequency: frequency, amplitude: amplitude, sampleRate: sampleRate), to: analyzer,
            rate: sampleRate)
        return analyzer.snapshot()
    }

    private func loudestBand(_ bands: [Double]) -> Int {
        bands.indices.max { bands[$0] < bands[$1] }!
    }

    private func tone(frequency: Double, amplitude: Double, sampleRate: Double = 48_000) -> [Float] {
        (0..<4096).map { Float(amplitude * sin(2 * .pi * frequency * Double($0) / sampleRate)) }
    }

    private func feed(_ samples: [Float], to analyzer: AudioSpectrum, rate: Double = 48_000) {
        samples.withUnsafeBufferPointer { analyzer.append($0, sampleRate: rate) }
    }

    /// Copies PCM into a real Core Media capture buffer, as delivered to the microphone delegate.
    private func captureBuffer(format: AVAudioFormat) throws -> CMSampleBuffer {
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        pcm.frameLength = 4096
        for buffer in UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList) {
            buffer.mData?.initializeMemory(as: UInt8.self, repeating: 0, count: Int(buffer.mDataByteSize))
        }
        if let floats = pcm.floatChannelData?[0] {
            for (index, sample) in tone(frequency: 3_000, amplitude: 0.1).enumerated() {
                floats[index * pcm.stride] = sample
            }
        }
        var sample: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
            sampleCount: Int(pcm.frameLength), presentationTimeStamp: .zero,
            packetDescriptions: nil, sampleBufferOut: &sample)
        #expect(status == noErr)
        let result = try #require(sample)
        #expect(
            CMSampleBufferSetDataBufferFromAudioBufferList(
                result, blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList)
                == noErr)
        #expect(CMSampleBufferSetDataReady(result) == noErr)
        return result
    }
}
