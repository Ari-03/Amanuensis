import CryptoKit
import Foundation
import Observation

@MainActor @Observable
final class ModelLibrary {
    let models = ModelCatalog.models
    private(set) var installations: [String: ModelInstallation]
    private(set) var progress: [String: DownloadProgress] = [:]
    private(set) var errors: [String: String] = [:]
    var inUseModelIDs: Set<String> = []

    @ObservationIgnored private let rootURL: URL
    @ObservationIgnored private let onChange: ([ModelInstallation]) -> Void
    @ObservationIgnored private var operations: [String: Task<Void, Error>] = [:]

    init(rootURL: URL, installations: [ModelInstallation], onChange: @escaping ([ModelInstallation]) -> Void)
    {
        self.rootURL = rootURL.standardizedFileURL
        self.onChange = onChange
        self.installations = installations.reduce(into: [:]) { $0[$1.id] = $1 }
    }

    /// Download only after an explicit user action. A model becomes installed after validation and rename.
    func install(_ model: ModelDescriptor) async throws {
        try requireAvailable(model)
        guard let repository = model.repository, let revision = model.revision else {
            throw ModelLibraryError.invalid(
                "This model is configured through its system or provider settings.")
        }
        let stage = rootURL.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        errors[model.id] = nil
        progress[model.id] = DownloadProgress(fraction: 0, label: "Checking download")
        let operation = Task { [self] in
            defer { try? FileManager.default.removeItem(at: stage) }
            let metadataURL = URL(
                string: "https://huggingface.co/api/models/\(repository)/revision/\(revision)?blobs=true")!
            let (data, response) = try await URLSession.shared.data(from: metadataURL)
            try ModelFiles.checkResponse(response)
            let metadata = try JSONDecoder().decode(HubMetadata.self, from: data)
            guard metadata.sha == revision else {
                throw ModelLibraryError.invalid("The model repository returned an unexpected revision.")
            }
            let files = try ModelFiles.selectedFiles(metadata.siblings, model: model)
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            let total = max(files.reduce(Int64(0)) { $0 + ($1.size ?? 0) }, 1)
            var completed: Int64 = 0
            for file in files {
                try Task.checkCancellation()
                let destination = stage.appendingPathComponent(file.rfilename)
                let completedBeforeFile = completed
                let delegate = ModelDownloadDelegate { [weak self] bytes in
                    Task { @MainActor in
                        guard let self, self.progress[model.id] != nil else { return }
                        self.progress[model.id] = DownloadProgress(
                            fraction: min(0.98, Double(completedBeforeFile + bytes) / Double(total)),
                            label: "Downloading \(file.rfilename)"
                        )
                    }
                }
                let url = URL(
                    string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(file.rfilename)")!
                let (temporary, response) = try await URLSession.shared.download(
                    from: url, delegate: delegate)
                defer { try? FileManager.default.removeItem(at: temporary) }
                try ModelFiles.checkResponse(response)
                try await ModelFiles.runOffMain {
                    try ModelFiles.validateFile(temporary, expectedSize: file.size, sha256: file.lfs?.sha256)
                }
                try Task.checkCancellation()
                try FileManager.default.moveItem(at: temporary, to: destination)
                completed += file.size ?? 0
            }
            progress[model.id] = DownloadProgress(fraction: 0.99, label: "Validating model")
            try await ModelFiles.runOffMain { try ModelFiles.validateDirectory(stage, model: model) }
            try ModelFiles.writeProvenance(model, directory: stage, imported: false)
            try Task.checkCancellation()
            try finishInstallation(model, stage: stage, revision: revision)
        }
        try await track(operation, modelID: model.id)
    }

    /// Imports are managed copies. Moving or deleting the source later does not break the app.
    func importModel(_ model: ModelDescriptor, from source: URL) async throws {
        try requireAvailable(model)
        guard model.location == .local, model.family != .ollama else {
            throw ModelLibraryError.invalid("This model does not support file imports.")
        }
        let stage = rootURL.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        errors[model.id] = nil
        progress[model.id] = DownloadProgress(fraction: 0, label: "Importing model")
        let operation = Task { [self] in
            defer { try? FileManager.default.removeItem(at: stage) }
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            try await ModelFiles.runOffMain {
                try ModelFiles.copyImport(source, into: stage, model: model)
                try ModelFiles.validateDirectory(stage, model: model)
            }
            try Task.checkCancellation()
            try ModelFiles.writeProvenance(model, directory: stage, imported: true)
            // Imported directories are validated for format, not asserted to equal an upstream revision.
            try finishInstallation(
                model, stage: stage, revision: model.family == .s1mini ? model.revision : nil)
        }
        try await track(operation, modelID: model.id)
    }

    func remove(_ model: ModelDescriptor) throws {
        guard !inUseModelIDs.contains(model.id), operations[model.id] == nil else {
            throw ModelLibraryError.invalid("Stop using this model before removing it.")
        }
        if let installation = installations[model.id], let directory = managedURL(installation.directory) {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
        installations[model.id] = nil
        errors[model.id] = nil
        onChange(Array(installations.values))
    }

    func localURL(for modelID: String) -> URL? {
        guard let installation = installations[modelID],
            let directory = managedURL(installation.directory),
            let model = models.first(where: { $0.id == modelID }),
            (try? ModelFiles.validateDirectory(directory, model: model, verifyHash: false)) != nil
        else { return nil }
        return directory
    }

    func cancelDownload(_ id: String) { operations[id]?.cancel() }

    private func requireAvailable(_ model: ModelDescriptor) throws {
        guard operations[model.id] == nil else {
            throw ModelLibraryError.invalid("This model already has an operation running.")
        }
        guard !inUseModelIDs.contains(model.id) else {
            throw ModelLibraryError.invalid("Stop using this model before replacing it.")
        }
        guard installations[model.id] == nil else {
            throw ModelLibraryError.invalid("Remove the installed copy before replacing it.")
        }
    }

    private func track(_ operation: Task<Void, Error>, modelID: String) async throws {
        operations[modelID] = operation
        defer {
            operations[modelID] = nil
            progress[modelID] = nil
        }
        do {
            try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: {
                operation.cancel()
            }
        } catch {
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                errors[modelID] = error.localizedDescription
            }
            throw error
        }
    }

    private func finishInstallation(_ model: ModelDescriptor, stage: URL, revision: String?) throws {
        guard !inUseModelIDs.contains(model.id) else {
            throw ModelLibraryError.invalid("This model became active. Stop using it before replacing it.")
        }
        let destination = rootURL.appendingPathComponent(
            "\(model.id)-\(UUID().uuidString)", isDirectory: true)
        let byteCount = try ModelFiles.byteCount(stage)
        // The stage and destination share a volume. The rename publishes the complete directory atomically.
        try FileManager.default.moveItem(at: stage, to: destination)
        installations[model.id] = ModelInstallation(
            id: model.id, directory: destination.lastPathComponent, byteCount: byteCount, revision: revision
        )
        onChange(Array(installations.values))
    }

    private func managedURL(_ directory: String) -> URL? {
        guard !directory.isEmpty, !directory.contains("/"), directory != ".", directory != ".." else {
            return nil
        }
        let url = rootURL.appendingPathComponent(directory, isDirectory: true)
        guard url.resolvingSymlinksInPath().deletingLastPathComponent() == rootURL.resolvingSymlinksInPath()
        else { return nil }
        return url
    }
}

private enum ModelLibraryError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        if case .invalid(let message) = self { return message }
        return nil
    }
}

