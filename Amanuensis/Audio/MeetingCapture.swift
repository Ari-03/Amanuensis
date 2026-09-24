import AVFoundation
import CoreMedia
import Foundation
import Observation
import ScreenCaptureKit

/// Captures microphone and computer audio without registering a screen output or writing video.
@MainActor
@Observable
final class MeetingCapture {
    private(set) var isRecording = false
    private(set) var level = 0.0
    private(set) var spectrum = AudioSpectrum.silence
    private(set) var duration = 0.0
    private(set) var selectedDeviceName = "No microphone selected"
    var onInterruption: (@MainActor (String) -> Void)?

    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var worker: MeetingAudioWorker?
    @ObservationIgnored private var deviceObserver: NSObjectProtocol?
    @ObservationIgnored private var operationID = UUID()
    @ObservationIgnored private var isStarting = false
    @ObservationIgnored private var isFinishing = false
    @ObservationIgnored private var captureStartTask: Task<Void, any Error>?
    @ObservationIgnored private var teardownTask: Task<Void, Never>?

    isolated deinit {
        if let deviceObserver { NotificationCenter.default.removeObserver(deviceObserver) }
        worker?.cancel()
        let oldStream = stream
        Task { try? await oldStream?.stopCapture() }
    }

    func start(preferences: [MicrophonePreference], outputURL: URL) async throws {
        guard !isStarting, stream == nil else { throw MeetingCaptureError.alreadyRecording }
        isStarting = true
        let operation = UUID()
        operationID = operation
        defer { if operationID == operation { isStarting = false } }
        await teardownTask?.value
        try validateOperation(operation)
        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: authorized = true
        case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .audio)
        default: authorized = false
        }
        guard authorized else { throw MeetingCaptureError.microphonePermission }
        try validateOperation(operation)
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices.filter(\.isConnected)
        let identifiers =
            preferences.isEmpty
            ? devices.map(\.uniqueID) : preferences.filter(\.isEnabled).map(\.id)
        guard let device = identifiers.compactMap({ id in devices.first { $0.uniqueID == id } }).first else {
            throw MeetingCaptureError.noMicrophone
        }
        // This call asks macOS for Screen & System Audio Recording permission when needed.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw MeetingCaptureError.systemAudioPermission(error.localizedDescription)
        }
        try validateOperation(operation)
        guard let display = content.displays.first else { throw MeetingCaptureError.noDisplay }
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.captureMicrophone = true
        configuration.microphoneCaptureDeviceID = device.uniqueID
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 1
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false
        let newWorker = try MeetingAudioWorker(outputURL: outputURL)
        newWorker.meter = { [weak self] value, spectrum, seconds in
            Task { @MainActor [weak self] in
                guard let self, self.operationID == operation else { return }
                self.level = value
                self.spectrum = spectrum
                self.duration = seconds
            }
        }
        newWorker.interrupted = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self, self.operationID == operation else { return }
                self.isRecording = false
                self.level = 0
                self.spectrum = AudioSpectrum.silence
                self.onInterruption?(message)
            }
        }
        let newStream = SCStream(
            filter: SCContentFilter(display: display, excludingWindows: []),
            configuration: configuration, delegate: newWorker
        )
        do {
            try newStream.addStreamOutput(newWorker, type: .audio, sampleHandlerQueue: newWorker.queue)
            try newStream.addStreamOutput(newWorker, type: .microphone, sampleHandlerQueue: newWorker.queue)
            worker = newWorker
            stream = newStream
            duration = 0
            level = 0
            spectrum = AudioSpectrum.silence
            selectedDeviceName = device.localizedName
            deviceObserver = NotificationCenter.default.addObserver(
                forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.operationID == operation else { return }
                    self.isRecording = false
                    self.onInterruption?(
                        "The meeting microphone disconnected. Stop to save the captured audio.")
                }
            }
            let startup = Task { try await newStream.startCapture() }
            captureStartTask = startup
            try await startup.value
            try await newWorker.waitForMicrophone()
            try validateOperation(operation)
            isRecording = true
        } catch {
            if operationID == operation {
                try? await newStream.stopCapture()
                await newWorker.cancelAndWait()
                clearCapture()
            } else {
                await teardownTask?.value
            }
            throw error
        }
    }

    func stop() async throws -> CapturedAudio {
        guard !isStarting, !isFinishing, let stream, let worker else {
            throw MeetingCaptureError.notRecording
        }
        let operation = operationID
        isFinishing = true
        defer { if operationID == operation { isFinishing = false } }
        isRecording = false
        // The writer also records delegate errors, but usable partial audio remains recoverable.
        try? await stream.stopCapture()
        do {
            let result = try await worker.finish()
            try validateOperation(operation)
            duration = result.duration
            clearCapture()
            return result
        } catch {
            await worker.cancelAndWait()
            if operationID == operation { clearCapture() }
            throw error
        }
    }

    /// Schedules teardown immediately. A subsequent start waits for this task automatically.
    func cancel() {
        operationID = UUID()
        let previousTeardown = teardownTask
        let oldStream = stream
        let oldWorker = worker
        let startup = captureStartTask
        oldWorker?.cancel()
        clearCapture()
        duration = 0
        teardownTask = Task {
            await previousTeardown?.value
            // stopCapture must follow an in-flight startCapture, including cancellation during startup.
            _ = try? await startup?.value
            try? await oldStream?.stopCapture()
            await oldWorker?.cancelAndWait()
        }
    }

    /// Returns after ScreenCaptureKit has stopped and the writer has closed and removed its files.
    func cancelAndWait() async {
        cancel()
        await teardownTask?.value
    }

    private func validateOperation(_ id: UUID) throws {
        try Task.checkCancellation()
        guard operationID == id else { throw CancellationError() }
    }

    private func clearCapture() {
        if let deviceObserver { NotificationCenter.default.removeObserver(deviceObserver) }
        deviceObserver = nil
        stream = nil
        captureStartTask = nil
        worker = nil
        isStarting = false
        isFinishing = false
        isRecording = false
        level = 0
        spectrum = AudioSpectrum.silence
    }
}

