import AVFoundation
import Foundation
import LocalSpeech

/// Compares transcribing after Stop with transcribing while recording, on a real model. `whole` prepares
/// the model, as the app does while recording, and times transcribing the file as the app does after Stop
/// (whole-file segments), reporting the model's own summed time too. `live` feeds the file's
/// 16-bit samples to `LiveTranscription` in 1024-sample buffers, like the microphone tap, at `pace` times
/// real time (0 for no waiting), then times `finish` from the moment the last buffer is in. It then
/// transcribes the file again without reuse and with the same live segments, in the same process, and
/// reports whether the texts match.
/// `evict` releases the model after the second committed segment; `drop` leaves out one buffer at 20 s;
/// `offset` leaves out the first sample, as a tap one sample late would, so no live text matches.
@main
struct SpeechStream {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard (6...8).contains(arguments.count), ["whole", "live"].contains(arguments[5]) else {
            print(
                "Usage: SpeechStream <family> <model-directory> <16-bit mono WAV> <language|auto>"
                    + " <whole|live> [pace] [evict|drop|offset]")
            throw StreamError.invalidArguments
        }
        let family = arguments[1]
        let model = URL(fileURLWithPath: arguments[2])
        let audio = URL(fileURLWithPath: arguments[3])
        let language: String? = arguments[4] == "auto" ? nil : arguments[4]
        let pace = arguments.count > 6 ? Double(arguments[6]) ?? 1 : 1
        let fault = arguments.count > 7 ? arguments[7] : "none"
        let engine = LocalSpeechEngine()
        try await engine.prepare(modelDirectory: model, family: family)
        var report: [String: Any] = ["mode": arguments[5], "fault": fault, "pace": pace]
        if arguments[5] == "whole" {
            let started = ContinuousClock.now
            let transcript = try await engine.transcribe(
                audioURL: audio, modelDirectory: model, family: family, language: language)
            report["stopSeconds"] = seconds(since: started)
            report["text"] = transcript.text
            report["modelSeconds"] = transcript.seconds
            report["segments"] = transcript.segments
        } else {
            let (pcm, rate) = try readPCM16(audio)
            let commits = Counter()
            let live = LiveTranscription(
                engine: engine, modelDirectory: model, family: family, language: language, sampleRate: rate
            ) { update in
                guard case .committed = update else { return }
                if commits.increment() == 2, fault == "evict" { Task { await engine.unload() } }
            }
            live.begin(after: nil)
            let started = ContinuousClock.now
            var position = fault == "offset" ? 1 : 0
            var dropped = false
            while position < pcm.count {
                let end = min(pcm.count, position + 1024)
                if fault == "drop", !dropped, Double(position) >= 20 * rate {
                    dropped = true
                } else {
                    pcm[position..<end].withUnsafeBufferPointer { live.append(pcm16: $0) }
                }
                position = end
                if pace > 0 {
                    try await Task.sleep(until: started + .seconds(Double(position) / rate / pace))
                }
            }
            let stopped = ContinuousClock.now
            let transcript = try await live.finish(audioURL: audio)
            report["stopSeconds"] = seconds(since: stopped)
            report["text"] = transcript.text
            report["modelSeconds"] = transcript.seconds
            report["segments"] = transcript.segments
            report["reused"] = transcript.reused
            report["commits"] = commits.value
            // The file pass a live recording finishes with, cut the same way, with nothing reused. After
            // an eviction nothing is left to reuse, and the file is cut as one never transcribed live.
            let minimum =
                fault == "evict"
                ? SpeechSegmenter.wholeFileMinimumSeconds
                : try LocalSpeechFamily.named(family).liveMinimumSeconds
            let whole = try await engine.transcribe(
                audioURL: audio, modelDirectory: model, family: family, language: language,
                minimumSeconds: minimum
            ).text
            report["wholeText"] = whole
            report["equal"] = whole == transcript.text
        }
        await engine.unload()
        let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print(String(decoding: json, as: UTF8.self))
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        (ContinuousClock.now - start) / .seconds(1)
    }

    private static func readPCM16(_ url: URL) throws -> ([Int16], Double) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: false)
        guard file.processingFormat.channelCount == 1,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw StreamError.notMono16 }
        try file.read(into: buffer)
        let samples = Array(
            UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength)))
        return (samples, file.processingFormat.sampleRate)
    }

    enum StreamError: Error { case invalidArguments, notMono16 }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}
