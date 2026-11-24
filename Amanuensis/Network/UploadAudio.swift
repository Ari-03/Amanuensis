import AVFoundation
import Foundation

/// The audio sent to cloud speech models: 16 kHz mono 16-bit WAV, the rate they listen at. A 48 kHz
/// recording would reach the providers' 25 MB limit in a third of the time. The saved recording is only
/// read, a little at a time, and the result stays in memory, so there is no temporary file to clean up.
enum UploadAudio {
    static let byteLimit = 25_000_000
    private static let sampleRate = 16_000.0
    private static let headerBytes = 44

    /// Blocks while it converts, so call it off the main actor. Cancelling the calling task stops it.
    static func wav(from url: URL) throws -> Data {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0,
            let format = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true),
            let converter = AVAudioConverter(from: file.processingFormat, to: format),
            let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384),
            let source = UploadAudioSource(file)
        else { throw CloudProviders.ProviderError.invalidAudio }
        // The size is known from the length, so a recording that cannot fit is refused before any work.
        let expected = Double(file.length) / file.processingFormat.sampleRate * sampleRate * 2
        guard expected + Double(headerBytes) <= Double(byteLimit) else {
            throw CloudProviders.ProviderError.audioTooLarge
        }
        converter.downmix = true
        var samples = Data(capacity: Int(expected))
        var status = AVAudioConverterOutputStatus.haveData
        while status == .haveData {
            try Task.checkCancellation()
            output.frameLength = 0
            status = converter.convert(to: output, error: nil) { _, inputStatus in source.next(inputStatus) }
            guard status != .error, !source.failed, let channel = output.int16ChannelData?[0] else {
                throw CloudProviders.ProviderError.invalidAudio
            }
            samples.append(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        }
        guard !samples.isEmpty else { throw CloudProviders.ProviderError.invalidAudio }
        let wav = header(sampleBytes: samples.count) + samples
        guard wav.count <= byteLimit else { throw CloudProviders.ProviderError.audioTooLarge }
        return wav
    }

    private static func header(sampleBytes: Int) -> Data {
        let rate = UInt32(sampleRate)
        var header = Data("RIFF".utf8)
        func append(_ value: UInt32, bytes: Int = 4) {
            withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0.prefix(bytes)) }
        }
        append(UInt32(headerBytes - 8 + sampleBytes))
        header.append(Data("WAVEfmt ".utf8))
        append(16)
        append(1, bytes: 2)  // PCM
        append(1, bytes: 2)  // Mono
        append(rate)
        append(rate * 2)
        append(2, bytes: 2)
        append(16, bytes: 2)
        header.append(Data("data".utf8))
        append(UInt32(sampleBytes))
        return header
    }
}

/// Feeds the file to AVAudioConverter, which asks for each piece synchronously, on the converting thread.
private final class UploadAudioSource: @unchecked Sendable {
    private(set) var failed = false
    private let file: AVAudioFile
    private let buffer: AVAudioPCMBuffer

    init?(_ file: AVAudioFile) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32_768) else {
            return nil
        }
        self.file = file
        self.buffer = buffer
    }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        status.pointee = .endOfStream
        guard file.framePosition < file.length else { return nil }
        do { try file.read(into: buffer) } catch {
            failed = true
            return nil
        }
        guard buffer.frameLength > 0 else { return nil }
        status.pointee = .haveData
        return buffer
    }
}
