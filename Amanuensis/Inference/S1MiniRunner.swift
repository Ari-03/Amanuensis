import Darwin
import Foundation

/// Runs the bundled normalizer in an isolated process and removes its private working files.
@MainActor
final class S1MiniRunner {
    private var operationID: UUID?
    private var cancelledOperationID: UUID?
    private var job: RunningJob?
    private let executableURL: URL
    private let processTimeout: Duration
    private let jobRoot: Result<URL, Error>

    // Multiple runners in one app must never sweep each other's live jobs.
    private static var preparedRoots: Set<URL> = []

    static var helperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/S1MiniHelper")
    }

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: helperURL.path)
    }

    init(helperURL: URL? = nil, timeout: Duration = .seconds(120), jobRootURL: URL? = nil) {
        executableURL = helperURL ?? Self.helperURL
        processTimeout = min(timeout, .seconds(120))
        // Eager preparation also removes files left by a previous app crash before any new job.
        jobRoot = Result { try Self.prepareJobRoot(override: jobRootURL) }
    }

    func clean(text: String, modelURL: URL, mode: DictationMode) async throws -> String {
        guard operationID == nil else { throw S1Error.busy }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw S1Error.helperMissing
        }
        let id = UUID()
        operationID = id
        defer {
            operationID = nil
            cancelledOperationID = nil
        }
        try checkCancellation(id)
        let file: URL
        if modelURL.pathExtension.lowercased() == "gguf" {
            file = modelURL
        } else {
            let contents = try FileManager.default.contentsOfDirectory(
                at: modelURL, includingPropertiesForKeys: nil
            )
            let candidates = contents.filter { $0.pathExtension.lowercased() == "gguf" }
            guard
                let found = candidates.first(where: { $0.lastPathComponent == "s1-mini-q4_k_m.gguf" })
                    ?? (candidates.count == 1 ? candidates.first : nil)
            else { throw S1Error.modelMissing }
            file = found
        }
        var results: [String] = []
        for chunk in Self.chunks(text, maximumCharacters: 2_400) {
            try checkCancellation(id)
            results.append(try await cleanChunk(chunk, model: file, mode: mode, operation: id))
        }
        try checkCancellation(id)
        return Self.join(results, mode: mode)
    }

    func cancel() {
        guard let operationID else { return }
        cancel(operation: operationID)
    }

    private func cancel(operation id: UUID) {
        guard operationID == id else { return }
        cancelledOperationID = id
        if let job { stop(jobID: job.id, error: CancellationError()) }
    }

    private func checkCancellation(_ id: UUID) throws {
        try Task.checkCancellation()
        if cancelledOperationID == id { throw CancellationError() }
    }

    private func cleanChunk(_ text: String, model: URL, mode: DictationMode, operation id: UUID) async throws
        -> String
    {
        try checkCancellation(id)
        do {
            return try await run(text: text, model: model, mode: mode, operation: id)
        } catch S1Error.inputTooLong {
            // Count actual helper tokens by retrying smaller complete partitions; never truncate.
            guard text.count > 1 else { throw S1Error.inputTooLong }
            var results: [String] = []
            for part in Self.chunks(text, maximumCharacters: max(1, text.count / 2)) {
                results.append(try await cleanChunk(part, model: model, mode: mode, operation: id))
            }
            return Self.join(results, mode: mode)
        }
    }

    private func run(text: String, model: URL, mode: DictationMode, operation id: UUID) async throws -> String
    {
        guard job == nil else { throw S1Error.busy }
        try checkCancellation(id)
        let directory = try jobRoot.get().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        // Covers encoding, writing, process-start errors, cancellation, and normal completion.
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.json")
        let output = directory.appendingPathComponent("output.json")
        let request = Request(
            transcript: text, styling: mode.tone.rawValue,
            structure: mode.useLists ? "lists" : "prose",
            context: mode.preset == .mail ? "email" : "general"
        )
        try JSONEncoder().encode(request).write(to: input, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.path)
        let child = Process()
        child.executableURL = executableURL
        child.arguments = ["--model", model.path, "--input", input.path, "--output", output.path]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        let current = RunningJob(process: child, directory: directory, output: output)
        job = current
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                current.continuation = continuation
                let jobID = current.id
                child.terminationHandler = { [weak self] child in
                    let status = child.terminationStatus
                    Task { @MainActor in self?.finished(jobID: jobID, exitCode: status) }
                }
                do {
                    try checkCancellation(id)
                    try child.run()
                    let deadline = processTimeout
                    current.timeoutTask = Task { [weak self] in
                        do { try await Task.sleep(for: deadline) } catch { return }
                        self?.stop(jobID: jobID, error: S1Error.timedOut)
                    }
                } catch {
                    finish(jobID: jobID, result: .failure(error))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(operation: id) }
        }
    }

    private func stop(jobID: UUID, error: Error) {
        guard let job, job.id == jobID, job.stoppingError == nil else { return }
        job.stoppingError = error
        job.timeoutTask?.cancel()
        guard job.process.isRunning else { return }
        job.process.terminate()
        job.killTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let current = self?.job, current.id == jobID, current.process.isRunning else { return }
            // Process identity is still live and matched, so a later job cannot receive this signal.
            kill(current.process.processIdentifier, SIGKILL)
        }
    }

    private func finished(jobID: UUID, exitCode: Int32) {
        guard let job, job.id == jobID else { return }
        if let operationID, cancelledOperationID == operationID {
            finish(jobID: jobID, result: .failure(CancellationError()))
            return
        }
        if let error = job.stoppingError {
            finish(jobID: jobID, result: .failure(error))
            return
        }
        do {
            let data = try Data(contentsOf: job.output)
            guard data.count <= 262_144 else { throw S1Error.invalidResponse }
            let response = try JSONDecoder().decode(Response.self, from: data)
            switch response.status {
            case "success":
                guard exitCode == 0, !response.text.isEmpty else { throw S1Error.invalidResponse }
                finish(jobID: jobID, result: .success(response.text))
            case "empty":
                guard exitCode == 0, response.text.isEmpty else { throw S1Error.invalidResponse }
                finish(jobID: jobID, result: .success(""))
            case "cancelled":
                finish(jobID: jobID, result: .failure(CancellationError()))
            case "error":
                if response.errorCode == "input_too_long" { throw S1Error.inputTooLong }
                throw S1Error.runtime(response.error ?? "S1-mini could not clean this transcript.")
            default:
                throw S1Error.invalidResponse
            }
        } catch let error as S1Error {
            finish(jobID: jobID, result: .failure(error))
        } catch {
            if exitCode == 130 || exitCode == SIGTERM || exitCode == SIGKILL {
                finish(jobID: jobID, result: .failure(CancellationError()))
            } else {
                finish(jobID: jobID, result: .failure(S1Error.invalidResponse))
            }
        }
    }

    private func finish(jobID: UUID, result: Result<String, Error>) {
        guard let current = job, current.id == jobID else { return }
        current.timeoutTask?.cancel()
        current.killTask?.cancel()
        current.process.terminationHandler = nil
        let pending = current.continuation
        current.continuation = nil
        job = nil
        try? FileManager.default.removeItem(at: current.directory)
        pending?.resume(with: result)
    }

    private static func prepareJobRoot(override: URL?) throws -> URL {
        let manager = FileManager.default
        let root = try
            (override
            ?? manager.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appendingPathComponent("Amanuensis/S1MiniJobs", isDirectory: true)).standardizedFileURL
        guard !preparedRoots.contains(root) else { return root }
        if manager.fileExists(atPath: root.path) {
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw S1Error.invalidJobRoot
            }
        }
        try manager.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        // This dedicated directory contains only disposable helper jobs, never history or models.
        for stale in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            try manager.removeItem(at: stale)
        }
        preparedRoots.insert(root)
        return root
    }

    private static func join(_ results: [String], mode: DictationMode) -> String {
        results.filter { !$0.isEmpty }.joined(separator: mode.useLists ? "\n" : " ")
    }

    /// Partitions the original text without dropping whitespace, punctuation, or Unicode characters.
    private static func chunks(_ text: String, maximumCharacters: Int) -> [String] {
        guard text.count > maximumCharacters else { return [text] }
        var result: [String] = []
        var remainder = text[...]
        while remainder.count > maximumCharacters {
            let upper = remainder.index(remainder.startIndex, offsetBy: maximumCharacters)
            let candidate = remainder[..<upper]
            let sentence = candidate.lastIndex(where: { ".!?\n".contains($0) })
            let cut =
                sentence.map { remainder.index(after: $0) }
                ?? candidate.lastIndex(where: { $0.isWhitespace }) ?? upper
            let safeCut = cut == remainder.startIndex ? upper : cut
            result.append(String(remainder[..<safeCut]))
            remainder = remainder[safeCut...]
        }
        if !remainder.isEmpty { result.append(String(remainder)) }
        return result
    }

    private final class RunningJob {
        let id = UUID()
        let process: Process
        let directory: URL
        let output: URL
        var continuation: CheckedContinuation<String, Error>?
        var timeoutTask: Task<Void, Never>?
        var killTask: Task<Void, Never>?
        var stoppingError: Error?

        init(process: Process, directory: URL, output: URL) {
            self.process = process
            self.directory = directory
            self.output = output
        }
    }

    private struct Request: Encodable {
        let transcript: String
        let styling: String
        let structure: String
        let context: String
    }
    private struct Response: Decodable {
        let status: String
        let text: String
        let errorCode: String?
        let error: String?
    }
    private enum S1Error: LocalizedError {
        case helperMissing, modelMissing, inputTooLong, busy, timedOut, invalidResponse, invalidJobRoot
        case runtime(String)
        var errorDescription: String? {
            switch self {
            case .helperMissing: "The S1-mini helper is missing from this build. Run the app's build script."
            case .modelMissing: "The S1-mini model file is missing. Install it from Models."
            case .inputTooLong: "This transcript exceeds S1-mini's input limit."
            case .busy: "S1-mini is still finishing the previous request."
            case .timedOut: "S1-mini exceeded its processing deadline. Your original transcript is saved."
            case .invalidResponse:
                "S1-mini stopped before producing a valid result. Your original transcript is saved."
            case .invalidJobRoot: "S1-mini could not prepare its private working directory."
            case .runtime(let message): message
            }
        }
    }
}
