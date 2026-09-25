import AppKit
import CryptoKit
import Foundation
import Observation

/// Finds newer builds on GitHub Releases, downloads and verifies the signed disk image, then swaps
/// the running app bundle and relaunches. Preferences live in UserDefaults, separate from saved settings.
@MainActor @Observable
final class AppUpdater {
    enum State: Equatable {
        case idle
        /// This build cannot update itself; the message explains why.
        case unavailable(String)
        case checking
        case upToDate
        case downloading(UpdateRelease, Double)
        /// A verified disk image is waiting for the user to restart.
        case ready(UpdateRelease)
        case installing(UpdateRelease)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var lastChecked: Date?
    /// A release the user postponed from the Home banner for this session.
    var postponed: AppVersion?
    var channel: UpdateChannel {
        didSet {
            guard channel != oldValue else { return }
            defaults.set(channel.rawValue, forKey: Keys.channel)
            activeCheck?.cancel()
            activeCheck = nil
            checkForUpdates()
        }
    }
    var checksAutomatically: Bool {
        didSet {
            guard checksAutomatically != oldValue else { return }
            defaults.set(checksAutomatically, forKey: Keys.automatic)
            scheduleAutomaticChecks()
        }
    }
    /// Runs after a successful install. The app quits and relaunches; checks replace this to inspect the result.
    @ObservationIgnored var didInstall: @MainActor () -> Void = {}
    let currentVersion: AppVersion
    let repository: String

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let installer: UpdateInstaller?
    @ObservationIgnored private var schedule: Task<Void, Never>?
    @ObservationIgnored private var activeCheck: Task<Void, Never>?
    @ObservationIgnored private var checkCount = 0
    @ObservationIgnored private var downloaded: (release: UpdateRelease, archive: URL)?
    @ObservationIgnored private var automaticChecksStarted = false

    private enum Keys {
        static let channel = "updateChannel"
        static let automatic = "automaticUpdateChecks"
        static let lastChecked = "updateLastChecked"
    }

    /// `feedURL` replaces the GitHub Releases endpoint derived from the bundle's repository, for checks.
    init(bundle: Bundle = .main, defaults: UserDefaults = .standard, feedURL: URL? = nil) {
        self.defaults = defaults
        let info = bundle.infoDictionary ?? [:]
        let version = AppVersion(info["CFBundleShortVersionString"] as? String ?? "")
        currentVersion = version ?? AppVersion(major: 0, minor: 0, patch: 0)
        repository = (info["AmanuensisUpdateRepository"] as? String ?? "").trimmingCharacters(
            in: .whitespacesAndNewlines)
        let key = Data(base64Encoded: info["AmanuensisUpdatePublicKey"] as? String ?? "")
        channel =
            (defaults.string(forKey: Keys.channel)).flatMap(UpdateChannel.init(rawValue:))
            ?? (currentVersion.isPrerelease ? .preview : .stable)
        checksAutomatically = defaults.object(forKey: Keys.automatic) as? Bool ?? true
        lastChecked = defaults.object(forKey: Keys.lastChecked) as? Date
        let feed = feedURL ?? URL(string: "https://api.github.com/repos/\(repository)/releases")
        if version == nil {
            installer = nil
            state = .unavailable("This build has no release version, so it cannot check for updates.")
        } else if repository.split(separator: "/").count != 2 || feed == nil {
            installer = nil
            state = .unavailable("This build does not name a GitHub repository for updates.")
        } else if let key, let feed, let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key)
        {
            installer = UpdateInstaller(
                publicKey: publicKey, bundleURL: bundle.bundleURL, feedURL: feed, version: currentVersion)
            installer?.removeStaleDownloads()
        } else {
            installer = nil
            state = .unavailable("This build has no update signing key, so it cannot verify updates.")
        }
        didInstall = { [weak self] in self?.relaunch() }
    }

    /// Checks shortly after launch and then every six hours while the app runs, unless disabled.
    func startAutomaticChecks() {
        automaticChecksStarted = true
        scheduleAutomaticChecks()
    }

    /// Starts a check unless one is already running. The result appears in `state`.
    func checkForUpdates() {
        guard installer != nil, activeCheck == nil else { return }
        if case .installing = state { return }
        checkCount += 1
        let count = checkCount
        activeCheck = Task { [weak self] in
            await self?.performCheck()
            if let self, checkCount == count { activeCheck = nil }
        }
    }

