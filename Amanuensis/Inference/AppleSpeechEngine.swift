import AVFoundation
import Foundation
import Observation
import Speech

/// Apple's recognizer runs on-device. Only the explicit prepare action may download model assets.
/// Assets are per language. macOS offers one or more regional locales per language; the engine uses
/// one locale for each language code, chosen by `locale(for:among:installed:)`. Preparing one language
/// and transcribing another run independently, and cancelling a transcription leaves a download alone.
@MainActor
@Observable
final class AppleSpeechEngine {
    /// The locale used for each language code macOS supports. Nil until the first check finishes.
    private(set) var locales: [String: Locale]?
    /// Language codes whose assets are installed.
    private(set) var readyLanguages: Set<String> = []
    /// The language whose assets are being prepared.
    private(set) var preparingLanguage: String?
    var isPreparing: Bool { preparingLanguage != nil }

    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var resultTask: Task<String, any Error>?
    @ObservationIgnored private var transcriptionID = UUID()
    @ObservationIgnored private var isTranscribing = false
    /// Advanced when a readiness check starts or a preparation finishes, so a check that was already
    /// running cannot overwrite the answer a finished preparation published.
    @ObservationIgnored private var readinessGeneration = 0
    @ObservationIgnored private var readinessCheck: Task<Void, Never>?

    static var isAvailable: Bool {
        SpeechTranscriber.isAvailable
    }

    /// Refreshes the supported languages and which have assets, without permitting a download or
    /// cloud fallback. Checking all of them takes tens of milliseconds. Checks run one after another,
    /// so every caller returns with an answer at least as new as its own call.
    func checkReadiness() async throws {
        guard Self.isAvailable else { throw AppleSpeechError.unavailable }
        let previous = readinessCheck
        let check = Task {
            await previous?.value
            await refreshReadiness()
        }
        readinessCheck = check
        await check.value
    }

    private func refreshReadiness() async {
        readinessGeneration += 1
        let generation = readinessGeneration
        let supported = await SpeechTranscriber.supportedLocales.filter {
            $0.language.languageCode?.identifier != "mul"
        }
        var installed: Set<String> = []
        for locale in supported where await Self.isInstalled(locale) { installed.insert(locale.identifier) }
        var chosen: [String: Locale] = [:]
        for code in Set(supported.compactMap(\.language.languageCode?.identifier)) {
            chosen[code] = await Self.locale(for: code, among: supported, installed: installed)
        }
        guard generation == readinessGeneration else { return }
        locales = chosen
        readyLanguages = Set(chosen.filter { installed.contains($0.value.identifier) }.keys)
    }

    /// Downloads one language's assets. macOS reserves a few locales per app
    /// (`AssetInventory.maximumReservedLocales`, five on the development Mac), so when they are all
    /// taken, locales for languages outside `keeping` are released first.
    func prepare(language code: String, keeping: Set<String>) async throws {
        guard !isPreparing else { throw AppleSpeechError.busy }
        preparingLanguage = code
        defer { preparingLanguage = nil }
        let transcriber = try await makeTranscriber(language: code)
        guard let locale = locales?[code] else { throw AppleSpeechError.languageUnavailable(code) }
        let kept = Set(keeping.union([code]).compactMap { locales?[$0]?.identifier })
        var reserved = await AssetInventory.reservedLocales
        while reserved.count >= AssetInventory.maximumReservedLocales,
            !reserved.contains(where: { $0.identifier == locale.identifier }),
            let unused = reserved.first(where: { !kept.contains($0.identifier) })
        {
            await AssetInventory.release(reservedLocale: unused)
            reserved.removeAll { $0.identifier == unused.identifier }
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        // Recheck every ready language too, since a released locale is no longer installed.
        var ready: Set<String> = []
        for candidate in readyLanguages.union([code]) {
            if let locale = locales?[candidate], await Self.isInstalled(locale) { ready.insert(candidate) }
        }
        readinessGeneration += 1
        readyLanguages = ready
        guard ready.contains(code) else { throw AppleSpeechError.assetsMissing(code) }
    }

    func transcribe(url: URL, language code: String) async throws -> String {
        guard !isTranscribing else { throw AppleSpeechError.busy }
        isTranscribing = true
        let requestID = UUID()
        transcriptionID = requestID
        defer {
            if transcriptionID == requestID {
                analyzer = nil
                resultTask = nil
                isTranscribing = false
            }
        }
        let transcriber = try await makeTranscriber(language: code)
        try checkCancellation(requestID)
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            readyLanguages.remove(code)
            throw AppleSpeechError.assetsMissing(code)
        }
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

    /// Stops a transcription. An asset download for another language keeps going.
    func cancel() {
        transcriptionID = UUID()
        resultTask?.cancel()
        resultTask = nil
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
        isTranscribing = false
    }

    private func makeTranscriber(language code: String) async throws -> SpeechTranscriber {
        if locales == nil { try await checkReadiness() }
        guard let locale = locales?[code] else { throw AppleSpeechError.languageUnavailable(code) }
        return SpeechTranscriber(locale: locale, preset: .transcription)
    }

    private static func isInstalled(_ locale: Locale) async -> Bool {
        await AssetInventory.status(forModules: [SpeechTranscriber(locale: locale, preset: .transcription)])
            == .installed
    }

    /// The regional locale used for a language. A locale whose assets are already installed wins, so an
    /// update never asks again for a language the user prepared under another region. Then the user's
    /// preferred languages as macOS matches them (Traditional Chinese finds Taiwan), the Mac's region,
    /// the language's usual region (French in France), and the first by identifier.
    private static func locale(for code: String, among supported: [Locale], installed: Set<String>) async
        -> Locale?
    {
        let all = supported.filter { $0.language.languageCode?.identifier == code }
            .sorted { $0.identifier < $1.identifier }
        let installedOnes = all.filter { installed.contains($0.identifier) }
        let candidates = installedOnes.isEmpty ? all : installedOnes
        for preference in Locale.preferredLanguages {
            let wanted = Locale(identifier: preference)
            guard wanted.language.languageCode?.identifier == code,
                let match = await SpeechTranscriber.supportedLocale(equivalentTo: wanted),
                let candidate = candidates.first(where: { $0.identifier == match.identifier })
            else { continue }
            return candidate
        }
        let usualRegion = Locale.Language(identifier: code).maximalIdentifier
            .split(separator: "-").last.map(String.init)
        return candidates.first { $0.region == Locale.current.region }
            ?? candidates.first { $0.region?.identifier == usualRegion } ?? candidates.first
    }

    private func checkCancellation(_ requestID: UUID) throws {
        try Task.checkCancellation()
        guard transcriptionID == requestID else { throw CancellationError() }
    }
}

private nonisolated enum AppleSpeechError: LocalizedError {
    case unavailable, emptyAudio, noSpeech, busy
    case languageUnavailable(String)
    case assetsMissing(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Apple Speech is unavailable on this Mac. Choose another local transcription model."
        case .languageUnavailable(let code):
            "Apple Speech does not support \(SpeechLanguage.name(of: code)) on this Mac."
        case .assetsMissing(let code):
            "Prepare Apple Speech in Models before recording. Its \(SpeechLanguage.name(of: code)) assets are not installed."
        case .emptyAudio: "The recording contains no audio to transcribe."
        case .noSpeech: "No speech was detected in this recording."
        case .busy: "Apple Speech is already busy with that. Try again when it finishes."
        }
    }
}
