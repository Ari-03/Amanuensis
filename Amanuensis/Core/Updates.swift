import Foundation

/// A release version such as `0.2.0` or `0.2.0-preview.1`, ordered by semantic-versioning precedence.
struct AppVersion: Equatable, Hashable, Comparable, Sendable, CustomStringConvertible {
    var major: Int
    var minor: Int
    var patch: Int
    /// Dot-separated prerelease identifiers; empty for a stable release.
    var prerelease: [String] = []

    var isPrerelease: Bool { !prerelease.isEmpty }

    /// Accepts `1.2.3`, `1.2.3-beta.1`, and the same with a leading `v`. Build metadata is not supported.
    init?(_ text: String) {
        var body = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if body.hasPrefix("v") { body = body.dropFirst() }
        let dash = body.firstIndex(of: "-")
        let core = dash.map { body[..<$0] } ?? body
        let numbers = core.split(separator: ".", omittingEmptySubsequences: false).map { Int(String($0)) }
        guard numbers.count == 3, let major = numbers[0], let minor = numbers[1], let patch = numbers[2],
            major >= 0, minor >= 0, patch >= 0
        else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
        if let dash {
            let identifiers = body[body.index(after: dash)...].split(
                separator: ".", omittingEmptySubsequences: false
            ).map(String.init)
            let valid = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
            guard !identifiers.isEmpty,
                identifiers.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(valid.contains) })
            else { return nil }
            prerelease = identifiers
        }
    }

    init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : core + "-" + prerelease.joined(separator: ".")
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        if (lhs.major, lhs.minor, lhs.patch) != (rhs.major, rhs.minor, rhs.patch) {
            return (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
        // A stable release outranks every prerelease of the same version.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, _): return false
        case (false, true): return true
        case (false, false): break
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            switch (Int(left), Int(right)) {
            case (let l?, let r?): return l < r
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

/// Stable receives only full releases. Preview also receives prereleases, so it is never behind stable.
enum UpdateChannel: String, CaseIterable, Sendable, Identifiable {
    case stable, preview
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// A published build the updater can install: one GitHub release with a signed arm64 disk image.
struct UpdateRelease: Equatable, Sendable {
    var version: AppVersion
    var tag: String
    var isPrerelease: Bool
    var notesURL: URL?
    var archiveURL: URL
    var archiveName: String
    var archiveByteCount: Int64
    var signatureURL: URL

    /// Reads GitHub's releases list, ignoring drafts, unparsable tags, and releases without a signed DMG.
    static func parse(githubReleases data: Data) throws -> [UpdateRelease] {
        try JSONDecoder().decode([GitHubRelease].self, from: data).compactMap { release in
            guard !release.draft, let version = AppVersion(release.tagName) else { return nil }
            guard
                let archive = release.assets.first(where: {
                    $0.name.hasPrefix("Amanuensis-") && $0.name.hasSuffix("-arm64.dmg")
                }),
                let signature = release.assets.first(where: { $0.name == archive.name + ".sig" })
            else { return nil }
            return UpdateRelease(
                version: version, tag: release.tagName,
                isPrerelease: release.prerelease || version.isPrerelease,
                notesURL: release.htmlURL, archiveURL: archive.browserDownloadURL, archiveName: archive.name,
                archiveByteCount: archive.size, signatureURL: signature.browserDownloadURL)
        }
    }

    /// The newest release on the channel that is ahead of the installed version, if any.
    static func newest(in releases: [UpdateRelease], channel: UpdateChannel, after current: AppVersion)
        -> UpdateRelease?
    {
        releases.filter { channel == .preview || !$0.isPrerelease }
            .filter { $0.version > current }
            .max { $0.version < $1.version }
    }
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        var name: String
        var size: Int64
        var browserDownloadURL: URL
        enum CodingKeys: String, CodingKey {
            case name, size
            case browserDownloadURL = "browser_download_url"
        }
    }
    var tagName: String
    var draft: Bool
    var prerelease: Bool
    var htmlURL: URL?
    var assets: [Asset]
    enum CodingKeys: String, CodingKey {
        case draft, prerelease, assets
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}
