import AVFoundation
import Foundation
import Observation

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
    func start(preferences: [MicrophonePreference], outputURL: URL) async throws {
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

        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: authorized = true
        case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .audio)
        default: authorized = false
        }
        guard authorized else { throw AudioCaptureError.microphonePermission }
        try Task.checkCancellation()
        guard operationID == requestID else { throw CancellationError() }
        refreshDevices()
        // An empty initial preference list uses discovered inputs. A configured list is authoritative.
        let inputIDs =
            preferences.isEmpty
            ? devices.filter(\.isConnected).map(\.id)
            : preferences.filter(\.isEnabled).map(\.id)
        guard !inputIDs.isEmpty else { throw AudioCaptureError.noMicrophone }
        duration = 0
        level = 0
        spectrum = AudioSpectrum.silence

        let name = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await worker.start(requestID: requestID, inputIDs: inputIDs, outputURL: outputURL) {
                [weak self] level, spectrum, duration in
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
    case alreadyRecording, microphonePermission, noMicrophone, unsupportedFileType
    case cannotRecord, notRecording, emptyRecording

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: "A recording is already in progress."
        case .microphonePermission: "Allow microphone access in System Settings to record your voice."
        case .noMicrophone: "No included microphone is connected and available."
        case .unsupportedFileType: "Recordings must use a WAV, CAF, or M4A file."
        case .cannotRecord: "The microphone could not start recording. Try another input."
        case .notRecording: "There is no recording to finish."
        case .emptyRecording: "The recording did not contain any audio."
        }
    }
}

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
                    guard let selectedDevice else { throw AudioCaptureError.noMicrophone }
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
                    spectrum.reset()
                    if fileType == .m4a {
                        newOutput.audioSettings = [
                            AVFormatIDKey: kAudioFormatMPEG4AAC,
                            AVSampleRateKey: 48_000,
                            AVNumberOfChannelsKey: 1,
                            AVEncoderBitRateKey: 96_000,
                        ]
                    } else {
                        newOutput.audioSettings = [
                            AVFormatIDKey: kAudioFormatLinearPCM,
                            AVSampleRateKey: 48_000,
                            AVNumberOfChannelsKey: 1,
                            AVLinearPCMBitDepthKey: 16,
                            AVLinearPCMIsFloatKey: false,
                            AVLinearPCMIsBigEndianKey: false,
                            AVLinearPCMIsNonInterleaved: false,
                        ]
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

    func fileOutput(
        _ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        queue.async { [self] in
            guard recordingURL == fileURL else { return }
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
                self.meter?(level, self.spectrum.bands, seconds.isFinite ? max(0, seconds) : 0)
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
        guard output === analysisOutput, !stopRequested, sampleBuffer.isValid,
            CMSampleBufferDataIsReady(sampleBuffer), let description = sampleBuffer.formatDescription
        else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard format.commonFormat == .pcmFormatFloat32, format.channelCount == 1 else { return }
        try? sampleBuffer.withAudioBufferList { list, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer),
                let samples = buffer.floatChannelData?[0]
            else { return }
            spectrum.append(
                UnsafeBufferPointer(start: samples, count: sampleBuffer.numSamples),
                sampleRate: format.sampleRate)
        }
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
        spectrum.reset()
        session?.stopRunning()
        session = nil
        activeRequestID = nil
        output = nil
        meter = nil
        interrupt = nil
    }
}
