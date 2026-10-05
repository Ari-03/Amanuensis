# GitHub releases and main protection plan

Checked October 4, 2026 against `Ari-03/Amanuensis`, at commit `7b0c180988e4c1171f9e2e9441127e43e0c27f21`. This is an implementation plan. No repository settings, workflows, tags, or releases were changed during planning. [GitHub policy sources](github-release-policy-sources.md) records the supporting platform behavior.

The recommendation is to keep the existing branch protection and tagged release workflow, then publish a signed nightly from each successful build of a merge to `main`. GitHub Releases becomes the download location. The existing Stable and Preview updater channels consume those releases.

| Area | Verified current state | Planned change |
| --- | --- | --- |
| Main protection | PR required, `Checks` and `Build DMG` required, branch must be current, conversations resolved, administrators included, force pushes and deletion disabled | Preserve these settings and verify them after workflow changes |
| Reviewer approvals | Zero required approvals | Keep this so a sole maintainer can merge their own PR after CI passes |
| Builds | PRs and pushes to `main` build an arm64 DMG and run an updater smoke check | Keep PR artifacts; publish successful main builds as nightlies |
| Tagged releases | `release.yml` already builds and publishes `v*` tags | Add checks and retry handling; document the stable release procedure |
| Published downloads | No tags or GitHub Releases exist | Bootstrap a nightly, then publish the first stable when ready |
| Update signing | `AMANUENSIS_UPDATE_PRIVATE_KEY` exists as a repository secret; the app contains a public key | Verify they match during publication; preserve the key |
| Apple distribution signing | Builds are ad-hoc signed and not notarized | Treat Developer ID signing and notarization as a separate distribution milestone |

The branch protection and release inventory above came from GitHub's repository APIs, including `/branches/main/protection`, `/rulesets`, `/tags`, and `/releases`. The latest main workflow run, [36224924608](https://github.com/Ari-03/Amanuensis/actions/runs/36224924608), passed both required jobs. Secret listing verifies the key's presence, not its contents or its match to the app's public key.

1. Preserve the protection that already meets the request.

   Keep the exact required job names `Checks` and `Build DMG`, and their association with GitHub Actions. Keep strict status checks and administrator enforcement. Do not add the nightly publishing job as a required PR check, since it runs after merge. There is no need to migrate this working classic protection rule to a ruleset for this task.

   Zero required approvals still requires a PR and passing CI. It lets the maintainer merge their own PR. Requiring another person's approval is a separate team policy. Administrators can still deliberately edit repository settings; protection prevents direct pushes while the rule remains enforced.

2. Publish a nightly after each successful merge build.

   Extend [macos.yml](../../.github/workflows/macos.yml). On `push` to `refs/heads/main`, derive a nightly version before building, then reuse that run's verified DMG. After the updater smoke check passes, sign the DMG with the existing Ed25519 key and verify it against the public key embedded in the built app. A publishing job uploads the DMG and matching `.sig` to a GitHub prerelease at the exact triggering commit SHA.

   Only the publishing job needs `contents: write`. PR builds and ordinary manual builds keep read access and do not publish. Expose the private key only to the trusted signing step. Keep Actions artifacts for build inspection, with a release link in the successful run summary.

   Use a unique release tag such as `v0.2.0-nightly.123`, and a title that includes the version and date. Include the source commit, merged changes, macOS 26 minimum, and Apple Silicon requirement in the release notes. Explicitly set `prerelease: true` and `latest: false` so stable remains the main download recommendation. GitHub's CLI supports explicit target commits, prereleases, and latest selection. [Release CLI](https://cli.github.com/manual/gh_release_create)

   Keep cancellation for superseded PR builds, but give each main run its own concurrency group, such as one based on `github.run_id`. The current shared main group can discard pending runs even with `cancel-in-progress: false`. Every successful merge should get its own release, including when several merges arrive while another build runs. [Workflow concurrency](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency)

   Publish within the successful main workflow. Do not push a nightly tag and expect it to start `release.yml`: tags created with `GITHUB_TOKEN` do not trigger another push workflow. Reserve `-nightly.*` for automation and exclude those tags from the manual tag workflow to prevent duplicate publication if a tag is later created with a different credential. [Workflow triggers](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow)

3. Make version progression part of the release process.

   Use the Xcode `MARKETING_VERSION` as the next stable target. Append `-nightly.<main-workflow-run-number>` for main builds. The tag, DMG filename, and `CFBundleShortVersionString` must agree. The run number remains unchanged when a failed run is retried; do not use a commit hash alone for ordering or rely on `CFBundleVersion`, which the updater does not compare.

   Start with a version bump from `0.1.0` to `0.2.0` in the implementation PR. Existing development installs already report `0.1.0`, so `0.1.0-nightly.123` would look older even after selecting Preview. The intended sequence is:

   ```text
   0.1.0 < 0.2.0-nightly.123 < 0.2.0-nightly.124 < 0.2.0 < 0.2.1-nightly.125
   ```

   After shipping `0.2.0`, advance main to the next target, such as `0.2.1`, through a PR before further development merges. Add a PR validation step that rejects a base version at or below the newest published stable, with an instruction to bump it. This keeps nightlies newer than the previous stable without changing the updater's version rules. The tagged stable workflow is exempt from this development-version check.

