import Foundation
import Testing

@testable import AmanuensisCore

struct UpdateTests {
    @Test func parsesVersionsWithOptionalPrefixAndPrerelease() throws {
        let stable = try #require(AppVersion("v0.2.0"))
        #expect(stable == AppVersion(major: 0, minor: 2, patch: 0))
        #expect(!stable.isPrerelease)
        let preview = try #require(AppVersion("0.2.0-preview.3"))
        #expect(preview.prerelease == ["preview", "3"])
        #expect(preview.description == "0.2.0-preview.3")
        for invalid in ["0.2", "1.2.3.4", "a.b.c", "1.2.3-", "1.2.3-beta..1", "1.2.3+build", "-1.0.0", ""] {
            #expect(AppVersion(invalid) == nil, "\(invalid) should not parse")
        }
    }

    @Test func ordersReleasesBySemanticVersioningPrecedence() throws {
        let ordered = try [
            "0.1.0", "0.2.0-alpha", "0.2.0-alpha.1", "0.2.0-alpha.beta", "0.2.0-beta", "0.2.0-beta.2",
            "0.2.0-beta.11", "0.2.0-preview.1", "0.2.0-rc.1", "0.2.0", "0.2.1", "0.10.0", "1.0.0",
        ].map { try #require(AppVersion($0)) }
        for (lower, higher) in zip(ordered, ordered.dropFirst()) {
            #expect(lower < higher, "\(lower) should sort before \(higher)")
            #expect(!(higher < lower))
        }
        #expect(!(ordered[0] < ordered[0]))
    }

    @Test func stableChannelIgnoresPrereleasesAndPreviewFollowsNewestBuild() throws {
        let releases = try [
            ("v0.1.0", false), ("v0.2.0", false), ("v0.3.0-preview.1", true), ("v0.3.0-preview.2", true),
            ("v0.2.1", false),
        ].map { tag, prerelease in
            UpdateRelease(
                version: try #require(AppVersion(tag)), tag: tag, isPrerelease: prerelease, notesURL: nil,
                archiveURL: URL(string: "https://example.com/\(tag).dmg")!,
                archiveName: "Amanuensis-arm64.dmg", archiveByteCount: 1,
                signatureURL: URL(string: "https://example.com/\(tag).dmg.sig")!)
        }
        let installed = try #require(AppVersion("0.2.0"))
        #expect(UpdateRelease.newest(in: releases, channel: .stable, after: installed)?.tag == "v0.2.1")
        #expect(
            UpdateRelease.newest(in: releases, channel: .preview, after: installed)?.tag == "v0.3.0-preview.2"
        )
        let newest = try #require(AppVersion("0.3.0-preview.2"))
        #expect(UpdateRelease.newest(in: releases, channel: .preview, after: newest) == nil)
        #expect(UpdateRelease.newest(in: releases, channel: .stable, after: newest) == nil)
        let olderPreview = try #require(AppVersion("0.3.0-preview.1"))
        #expect(UpdateRelease.newest(in: releases, channel: .stable, after: olderPreview) == nil)
    }

    @Test func findsTheNextPageInLinkHeaders() {
        let header =
            "<https://api.github.com/repositories/1/releases?per_page=100&page=2>; rel=\"next\", "
            + "<https://api.github.com/repositories/1/releases?per_page=100&page=4>; rel=\"last\""
        #expect(
            UpdateRelease.nextPage(in: header)?.absoluteString
                == "https://api.github.com/repositories/1/releases?per_page=100&page=2")
        let last = "<https://api.github.com/repositories/1/releases?page=1>; rel=\"prev\""
        #expect(UpdateRelease.nextPage(in: last) == nil)
        #expect(UpdateRelease.nextPage(in: "") == nil)
    }

    @Test func parsesGitHubReleasesAndSkipsUnusableOnes() throws {
        let json = """
            [
              {"tag_name": "v0.3.0", "draft": true, "prerelease": false, "html_url": "https://g/3",
               "assets": [{"name": "Amanuensis-0.3.0-arm64.dmg", "size": 5, "browser_download_url": "https://g/3.dmg"},
                          {"name": "Amanuensis-0.3.0-arm64.dmg.sig", "size": 1, "browser_download_url": "https://g/3.sig"}]},
              {"tag_name": "v0.2.0", "draft": false, "prerelease": false, "html_url": "https://g/2",
               "assets": [{"name": "Amanuensis-0.2.0-arm64.dmg", "size": 5, "browser_download_url": "https://g/2.dmg"}]},
              {"tag_name": "nightly", "draft": false, "prerelease": true, "html_url": "https://g/n", "assets": []},
              {"tag_name": "v0.2.0-preview.1", "draft": false, "prerelease": false, "html_url": "https://g/p",
               "assets": [{"name": "Read me.txt", "size": 2, "browser_download_url": "https://g/p.txt"},
                          {"name": "Amanuensis-0.2.0-preview.1-arm64.dmg", "size": 7, "browser_download_url": "https://g/p.dmg"},
                          {"name": "Amanuensis-0.2.0-preview.1-arm64.dmg.sig", "size": 1, "browser_download_url": "https://g/p.sig"}]}
            ]
            """
        let releases = try UpdateRelease.parse(githubReleases: Data(json.utf8))
        #expect(releases.count == 1)
        let release = try #require(releases.first)
        #expect(release.tag == "v0.2.0-preview.1")
        #expect(release.isPrerelease, "a prerelease version string marks the release as preview")
        #expect(release.archiveName == "Amanuensis-0.2.0-preview.1-arm64.dmg")
        #expect(release.archiveByteCount == 7)
        #expect(release.archiveURL.absoluteString == "https://g/p.dmg")
        #expect(release.signatureURL.absoluteString == "https://g/p.sig")
        #expect(release.notesURL?.absoluteString == "https://g/p")
    }
}
