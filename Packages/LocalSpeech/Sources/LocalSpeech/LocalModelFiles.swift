import Foundation

/// Captures tokenizer/configuration files so a removed source tokenizer cannot activate
/// upstream Whisper's automatic tokenizer download. Weights stay on disk in their original location.
struct LocalModelFiles {
    let directory: URL

    static func validate(directory: URL, family: ModelFamily) throws -> [URL] {
        guard directory.isFileURL,
            (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        else {
            throw LocalSpeechError.invalidModelDirectory
        }

        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        )
        let readableFiles = files.filter { file in
            guard
                let values = try? file.resolvingSymlinksInPath().resourceValues(forKeys: [
                    .isRegularFileKey, .fileSizeKey,
                ])
            else { return false }
            return values.isRegularFile == true && (values.fileSize ?? 0) > 0
                && FileManager.default.isReadableFile(atPath: file.path)
        }

        for filename in family.requiredMetadata {
            guard readableFiles.contains(where: { $0.lastPathComponent == filename }) else {
                throw LocalSpeechError.missingModelFile(filename)
            }
        }
        guard readableFiles.contains(where: { $0.pathExtension == "safetensors" }) else {
            throw LocalSpeechError.missingModelFile(".safetensors weights")
        }
        return readableFiles
    }

    init(source: URL, family: ModelFamily) throws {
        let files = try Self.validate(directory: source, family: family)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("Amanuensis-local-speech-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            for file in files {
                let target = destination.appendingPathComponent(file.lastPathComponent)
                if file.pathExtension == "safetensors" {
                    try FileManager.default.createSymbolicLink(
                        at: target, withDestinationURL: file.resolvingSymlinksInPath()
                    )
                } else if ["json", "model", "txt"].contains(file.pathExtension) {
                    try FileManager.default.copyItem(at: file.resolvingSymlinksInPath(), to: target)
                }
            }
            // Validate the snapshot before any runtime code can run.
            _ = try Self.validate(directory: destination, family: family)
            directory = destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
