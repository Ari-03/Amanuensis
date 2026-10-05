# GitHub branch protection and release sources

Research checked October 4, 2026 against official GitHub documentation. These are platform facts and implementation recommendations for Amanuensis, not evidence that repository settings or workflows have been changed.

## Preserve the existing main protection

Classic branch protection can require pull requests without requiring an approving review. Administrator enforcement is a separate setting. Strict status checks require the branch to be current with its base before merging, and checks can be tied to their producing GitHub App. Preserve the existing protections and check names when changing release workflows. Duplicate job names across workflows can make required checks ambiguous. [Protected branches](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches), [Configuring the pull request requirement](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/managing-a-branch-protection-rule)

Rulesets also support requiring a pull request without approval. This provides a future alternative, but a ruleset migration is not needed for this release work. Recommendation: keep zero required approvals while the owner needs to merge their own work, retain administrator enforcement, and retain the existing strict checks. [Ruleset pull request requirement](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets)

## Publish complete releases with distinct tags

GitHub separates a published prerelease from the latest full release. Drafts and prereleases cannot be marked latest. Recommendation: publish each successful main build as a uniquely versioned prerelease with `prerelease: true` and `make_latest: "false"`. Publish an intentionally chosen stable version with `prerelease: false` and `make_latest: "true"`. Both appear in Releases, while stable remains the normal download target. [Release API](https://docs.github.com/en/rest/releases/releases)

Create a draft, attach the DMG and all required companion assets, validate them, then publish. GitHub recommends this sequence for immutable releases. Immutability locks the published tag and assets, including prerelease assets, while allowing changes to notes and release classification. Recommendation: use a new version for fixes; avoid replacing the files behind a moving `nightly` tag. This design works before and after enabling repository immutability. [Immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)

`gh release create` can create a missing tag at the latest default-branch commit. Pass the exact built SHA with `--target`, or verify an existing tag and its commit before publishing. Use `--notes-start-tag` with the previous stable tag for stable release notes so intervening nightly tags do not shorten the intended comparison. Current CLI documentation says attaching files during creation internally uses draft, upload, then publish. [GitHub CLI release creation](https://cli.github.com/manual/gh_release_create)

## Keep publishing tied to the successful build

Tag pushes and release events produced with `GITHUB_TOKEN` do not launch downstream workflows. Explicit `workflow_dispatch` and `repository_dispatch` are supported exceptions. Recommendation: finish nightly publication in the same main-push workflow that built and checked the app. Do not create a nightly tag with `GITHUB_TOKEN` and expect the existing tag-triggered release workflow to run. [GITHUB_TOKEN event behavior](https://docs.github.com/en/actions/concepts/security/github_token)

`workflow_run` is available, but its default SHA is the latest default-branch commit, and it triggers regardless of upstream success. It can receive secrets and write permissions even when the preceding workflow could not. A separate publisher therefore needs explicit success, repository, branch, event, source SHA, and artifact-run checks. Recommendation: avoid that extra coordination here by adding a main-only publication job after the existing successful build. [Workflow events](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_run)

## Preserve a build for every merge

A fixed concurrency group with `cancel-in-progress: false` protects the running build, but the default queue still replaces a pending build when another arrives. For every-merge publication, give main runs a group unique to their SHA or run ID, or omit main concurrency. PR runs can continue canceling superseded work. GitHub now supports `queue: max` for serialized processing, but it allows only 100 pending runs and cancels further arrivals. [Concurrency behavior](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency)