private struct HubMetadata: Decodable, Sendable {
    let sha: String
    let siblings: [HubFile]
}

private struct HubFile: Decodable, Sendable {
    struct LFS: Decodable, Sendable { let sha256: String? }
    let rfilename: String
    let size: Int64?
    let lfs: LFS?
}

private final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let update: @Sendable (Int64) -> Void
    init(update: @escaping @Sendable (Int64) -> Void) { self.update = update }
    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {}
    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) { update(totalBytesWritten) }
}

private enum ModelFiles {
    /// Unstructured background work must share cancellation with the owning operation.
    static func runOffMain(_ work: @escaping @Sendable () throws -> Void) async throws {
        let task = Task.detached(priority: .utility) { try work() }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func checkResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ModelLibraryError.invalid("The download returned no HTTP response.")
        }
        switch http.statusCode {
        case 200..<300: return
        case 401, 403:
            throw ModelLibraryError.invalid(
                "The publisher requires access approval or authentication. Download an authorized compatible artifact from its repository, then import it."
            )
        case 404:
            throw ModelLibraryError.invalid(
                "This pinned model artifact is no longer available. You can import a compatible local copy.")
        default:
            throw ModelLibraryError.invalid(
                "The model server returned HTTP \(http.statusCode). Try again later.")
        }
    }

    static func selectedFiles(_ files: [HubFile], model: ModelDescriptor) throws -> [HubFile] {
        let selected = files.filter { file in
            let name = file.rfilename
            guard !name.contains("/"), !name.hasPrefix(".") else { return false }
            if model.family == .s1mini {
                return [model.fileName, "LICENSE", "NOTICE", "README.md"].contains(name)
            }
            if name.contains(".fp32") { return false }
            return name.hasSuffix(".json") || name.hasSuffix(".safetensors") || name.hasSuffix(".txt")
                || name.hasSuffix(".model") || name.hasSuffix(".vocab")
                || ["LICENSE", "LICENSE.md", "LICENSE.txt", "NOTICE", "README.md"].contains(name)
        }
        guard !selected.isEmpty else {
            throw ModelLibraryError.invalid("This artifact has no compatible model files.")
        }
        return selected.sorted { $0.rfilename < $1.rfilename }
    }

    static func copyImport(_ source: URL, into directory: URL, model: ModelDescriptor) throws {
        let manager = FileManager.default
        let info = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard info.isSymbolicLink != true else {
            throw ModelLibraryError.invalid("Import the actual model files, rather than a symbolic link.")
        }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        if model.family == .s1mini, info.isDirectory != true {
            guard let fileName = model.fileName else {
                throw ModelLibraryError.invalid("The S1-mini filename is missing.")
            }
            try manager.copyItem(at: source, to: directory.appendingPathComponent(fileName))
            // Licensing must accompany an imported standalone GGUF, even if its model card is separate.
            for name in ["LICENSE", "NOTICE"] {
                let sibling = source.deletingLastPathComponent().appendingPathComponent(name)
                guard manager.fileExists(atPath: sibling.path) else {
                    throw ModelLibraryError.invalid(
                        "Keep S1-mini's LICENSE and NOTICE next to the GGUF before importing, or use Download."
                    )
                }
                try rejectSymlinks(sibling)
                try manager.copyItem(at: sibling, to: directory.appendingPathComponent(name))
            }
        } else {
            guard info.isDirectory == true else {
                throw ModelLibraryError.invalid(
                    "Choose a complete model folder containing safetensors, config, and tokenizer files. .pt and whisper.cpp .bin files cannot be loaded by this backend."
                )
            }
            try rejectSymlinks(source)
            for file in try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                try Task.checkCancellation()
                try manager.copyItem(at: file, to: directory.appendingPathComponent(file.lastPathComponent))
            }
        }
    }

    static func rejectSymlinks(_ source: URL) throws {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey]
        if try source.resourceValues(forKeys: keys).isSymbolicLink == true {
            throw ModelLibraryError.invalid("Model imports cannot contain symbolic links.")
        }
        if let enumerator = FileManager.default.enumerator(
            at: source, includingPropertiesForKeys: Array(keys))
        {
            for case let url as URL in enumerator {
                if try url.resourceValues(forKeys: keys).isSymbolicLink == true {
                    throw ModelLibraryError.invalid(
                        "Model imports cannot contain symbolic links. Export a complete copy first.")
                }
            }
        }
    }

    static func validateDirectory(_ directory: URL, model: ModelDescriptor, verifyHash: Bool = true) throws {
        let manager = FileManager.default
        func require(_ name: String) throws {
            let path = directory.appendingPathComponent(name)
            let info = try path.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? 0) > 0 else {
                throw ModelLibraryError.invalid("The model folder is missing a complete \(name).")
            }
        }
        if model.family == .s1mini {
            guard let name = model.fileName else {
                throw ModelLibraryError.invalid("Missing S1-mini artifact name.")
            }
            for file in [name, "LICENSE", "NOTICE"] { try require(file) }
            let file = directory.appendingPathComponent(name)
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            guard try handle.read(upToCount: 4) == Data("GGUF".utf8) else {
                throw ModelLibraryError.invalid("S1-mini must be a GGUF file.")
            }
            if verifyHash { try validateFile(file, expectedSize: 484_219_808, sha256: model.sha256) }
            return
        }
        try require("config.json")
        var configData = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        if model.family == .parakeet, var text = String(data: configData, encoding: .utf8) {
            // Match the pinned NeMo loader's treatment of non-standard floating-point values.
            for value in ["-Infinity", "Infinity", "NaN"] {
                text = text.replacingOccurrences(of: value, with: "null")
            }
            configData = Data(text.utf8)
        }
        guard let config = try JSONSerialization.jsonObject(with: configData) as? [String: Any] else {
            throw ModelLibraryError.invalid("The model configuration is not a JSON object.")
        }
        switch model.family {
        case .whisper:
            guard config["model_type"] as? String == "whisper" || config["n_mels"] != nil else {
                throw ModelLibraryError.invalid("This folder does not contain a Whisper configuration.")
            }
            try require("tokenizer.json")
            try require("tokenizer_config.json")
        case .parakeet:
            guard config["encoder"] != nil, config["decoder"] != nil else {
                throw ModelLibraryError.invalid("This folder does not contain a Parakeet configuration.")
            }
            // Parakeet's decoder reads its token table directly from the configuration.
            // The accompanying SentencePiece file is useful provenance, but is not needed offline.
            let joint = config["joint"] as? [String: Any]
            let decoder = config["decoder"] as? [String: Any]
            let vocabulary =
                joint?["vocabulary"] as? [String]
                ?? decoder?["vocabulary"] as? [String]
                ?? config["labels"] as? [String]
            guard let vocabulary, !vocabulary.isEmpty else {
                throw ModelLibraryError.invalid(
                    "Parakeet's configuration is missing its embedded vocabulary.")
            }
        case .cohere:
            guard (config["model_type"] as? String)?.contains("cohere") == true else {
                throw ModelLibraryError.invalid(
                    "This folder does not contain a Cohere Transcribe configuration.")
            }
            try require("tokenizer.model")
            try require("tokenizer_config.json")
        default: throw ModelLibraryError.invalid("This model has no managed local artifact.")
        }
        let weights = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "safetensors" }
        guard !weights.isEmpty else {
            throw ModelLibraryError.invalid("The model folder contains no safetensors weights.")
        }
        for file in weights {
            try require(file.lastPathComponent)
            if verifyHash { try validateSafetensors(file) }
        }
        let index = directory.appendingPathComponent("model.safetensors.index.json")
        if manager.fileExists(atPath: index.path) {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any]
            guard let map = object?["weight_map"] as? [String: String], !map.isEmpty else {
                throw ModelLibraryError.invalid("The weight shard index is invalid.")
            }
            for file in Set(map.values) {
                guard !file.contains("/"), file.hasSuffix(".safetensors") else {
                    throw ModelLibraryError.invalid("The weight shard index contains an invalid filename.")
                }
                try require(file)
            }
        } else if weights.contains(where: { $0.lastPathComponent.contains("-of-") }) {
            throw ModelLibraryError.invalid("A sharded model must include model.safetensors.index.json.")
        }
    }

    /// Check the tensor directory and byte offsets without loading gigabytes of weights into memory.
    static func validateSafetensors(_ url: URL) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard let prefix = try file.read(upToCount: 8), prefix.count == 8 else {
            throw ModelLibraryError.invalid("The safetensors file is incomplete.")
        }
        let headerLength = prefix.enumerated().reduce(UInt64(0)) {
            $0 | UInt64($1.element) << ($1.offset * 8)
        }
        guard headerLength > 0, headerLength < 100_000_000, headerLength + 8 < UInt64(size),
            let header = try file.read(upToCount: Int(headerLength)), header.count == Int(headerLength),
            let tensors = try JSONSerialization.jsonObject(with: header) as? [String: Any],
            tensors.keys.contains(where: { $0 != "__metadata__" })
        else { throw ModelLibraryError.invalid("The safetensors header is invalid or incomplete.") }
        let availableBytes = UInt64(size) - headerLength - 8
        for (name, value) in tensors where name != "__metadata__" {
            guard let tensor = value as? [String: Any], let offsets = tensor["data_offsets"] as? [UInt64],
                offsets.count == 2, offsets[0] <= offsets[1], offsets[1] <= availableBytes,
                tensor["dtype"] is String, tensor["shape"] is [Int]
            else { throw ModelLibraryError.invalid("The model contains an invalid or truncated tensor.") }
        }
    }

    static func validateFile(_ url: URL, expectedSize: Int64?, sha256: String?) throws {
        let actual = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard actual > 0, expectedSize == nil || Int64(actual) == expectedSize else {
            throw ModelLibraryError.invalid("A model file is incomplete. Download it again.")
        }
        if let sha256 {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var digest = SHA256()
            while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                digest.update(data: data)
            }
            let actualHash = digest.finalize().map { String(format: "%02x", $0) }.joined()
            guard actualHash == sha256.lowercased() else {
                throw ModelLibraryError.invalid("Model checksum verification failed. Download a fresh copy.")
            }
        }
    }

    static func byteCount(_ directory: URL) throws -> Int64 {
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        return total
    }

    static func writeProvenance(_ model: ModelDescriptor, directory: URL, imported: Bool) throws {
        let text = """
            Model: \(model.name)
            Publisher: \(model.provider)
            Catalog artifact: https://huggingface.co/\(model.repository ?? "")
            Catalog revision: \(model.revision ?? "none")
            Acquisition: \(imported ? "User import; compatibility checked. Upstream identity is not asserted except for hash-verified S1-mini." : "Downloaded from the pinned repository revision. LFS SHA-256 verified where published.")
            License: \(model.license)
            Conversion and model documentation: see README.md and any LICENSE/NOTICE files in this folder.
            """
        try text.write(
            to: directory.appendingPathComponent("AMANUENSIS-PROVENANCE.txt"), atomically: true,
            encoding: .utf8)
    }
}
