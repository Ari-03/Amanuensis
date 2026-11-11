import AVFoundation
import Foundation
import Observation
import os

@MainActor
@Observable
final class AudioCapture {
    private(set) var devices: [MicrophoneDevice] = []
    private(set) var selectedDeviceName = "No microphone selected"
    private(set) var level = 0.0
    private(set) var spectrum = AudioSpectrum.silence
    private(set) var duration = 0.0
    private(set) var isRecording = false
    var onInterruption: (@MainActor (String) -> Void)?
    /// The rate of the recorded file and of the samples `start` hands to its `samples` callback.
    nonisolated static let sampleRate = 48_000.0

    @ObservationIgnored private let worker = AudioRecordingWorker()
    @ObservationIgnored private var deviceObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var operationID = UUID()
    @ObservationIgnored private var isStarting = false
    @ObservationIgnored private var cancellation: (id: UUID, task: Task<Void, Never>)?

    init() {
        refreshDevices()
        for notification in [
            AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification,
        ] {
            let observer = NotificationCenter.default.addObserver(
                forName: notification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshDevices()
                }
            }
            deviceObservers.append(observer)
        }
    }

    isolated deinit {
        deviceObservers.forEach(NotificationCenter.default.removeObserver)
        worker.cancel()
    }

    /// The system microphone permission, read fresh on every call.
    static var access: MicrophoneAccess {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        default: .denied
        }
    }

    /// Shows the system prompt when the permission is undecided. Returns whether access is granted.
    static func requestAccess() async -> Bool {
        switch access {
        case .granted: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted: false
        }
    }

    func refreshDevices() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        )
        var seen = Set<String>()
        devices = discovery.devices.filter { seen.insert($0.uniqueID).inserted }.map {
            MicrophoneDevice(id: $0.uniqueID, name: $0.localizedName, isConnected: $0.isConnected)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Chooses the first available included input without changing the system input device.
    /// `samples` receives the recording's 16-bit PCM on the capture thread as it arrives, starting at the
    /// file's first sample, and must return quickly. It stops at the first gap, so what it received is
    /// always the start of the file unless the two disagree.
    func start(
        preferences: [MicrophonePreference], outputURL: URL,
        samples: (@Sendable (UnsafeBufferPointer<Int16>) -> Void)? = nil
    ) async throws {
        // Also serialize callers that use the synchronous cancel API before restarting.
        while let pending = cancellation {
            await pending.task.value
            if cancellation?.id == pending.id { cancellation = nil }
        }
        try Task.checkCancellation()
        guard !isRecording, !isStarting else { throw AudioCaptureError.alreadyRecording }
        isStarting = true
        let requestID = UUID()
        operationID = requestID
        defer {
            if operationID == requestID { isStarting = false }
        }

        guard await Self.requestAccess() else { throw AudioCaptureError.microphonePermission }
        try Task.checkCancellation()
        guard operationID == requestID else { throw CancellationError() }
        refreshDevices()
        // An empty initial preference list uses discovered inputs. A configured list is authoritative.
        let inputIDs =
            preferences.isEmpty
            ? devices.filter(\.isConnected).map(\.id)
            : preferences.filter(\.isEnabled).map(\.id)
        guard !inputIDs.isEmpty else { throw RecordingFailure.noMicrophone }
        duration = 0
        level = 0
        spectrum = AudioSpectrum.silence

        let name = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await worker.start(
                requestID: requestID, inputIDs: inputIDs, outputURL: outputURL, samples: samples
            ) { [weak self] level, spectrum, duration in
                Task { @MainActor [weak self] in
                    guard let self, self.operationID == requestID else { return }
                    self.level = level
                    self.spectrum = spectrum
                    self.duration = duration
                }
            } interrupted: { [weak self] message in
                Task { @MainActor [weak self] in
                    guard let self, self.operationID == requestID else { return }
                    self.isRecording = false
                    self.level = 0
                    self.spectrum = AudioSpectrum.silence
                    self.onInterruption?(message)
                }
            }
        } onCancel: {
            self.worker.cancel(requestID: requestID)
        }
        guard operationID == requestID, !Task.isCancelled else {
            await worker.cancelAndWait(requestID: requestID)
            throw CancellationError()
        }
        selectedDeviceName = name
        isRecording = true
    }

    /// Waits until the capture delegate confirms the file is closed and readable.
    func stop() async throws -> CapturedAudio {
        let requestID = operationID
        defer {
            if operationID == requestID {
                isRecording = false
                level = 0
                spectrum = AudioSpectrum.silence
            }
        }
        let result = try await worker.stop()
        guard operationID == requestID else { throw CancellationError() }
        duration = result.duration
        return CapturedAudio(url: result.url, duration: result.duration)
    }

    func cancel() {
        _ = beginCancellation()
    }

    /// Returns only after file finalization, session shutdown, and canceled-file removal.
    func cancelAndWait() async {
        await beginCancellation().value
    }

    private func beginCancellation() -> Task<Void, Never> {
        operationID = UUID()
        isStarting = false
        isRecording = false
        level = 0
        spectrum = AudioSpectrum.silence
        duration = 0
        if let cancellation { return cancellation.task }
        let task = Task { [worker] in await worker.cancelAndWait() }
        cancellation = (UUID(), task)
        return task
    }
}

