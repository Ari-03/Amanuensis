import AVFoundation
import Foundation
import Observation
import Speech

/// Apple's recognizer runs on-device. Only the explicit prepare action may download model assets.
@MainActor
@Observable
final class AppleSpeechEngine {
    private(set) var isPrepared = false
    private(set) var isPreparing = false

    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var resultTask: Task<String, any Error>?
    @ObservationIgnored private var installation: AssetInstallationRequest?
    @ObservationIgnored private var operationID = UUID()
    @ObservationIgnored private var isTranscribing = false

    static var isAvailable: Bool {
        SpeechTranscriber.isAvailable
    }

    /// Refreshes asset readiness without permitting a download or cloud fallback.
    @discardableResult
    func checkReadiness() async throws -> Bool {
        let transcriber = try await makeTranscriber()
        isPrepared = await AssetInventory.status(forModules: [transcriber]) == .installed
        return isPrepared
    }

    func prepare() async throws {
        guard !isPreparing, !isTranscribing else { throw AppleSpeechError.busy }
        let requestID = UUID()
        operationID = requestID
        isPreparing = true
        defer {
            if operationID == requestID {
                isPreparing = false
                installation = nil
            }
        }
        let transcriber = try await makeTranscriber()
        try checkCancellation(requestID)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            installation = request
            try checkCancellation(requestID)
            try await request.downloadAndInstall()
        }
        try checkCancellation(requestID)
        isPrepared = await AssetInventory.status(forModules: [transcriber]) == .installed
        guard isPrepared else { throw AppleSpeechError.assetsMissing }
    }

    func transcribe(url: URL) async throws -> String {
        guard !isPreparing, !isTranscribing else { throw AppleSpeechError.busy }
        isTranscribing = true
        let requestID = UUID()
        operationID = requestID
        defer {
            if operationID == requestID {
                analyzer = nil
                resultTask = nil
                isTranscribing = false
            }
        }
        let transcriber = try await makeTranscriber()
        try checkCancellation(requestID)
        isPrepared = await AssetInventory.status(forModules: [transcriber]) == .installed
        guard isPrepared else { throw AppleSpeechError.assetsMissing }
        try checkCancellation(requestID)

        let currentAnalyzer = SpeechAnalyzer(modules: [transcriber])
        analyzer = currentAnalyzer
        let results = Task<String, any Error> {
            var pieces: [String] = []
            for try await result in transcriber.results {
                try Task.checkCancellation()
                guard result.isFinal else { continue }
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { pieces.append(text) }
            }
            return pieces.joined(separator: " ")
        }
        resultTask = results

        do {
            let text = try await withTaskCancellationHandler {
                let audioFile = try AVAudioFile(forReading: url)
                guard audioFile.length > 0 else { throw AppleSpeechError.emptyAudio }
                try await currentAnalyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
                let text = try await results.value
                try checkCancellation(requestID)
                return text
            } onCancel: {
                results.cancel()
                Task { await currentAnalyzer.cancelAndFinishNow() }
            }
            guard !text.isEmpty else { throw AppleSpeechError.noSpeech }
            return text
        } catch {
            results.cancel()
            await currentAnalyzer.cancelAndFinishNow()
            throw error
        }
    }

    func cancel() {
        operationID = UUID()
        installation?.progress.cancel()
        installation = nil
        resultTask?.cancel()
        resultTask = nil
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
        isPreparing = false
        isTranscribing = false
    }

    private func makeTranscriber() async throws -> SpeechTranscriber {
        guard Self.isAvailable else { throw AppleSpeechError.unavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
        else {
            throw AppleSpeechError.englishUnavailable
        }
        return SpeechTranscriber(locale: locale, preset: .transcription)
    }

    private func checkCancellation(_ requestID: UUID) throws {
        try Task.checkCancellation()
        guard operationID == requestID else { throw CancellationError() }
    }
}

private nonisolated enum AppleSpeechError: LocalizedError {
    case unavailable, englishUnavailable, assetsMissing, emptyAudio, noSpeech, busy

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Apple Speech is unavailable on this Mac. Choose another local transcription model."
        case .englishUnavailable: "Apple Speech does not support English on this Mac."
        case .assetsMissing:
            "Prepare Apple Speech in Models before recording. Its English assets are not installed."
        case .emptyAudio: "The recording contains no audio to transcribe."
        case .noSpeech: "No speech was detected in this recording."
        case .busy: "Apple Speech is already preparing or transcribing."
        }
    }
}
