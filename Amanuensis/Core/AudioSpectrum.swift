import Accelerate
import Foundation

/// Twelve speech-frequency bands, ordered from 80 Hz to 8 kHz. Confine each analyzer to one queue.
nonisolated final class AudioSpectrum {
    static let bandCount = 12
    static var silence: [Double] { Array(repeating: 0, count: bandCount) }
    private static let log2Size: vDSP_Length = 11
    private static let size = 1 << Int(log2Size)

    private let setup = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2))!
    private let window: [Float] = (0..<size).map {
        Float(0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(size)))
    }
    private var samples = [Float](repeating: 0, count: size)
    private var real = [Float](repeating: 0, count: size / 2)
    private var imaginary = [Float](repeating: 0, count: size / 2)
    private var position = 0
    private var sampleRate = 0.0
    private(set) var bands = silence

    deinit { vDSP_destroy_fftsetup(setup) }

    func reset() {
        position = 0
        sampleRate = 0
        bands = Self.silence
    }

    /// Accumulates complete analysis windows even when capture delivers small audio buffers.
    func append(_ input: UnsafeBufferPointer<Float>, sampleRate: Double) {
        guard sampleRate.isFinite, sampleRate > 0 else { return }
        if self.sampleRate != sampleRate {
            reset()
            self.sampleRate = sampleRate
        }
        for sample in input {
            samples[position] = sample.isFinite ? sample : 0
            position += 1
            if position == Self.size {
                analyze()
                position = 0
            }
        }
    }

    private func analyze() {
        // Remove DC before windowing so microphone bias does not lift the lowest bars.
        let mean = samples.reduce(0, +) / Float(Self.size)
        for index in real.indices {
            real[index] = (samples[2 * index] - mean) * window[2 * index]
            imaginary[index] = (samples[2 * index + 1] - mean) * window[2 * index + 1]
        }
        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var split = DSPSplitComplex(
                    realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, Self.log2Size, FFTDirection(FFT_FORWARD))
            }
        }
        // The real FFT doubles its output; the Hann window halves amplitude. These factors cancel.
        let scale = 2 / Double(Self.size)
        bands = (0..<Self.bandCount).map { band in
            let lower = 80 * pow(100, Double(band) / Double(Self.bandCount))
            let upper = 80 * pow(100, Double(band + 1) / Double(Self.bandCount))
            let first = max(1, Int(ceil(lower * Double(Self.size) / sampleRate)))
            let end = min(Self.size / 2, Int(ceil(upper * Double(Self.size) / sampleRate)))
            guard first < end else { return 0 }
            var power = 0.0
            for bin in first..<end {
                power = max(
                    power,
                    Double(real[bin]) * Double(real[bin]) + Double(imaginary[bin]) * Double(imaginary[bin]))
            }
            let amplitude = sqrt(power) * scale
            guard amplitude > 0 else { return 0 }
            // Fixed gain preserves loudness differences. Quiet bands settle back to dots.
            return min(1, max(0, (20 * log10(amplitude) + 60) / 48))
        }
    }
}