private nonisolated enum MeetingCaptureError: LocalizedError {
    case alreadyRecording, microphonePermission, noMicrophone, noDisplay, notRecording
    case systemAudioPermission(String)
    case noMicrophoneSamples, unsupportedAudio, emptyRecording
    var errorDescription: String? {
        switch self {
        case .alreadyRecording: "A meeting recording is already in progress."
        case .microphonePermission: "Allow microphone access in System Settings to record your voice."
        case .noMicrophone: "No included microphone is connected."
        case .noDisplay: "macOS could not find a display for system audio capture."
        case .notRecording: "There is no meeting recording to finish."
        case .systemAudioPermission(let detail):
            "System audio capture could not start. Check Screen & System Audio Recording in System Settings. \(detail)"
        case .noMicrophoneSamples: "The selected microphone did not provide audio. Try another input."
        case .unsupportedAudio: "The meeting audio format could not be recorded."
        case .emptyRecording: "The meeting did not contain any recorded audio."
        }
    }
}

/// All mutable recording state is confined to queue. Only audio samples enter this writer.
private nonisolated final class MeetingAudioWorker: NSObject, SCStreamOutput, SCStreamDelegate,
    @unchecked Sendable
{
    let queue = DispatchQueue(label: "ari.Amanuensis.meeting-audio")
    var meter: (@Sendable (Double, [Double], Double) -> Void)?
    var interrupted: (@Sendable (String) -> Void)?
    private let outputURL: URL
    private let temporaryDirectory: URL
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    private var microphone: MeetingAudioTrack?
    private var system: MeetingAudioTrack?
    private var readiness: CheckedContinuation<Void, any Error>?
    private var failure: (any Error)?
    private var closed = false
    private var cancelled = false
    private var createdOutput = false
    private var lastMeterTime = 0.0

    init(outputURL: URL) throws {
        guard outputURL.isFileURL, ["wav", "m4a", "caf"].contains(outputURL.pathExtension.lowercased()) else {
            throw MeetingCaptureError.unsupportedAudio
        }
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        self.outputURL = outputURL
        temporaryDirectory = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".meeting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        super.init()
    }

    func waitForMicrophone() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                if cancelled {
                    continuation.resume(throwing: CancellationError())
                } else if let failure {
                    continuation.resume(throwing: failure)
                } else if microphone != nil {
                    continuation.resume()
                } else {
                    readiness = continuation
                    queue.asyncAfter(deadline: .now() + 8) { [weak self] in
                        guard let self, let pending = self.readiness else { return }
                        self.readiness = nil
                        pending.resume(throwing: MeetingCaptureError.noMicrophoneSamples)
                    }
                }
            }
        }
    }

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType
    ) {
        guard !closed, failure == nil, sampleBuffer.isValid,
            CMSampleBufferDataIsReady(sampleBuffer), type == .audio || type == .microphone
        else { return }
        do {
            let isMicrophone = type == .microphone
            var track = isMicrophone ? microphone : system
            if track == nil {
                track = try MeetingAudioTrack(
                    url: temporaryDirectory.appendingPathComponent(
                        isMicrophone ? "microphone.caf" : "system.caf"),
                    format: format, firstTimestamp: sampleBuffer.presentationTimeStamp.seconds
                )
            }
            guard let track else { return }
            let peak = try track.append(sampleBuffer)
            if isMicrophone {
                microphone = track
                readiness?.resume()
                readiness = nil
            } else {
                system = track
            }
            let seconds = max(microphone?.duration ?? 0, system?.duration ?? 0)
            if seconds - lastMeterTime >= 0.05 {
                lastMeterTime = seconds
                meter?(Double(peak), microphone?.spectrum.snapshot() ?? AudioSpectrum.silence, seconds)
            }
        } catch {
            failure = error
            readiness?.resume(throwing: error)
            readiness = nil
            interrupted?("Meeting audio capture failed. \(error.localizedDescription)")
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        queue.async { [self] in
            guard !closed else { return }
            failure = error
            readiness?.resume(throwing: error)
            readiness = nil
            interrupted?("Meeting recording stopped. \(error.localizedDescription)")
        }
    }

    func finish() async throws -> CapturedAudio {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                closed = true
                readiness?.resume(throwing: MeetingCaptureError.notRecording)
                readiness = nil
                do {
                    guard !cancelled else { throw CancellationError() }
                    let tracks = [microphone, system].compactMap { $0 }
                    guard !tracks.isEmpty else { throw failure ?? MeetingCaptureError.emptyRecording }
                    for track in tracks { track.close() }
                    let result = try mix(tracks)
                    createdOutput = true
                    try? FileManager.default.removeItem(at: temporaryDirectory)
                    continuation.resume(returning: result)
                } catch {
                    try? FileManager.default.removeItem(at: outputURL)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func cancel() {
        queue.async { [self] in cancelOnQueue() }
    }

    func cancelAndWait() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                cancelOnQueue()
                continuation.resume()
            }
        }
    }

    private func cancelOnQueue() {
        cancelled = true
        closed = true
        readiness?.resume(throwing: CancellationError())
        readiness = nil
        microphone?.close()
        system?.close()
        try? FileManager.default.removeItem(at: temporaryDirectory)
        if createdOutput {
            try? FileManager.default.removeItem(at: outputURL)
            createdOutput = false
        }
    }

    /// Streams the aligned tracks in small blocks; meeting length does not grow memory usage.
    private func mix(_ tracks: [MeetingAudioTrack]) throws -> CapturedAudio {
        let firstTimestamp = tracks.map(\.firstTimestamp).min() ?? 0
        let readers = try tracks.map { try AVAudioFile(forReading: $0.url) }
        let offsets = tracks.map {
            AVAudioFramePosition(max(0, (($0.firstTimestamp - firstTimestamp) * 48_000).rounded()))
        }
        let length = zip(readers, offsets).map { $0.length + $1 }.max() ?? 0
        guard length > 0 else { throw MeetingCaptureError.emptyRecording }
        let settings: [String: Any] =
            outputURL.pathExtension.lowercased() == "m4a"
            ? [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000,
            ]
            : [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            ]
        let output = try AVAudioFile(forWriting: outputURL, settings: settings)
        guard let mixed = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096),
            let scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096),
            let destination = mixed.floatChannelData?[0]
        else { throw MeetingCaptureError.unsupportedAudio }
        var position: AVAudioFramePosition = 0
        while position < length {
            let count = AVAudioFrameCount(min(4096, length - position))
            mixed.frameLength = count
            destination.update(repeating: 0, count: Int(count))
            for index in readers.indices {
                let reader = readers[index]
                let start = max(position, offsets[index])
                let end = min(position + Int64(count), offsets[index] + reader.length)
                guard end > start else { continue }
                reader.framePosition = start - offsets[index]
                try reader.read(into: scratch, frameCount: AVAudioFrameCount(end - start))
                guard let samples = scratch.floatChannelData?[0] else {
                    throw MeetingCaptureError.unsupportedAudio
                }
                for frame in 0..<Int(scratch.frameLength) {
                    let destinationIndex = Int(start - position) + frame
                    // Fixed headroom prevents clipping when both sources speak together.
                    destination[destinationIndex] += samples[frame] * 0.5
                }
            }
            try output.write(from: mixed)
            position += Int64(count)
        }
        return CapturedAudio(url: outputURL, duration: Double(length) / 48_000)
    }
}

