import CryptoKit
import Foundation
import LocalSpeech
import Observation

@MainActor @Observable
final class ModelLibrary {
    let models = ModelCatalog.models
    private(set) var installations: [String: ModelInstallation]
    private(set) var progress: [String: DownloadProgress] = [:]
    private(set) var errors: [String: String] = [:]
    /// Models whose folders passed a quick check, so views can ask without reading the disk on every
    /// render. Install and remove keep it current; recording validation calls `refreshInstalledModels()`.
    private(set) var installedModelIDs: Set<String> = []
    var inUseModelIDs: Set<String> = []

    @ObservationIgnored private let rootURL: URL
    @ObservationIgnored private let onChange: ([ModelInstallation]) -> Void
    @ObservationIgnored private var operations: [String: Task<Void, Error>] = [:]
    /// Each download's staging folder, by model, from its start until it installs or is discarded.
    /// One that stopped on an error stays while the app runs, so Retry continues from its files.
    private var partials: [String: PartialDownload] = [:]

    init(rootURL: URL, installations: [ModelInstallation], onChange: @escaping ([ModelInstallation]) -> Void)
    {
        self.rootURL = rootURL.standardizedFileURL
        self.onChange = onChange
        self.installations = installations.reduce(into: [:]) { $0[$1.id] = $1 }
        discardAbandonedStaging()
        refreshInstalledModels()
    }

    /// Rechecks every installed folder. Catches files removed or damaged outside the app.
    func refreshInstalledModels() {
        let valid = Set(installations.keys.filter { localURL(for: $0) != nil })
        if valid != installedModelIDs { installedModelIDs = valid }
    }

