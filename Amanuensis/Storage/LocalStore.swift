import Foundation
import SQLite3

/// Owns the on-disk records. SQLite transactions also schedule file deletion so a crash can resume it.
/// The system SQLite library keeps this store independent of a third-party database package.
@MainActor
final class LocalStore {
    let rootURL: URL
    let recordingsURL: URL
    let modelsURL: URL

    private let connection: SQLiteConnection
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var configuration = SavedConfiguration()
    private var recordings: [RecordingEntry] = []
    private var installedModels: [ModelInstallation] = []
    private var usage = UsageStatistics()
    private var audioLeases: [String: Int] = [:]

    init(rootURL: URL? = nil) throws {
        let fileManager = FileManager.default
        let directory =
            try rootURL
            ?? fileManager.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appendingPathComponent("Amanuensis", isDirectory: true)
        self.rootURL = directory
        recordingsURL = directory.appendingPathComponent("Recordings", isDirectory: true)
        modelsURL = directory.appendingPathComponent("Models", isDirectory: true)
        for url in [directory, recordingsURL, modelsURL] {
            try fileManager.createDirectory(
                at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw StoreError.invalidStorageDirectory
            }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        connection = try SQLiteConnection(url: directory.appendingPathComponent("Amanuensis.sqlite"))
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA secure_delete = ON")
        // DELETE mode avoids retaining deleted transcript content in a long-lived WAL file.
        try execute("PRAGMA journal_mode = DELETE")
        try execute("PRAGMA synchronous = FULL")
        try migrate()
        try reload()
        try recoverInterruptedRecordings()
        try finishPendingAudioDeletions()
        try discardAbandonedMeetingStaging()
    }

    func loadConfiguration() -> SavedConfiguration { configuration }
    func loadRecordings() -> [RecordingEntry] { recordings }
    func installations() -> [ModelInstallation] { installedModels }
    func statistics() -> UsageStatistics { usage }

    func saveConfiguration(_ value: SavedConfiguration) throws {
        try execute(
            "INSERT OR REPLACE INTO configuration (id, payload) VALUES (1, ?)",
            [.data(try encoder.encode(value))]
        )
        configuration = value
    }

    func saveInstallations(_ values: [ModelInstallation]) throws {
        try transaction {
            try execute("DELETE FROM installations")
            for value in values {
                try execute(
                    "INSERT INTO installations (id, payload) VALUES (?, ?)",
                    [.text(value.id), .data(try encoder.encode(value))]
                )
            }
        }
        installedModels = values
    }

    func upsertRecording(_ recording: RecordingEntry) throws {
        if let fileName = recording.audioFileName { _ = try checkedAudioURL(fileName) }
        guard try !hasTombstone(recording.id) else { throw StoreError.recordingDeleted }
        // A retained ledger entry takes precedence over an out-of-date in-memory flag.
        var value = recording
        value.countedInStatistics = try hasCounted(recording.parentRecordingID ?? recording.id)
        try writeRecording(value)
        try reloadRecordings()
    }

    /// A tombstone rejects results from inference that finishes after the user deletes the recording.
    func deleteRecording(id: UUID) throws {
        let entry = recordings.first { $0.id == id }
        try transaction {
            if let name = entry?.audioFileName { try scheduleAudioDeletion(name) }
            try execute("INSERT OR IGNORE INTO deleted_recordings (id) VALUES (?)", [.text(id.uuidString)])
            try execute("DELETE FROM recordings WHERE id = ?", [.text(id.uuidString)])
        }
        try reloadRecordings()
        try finishPendingAudioDeletions()
    }

    /// Counts completed dictation once. The ledger has no transcript and survives history deletion and resets.
    func countIfNeeded(recording: RecordingEntry) throws {
        guard recording.status == .complete, recording.mode.preset != .meeting,
            !recording.finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            recording.duration.isFinite, recording.duration >= 0,
            try !hasTombstone(recording.id)
        else { return }
        let words = recording.finalText.split(whereSeparator: { $0.isWhitespace }).count
        try transaction {
            try execute(
                "INSERT OR IGNORE INTO usage_ledger (id, words, seconds, sessions) VALUES (?, ?, ?, 1)",
                [
                    .text((recording.parentRecordingID ?? recording.id).uuidString), .integer(words),
                    .double(recording.duration),
                ]
            )
            if var saved = recordings.first(where: { $0.id == recording.id }) {
                saved.countedInStatistics = true
                try writeRecording(saved)
            }
        }
        try reloadUsage()
        try reloadRecordings()
    }

    func resetStatistics() throws {
        // Preserve IDs so retrying an old recording cannot count it again after a reset.
        try execute("UPDATE usage_ledger SET words = 0, seconds = 0, sessions = 0")
        usage = UsageStatistics()
    }

    /// Zero means forever, positive values mean days, and negative values expire immediately.
    /// Active recordings and caller-specified jobs are excluded from both retention policies.
    func enforceRetention(
        settings: AppSettings, now: Date = Date(), activeIDs: Set<UUID> = []
    ) throws {
        try transaction {
            for var entry in recordings {
                guard !activeIDs.contains(entry.id), !Self.inProgress(entry.status) else { continue }
                let expireAudio = Self.expired(entry.createdAt, days: settings.audioRetentionDays, now: now)
                let expireText = Self.expired(entry.createdAt, days: settings.textRetentionDays, now: now)
                guard expireAudio || expireText else { continue }
                if expireAudio, let name = entry.audioFileName {
                    try scheduleAudioDeletion(name)
                    entry.audioFileName = nil
                }
                if expireText {
                    entry.rawText = ""
                    entry.cleanedText = nil
                    entry.finalText = ""
                    entry.error = nil
                    entry.deliveryMessage = nil
                    entry.destinationApp = nil
                    entry.mode.customPrompt = ""
                    entry.status = .empty
                }
                if expireText && entry.audioFileName == nil {
                    try execute(
                        "INSERT OR IGNORE INTO deleted_recordings (id) VALUES (?)",
                        [.text(entry.id.uuidString)]
                    )
                    try execute("DELETE FROM recordings WHERE id = ?", [.text(entry.id.uuidString)])
                } else {
                    try writeRecording(entry)
                }
            }
        }
        try reloadRecordings()
        try finishPendingAudioDeletions()
    }

    func audioURL(for entry: RecordingEntry) -> URL? {
        guard let name = entry.audioFileName, let url = try? checkedAudioURL(name),
            recordings.contains(where: { $0.id == entry.id && $0.audioFileName == name }),
            FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    /// Call before playback or retry. Deleting the entry hides it immediately but waits for this lease to end.
    func acquireAudioLease(for entry: RecordingEntry) -> URL? {
        guard let url = audioURL(for: entry), let name = entry.audioFileName else { return nil }
        audioLeases[name, default: 0] += 1
        return url
    }

    func releaseAudioLease(for entry: RecordingEntry) throws {
        if let name = entry.audioFileName, let count = audioLeases[name] {
            if count <= 1 { audioLeases.removeValue(forKey: name) } else { audioLeases[name] = count - 1 }
        }
        try finishPendingAudioDeletions()
    }

    private static func inProgress(_ status: RecordingStatus) -> Bool {
        [.recording, .transcribing, .cleaning].contains(status)
    }

    private static func expired(_ date: Date, days: Int, now: Date) -> Bool {
        days < 0 || (days > 0 && now.timeIntervalSince(date) >= Double(days) * 86_400)
    }

    private func migrate() throws {
        let version = try rows("PRAGMA user_version").first?.first?.integer ?? 0
        guard version <= 1 else { throw StoreError.newerDatabase(version) }
        guard version == 0 else { return }
        try transaction {
            try execute(
                "CREATE TABLE configuration (id INTEGER PRIMARY KEY CHECK (id = 1), payload BLOB NOT NULL)")
            try execute("CREATE TABLE installations (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL)")
            try execute(
                """
                CREATE TABLE recordings (
                    id TEXT PRIMARY KEY NOT NULL,
                    created_at REAL NOT NULL,
                    payload BLOB NOT NULL
                )
                """
            )
            try execute("CREATE INDEX recordings_by_date ON recordings (created_at DESC)")
            try execute(
                """
                CREATE TABLE usage_ledger (
                    id TEXT PRIMARY KEY NOT NULL,
                    words INTEGER NOT NULL,
                    seconds REAL NOT NULL,
                    sessions INTEGER NOT NULL
                )
                """
            )
            try execute("CREATE TABLE pending_audio_deletions (file_name TEXT PRIMARY KEY NOT NULL)")
            try execute("CREATE TABLE deleted_recordings (id TEXT PRIMARY KEY NOT NULL)")
            try execute("PRAGMA user_version = 1")
        }
    }

    private func reload() throws {
        if let payload = try rows("SELECT payload FROM configuration WHERE id = 1").first?.first?.data {
            configuration = try decoder.decode(SavedConfiguration.self, from: payload)
        }
        installedModels = try rows("SELECT payload FROM installations ORDER BY id").map {
            try decoder.decode(ModelInstallation.self, from: try $0[0].requiredData())
        }
        try reloadRecordings()
        try reloadUsage()
    }

    private func reloadRecordings() throws {
        recordings = try rows("SELECT payload FROM recordings ORDER BY created_at DESC, id").map {
            try decoder.decode(RecordingEntry.self, from: try $0[0].requiredData())
        }
    }

    private func reloadUsage() throws {
        guard
            let row = try rows(
                "SELECT COALESCE(SUM(words), 0), COALESCE(SUM(seconds), 0), COALESCE(SUM(sessions), 0) FROM usage_ledger"
            ).first
        else { return }
        usage = UsageStatistics(
            words: row[0].integer, recordingSeconds: row[1].double, sessions: row[2].integer)
    }

    private func recoverInterruptedRecordings() throws {
        try transaction {
            for var entry in recordings where Self.inProgress(entry.status) {
                entry.status = .interrupted
                entry.error =
                    "The app closed before this recording finished. You can retry if its audio is available."
                try writeRecording(entry)
            }
        }
        try reloadRecordings()
    }

    /// Runs only when the single app instance opens its store. A crashed meeting's unfinished
    /// channel files are discarded instead of surviving outside the recording retention policy.
    private func discardAbandonedMeetingStaging() throws {
        let manager = FileManager.default
        for url in try manager.contentsOfDirectory(at: recordingsURL, includingPropertiesForKeys: nil) {
            let name = url.lastPathComponent
            guard name.hasPrefix(".meeting-") else { continue }
            let suffix = String(name.dropFirst(".meeting-".count))
            guard let id = UUID(uuidString: suffix),
                id.uuidString.caseInsensitiveCompare(suffix) == .orderedSame
            else {
                continue
            }
            // Inspect the directory entry itself, so a matching symlink cannot authorize deleting its target.
            let attributes = try manager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { continue }
            try manager.removeItem(at: url)
        }
    }

    private func writeRecording(_ entry: RecordingEntry) throws {
        try execute(
            "INSERT OR REPLACE INTO recordings (id, created_at, payload) VALUES (?, ?, ?)",
            [
                .text(entry.id.uuidString), .double(entry.createdAt.timeIntervalSince1970),
                .data(try encoder.encode(entry)),
            ]
        )
    }

    private func hasTombstone(_ id: UUID) throws -> Bool {
        try !rows("SELECT id FROM deleted_recordings WHERE id = ?", [.text(id.uuidString)]).isEmpty
    }

    private func hasCounted(_ id: UUID) throws -> Bool {
        try !rows("SELECT id FROM usage_ledger WHERE id = ?", [.text(id.uuidString)]).isEmpty
    }

    private func checkedAudioURL(_ fileName: String) throws -> URL {
        guard !fileName.isEmpty, fileName != ".", fileName != "..",
            !fileName.contains("/"), !fileName.contains("\\"), !fileName.contains("\0")
        else { throw StoreError.invalidAudioPath }
        let url = recordingsURL.appendingPathComponent(fileName)
        guard
            url.resolvingSymlinksInPath().deletingLastPathComponent()
                == recordingsURL.resolvingSymlinksInPath()
        else { throw StoreError.invalidAudioPath }
        return url
    }

    private func scheduleAudioDeletion(_ fileName: String) throws {
        _ = try checkedAudioURL(fileName)
        try execute("INSERT OR IGNORE INTO pending_audio_deletions (file_name) VALUES (?)", [.text(fileName)])
    }

    private func finishPendingAudioDeletions() throws {
        for row in try rows("SELECT file_name FROM pending_audio_deletions") {
            guard let name = row[0].text, audioLeases[name, default: 0] == 0 else { continue }
            let url = try checkedAudioURL(name)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try execute("DELETE FROM pending_audio_deletions WHERE file_name = ?", [.text(name)])
        }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String, _ values: [SQLValue] = []) throws {
        _ = try rows(sql, values)
    }

    private func rows(_ sql: String, _ values: [SQLValue] = []) throws -> [[SQLValue]] {
        let database = connection.handle
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw connection.error()
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let value): result = sqlite3_bind_text(statement, index, value, -1, transient)
            case .integer(let value): result = sqlite3_bind_int64(statement, index, Int64(value))
            case .double(let value): result = sqlite3_bind_double(statement, index, value)
            case .data(let value):
                result = value.withUnsafeBytes {
                    sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient)
                }
            case .null: result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw connection.error() }
        }
        var result: [[SQLValue]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw connection.error() }
            result.append(
                (0..<sqlite3_column_count(statement)).map { column in
                    switch sqlite3_column_type(statement, column) {
                    case SQLITE_INTEGER: return .integer(Int(sqlite3_column_int64(statement, column)))
                    case SQLITE_FLOAT: return .double(sqlite3_column_double(statement, column))
                    case SQLITE_TEXT:
                        guard let bytes = sqlite3_column_text(statement, column) else { return .null }
                        return .text(String(cString: bytes))
                    case SQLITE_BLOB:
                        let count = Int(sqlite3_column_bytes(statement, column))
                        guard let bytes = sqlite3_column_blob(statement, column) else { return .data(Data()) }
                        return .data(Data(bytes: bytes, count: count))
                    default: return .null
                    }
                })
        }
    }
}

