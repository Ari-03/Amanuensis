# Storage and model management

Researched September 19, 2026. These are implementation recommendations for the [product brief](../product-brief.md), informed by the [runtime research](local-model-pipeline.md). No runtime or migration experiments were performed.

Consolidation note: the [implementation plan](../implementation-plan.md) adopts GRDB and independent content-free usage aggregates, so All time statistics survive history retention. Its explicit retry and deletion rules take precedence over alternatives in this note.

## One database, ordinary files

Use SQLite through GRDB, with one `DatabaseQueue` owned by `AppStore`. Start with async database operations and observed result snapshots for SwiftUI. GRDB documents transactions, migrations, observation, and full-text search, and recommends a queue when concurrent reads are unnecessary. Pin a tested release. [GRDB documentation](https://github.com/groue/GRDB.swift/blob/master/README.md)

SwiftData supports versioned schemas and explicit migration stages, so it is a viable alternative. I recommend GRDB because history search, deletion, aggregate statistics, and recovery records benefit from direct SQL control. That is an architectural preference, not evidence that SwiftData is unreliable. Do not combine both stores. [Apple migration guidance](https://developer.apple.com/videos/play/wwdc2025/291/)

Put the database, `Recordings/`, `Models/`, and `Staging/` under the app's Application Support directory. Store large audio/model assets as files, referenced by relative paths. Keep installed models out of purgeable caches. No cloud synchronization initially.

| Stored item | Contents |
| --- | --- |
| Recording | UUID, timestamps, duration, lifecycle status, raw/cleaned/final text, error category, audio path, expiry dates |
| Recording snapshot | Mode name/settings, model IDs and revisions, actual processing location, insertion outcome |
| Modes | Preset, selected model references, formatting, app rules, insertion/audio settings |
| Vocabulary | Words and replacement rules with stable IDs |
| Installations | Model identity/revision, files, checksums, source, runtime, readiness, last failure |
| Preferences | Theme, shortcuts, retention, microphone device IDs/order/exclusions, provider configuration without secrets |

Keep ordinary preferences in one versioned Codable settings record. Use concrete methods such as `saveMode`, `finishTranscription`, and `deleteRecording`; avoid a generic repository layer per entity. Snapshot mode/model labels so later edits or uninstallations cannot rewrite history.

## Durable history and deletion

Create the recording row before capture. Finish the audio file before recording its final path; save successful raw transcription before cleanup starts. Cleanup failure keeps raw text. A crash between these steps leaves a recoverable interrupted entry. Relaunch reconciles interrupted rows and unreferenced staging files; it never automatically replays insertion or uploads a recovered recording.

Start with indexed date ordering and paginated, parameterized substring search over raw and final text. This satisfies the requested search without introducing a second copy of transcript text. Measure a large history fixture before adding FTS. If needed, GRDB supports FTS5; its deletion behavior must be tested alongside retention. [GRDB search support](https://github.com/groue/GRDB.swift/blob/master/README.md#full-text-search)

Audio and transcript expiry are independent. Proposed defaults are seven days for audio and until manually deleted for text, visibly selectable during setup. Audio expiry removes playback/retry while retaining text. Text expiry removes raw, cleaned, and final text; retained audio may remain as an audio-only entry until its own deadline. Explicit Delete recording removes both.

Use an idempotent deletion job: record pending deletion, hide the entry, delete its files, then remove the row. Retry file failures on launch and report incomplete deletion. Do not retain automatic database backups containing deleted history. User exports and OS backups remain outside app-managed deletion. Never promise forensic erasure of SSD blocks.

Derive Home statistics from retained completed entries initially and label the period accordingly. If lifetime totals must survive history deletion, make that a separate product decision about retaining content-free aggregates.

## Model acquisition and readiness

Ship a versioned catalog identifying purpose, runtime/format, exact upstream revision, required files, byte sizes, SHA-256 hashes, license/attribution, and hardware/OS constraints. The catalog describes compatibility; installation records describe actual local state. Treat Apple-managed speech assets separately rather than pretending they are downloadable model folders.

Download with `URLSessionDownloadTask` into staging. Check HTTP status, persist resume data when available, and show restart when resumption fails. Apple's downloaded file URL is temporary and must be moved before the completion callback returns. Resume support is conditional, not a promise that every interrupted download continues. [Apple downloads](https://developer.apple.com/documentation/foundation/downloading-files-from-websites), [download task](https://developer.apple.com/documentation/foundation/urlsessiondownloadtask)

Validate every required file, hash, runtime format, tokenizer, and total package size. Then move the completed directory within the same volume and record installation. Reconcile that directory if the app crashes before the database write. States should include downloading, paused, verifying, installed, preparing, ready, incompatible, and failed. Installed bytes alone do not establish inference readiness. Updating a model installs a separate revision; keep the current revision usable until validation succeeds.

Default imports to a managed copy through an open panel. Show required disk space and preserve the source. This removes dependence on a removable drive or another app's storage. Reject incomplete bundles with specific missing filenames. Retain source metadata and local checksums without claiming an unknown import has a publisher-verified hash.

External-folder references can follow later. A sandboxed build needs persistent security-scoped bookmarks, balanced access calls, stale-bookmark repair, and a reconnect state when the volume disappears. This extra failure path is why copying is the first choice. [Apple bookmark guidance](https://developer.apple.com/forums/thread/797469?answerId=855165022)

Before uninstalling, list dependent modes and require reassignment or leave them visibly unavailable. Never silently switch providers. Prevent deletion while inference is using the package. Historical model snapshots survive uninstall.

## Credentials and migrations

Keep API keys and gated-download tokens in Keychain, addressed by provider-account UUID. Store only that reference in settings. Redact authorization headers and transcript bodies from diagnostics. A locked/missing credential produces a recoverable provider error. [Apple Keychain services](https://developer.apple.com/documentation/security/keychain-services)

Use ordered GRDB migrations from the first schema. Test upgrades with old fixtures; never reset a production database on migration failure. Offer a readable error and explicit recovery/export action. Keep model-catalog versions separate from database versions.

## Acceptance checks

- Relaunch after every capture/transcription/cleanup boundary preserves completed work without duplicate insertion.
- Audio expiry preserves text; transcript deletion removes every app search result and pending copy.
- Disconnect, corrupt resume data, full disk, wrong checksum, and missing tokenizer never produce Ready.
- Imports work offline after moving the original source elsewhere.
- Deleting an in-use model is blocked; dependent modes never fall back to cloud.
- Migration fixtures preserve settings/history; keys appear only in Keychain.
