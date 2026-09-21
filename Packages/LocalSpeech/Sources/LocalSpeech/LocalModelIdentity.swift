import Foundation

/// Managed imports use unique directories. File metadata also invalidates a resident model
/// when a caller replaces weights or tokenizer files in an existing directory.
struct LocalModelIdentity: Equatable {
    let directory: URL
    let family: ModelFamily
    private let files: [FileIdentity]

    init(directory: URL, family: ModelFamily) throws {
        self.directory = directory.resolvingSymlinksInPath().standardizedFileURL
        self.family = family
        files = try LocalModelFiles.validate(directory: directory, family: family)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { file in
                let resolved = file.resolvingSymlinksInPath()
                let attributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
                return FileIdentity(
                    name: file.lastPathComponent, target: resolved.path,
                    inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
                    size: (attributes[.size] as? NSNumber)?.uint64Value,
                    modified: attributes[.modificationDate] as? Date,
                    created: attributes[.creationDate] as? Date)
            }
    }

    private struct FileIdentity: Equatable {
        let name: String
        let target: String
        let inode: UInt64?
        let size: UInt64?
        let modified: Date?
        let created: Date?
    }
}
