import Foundation
import SQLite3

// Run with:
// swiftc -swift-version 6 Amanuensis/Core/Domain.swift Amanuensis/Storage/LocalStore.swift \
//   Tests/Storage/LocalStoreChecks.swift -o /tmp/amanuensis-storage-checks && /tmp/amanuensis-storage-checks
@main
struct LocalStoreChecks {
    @MainActor
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try roundTrip(root.appendingPathComponent("roundtrip"))
        try statistics(root.appendingPathComponent("statistics"))
        try retryPreservation(root.appendingPathComponent("retries"))
        try retention(root.appendingPathComponent("retention"))
        try deletionAndRecovery(root.appendingPathComponent("recovery"))
        try migrationAndCorruption(root.appendingPathComponent("migration"))
        try meetingStagingCleanup(root.appendingPathComponent("meeting-staging"))
        print(
            "Storage checks passed: persistence, transactions, usage, retention, leases, deletion recovery, schema checks."
        )
    }

    @MainActor
    static func roundTrip(_ root: URL) throws {
        let store = try LocalStore(rootURL: root)
        var configuration = SavedConfiguration()
        configuration.settings.appearance = .dark
        configuration.vocabulary = [VocabularyEntry(word: "Aritra", replacement: "Aritra Das")]
        try store.saveConfiguration(configuration)
        let installation = ModelInstallation(id: "whisper", directory: "local", byteCount: 123)
        try store.saveInstallations([installation])
        do {
            try store.saveInstallations([installation, installation])
            throw Failure("Duplicate installation should roll back the replacement transaction")
        } catch is Failure { throw Failure("Duplicate installation was accepted") } catch {}
        let reloaded = try LocalStore(rootURL: root)
        try require(
            reloaded.loadConfiguration().settings == configuration.settings, "Settings must survive relaunch")
        try require(
            reloaded.loadConfiguration().vocabulary == configuration.vocabulary,
            "Vocabulary must survive relaunch")
        try require(
            reloaded.installations() == [installation], "A failed transaction must preserve installations")
    }

    @MainActor
    static func statistics(_ root: URL) throws {
        let store = try LocalStore(rootURL: root)
        let entry = completed(text: "one two three", seconds: 30)
        try store.upsertRecording(entry)
        try store.countIfNeeded(recording: entry)
        try store.countIfNeeded(recording: entry)
        try require(
            store.statistics() == UsageStatistics(words: 3, recordingSeconds: 30, sessions: 1), "Count once")
        var meeting = completed(text: "meeting transcript", seconds: 120)
        meeting.mode.preset = .meeting
        try store.countIfNeeded(recording: meeting)
        try require(store.statistics().sessions == 1, "Meetings do not inflate dictation statistics")
        try store.deleteRecording(id: entry.id)
        try require(store.statistics().words == 3, "Deleting history must preserve totals")
        try store.countIfNeeded(recording: entry)
        try require(store.statistics().words == 3, "Late results for deleted recordings must not count")
        let another = completed(text: "four five", seconds: 20)
        try store.upsertRecording(another)
        try store.countIfNeeded(recording: another)
        try store.resetStatistics()
        try store.countIfNeeded(recording: another)
        try require(store.statistics() == UsageStatistics(), "Reset must not permit old jobs to count again")
        let reloaded = try LocalStore(rootURL: root)
        try reloaded.countIfNeeded(recording: another)
        try require(reloaded.statistics() == UsageStatistics(), "Counted IDs must survive relaunch and reset")
    }

    @MainActor
    static func retryPreservation(_ root: URL) throws {
        let store = try LocalStore(rootURL: root)
        var original = completed(text: "original transcript", seconds: 30)
        original.audioFileName = "original.wav"
        original.speechSnapshot = ModelDescriptor(
            id: "saved-model", name: "Saved model", provider: "Local", purpose: .speech,
            location: .local, family: .whisper, summary: "Snapshot"
        )
        let source = store.recordingsURL.appendingPathComponent("original.wav")
        try Data("original audio".utf8).write(to: source)
        try store.upsertRecording(original)
        try store.countIfNeeded(recording: original)
        let savedOriginal = store.loadRecordings()[0]
        let canceled = original.retryAttempt()
        try require(
            canceled.id != original.id && canceled.parentRecordingID == original.id,
            "Retry needs a separate identity and original capture anchor")
        try require(
            canceled.rawText.isEmpty && canceled.finalText.isEmpty && canceled.cleanedText == nil,
            "Retry must not display old output as new output")
        try require(
            canceled.speechSnapshot == original.speechSnapshot, "Retry must preserve the model snapshot")
        try require(store.acquireAudioLease(for: original) == source, "Retry acquires the source audio")
        try store.upsertRecording(canceled)
        let attemptAudio = store.recordingsURL.appendingPathComponent(canceled.audioFileName!)
        try FileManager.default.copyItem(at: source, to: attemptAudio)
        try store.deleteRecording(id: canceled.id)
        try store.releaseAudioLease(for: original)
        try require(
            store.loadRecordings() == [savedOriginal], "Canceling retry must preserve the original transcript"
        )
        try require(
            FileManager.default.fileExists(atPath: source.path),
            "Canceling retry must preserve original audio")
        try require(
            !FileManager.default.fileExists(atPath: attemptAudio.path),
            "Canceling retry must discard only attempt audio")

        var successful = original.retryAttempt()
        successful.finalText = "revised transcript has more words"
        successful.status = .complete
        try store.upsertRecording(successful)
        try store.countIfNeeded(recording: successful)
        var nested = successful.retryAttempt()
        nested.finalText = "third attempt"
        nested.status = .complete
        try store.upsertRecording(nested)
        try store.countIfNeeded(recording: nested)
        try require(
            nested.parentRecordingID == original.id, "Nested retries retain the original capture anchor")
        try require(
            store.statistics() == UsageStatistics(words: 2, recordingSeconds: 30, sessions: 1),
            "Retry chains must not inflate usage")
        try store.deleteRecording(id: original.id)
        try store.countIfNeeded(recording: successful)
        try require(
            store.statistics().sessions == 1, "Deleting original history must not break retry deduplication")

        var failed = completed(text: "", seconds: 15)
        failed.status = .failed
        try store.upsertRecording(failed)
        var recovered = failed.retryAttempt()
        recovered.status = .complete
        recovered.finalText = "recovered words"
        try store.upsertRecording(recovered)
        try store.countIfNeeded(recording: recovered)
        try require(
            store.statistics().sessions == 2, "First successful retry of a failed capture counts once")
        let reopened = try LocalStore(rootURL: root)
        try reopened.countIfNeeded(recording: recovered)
        try require(reopened.statistics().sessions == 2, "Retry deduplication survives relaunch")
    }

    @MainActor
    static func retention(_ root: URL) throws {
        let store = try LocalStore(rootURL: root)
        let now = Date()
        var old = completed(text: "private transcript", seconds: 10)
        old.createdAt = now.addingTimeInterval(-10 * 86_400)
        old.audioFileName = "old.wav"
        try Data("audio".utf8).write(to: store.recordingsURL.appendingPathComponent("old.wav"))
        try store.upsertRecording(old)
        try store.countIfNeeded(recording: old)
        var settings = AppSettings()
        settings.audioRetentionDays = 7
        settings.textRetentionDays = 0
        try store.enforceRetention(settings: settings, now: now)
        try require(
            store.loadRecordings()[0].finalText == "private transcript", "Audio retention must keep text")
        try require(store.loadRecordings()[0].audioFileName == nil, "Expired audio must detach from history")
        try require(
            !FileManager.default.fileExists(
                atPath: store.recordingsURL.appendingPathComponent("old.wav").path),
            "Expired audio must be removed")
        settings.textRetentionDays = 7
        try store.enforceRetention(settings: settings, now: now)
        try require(store.loadRecordings().isEmpty, "Both expired contents must remove the history row")
        try require(store.statistics().words == 2, "Retention must not reduce usage totals")

        var retainedAudio = old
        retainedAudio.id = UUID()
        retainedAudio.audioFileName = "retained.wav"
        try Data("audio".utf8).write(to: store.recordingsURL.appendingPathComponent("retained.wav"))
        try store.upsertRecording(retainedAudio)
        settings.audioRetentionDays = 0
        try store.enforceRetention(settings: settings, now: now)
        let scrubbed = store.loadRecordings()[0]
        try require(
            scrubbed.finalText.isEmpty && scrubbed.rawText.isEmpty && scrubbed.cleanedText == nil,
            "Text expires independently")
        try require(
            store.audioURL(for: scrubbed) != nil, "Text retention must preserve audio under its own policy")

        var active = completed(text: "in progress", seconds: 10)
        active.status = .transcribing
        active.createdAt = old.createdAt
        try store.upsertRecording(active)
        var leased = completed(text: "active retry", seconds: 10)
        leased.createdAt = old.createdAt
        try store.upsertRecording(leased)
        settings.audioRetentionDays = -1
        settings.textRetentionDays = -1
        try store.enforceRetention(settings: settings, now: now, activeIDs: [leased.id])
        try require(
            Set(store.loadRecordings().map(\.id)) == [active.id, leased.id],
            "Exclude in-progress and explicitly active jobs")
    }

    @MainActor
    static func deletionAndRecovery(_ root: URL) throws {
        let store = try LocalStore(rootURL: root)
        var entry = completed(text: "recovery text", seconds: 10)
        entry.audioFileName = "leased.wav"
        let audio = store.recordingsURL.appendingPathComponent("leased.wav")
        try Data("audio".utf8).write(to: audio)
        try store.upsertRecording(entry)
        try require(store.acquireAudioLease(for: entry) == audio, "Acquire a real audio lease")
        try store.deleteRecording(id: entry.id)
        try require(store.loadRecordings().isEmpty, "Deletion must hide a leased recording immediately")
        try require(FileManager.default.fileExists(atPath: audio.path), "Lease must protect in-use audio")
        do {
            try store.upsertRecording(entry)
            throw Failure("A late result resurrected a deleted recording")
        } catch is Failure { throw Failure("Tombstone missing") } catch {}
        try store.releaseAudioLease(for: entry)
        try require(!FileManager.default.fileExists(atPath: audio.path), "Last lease must finish deletion")

        var interrupted = completed(text: "partial", seconds: 10)
        interrupted.status = .cleaning
        try store.upsertRecording(interrupted)
        let pendingAudio = store.recordingsURL.appendingPathComponent("pending.wav")
        try Data("audio".utf8).write(to: pendingAudio)
        try sql(root, "INSERT INTO pending_audio_deletions (file_name) VALUES ('pending.wav')")
        let reopened = try LocalStore(rootURL: root)
        try require(
            reopened.loadRecordings()[0].status == .interrupted,
            "Relaunch must recover active jobs as interrupted")
        try require(
            reopened.loadRecordings()[0].finalText == "partial",
            "Interrupted recovery must keep existing output")
        try require(
            !FileManager.default.fileExists(atPath: pendingAudio.path),
            "Relaunch must resume pending file deletion")
        var invalid = entry
        invalid.id = UUID()
        invalid.audioFileName = "../outside.wav"
        do {
            try reopened.upsertRecording(invalid)
            throw Failure("Path traversal was accepted")
        } catch is Failure { throw Failure("Unsafe audio location") } catch {}
    }

    @MainActor
    static func meetingStagingCleanup(_ root: URL) throws {
        let manager = FileManager.default
        let recordings = root.appendingPathComponent("Recordings", isDirectory: true)
        let models = root.appendingPathComponent("Models", isDirectory: true)
        try manager.createDirectory(at: recordings, withIntermediateDirectories: true)
        try manager.createDirectory(at: models, withIntermediateDirectories: true)
        for directory in [root, recordings, models] {
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        }
        let abandoned = recordings.appendingPathComponent(".meeting-00000000-0000-0000-0000-000000000001")
        try manager.createDirectory(at: abandoned, withIntermediateDirectories: true)
        try Data("unfinished private audio".utf8).write(
            to: abandoned.appendingPathComponent("microphone.wav"))
        let unrelated = recordings.appendingPathComponent(".meeting-not-a-uuid")
        try manager.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let ordinary = recordings.appendingPathComponent("ordinary.wav")
        try Data("retained audio".utf8).write(to: ordinary)
        let matchingFile = recordings.appendingPathComponent(".meeting-00000000-0000-0000-0000-000000000002")
        try Data("unrelated file".utf8).write(to: matchingFile)
        let outside = root.appendingPathComponent("unrelated-target")
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideAudio = outside.appendingPathComponent("untouched.wav")
        try Data("must survive".utf8).write(to: outsideAudio)
        let link = recordings.appendingPathComponent(".meeting-00000000-0000-0000-0000-000000000003")
        try manager.createSymbolicLink(at: link, withDestinationURL: outside)
        try manager.createSymbolicLink(
            at: abandoned.appendingPathComponent("external"), withDestinationURL: outside)

        _ = try LocalStore(rootURL: root)
        try require(
            !manager.fileExists(atPath: abandoned.path),
            "Startup must discard owned incomplete meeting channels")
        try require(manager.fileExists(atPath: unrelated.path), "An invalid staging name must be preserved")
        try require(
            manager.fileExists(atPath: ordinary.path), "Startup staging cleanup must preserve ordinary audio")
        try require(
            manager.fileExists(atPath: matchingFile.path),
            "A matching file must not be treated as a staging directory")
        try require(
            manager.fileExists(atPath: outsideAudio.path),
            "Staging symlinks must not delete their external targets")
        let linkAttributes = try manager.attributesOfItem(atPath: link.path)
        try require(
            linkAttributes[.type] as? FileAttributeType == .typeSymbolicLink,
            "A top-level matching symlink must be preserved")
        for directory in [root, recordings, models] {
            let attributes = try manager.attributesOfItem(atPath: directory.path)
            try require(
                (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
                "Storage directories must be private to the current user")
        }
    }

    @MainActor
    static func migrationAndCorruption(_ root: URL) throws {
        _ = try LocalStore(rootURL: root)
        try sql(root, "PRAGMA user_version = 999")
        do {
            _ = try LocalStore(rootURL: root)
            throw Failure("Newer schema was opened")
        } catch is Failure { throw Failure("Schema version check missing") } catch {}
        try sql(root, "PRAGMA user_version = 1")
        try sql(root, "INSERT INTO configuration (id, payload) VALUES (1, X'00')")
        do {
            _ = try LocalStore(rootURL: root)
            throw Failure("Corrupt preferences were silently reset")
        } catch is Failure { throw Failure("Corruption check missing") } catch {}
    }

    static func completed(text: String, seconds: Double) -> RecordingEntry {
        RecordingEntry(
            duration: seconds, mode: DictationMode(name: "Dictation", preset: .dictation), rawText: text,
            finalText: text, status: .complete)
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message) }
    }

    static func sql(_ root: URL, _ statement: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("Amanuensis.sqlite").path, &database) == SQLITE_OK
        else {
            throw Failure("Unable to open test database")
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK else {
            throw Failure("Test SQL failed")
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