private enum SQLValue {
    case text(String)
    case integer(Int)
    case double(Double)
    case data(Data)
    case null
    var integer: Int { if case .integer(let value) = self { value } else { 0 } }
    var double: Double {
        switch self {
        case .double(let value): value
        case .integer(let value): Double(value)
        default: 0
        }
    }
    var data: Data? { if case .data(let value) = self { value } else { nil } }
    var text: String? { if case .text(let value) = self { value } else { nil } }
    func requiredData() throws -> Data {
        guard let data else { throw StoreError.invalidPayload }
        return data
    }
}

/// Used only by LocalStore on the main actor. The separate owner closes the handle on deallocation.
private final class SQLiteConnection {
    let handle: OpaquePointer
    init(url: URL) throws {
        var database: OpaquePointer?
        let code = sqlite3_open_v2(
            url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open the database."
            if let database { sqlite3_close(database) }
            throw StoreError.database(message)
        }
        handle = database
        sqlite3_busy_timeout(handle, 5_000)
    }
    deinit { sqlite3_close(handle) }
    func error() -> StoreError { .database(String(cString: sqlite3_errmsg(handle))) }
}

private enum StoreError: LocalizedError {
    case database(String)
    case newerDatabase(Int)
    case invalidPayload, invalidAudioPath, invalidStorageDirectory, recordingDeleted
    var errorDescription: String? {
        switch self {
        case .database(let message): "The local database could not complete the operation: \(message)"
        case .newerDatabase(let version):
            "This database uses format \(version). Open it with a newer version of Amanuensis."
        case .invalidPayload: "The local database contains an unreadable record."
        case .invalidAudioPath: "The recording has an invalid audio file location."
        case .invalidStorageDirectory: "The storage location must be a directory, not a symbolic link."
        case .recordingDeleted: "This recording has already been deleted."
        }
    }
}