private nonisolated final class MeetingAudioTrack {
    let url: URL
    let firstTimestamp: Double
    var duration: Double { Double(writtenFrames) / format.sampleRate }
    let spectrum = AudioSpectrum()
    private let format: AVAudioFormat
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var writtenFrames: AVAudioFramePosition = 0

    init(url: URL, format: AVAudioFormat, firstTimestamp: Double) throws {
        guard firstTimestamp.isFinite else { throw MeetingCaptureError.unsupportedAudio }
        self.url = url
        self.format = format
        self.firstTimestamp = firstTimestamp
        file = try AVAudioFile(forWriting: url, settings: format.settings)
    }

    func close() { file = nil }

    func append(_ sample: CMSampleBuffer) throws -> Float {
        guard let description = sample.formatDescription, let file else {
            throw MeetingCaptureError.unsupportedAudio
        }
        let inputFormat = AVAudioFormat(cmAudioFormatDescription: description)
        if converter?.inputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: format)
            converter?.primeMethod = .none
        }
        guard let converter else { throw MeetingCaptureError.unsupportedAudio }
        return try sample.withAudioBufferList { list, _ in
            guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, bufferListNoCopy: list.unsafePointer),
                let output = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(
                        ceil(Double(sample.numSamples) * 48_000 / inputFormat.sampleRate)) + 256
                )
            else { throw MeetingCaptureError.unsupportedAudio }
            input.frameLength = AVAudioFrameCount(sample.numSamples)
            let provider = MeetingConverterInput(input)
            let timestamp = sample.presentationTimeStamp.seconds
            guard timestamp.isFinite else { throw MeetingCaptureError.unsupportedAudio }
            let target = AVAudioFramePosition(max(0, ((timestamp - firstTimestamp) * 48_000).rounded()))
            // Fill genuine source gaps while ignoring sub-buffer timestamp jitter.
            if target > writtenFrames + 480 {
                guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096),
                    let zeros = silence.floatChannelData?[0]
                else { throw MeetingCaptureError.unsupportedAudio }
                zeros.update(repeating: 0, count: 4096)
                while writtenFrames < target {
                    silence.frameLength = AVAudioFrameCount(min(4096, target - writtenFrames))
                    try file.write(from: silence)
                    writtenFrames += Int64(silence.frameLength)
                }
            }
            var peak: Float = 0
            while true {
                output.frameLength = 0
                var error: NSError?
                let status = converter.convert(to: output, error: &error) { packets, inputStatus in
                    provider.next(frameCount: packets, status: inputStatus)
                }
                if let error { throw error }
                guard status != .error, let samples = output.floatChannelData?[0] else {
                    throw MeetingCaptureError.unsupportedAudio
                }
                if output.frameLength > 0 {
                    try file.write(from: output)
                    writtenFrames += Int64(output.frameLength)
                    spectrum.append(
                        UnsafeBufferPointer(start: samples, count: Int(output.frameLength)),
                        sampleRate: format.sampleRate)
                    for index in 0..<Int(output.frameLength) { peak = max(peak, abs(samples[index])) }
                }
                if status != .haveData { break }
            }
            return min(1, peak)
        }
    }
}

/// AVAudioConverter consumes this borrowed buffer synchronously before append returns.
private nonisolated final class MeetingConverterInput: @unchecked Sendable {
    private let lock = NSLock()
    private let buffer: AVAudioPCMBuffer
    private var position: AVAudioFrameCount = 0

    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func next(frameCount: AVAudioPacketCount, status: UnsafeMutablePointer<AVAudioConverterInputStatus>)
        -> AVAudioBuffer?
    {
        lock.lock()
        defer { lock.unlock() }
        guard position < buffer.frameLength else {
            status.pointee = .noDataNow
            return nil
        }
        let count = min(frameCount, buffer.frameLength - position)
        guard count > 0, let chunk = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: count) else {
            status.pointee = .noDataNow
            return nil
        }
        chunk.frameLength = count
        let source = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(chunk.mutableAudioBufferList)
        for index in source.indices {
            let stride = Int(source[index].mDataByteSize) / Int(buffer.frameLength)
            if let input = source[index].mData, let output = destination[index].mData {
                memcpy(output, input.advanced(by: Int(position) * stride), Int(count) * stride)
            }
        }
        position += count
        status.pointee = .haveData
        return chunk
    }
}
