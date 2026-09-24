import Foundation
import Testing

@testable import AmanuensisCore

struct AudioSpectrumTests {
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
        #expect(analyzer.bands.max()! > 0)
        feed(Array(repeating: 0, count: 4096), to: analyzer)
        #expect(analyzer.bands == AudioSpectrum.silence)
        feed(Array(repeating: 0.2, count: 4096), to: analyzer)
        #expect(analyzer.bands == AudioSpectrum.silence)
        feed(Array(repeating: 0.5, count: 1000), to: analyzer)
        analyzer.reset()
        feed(Array(repeating: 0, count: 4096), to: analyzer)
        #expect(analyzer.bands == AudioSpectrum.silence)
    }

    @Test func arbitraryCaptureChunksProduceTheSameSpectrum() {
        let samples = tone(frequency: 700, amplitude: 0.1)
        let whole = AudioSpectrum()
        feed(samples, to: whole)
        let chunked = AudioSpectrum()
        for start in stride(from: 0, to: samples.count, by: 137) {
            feed(Array(samples[start..<min(samples.count, start + 137)]), to: chunked)
        }
        #expect(chunked.bands == whole.bands)
    }

    @Test func multipleTonesRemainVisibleAndInvalidSamplesStayFinite() {
        let low = tone(frequency: 180, amplitude: 0.05)
        let high = tone(frequency: 3_000, amplitude: 0.05)
        let analyzer = AudioSpectrum()
        feed(zip(low, high).map(+), to: analyzer)
        #expect(analyzer.bands[2] > 0.4)
        #expect(analyzer.bands[9] > 0.4)
        feed(Array(repeating: .nan, count: 4096), to: analyzer)
        #expect(analyzer.bands == AudioSpectrum.silence)
    }

    private func spectrum(frequency: Double, amplitude: Double, sampleRate: Double = 48_000) -> [Double] {
        let analyzer = AudioSpectrum()
        feed(
            tone(frequency: frequency, amplitude: amplitude, sampleRate: sampleRate), to: analyzer,
            rate: sampleRate)
        return analyzer.bands
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
}