    /// Replaces the app bundle with the verified download, then hands over to `didInstall`.
    func installAndRelaunch() {
        guard case .ready(let release) = state, let downloaded, downloaded.release == release,
            let installer
        else { return }
        activeCheck?.cancel()
        activeCheck = nil
        state = .installing(release)
        Task { [weak self] in
            do {
                try await installer.install(archive: downloaded.archive, release: release)
                self?.downloaded = nil
                self?.didInstall()
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    private func relaunch() {
        do {
            try installer?.relaunchAfterExit()
        } catch {
            state = .failed("Installed, but the app could not relaunch itself. Open Amanuensis again.")
            return
        }
        ApplicationDelegate.requestTermination()
    }

    private func scheduleAutomaticChecks() {
        schedule?.cancel()
        schedule = nil
        guard automaticChecksStarted, checksAutomatically, installer != nil else { return }
        schedule = Task { [weak self] in
            var delay: Duration = .seconds(15)
            while !Task.isCancelled {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                self?.checkForUpdates()
                delay = .seconds(6 * 60 * 60)
            }
        }
    }

    private func performCheck() async {
        guard let installer else { return }
        state = .checking
        do {
            let releases = try await installer.fetchReleases()
            try Task.checkCancellation()
            lastChecked = Date()
            defaults.set(lastChecked, forKey: Keys.lastChecked)
            guard let release = UpdateRelease.newest(in: releases, channel: channel, after: currentVersion)
            else {
                state = .upToDate
                return
            }
            if let downloaded, downloaded.release == release {
                state = .ready(release)
                return
            }
            discardDownload()
            state = .downloading(release, 0)
            let archive = try await installer.download(release) { [weak self] fraction in
                if case .downloading(release, _) = self?.state {
                    self?.state = .downloading(release, fraction)
                }
            }
            try Task.checkCancellation()
            downloaded = (release, archive)
            state = .ready(release)
        } catch is CancellationError {
            if !Task.isCancelled { state = .idle }
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(error.localizedDescription)
        }
    }

    private func discardDownload() {
        if let downloaded { try? FileManager.default.removeItem(at: downloaded.archive) }
        downloaded = nil
    }
}

/// Network, signature, and file operations that run off the main actor.
private struct UpdateInstaller: Sendable {
    let publicKey: Curve25519.Signing.PublicKey
    let bundleURL: URL
    let feedURL: URL
    let version: AppVersion
    private let session: URLSession
    private let downloads: URL

    init(publicKey: Curve25519.Signing.PublicKey, bundleURL: URL, feedURL: URL, version: AppVersion) {
        self.publicKey = publicKey
        self.bundleURL = bundleURL
        self.feedURL = feedURL
        self.version = version
        let configuration = URLSessionConfiguration.ephemeral
        // A cached signature or feed would hide a republished release, so always fetch fresh copies.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 15 * 60
        session = URLSession(configuration: configuration)
        downloads = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Amanuensis/Updates", isDirectory: true)
    }

    func removeStaleDownloads() {
        try? FileManager.default.removeItem(at: downloads)
    }

    func fetchReleases() async throws -> [UpdateRelease] {
        var request = URLRequest(url: feedURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Amanuensis/\(version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw UpdateFailure(
                status == 403 || status == 429
                    ? "GitHub is rate limiting update checks. Try again later."
                    : "GitHub returned status \(status) while checking for updates.")
        }
        return try UpdateRelease.parse(githubReleases: data)
    }

    /// Downloads the signature and disk image, then verifies the image before returning its location.
    func download(_ release: UpdateRelease, progress: @MainActor @Sendable @escaping (Double) -> Void)
        async throws -> URL
    {
        let (signatureData, signatureResponse) = try await session.data(from: release.signatureURL)
        guard (signatureResponse as? HTTPURLResponse)?.statusCode == 200,
            let signature = Data(
                base64Encoded: String(decoding: signatureData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines))
        else { throw UpdateFailure("The update signature could not be downloaded.") }

        let files = FileManager.default
        try files.createDirectory(at: downloads, withIntermediateDirectories: true)
        let destination = downloads.appendingPathComponent(release.archiveName)
        try? files.removeItem(at: destination)
        do {
            try await write(release.archiveURL, to: destination, expecting: release.archiveByteCount) {
                await progress($0)
            }
            let contents = try Data(contentsOf: destination, options: .mappedIfSafe)
            guard publicKey.isValidSignature(signature, for: contents) else {
                throw UpdateFailure("The update failed signature verification and was discarded.")
            }
        } catch {
            try? files.removeItem(at: destination)
            throw error
        }
        await progress(1)
        return destination
    }

    private func write(
        _ source: URL, to destination: URL, expecting expected: Int64,
        progress: @Sendable (Double) async -> Void
    ) async throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw UpdateFailure("Could not create the download file.")
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        let (bytes, response) = try await session.bytes(from: source)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateFailure("The update could not be downloaded.")
        }
        var chunk = Data(capacity: 1 << 20)
        var written: Int64 = 0
        var reported = 0.0
        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count == 1 << 20 {
                try handle.write(contentsOf: chunk)
                written += Int64(chunk.count)
                chunk.removeAll(keepingCapacity: true)
                let fraction = min(1, Double(written) / Double(max(expected, 1)))
                if fraction - reported >= 0.01 {
                    reported = fraction
                    await progress(fraction)
                }
            }
        }
        try handle.write(contentsOf: chunk)
        written += Int64(chunk.count)
        try handle.close()
        guard written == expected else { throw UpdateFailure("The downloaded update is incomplete.") }
    }

    /// Mounts the verified image, stages a copy beside the running bundle, checks it, and swaps it in.
    func install(archive: URL, release: UpdateRelease) async throws {
        let files = FileManager.default
        let parent = bundleURL.deletingLastPathComponent()
        guard bundleURL.pathExtension == "app", !bundleURL.path.contains("/AppTranslocation/") else {
            throw UpdateFailure(
                "macOS is running a quarantined copy. Move Amanuensis to Applications, open it from there, then update."
            )
        }
        guard files.isWritableFile(atPath: parent.path), files.isWritableFile(atPath: bundleURL.path) else {
            throw UpdateFailure(
                "Amanuensis cannot replace itself in \(parent.path). Install the update manually from GitHub."
            )
        }
        let mount = files.temporaryDirectory.appendingPathComponent("amanuensis-update-\(UUID().uuidString)")
        try files.createDirectory(at: mount, withIntermediateDirectories: true)
        try await run(
            "/usr/bin/hdiutil",
            ["attach", archive.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        let staged = parent.appendingPathComponent(".Amanuensis-update-\(UUID().uuidString).app")
        do {
            let source = mount.appendingPathComponent("Amanuensis.app")
            try verifyBundle(at: source, release: release)
            try await run("/usr/bin/ditto", [source.path, staged.path])
            try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path])
            try verifyBundle(at: staged, release: release)
            removeQuarantine(at: staged)
        } catch {
            try? files.removeItem(at: staged)
            _ = try? await run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            throw error
        }
        _ = try? await run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
        try? files.removeItem(at: mount)

        let previous = parent.appendingPathComponent(".Amanuensis-previous-\(UUID().uuidString).app")
        try files.moveItem(at: bundleURL, to: previous)
        do {
            try files.moveItem(at: staged, to: bundleURL)
        } catch {
            try? files.moveItem(at: previous, to: bundleURL)
            try? files.removeItem(at: staged)
            throw UpdateFailure("Could not move the new version into place: \(error.localizedDescription)")
        }
        try? files.removeItem(at: previous)
        try? files.removeItem(at: archive)
    }

    /// Waits for this process to exit, then opens the bundle at the same path.
    func relaunchAfterExit() throws {
        let watcher = Process()
        watcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        watcher.arguments = [
            "-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
            "amanuensis-relaunch", String(ProcessInfo.processInfo.processIdentifier), bundleURL.path,
        ]
        watcher.standardOutput = FileHandle.nullDevice
        watcher.standardError = FileHandle.nullDevice
        try watcher.run()
    }

    private func verifyBundle(at url: URL, release: UpdateRelease) throws {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw UpdateFailure("The downloaded image does not contain an app.") }
        let expectedID = Bundle.main.bundleIdentifier ?? "ari.Amanuensis"
        guard info["CFBundleIdentifier"] as? String == expectedID,
            info["CFBundleShortVersionString"] as? String == release.version.description
        else { throw UpdateFailure("The downloaded app does not match release \(release.version).") }
    }

