import AppKit
import Foundation

/// Drives the real updater against a local release feed: pagination, channel preferences, rejected
/// signatures and bundle versions, and an in-place bundle swap. Run through Scripts/check-updater.sh.
///
/// Arguments: <installed app bundle> <feed URL> <good signature path> <bad signature path> <served signature>
/// The served signature file is swapped between the bad and good contents to exercise both paths.

/// The app quits and relaunches after installing; the check replaces that step to inspect the result.
enum ApplicationDelegate {
    @MainActor static func requestTermination() { fatalError("The check must not request termination") }
}

@MainActor
enum UpdaterChecks {
    static var failures = 0

    static func expect(_ condition: Bool, _ message: String) {
        if !condition {
            failures += 1
            print("FAIL: \(message)")
        } else {
            print("ok: \(message)")
        }
    }

    /// Waits for a check that started after `previous` to settle. Every check records a new last-checked
    /// time before it downloads, so polling the timestamp avoids reading the previous result.
    static func settle(_ updater: AppUpdater, after previous: Date?, seconds: Double) async
        -> AppUpdater.State
    {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if updater.lastChecked != previous, isSettled(updater.state) { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return updater.state
    }

    static func isSettled(_ state: AppUpdater.State) -> Bool {
        switch state {
        case .upToDate, .ready, .failed, .unavailable: true
        case .idle, .checking, .downloading, .installing: false
        }
    }

    /// A fresh nightly opts into Preview, while an explicit choice survives installation of any build.
    static func checkChannelPreferences(bundle: Bundle, defaults: UserDefaults, feed: URL) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removeObject(forKey: "updateChannel")
        }
        let cases: [(String, UpdateChannel?, UpdateChannel)] = [
            ("0.2.0-nightly.123", nil, .preview),
            ("0.2.0-nightly.123", .stable, .stable),
            ("0.2.0", nil, .stable),
            ("0.2.0", .preview, .preview),
        ]
        for (index, entry) in cases.enumerated() {
            let (version, saved, expected) = entry
            let app = root.appendingPathComponent("\(index).app")
            let contents = app.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            var info = bundle.infoDictionary ?? [:]
            info["CFBundleShortVersionString"] = version
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            defaults.set(saved?.rawValue, forKey: "updateChannel")
            guard let fixture = Bundle(url: app) else {
                expect(false, "could not create channel-preference bundle")
                continue
            }
            let updater = AppUpdater(bundle: fixture, defaults: defaults, feedURL: feed)
            expect(updater.state == .idle, "\(version) preference fixture can check for updates")
            expect(
                updater.channel == expected,
                "\(version) with saved channel \(saved?.rawValue ?? "unset") selects \(expected.rawValue)")
            expect(
                defaults.string(forKey: "updateChannel") == saved?.rawValue,
                "initialization preserves the saved channel preference")
        }
    }

    /// The second page offers a signed image with a deliberately wrong stable tag. Discovery must
    /// follow the Link header, and installation must reject the mismatch before replacing the app.
    static func checkPaginationAndBundleVersion(bundle: Bundle, defaults: UserDefaults, feed: URL) async {
        let paginated = feed.deletingLastPathComponent().appendingPathComponent("paginated.json")
        let updater = AppUpdater(bundle: bundle, defaults: defaults, feedURL: paginated)
        updater.checkForUpdates()
        let state = await settle(updater, after: updater.lastChecked, seconds: 300)
        guard case .ready(let release) = state else {
            expect(false, "stable release on page two should be ready, got \(state)")
            return
        }
        expect(
            release.tag == "v999.0.0",
            "Stable finds the signed stable release behind 100 newer nightly entries")
        var didInstall = false
        updater.didInstall = { didInstall = true }
        updater.installAndRelaunch()
        let deadline = Date().addingTimeInterval(300)
        while !didInstall, Date() < deadline {
            if case .failed = updater.state { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if case .failed(let reason) = updater.state {
            expect(reason.contains("does not match release"), "bundle/tag mismatch is rejected: \(reason)")
        } else {
            expect(false, "mismatched bundle should fail installation, got \(updater.state)")
        }
        expect(!didInstall, "mismatched bundle does not complete installation")
        let plist = bundle.bundleURL.appendingPathComponent("Contents/Info.plist")
        let info =
            (try? PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil))
            as? [String: Any]
        expect(info?["CFBundleShortVersionString"] as? String == "0.0.1", "original bundle remains installed")
        defaults.removeObject(forKey: "updateLastChecked")
    }

    static func run() async {
        let arguments = CommandLine.arguments
        guard arguments.count == 6, let feed = URL(string: arguments[2]) else {
            print("usage: updater-checks <installed app> <feed url> <good sig> <bad sig> <served sig>")
            exit(2)
        }
        let installed = URL(fileURLWithPath: arguments[1])
        let goodSignature = URL(fileURLWithPath: arguments[3])
        let badSignature = URL(fileURLWithPath: arguments[4])
        let servedSignature = URL(fileURLWithPath: arguments[5])
        let suite = "amanuensis-updater-checks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        func finish(_ code: Int32) -> Never {
            defaults.removePersistentDomain(forName: suite)
            exit(code)
        }
        guard let bundle = Bundle(url: installed) else {
            print("FAIL: could not open \(installed.path) as a bundle")
            finish(1)
        }

        do {
            try checkChannelPreferences(bundle: bundle, defaults: defaults, feed: feed)
        } catch {
            expect(false, "channel preference checks failed: \(error)")
        }
        await checkPaginationAndBundleVersion(bundle: bundle, defaults: defaults, feed: feed)

        let updater = AppUpdater(bundle: bundle, defaults: defaults, feedURL: feed)
        expect(updater.state == .idle, "updater starts idle")
        expect(updater.currentVersion.description == "0.0.1", "installed version is 0.0.1")
        expect(updater.channel == .stable, "a stable installed version starts on the stable channel")
        expect(updater.checksAutomatically, "automatic checks default on")

        // The feed only carries a prerelease, so stable is up to date.
        var checked = updater.lastChecked
        updater.checkForUpdates()
        var state = await settle(updater, after: checked, seconds: 60)
        expect(state == .upToDate, "stable channel ignores the prerelease feed entry, got \(state)")
        expect(updater.lastChecked != nil, "last-checked time recorded")

        // Preview finds the release but rejects a bad signature.
        try? FileManager.default.removeItem(at: servedSignature)
        try? FileManager.default.copyItem(at: badSignature, to: servedSignature)
        checked = updater.lastChecked
        updater.channel = .preview
        state = await settle(updater, after: checked, seconds: 120)
        if case .failed(let reason) = state {
            expect(reason.contains("signature"), "bad signature is rejected: \(reason)")
        } else {
            expect(false, "bad signature should fail the check, got \(state)")
        }

        // With the real signature the download is verified and ready.
        try? FileManager.default.removeItem(at: servedSignature)
        try? FileManager.default.copyItem(at: goodSignature, to: servedSignature)
        checked = updater.lastChecked
        updater.checkForUpdates()
        state = await settle(updater, after: checked, seconds: 300)
        guard case .ready(let release) = state else {
            expect(false, "verified download should be ready, got \(state)")
            finish(1)
        }
        expect(release.version > updater.currentVersion, "ready release \(release.version) is newer")

        // Changing the channel re-checks without losing the verified download.
        checked = updater.lastChecked
        updater.channel = .stable
        state = await settle(updater, after: checked, seconds: 60)
        expect(state == .upToDate, "switching to stable hides the prerelease, got \(state)")
        checked = updater.lastChecked
        updater.channel = .preview
        state = await settle(updater, after: checked, seconds: 300)
        expect(state == .ready(release), "switching back to preview restores the release, got \(state)")

        // Install swaps the bundle in place instead of relaunching.
        var didFinishInstall = false
        updater.didInstall = { didFinishInstall = true }
        updater.installAndRelaunch()
        let deadline = Date().addingTimeInterval(300)
        while !didFinishInstall, Date() < deadline {
            if case .failed = updater.state { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        expect(didFinishInstall, "install completed, state \(updater.state)")
        let plist = installed.appendingPathComponent("Contents/Info.plist")
        let info =
            (try? PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil))
            as? [String: Any]
        expect(
            info?["CFBundleShortVersionString"] as? String == release.version.description,
            "installed bundle now reports \(release.version)")
        let siblings =
            (try? FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path))
            ?? []
        expect(siblings == ["Amanuensis.app"], "no staging or previous bundles remain: \(siblings)")
        expect(
            getxattr(installed.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) == -1,
            "quarantine flag is cleared")
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--verify", "--deep", "--strict", installed.path]
        try? codesign.run()
        codesign.waitUntilExit()
        expect(codesign.terminationStatus == 0, "installed bundle passes codesign verification")
        finish(failures == 0 ? 0 : 1)
    }
}

@main
enum UpdaterChecksMain {
    static func main() async { await UpdaterChecks.run() }
}