4. Keep stable releases deliberate and reproducible.

   When a tested main commit is ready, push its stable tag with the matching base version, such as `v0.2.0`. The existing [release.yml](../../.github/workflows/release.yml) already checks the version, builds, tests, signs, and creates the release. Extend it to verify that the tagged commit belongs to main's history before signing. Keep publishing authority limited to trusted maintainers and the release workflow.

   Rebuild that commit with the stable version embedded in the app. Merely changing a nightly release's title or prerelease flag would leave the nightly version inside the bundle. Mark the stable release Latest, provided it is the newest stable version. Generate stable notes from the previous stable tag so intervening nightlies do not reduce the notes to the last merge. For the first stable release, review the initial generated notes.

   Share a small publication helper between the two workflows. Assemble each release as a draft, attach and verify both assets, then publish. On retry, resume an incomplete draft or recognize an already complete release for the same tag and commit. Never overwrite a published DMG, replace its signature, or move its tag. A bad published build is fixed by a newer version. The CLI documents draft upload and publication behavior, including immutable releases. [Release publication](https://cli.github.com/manual/gh_release_create)

5. Connect distribution to the existing updater.

   This app has a custom updater, not Sparkle. [Updates.swift](../../Amanuensis/Core/Updates.swift) reads semantic versions and selects signed DMG releases. [AppUpdater.swift](../../Amanuensis/App/AppUpdater.swift) fetches GitHub Releases and verifies downloads before installation. No additional feed service is required.

   | Installed channel | Offered updates |
   | --- | --- |
   | Stable | Newer stable releases only |
   | Preview | Newer nightlies and stable releases, ordered by version |

   Keep these two channels. Update Settings copy to explicitly say that Preview includes automatic builds from main. A fresh nightly installation defaults to Preview; an existing saved channel choice is preserved. Users of existing stable development builds must select Preview to receive nightlies. Switching a newer nightly to Stable waits for a newer stable release; it does not downgrade the app.

   Retain the latest 30 automatic nightly releases, keeping stable releases and manually tagged previews. Cleanup must match only the automation's nightly tags, use version order rather than completion time, and run only after a successful publication. The current updater fetches at most ten pages of 100 releases despite its comment saying every page. Bounded nightly retention avoids eventually hiding a stable release behind thousands of main builds; correct that comment and test pagination. This retention policy affects release downloads, separately from the existing 30-day Actions artifact expiry.

   Preserve the current signing key so existing installs continue trusting updates. Ed25519 update signing does not replace Apple Developer ID signing or notarization. The first releases must accurately describe the current ad-hoc signing limitation. Adding Developer ID and notarization later should happen before final DMG signing, with a downloaded-app installation check on a clean Mac.

6. Finish the download experience and verify the rollout.

   Put a Download section near the top of [README.md](../../README.md). Link stable downloads to `https://github.com/Ari-03/Amanuensis/releases/latest` once the first stable exists, and link nightly downloads to the Releases list with clear prerelease wording. Before the first stable, link directly to the available nightly and state that stable is not published yet. Explain that the DMG is the installer and `.sig` is used by automatic updates.

   Implement workflow changes, version checks, publication retry handling, updater copy, and tests in a PR. Read back main protection after merge. Verify the first published nightly by downloading its assets and exercising the updater, then use the tagged path for the first stable after the app's release checks pass.

   Acceptance checks should cover:

   - PRs run both required jobs without publishing; failed main builds publish nothing.
   - Two nearby merges both publish prereleases tied to their own commits, even if they finish out of order.
   - A failed upload leaves a draft; reruns produce one complete release without changing published assets.
   - Nightly-to-nightly and nightly-to-stable versions update correctly; Stable rejects nightlies.
   - An existing `0.1.0` install on Preview can discover the first new nightly.
   - The actual signed DMG and `.sig` work together; wrong signatures and bundle/tag mismatches fail.
   - Stable remains Latest, pagination finds stable behind nightlies, and cleanup preserves stable releases.
   - `Scripts/check.sh`, packaging verification, and `Scripts/check-updater.sh` pass for the implementation. Add focused version and release-selection cases to [UpdateTests.swift](../../Tests/Core/UpdateTests.swift).

The existing distribution research predates the implemented custom updater. For this work, the current source and live GitHub settings take precedence over its earlier Sparkle recommendation.
