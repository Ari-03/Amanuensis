import Darwin
import Foundation

/// Reuses an isolated normalizer process while its model file remains unchanged.
@MainActor
final class S1MiniRunner {
    private var operationID: UUID?
    private var cancelledOperationID: UUID?
    private var session: Session?
    private let idleTimeout: Duration
    private var memoryPressure: DispatchSourceMemoryPressure?
    private var releaseAfterOperation = false
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

    init(
        helperURL: URL? = nil, timeout: Duration = .seconds(120), jobRootURL: URL? = nil,
        idleTimeout: Duration = .seconds(60)
    ) {
        executableURL = helperURL ?? Self.helperURL
        processTimeout = min(timeout, .seconds(120))
        self.idleTimeout = idleTimeout
        // Eager preparation also removes files left by a previous app crash before any new job.
        jobRoot = Result { try Self.prepareJobRoot(override: jobRootURL) }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.releaseForMemoryPressure() }
        }
        source.resume()
        memoryPressure = source
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
            if releaseAfterOperation {
                releaseAfterOperation = false
                if let session { stop(sessionID: session.id, error: CancellationError()) }
            }
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
        if let session { stop(sessionID: session.id, error: CancellationError()) }
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
        try checkCancellation(id)
        _ = try jobRoot.get()
        let key: ModelKey
        do { key = try ModelKey(model) } catch {
            await releaseSession()
            throw error
        }
        if let session, session.key != key || session.stoppingError != nil {
            await releaseSession()
            try checkCancellation(id)
        }
        if session == nil { try startSession(model: model, key: key) }
        guard let current = session, current.requestID == nil else { throw S1Error.busy }
        current.idleTask?.cancel()
        let requestID = UUID().uuidString
        let request = Request(
            id: requestID, transcript: text, styling: mode.tone.rawValue,
            structure: mode.useLists ? "lists" : "prose",
            context: mode.preset == .mail ? "email" : "general"
        )
        var payload = try JSONEncoder().encode(request)
        payload.append(0x0A)
        let bytes = payload
        let sessionID = current.id
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                current.requestID = requestID
                current.continuation = continuation
                let deadline = processTimeout
                current.timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(for: deadline) } catch { return }
                    guard self?.session?.requestID == requestID else { return }
                    self?.stop(sessionID: sessionID, error: S1Error.timedOut)
                }
                // Pipe backpressure must never block the main actor during model loading.
                let input = current.input.fileHandleForWriting
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    do { try input.write(contentsOf: bytes) } catch {
                        Task { @MainActor in self?.stop(sessionID: sessionID, error: S1Error.invalidResponse)
                        }
                    }
                }
                if cancelledOperationID == id || Task.isCancelled {
                    stop(sessionID: sessionID, error: CancellationError())
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(operation: id) }
        }
    }

    private func startSession(model: URL, key: ModelKey) throws {
        let child = Process()
        child.executableURL = executableURL
        child.arguments = ["--model", model.path, "--serve"]
        let current = Session(process: child, key: key)
        guard fcntl(current.input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw S1Error.invalidResponse
        }
        child.standardInput = current.input
        child.standardOutput = current.output
        child.standardError = FileHandle.nullDevice
        let sessionID = current.id
        current.output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.received(data, sessionID: sessionID) }
        }
        child.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.terminated(sessionID: sessionID) }
        }
        session = current
        do { try child.run() } catch {
            terminated(sessionID: sessionID)
            throw error
        }
    }

    private func received(_ data: Data, sessionID: UUID) {
        guard let current = session, current.id == sessionID, current.stoppingError == nil else { return }
        guard !data.isEmpty, current.buffer.count + data.count <= 262_144 else {
            stop(sessionID: sessionID, error: S1Error.invalidResponse)
            return
        }
        current.buffer.append(data)
        guard let newline = current.buffer.firstIndex(of: 0x0A) else { return }
        // Exactly one response is permitted for the one outstanding request.
        guard newline == current.buffer.index(before: current.buffer.endIndex),
            let requestID = current.requestID
        else {
            stop(sessionID: sessionID, error: S1Error.invalidResponse)
            return
        }
        do {
            let response = try JSONDecoder().decode(Response.self, from: current.buffer[..<newline])
            current.buffer.removeAll(keepingCapacity: true)
            guard response.id == requestID else { throw S1Error.invalidResponse }
            if let operationID { try checkCancellation(operationID) }
            switch response.status {
            case "success":
                guard !response.text.isEmpty else { throw S1Error.invalidResponse }
                finishRequest(current, result: .success(response.text))
            case "empty":
                guard response.text.isEmpty else { throw S1Error.invalidResponse }
                finishRequest(current, result: .success(""))
            case "error":
                guard response.text.isEmpty else { throw S1Error.invalidResponse }
                if response.errorCode == "input_too_long" {
                    finishRequest(current, result: .failure(S1Error.inputTooLong))
                } else {
                    throw S1Error.runtime(response.error ?? "S1-mini could not clean this transcript.")
                }
            case "cancelled": throw CancellationError()
            default: throw S1Error.invalidResponse
            }
        } catch {
            stop(sessionID: sessionID, error: error is DecodingError ? S1Error.invalidResponse : error)
        }
    }

    private func finishRequest(_ current: Session, result: Result<String, Error>) {
        current.timeoutTask?.cancel()
        current.timeoutTask = nil
        current.requestID = nil
        let pending = current.continuation
        current.continuation = nil
        current.idleTask?.cancel()
        let sessionID = current.id
        let deadline = idleTimeout
        current.idleTask = Task { [weak self] in
            do { try await Task.sleep(for: deadline) } catch { return }
            guard let current = self?.session, current.id == sessionID, current.requestID == nil else {
                return
            }
            self?.stop(sessionID: sessionID, error: CancellationError())
        }
        pending?.resume(with: result)
    }

    private func stop(sessionID: UUID, error: Error) {
        guard let current = session, current.id == sessionID, current.stoppingError == nil else { return }
        current.stoppingError = error
        current.timeoutTask?.cancel()
        current.idleTask?.cancel()
        try? current.input.fileHandleForWriting.close()
        guard current.process.isRunning else {
            terminated(sessionID: sessionID)
            return
        }
        current.process.terminate()
        current.killTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let current = self?.session, current.id == sessionID, current.process.isRunning else {
                return
            }
            kill(current.process.processIdentifier, SIGKILL)
        }
    }

    private func terminated(sessionID: UUID) {
        guard let current = session, current.id == sessionID else { return }
        current.timeoutTask?.cancel()
        current.idleTask?.cancel()
        current.killTask?.cancel()
        current.output.fileHandleForReading.readabilityHandler = nil
        try? current.input.fileHandleForWriting.close()
        try? current.output.fileHandleForReading.close()
        current.process.terminationHandler = nil
        session = nil
        let pending = current.continuation
        current.continuation = nil
        pending?.resume(throwing: current.stoppingError ?? S1Error.invalidResponse)
        for waiter in current.releaseWaiters { waiter.resume() }
        current.releaseWaiters.removeAll()
    }

    /// Finish the current transcript before releasing weights under memory pressure.
    func releaseForMemoryPressure() {
        if operationID != nil {
            releaseAfterOperation = true
        } else if let session {
            stop(sessionID: session.id, error: CancellationError())
        }
    }

    /// Cancels work and waits until the helper releases its mapped model file.
    /// Call before removing model files, sleeping, or completing app shutdown.
    func unload() async {
        cancel()
        await releaseSession()
    }

    private func releaseSession() async {
        guard let current = session else { return }
        await withCheckedContinuation { continuation in
            current.releaseWaiters.append(continuation)
            stop(sessionID: current.id, error: CancellationError())
        }
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

    private final class Session {
        let id = UUID()
        let process: Process
        let key: ModelKey
        let input = Pipe()
        let output = Pipe()
        var buffer = Data()
        var requestID: String?
        var continuation: CheckedContinuation<String, Error>?
        var releaseWaiters: [CheckedContinuation<Void, Never>] = []
        var timeoutTask: Task<Void, Never>?
        var idleTask: Task<Void, Never>?
        var killTask: Task<Void, Never>?
        var stoppingError: Error?

        init(process: Process, key: ModelKey) {
            self.process = process
            self.key = key
        }

        deinit {
            output.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            // No actor remains to service a grace-period task after owner destruction.
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    private struct ModelKey: Equatable {
        let path: String
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int

        init(_ url: URL) throws {
            path = url.resolvingSymlinksInPath().standardizedFileURL.path
            var attributes = stat()
            guard stat(path, &attributes) == 0,
                attributes.st_mode & S_IFMT == S_IFREG
            else { throw S1Error.modelMissing }
            device = attributes.st_dev
            inode = attributes.st_ino
            size = attributes.st_size
            modifiedSeconds = attributes.st_mtimespec.tv_sec
            modifiedNanos = attributes.st_mtimespec.tv_nsec
            changedSeconds = attributes.st_ctimespec.tv_sec
            changedNanos = attributes.st_ctimespec.tv_nsec
        }
    }

    private struct Request: Encodable {
        let id: String
        let transcript: String
        let styling: String
        let structure: String
        let context: String
    }
    private struct Response: Decodable {
        let id: String
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
