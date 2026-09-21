import AVFoundation
import Foundation

enum FixtureError: Error {
    case usage, invalidAudio
}

// Function scope closes the output file and finalizes its WAV header before the process exits.
func writePaddedFixture() throws {
    guard CommandLine.arguments.count == 3 else { throw FixtureError.usage }
    let input = try AVAudioFile(
        forReading: URL(fileURLWithPath: CommandLine.arguments[1]),
        commonFormat: .pcmFormatFloat32, interleaved: false)
    guard input.processingFormat.channelCount == 1, input.length > 0,
        input.length <= AVAudioFramePosition(input.processingFormat.sampleRate * 30),
        let audio = AVAudioPCMBuffer(
            pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(input.length)),
        let silence = AVAudioPCMBuffer(
            pcmFormat: input.processingFormat,
            frameCapacity: AVAudioFrameCount(input.processingFormat.sampleRate * 5)),
        let samples = silence.floatChannelData
    else { throw FixtureError.invalidAudio }
    try input.read(into: audio)
    silence.frameLength = silence.frameCapacity
    samples[0].update(repeating: 0, count: Int(silence.frameLength))
    let output = try AVAudioFile(
        forWriting: URL(fileURLWithPath: CommandLine.arguments[2]),
        settings: input.fileFormat.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    try output.write(from: silence)
    try output.write(from: audio)
    try output.write(from: silence)
}

try writePaddedFixture()