    /// Clears the quarantine flag inherited from the disk image so the updated app opens normally.
    private func removeQuarantine(at root: URL) {
        let attribute = "com.apple.quarantine"
        removexattr(root.path, attribute, XATTR_NOFOLLOW)
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let item = enumerator?.nextObject() as? URL {
            removexattr(item.path, attribute, XATTR_NOFOLLOW)
        }
    }

    /// Runs a tool with its output in a temporary file, so a lingering child process cannot stall a pipe.
    @discardableResult
    private func run(_ tool: String, _ arguments: [String]) async throws -> String {
        let files = FileManager.default
        let log = files.temporaryDirectory.appendingPathComponent("amanuensis-tool-\(UUID().uuidString).log")
        guard files.createFile(atPath: log.path, contents: nil) else {
            throw UpdateFailure("Could not create a temporary file.")
        }
        defer { try? files.removeItem(at: log) }
        let output = try FileHandle(forWritingTo: log)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        try? output.close()
        let text = String(decoding: (try? Data(contentsOf: log)) ?? Data(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard status == 0 else {
            let name = URL(fileURLWithPath: tool).lastPathComponent
            throw UpdateFailure("\(name) failed: \(text.isEmpty ? "status \(status)" : text)")
        }
        return text
    }
}

private struct UpdateFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