private nonisolated enum AudioCaptureError: LocalizedError {
    case alreadyRecording, microphonePermission, unsupportedFileType
    case cannotRecord, notRecording, emptyRecording

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: "A recording is already in progress."
        case .microphonePermission: "Allow microphone access in System Settings to record your voice."
        case .unsupportedFileType: "Recordings must use a WAV, CAF, or M4A file."
        case .cannotRecord: "The microphone could not start recording. Try another input."
        case .notRecording: "There is no recording to finish."
        case .emptyRecording: "The recording did not contain any audio."
        }
    }
}

/// Shows in Console without extra settings, with the live transcription log under the same subsystem.
private nonisolated let captureLog = Logger(subsystem: "dev.amanuensis", category: "audio-capture")

private nonisolated struct FinishedRecording: Sendable {
    let url: URL
    let duration: Double
}

/// AVFoundation state and continuations are confined to queue. Delegate callbacks hop to it.
private nonisolated final class AudioRecordingWorker: NSObject, AVCaptureFileOutputRecordingDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate,
    @unchecked Sendable
{
    private let queue = DispatchQueue(label: "ari.Amanuensis.audio-capture")
    private var session: AVCaptureSession?
    private var output: AVCaptureAudioFileOutput?
    private var analysisOutput: AVCaptureAudioDataOutput?
    /// Taps the same PCM the file gets, for transcription while recording.
    private var pcmOutput: AVCaptureAudioDataOutput?
    private var samples: (@Sendable (UnsafeBufferPointer<Int16>) -> Void)?
    /// When the file's first sample was captured, and the tap's buffers that arrived before that was known.
    private var fileStart: CMTime?
    /// Copies, so capture's own buffers go straight back to it.
    private var earlyPCM: [(time: CMTime, samples: [Int16])] = []
    /// Where the next tap buffer must start for the samples to stay continuous.
    private var nextPCMTime: CMTime?
    private let spectrum = AudioSpectrum()
    private var timer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var startContinuation: CheckedContinuation<String, any Error>?
    private var stopContinuations: [CheckedContinuation<FinishedRecording, any Error>] = []
    private var cancellationContinuations: [CheckedContinuation<Void, Never>] = []
    private var finished: Result<FinishedRecording, any Error>?
    private var recordingURL: URL?
    private var deviceName = "Microphone"
    private var activeRequestID: UUID?
    private var cancelled = false
    private var stopRequested = false
    private var interrupt: (@Sendable (String) -> Void)?
    private var meter: (@Sendable (Double, [Double], Double) -> Void)?

    func start(
        requestID: UUID, inputIDs: [String], outputURL: URL,
        samples: (@Sendable (UnsafeBufferPointer<Int16>) -> Void)?,
        metering: @escaping @Sendable (Double, [Double], Double) -> Void,
        interrupted: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard session == nil else {
                    continuation.resume(throwing: AudioCaptureError.alreadyRecording)
                    return
                }
                do {
                    guard outputURL.isFileURL, !FileManager.default.fileExists(atPath: outputURL.path) else {
                        throw CocoaError(.fileWriteFileExists)
                    }
                    let fileType: AVFileType
                    switch outputURL.pathExtension.lowercased() {
                    case "wav": fileType = .wav
                    case "caf": fileType = .caf
                    case "m4a": fileType = .m4a
                    default: throw AudioCaptureError.unsupportedFileType
                    }
                    let newSession = AVCaptureSession()
                    var selectedDevice: AVCaptureDevice?
                    for id in inputIDs {
                        guard let device = AVCaptureDevice(uniqueID: id), device.isConnected,
                            let input = try? AVCaptureDeviceInput(device: device),
                            newSession.canAddInput(input)
                        else { continue }
                        newSession.addInput(input)
                        selectedDevice = device
                        break
                    }
                    guard let selectedDevice else { throw RecordingFailure.noMicrophone }
                    let newOutput = AVCaptureAudioFileOutput()
                    guard newSession.canAddOutput(newOutput) else { throw AudioCaptureError.cannotRecord }
                    newSession.addOutput(newOutput)
                    let analysis = AVCaptureAudioDataOutput()
                    guard newSession.canAddOutput(analysis) else { throw AudioCaptureError.cannotRecord }
                    newSession.addOutput(analysis)
                    analysis.audioSettings = [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVSampleRateKey: 48_000,
                        AVNumberOfChannelsKey: 1,
                        AVLinearPCMBitDepthKey: 32,
                        AVLinearPCMIsFloatKey: true,
                        AVLinearPCMIsBigEndianKey: false,
                        AVLinearPCMIsNonInterleaved: false,
                    ]
                    analysis.setSampleBufferDelegate(self, queue: queue)
                    analysisOutput = analysis
                    if let samples {
                        let tap = AVCaptureAudioDataOutput()
                        guard newSession.canAddOutput(tap) else { throw AudioCaptureError.cannotRecord }
                        newSession.addOutput(tap)
                        tap.audioSettings = Self.pcm16Settings
                        tap.setSampleBufferDelegate(self, queue: queue)
                        pcmOutput = tap
                        self.samples = samples
                    }
                    spectrum.reset()
                    if fileType == .m4a {
                        newOutput.audioSettings = [
                            AVFormatIDKey: kAudioFormatMPEG4AAC,
                            AVSampleRateKey: 48_000,
                            AVNumberOfChannelsKey: 1,
                            AVEncoderBitRateKey: 96_000,
                        ]
                    } else {
                        newOutput.audioSettings = Self.pcm16Settings
                    }
                    try FileManager.default.createDirectory(
                        at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true
                    )
                    session = newSession
                    activeRequestID = requestID
                    output = newOutput
                    recordingURL = outputURL
                    deviceName = selectedDevice.localizedName
                    startContinuation = continuation
                    finished = nil
                    cancelled = false
                    stopRequested = false
                    interrupt = interrupted
                    meter = metering
                    observeInterruptions(device: selectedDevice, session: newSession)
                    newSession.startRunning()
                    guard newSession.isRunning else { throw AudioCaptureError.cannotRecord }
                    newOutput.startRecording(to: outputURL, outputFileType: fileType, recordingDelegate: self)
                    queue.asyncAfter(deadline: .now() + 8) { [weak self] in
                        guard let self, self.recordingURL == outputURL,
                            let continuation = self.startContinuation
                        else { return }
                        self.startContinuation = nil
                        self.stopRequested = true
                        continuation.resume(throwing: AudioCaptureError.cannotRecord)
                        self.output?.stopRecording()
                        self.session?.stopRunning()
                    }
                } catch {
                    // Before startRecording there is no delegate completion to wait for.
                    startContinuation = nil
                    cleanUp()
                    recordingURL = nil
                    finished = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async throws -> FinishedRecording {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if let finished {
                    recordingURL = nil
                    continuation.resume(with: finished)
                } else if let output {
                    stopContinuations.append(continuation)
                    stopRequested = true
                    if output.isRecording { output.stopRecording() }
                } else {
                    continuation.resume(throwing: AudioCaptureError.notRecording)
                }
            }
        }
    }

    func cancel(requestID: UUID? = nil) {
        queue.async { [self] in
            guard requestID == nil || activeRequestID == requestID else { return }
            requestCancellation()
        }
    }

    func cancelAndWait(requestID: UUID? = nil) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard requestID == nil || activeRequestID == requestID else {
                    continuation.resume()
                    return
                }
                cancellationContinuations.append(continuation)
                requestCancellation()
            }
        }
    }

    private func requestCancellation() {
        let wasCancelled = cancelled
        cancelled = true
        stopRequested = true
        startContinuation?.resume(throwing: CancellationError())
        startContinuation = nil
        if let output {
            if !wasCancelled {
                // Stop the session even if the first audio sample has not arrived yet.
                output.stopRecording()
                session?.stopRunning()
            }
        } else {
            cleanUp()
            if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
            recordingURL = nil
            finished = nil
            finishCancellation()
        }
    }

    private func finishCancellation() {
        let waiters = cancellationContinuations
        cancellationContinuations.removeAll()
        for continuation in waiters { continuation.resume() }
    }

    /// Mono 16-bit 48 kHz, for the WAV file and the transcription tap alike.
    private static var pcm16Settings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioCapture.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    func fileOutput(
        _ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, startPTS: CMTime,
        from connections: [AVCaptureConnection]
    ) {
        queue.async { [self] in
            guard recordingURL == fileURL else { return }
            fileStart = startPTS
            let early = earlyPCM
            earlyPCM.removeAll()
            for (time, pcm) in early { pcm.withUnsafeBufferPointer { deliverPCM($0, at: time) } }
            startContinuation?.resume(returning: deviceName)
            startContinuation = nil
            if stopRequested {
                self.output?.stopRecording()
                return
            }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .milliseconds(60))
            source.setEventHandler { [weak self] in
                guard let self, let output = self.output else { return }
                let decibels =
                    output.connections.flatMap(\.audioChannels).map(\.averagePowerLevel).max() ?? -160
                let level = decibels.isFinite ? min(1, max(0, pow(10, Double(decibels) / 20))) : 0
                let seconds = output.recordedDuration.seconds
                self.meter?(level, self.spectrum.snapshot(), seconds.isFinite ? max(0, seconds) : 0)
            }
            timer = source
            source.resume()
        }
    }

    func fileOutput(
        _ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection], error: (any Error)?
    ) {
        queue.async { [self] in
            guard recordingURL == outputFileURL else { return }
            let wasUnexpected = !stopRequested
            let callback = interrupt
            let result: Result<FinishedRecording, any Error>
            if cancelled {
                result = .failure(CancellationError())
            } else {
                do {
                    if let error,
                        (error as NSError).userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool != true
                    {
                        throw error
                    }
                    let file = try AVAudioFile(forReading: outputFileURL)
                    let seconds = Double(file.length) / file.processingFormat.sampleRate
                    guard seconds.isFinite, seconds > 0 else { throw AudioCaptureError.emptyRecording }
                    result = .success(FinishedRecording(url: outputFileURL, duration: seconds))
                } catch {
                    result = .failure(error)
                }
            }
            startContinuation?.resume(throwing: error ?? AudioCaptureError.cannotRecord)
            startContinuation = nil
            cleanUp()
            if cancelled {
                try? FileManager.default.removeItem(at: outputFileURL)
                recordingURL = nil
            }
            finished = result
            // Once stop hands off a file, its owner manages retention and cancellation.
            if !stopContinuations.isEmpty { recordingURL = nil }
            for continuation in stopContinuations {
                continuation.resume(with: result)
            }
            stopContinuations.removeAll()
            finishCancellation()
            if wasUnexpected, !cancelled {
                callback?(
                    error?.localizedDescription
                        ?? "Recording stopped unexpectedly. Your recorded audio was preserved.")
            }
        }
    }

    /// Runs on the same serial queue as file capture; the recorded file keeps its existing encoding.
    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard !stopRequested else { return }
        if output === pcmOutput {
            receivePCM(sampleBuffer)
        } else if output === analysisOutput {
            spectrum.append(sampleBuffer)
        }
    }

    /// Hands the tap's samples on from the file's first sample, by capture time. Buffers that arrive
    /// before that time is known wait as copies. A format change ends the hand-off.
    private func receivePCM(_ buffer: CMSampleBuffer) {
        guard samples != nil else { return }
        let count = buffer.numSamples
        guard buffer.isValid, CMSampleBufferDataIsReady(buffer), count > 0,
            let description = buffer.formatDescription
        else { return stopPCM("a buffer had no audio") }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard format.commonFormat == .pcmFormatInt16, format.channelCount == 1,
            format.sampleRate == AudioCapture.sampleRate
        else { return stopPCM("a buffer was not 16-bit mono at 48 kHz") }
        do {
            try buffer.withAudioBufferList { list, _ in
                guard let data = list.first?.mData, Int(list.first?.mDataByteSize ?? 0) >= count * 2 else {
                    return stopPCM("a buffer held fewer bytes than samples")
                }
                let pcm = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int16.self), count: count)
                if fileStart != nil {
                    deliverPCM(pcm, at: buffer.presentationTimeStamp)
                } else if earlyPCM.count < 100 {
                    earlyPCM.append((buffer.presentationTimeStamp, Array(pcm)))
                } else {
                    stopPCM("the file's start time did not arrive within 100 buffers")
                }
            }
        } catch { stopPCM("a buffer could not be read") }
    }

    /// Any gap, overlap or late start ends the hand-off rather than shifting the samples against the file.
    private func deliverPCM(_ pcm: UnsafeBufferPointer<Int16>, at time: CMTime) {
        guard let samples, let fileStart else { return }
        guard fileStart.isNumeric, time.isNumeric else { return stopPCM("a capture time was not a number") }
        let rate = AudioCapture.sampleRate
        let offset = ((fileStart - time).seconds * rate).rounded()
        if nextPCMTime == nil, offset < 0 {
            return stopPCM("the tap's first buffer began \(Int(-offset)) samples after the file")
        }
        let first = Int(max(0, offset))
        guard first < pcm.count else { return }
        if let expected = nextPCMTime, abs((time - expected).seconds) * rate > 0.5 {
            return stopPCM("the tap skipped or repeated audio")
        }
        nextPCMTime = time + CMTime(value: CMTimeValue(pcm.count), timescale: CMTimeScale(rate))
        samples(UnsafeBufferPointer(rebasing: pcm[first...]))
    }

    /// Ends the hand-off. A reason means live transcription stops early, and is logged; everything not yet
    /// transcribed is transcribed from the file after Stop.
    private func stopPCM(_ reason: String? = nil) {
        if let reason, samples != nil {
            captureLog.notice("Transcription tap stopped: \(reason, privacy: .public)")
        }
        samples = nil
        earlyPCM.removeAll()
    }

    private func observeInterruptions(device: AVCaptureDevice, session: AVCaptureSession) {
        for (name, object) in [
            (AVCaptureDevice.wasDisconnectedNotification, device as AnyObject),
            (AVCaptureSession.runtimeErrorNotification, session as AnyObject),
            (AVCaptureSession.wasInterruptedNotification, session as AnyObject),
        ] {
            let token = NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) {
                [weak self] _ in
                self?.queue.async { [weak self] in
                    guard let self, !self.stopRequested else { return }
                    self.stopRequested = true
                    if self.output?.isRecording == true { self.output?.stopRecording() }
                    self.interrupt?(
                        "The microphone disconnected or recording was interrupted. Recorded audio was preserved."
                    )
                }
            }
            observers.append(token)
        }
    }

    private func cleanUp() {
        timer?.cancel()
        timer = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        analysisOutput?.setSampleBufferDelegate(nil, queue: nil)
        analysisOutput = nil
        pcmOutput?.setSampleBufferDelegate(nil, queue: nil)
        pcmOutput = nil
        stopPCM()
        fileStart = nil
        nextPCMTime = nil
        spectrum.reset()
        session?.stopRunning()
        session = nil
        activeRequestID = nil
        output = nil
        meter = nil
        interrupt = nil
    }
}