    /// Runs only when the single app instance opens its library. A quit or crash during a download or
    /// import leaves its `.staging-<UUID>` folder behind. Other entries are never touched.
    private func discardAbandonedStaging() {
        let manager = FileManager.default
        for name in (try? manager.contentsOfDirectory(atPath: rootURL.path)) ?? [] {
            guard name.hasPrefix(".staging-") else { continue }
            let suffix = String(name.dropFirst(".staging-".count))
            guard let id = UUID(uuidString: suffix),
                id.uuidString.caseInsensitiveCompare(suffix) == .orderedSame
            else { continue }
            let url = rootURL.appendingPathComponent(name)
            // Inspect the directory entry itself, so a matching symlink cannot authorize deleting its target.
            guard
                (try? manager.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
                    == .typeDirectory
            else { continue }
            try? manager.removeItem(at: url)
        }
    }

    /// Download only after an explicit user action. A model becomes installed after validation and rename.
    /// Each file arrives as `<name>.part` in the staging folder and gets its final name once its size,
    /// and its SHA-256 where the hub publishes one, pass. After a failure the folder stays, so the next
    /// install keeps the finished files and resumes the partial one. Cancel, or a folder that fails
    /// validation, discards it.
    func install(_ model: ModelDescriptor) async throws {
        try requireAvailable(model)
        guard let repository = model.repository, let revision = model.revision else {
            throw ModelLibraryError.invalid(
                "This model is configured through its system or provider settings.")
        }
        let stage =
            partials[model.id]?.stage
            ?? rootURL.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        partials[model.id] = PartialDownload(stage: stage, totalBytes: partials[model.id]?.totalBytes ?? 0)
        errors[model.id] = nil
        progress[model.id] = DownloadProgress(stage: .checking)
        let operation = Task { [self] in
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
            let total = files.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
            partials[model.id]?.totalBytes = total
            // A Retry starts from the finished files and the partial one, not from zero.
            progress[model.id] = DownloadProgress(
                stage: .downloading, completedBytes: (try? ModelFiles.byteCount(stage)) ?? 0,
                totalBytes: total)
            var completed: Int64 = 0
            for file in files {
                try Task.checkCancellation()
                let destination = stage.appendingPathComponent(file.rfilename)
                // A file with its final name passed its checks before an earlier attempt failed.
                if let size = file.size, (try? ModelFiles.fileSize(destination)) == size {
                    completed += size
                    continue
                }
                let part = stage.appendingPathComponent(file.rfilename + ".part")
                let completedBeforeFile = completed
                let url = URL(
                    string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(file.rfilename)")!
                try await FileDownload.fetch(
                    url, to: part, expectedSize: file.size,
                    checkResponse: { try ModelFiles.checkResponse($0) }
                ) { [weak self] bytes in
                    Task { @MainActor in
                        guard let self, self.progress[model.id]?.stage == .downloading else { return }
                        self.progress[model.id] = DownloadProgress(
                            stage: .downloading, completedBytes: completedBeforeFile + bytes,
                            totalBytes: total)
                    }
                }
                do {
                    try await ModelFiles.runOffMain {
                        try ModelFiles.validateFile(part, expectedSize: file.size, sha256: file.lfs?.sha256)
                    }
                } catch {
                    // A resumed file that fails its check is never kept, so Retry fetches it again.
                    try? FileManager.default.removeItem(at: part)
                    throw error
                }
                try Task.checkCancellation()
                try FileManager.default.moveItem(at: part, to: destination)
                completed += file.size ?? 0
            }
            progress[model.id] = DownloadProgress(
                stage: .validating, completedBytes: total, totalBytes: total)
            do {
                try await ModelFiles.runOffMain { try ModelFiles.validateDirectory(stage, model: model) }
            } catch {
                discardPartial(model.id)
                throw error
            }
            try ModelFiles.writeProvenance(model, directory: stage, imported: false)
            try Task.checkCancellation()
            try finishInstallation(model, stage: stage, revision: revision)
        }
        do {
            try await track(operation, modelID: model.id)
        } catch {
            if Self.isCancellation(error) {
                discardPartial(model.id)
            } else if let stage = partials[model.id]?.stage {
                partials[model.id]?.keptBytes = (try? ModelFiles.byteCount(stage)) ?? 0
            }
            throw error
        }
    }

    /// What a download that stopped on an error kept on disk, which Retry continues from while the app
    /// runs, or nil. Cancel discards it.
    func resumable(_ id: String) -> DownloadProgress? {
        guard progress[id] == nil, let partial = partials[id], let kept = partial.keptBytes, kept > 0 else {
            return nil
        }
        return DownloadProgress(stage: .downloading, completedBytes: kept, totalBytes: partial.totalBytes)
    }

    /// Deletes a download's own staging folder and nothing else.
    private func discardPartial(_ id: String) {
        if let partial = partials.removeValue(forKey: id) {
            try? FileManager.default.removeItem(at: partial.stage)
        }
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// Imports are managed copies. Moving or deleting the source later does not break the app.
    func importModel(_ model: ModelDescriptor, from source: URL) async throws {
        try requireAvailable(model)
        guard model.location == .local else {
            throw ModelLibraryError.invalid("This model does not support file imports.")
        }
        let stage = rootURL.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        errors[model.id] = nil
        progress[model.id] = DownloadProgress(stage: .importing)
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
                model, stage: stage, revision: model.engine == .s1mini ? model.revision : nil)
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
        installedModelIDs.remove(model.id)
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

    /// Stops a running download, or discards what a stopped one kept, with its error, so the row offers
    /// a fresh Download. Either way its partial files go. An import has no partial files; canceling it
    /// stops the copy.
    func cancelDownload(_ id: String) {
        if let operation = operations[id] {
            operation.cancel()
        } else {
            discardPartial(id)
            errors[id] = nil
        }
    }

    /// A refused start is recorded like a failed download, so every download row can show it.
    private func requireAvailable(_ model: ModelDescriptor) throws {
        do { try checkAvailable(model) } catch {
            if operations[model.id] == nil { errors[model.id] = error.localizedDescription }
            throw error
        }
    }

    private func checkAvailable(_ model: ModelDescriptor) throws {
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
            if !Self.isCancellation(error) { errors[modelID] = error.localizedDescription }
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
        installedModelIDs.insert(model.id)
        // An import can finish while a stopped download's files wait for Retry; they are no longer needed.
        discardPartial(model.id)
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

/// A download's staging folder. `keptBytes` is what was on disk when it last stopped on an error.
private struct PartialDownload {
    let stage: URL
    var totalBytes: Int64
    var keptBytes: Int64? = nil
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
            if model.engine == .s1mini {
                return [model.fileName, "LICENSE", "NOTICE", "README.md"].contains(name)
            }
            return LocalSpeechFamily.isModelFile(name)
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
        if model.engine == .s1mini, info.isDirectory != true {
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
        if model.engine == .s1mini {
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
        // Everything else runs on a LocalSpeech family, which knows its files and configuration.
        let family: LocalSpeechFamily
        do { family = try LocalSpeechFamily.named(model.engine.rawValue) } catch {
            throw ModelLibraryError.invalid("This model has no managed local artifact.")
        }
        for file in family.requiredFiles { try require(file) }
        try family.checkConfiguration(Data(contentsOf: directory.appendingPathComponent("config.json")))
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

    static func fileSize(_ url: URL) throws -> Int64 {
        Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }

    static func validateFile(_ url: URL, expectedSize: Int64?, sha256: String?) throws {
        let actual = try fileSize(url)
        guard actual > 0, expectedSize == nil || actual == expectedSize else {
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
