import AppKit
import Foundation
import SQLite3

/// Seeds explicitly supplied tested artifacts through the app's real storage and import code.
/// Existing models and configuration are never replaced.
@main struct SeedModels {
    @MainActor static func main() async {
        do { try await run() } catch {
            FileHandle.standardError.write(Data("Seed failed: \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    @MainActor static func run() async throws {
        let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "ari.Amanuensis").isEmpty else {
            throw Failure.message(
                "Quit Amanuensis before seeding so its saved state cannot overwrite these changes.")
        }
        for id in ["whisper-tiny", "parakeet-v2", "cohere-transcribe", "s1-mini"] {
            let source = options.sources.appendingPathComponent(id, isDirectory: true)
            for sidecar in id == "s1-mini" ? ["README.md", "LICENSE", "NOTICE"] : ["README.md", "LICENSE"] {
                guard FileManager.default.fileExists(atPath: source.appendingPathComponent(sidecar).path)
                else {
                    throw Failure.message("Missing \(sidecar) for \(id). Run prepare-fixtures.sh first.")
                }
            }
        }
        let savedConfigurationExists = try hasSavedConfiguration(in: options.destination)
        let store = try LocalStore(rootURL: options.destination)
        var persistenceFailure: Error?
        let library = ModelLibrary(rootURL: store.modelsURL, installations: store.installations()) {
            installations in
            do { try store.saveInstallations(installations) } catch { persistenceFailure = error }
        }
        for id in ["whisper-tiny", "parakeet-v2", "cohere-transcribe", "s1-mini"] {
            guard let descriptor = ModelCatalog.models.first(where: { $0.id == id }) else {
                throw Failure.message("Catalog entry missing: \(id)")
            }
            if library.installations[id] != nil {
                guard library.localURL(for: id) != nil else {
                    throw Failure.message(
                        "Existing \(id) installation is incomplete. It was preserved; remove it through the app before retrying."
                    )
                }
                print("Preserved installed \(id)")
                continue
            }
            let source = options.sources.appendingPathComponent(id, isDirectory: true)
            for sidecar in id == "s1-mini" ? ["README.md", "LICENSE", "NOTICE"] : ["README.md", "LICENSE"] {
                guard FileManager.default.fileExists(atPath: source.appendingPathComponent(sidecar).path)
                else {
                    throw Failure.message("Missing \(sidecar) for \(id). Run prepare-fixtures.sh first.")
                }
            }
            try await library.importModel(descriptor, from: source)
            if let persistenceFailure { throw persistenceFailure }
            print("Installed \(id) through ModelLibrary")
        }
        if options.initializeConfiguration && !savedConfigurationExists {
            var configuration = store.loadConfiguration()
            // Preserve each preset's cleanup model, formatting options, and IDs.
            for index in configuration.modes.indices {
                configuration.modes[index].speechModelID = "parakeet-v2"
            }
            try store.saveConfiguration(configuration)
            print("Initialized new configuration with Parakeet V2; preset cleanup defaults preserved")
        } else {
            print("Configuration preserved")
        }
        print("Seed complete: \(store.rootURL.path)")
    }

    /// Inspect before LocalStore creates a fresh database. An existing configuration row always wins.
    static func hasSavedConfiguration(in root: URL) throws -> Bool {
        let databaseURL = root.appendingPathComponent("Amanuensis.sqlite")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return false }
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw Failure.message("Cannot inspect existing app configuration.")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(database, "SELECT 1 FROM configuration WHERE id = 1", -1, &statement, nil)
                == SQLITE_OK
        else {
            throw Failure.message(
                "Existing database has no readable configuration table. Seeding stopped without changing it.")
        }
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_ROW || status == SQLITE_DONE else {
            throw Failure.message("Cannot read existing app configuration.")
        }
        return status == SQLITE_ROW
    }
}

private struct Options {
    let sources: URL
    let destination: URL
    let initializeConfiguration: Bool

    init(arguments: [String]) throws {
        var sourcePath: String?
        var destinationPath: String?
        var initialize = false
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--sources", "--destination":
                guard index + 1 < arguments.count else { throw Failure.usage }
                if arguments[index] == "--sources" {
                    sourcePath = arguments[index + 1]
                } else {
                    destinationPath = arguments[index + 1]
                }
                index += 2
            case "--new-configuration":
                initialize = true
                index += 1
            default: throw Failure.usage
            }
        }
        guard let sourcePath, let destinationPath else { throw Failure.usage }
        sources = URL(fileURLWithPath: sourcePath, isDirectory: true).standardizedFileURL
        destination = URL(fileURLWithPath: destinationPath, isDirectory: true).standardizedFileURL
        guard sources != destination else {
            throw Failure.message("Sources and destination must be separate folders.")
        }
        initializeConfiguration = initialize
    }
}

private enum Failure: LocalizedError {
    case message(String)
    case usage
    var errorDescription: String? {
        switch self {
        case .message(let value): value
        case .usage:
            "Usage: seed.sh --sources /prepared/fixtures --destination /app/data [--new-configuration]"
        }
    }
}
