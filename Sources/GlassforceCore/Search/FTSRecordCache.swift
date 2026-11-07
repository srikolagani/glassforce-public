import Foundation
#if os(macOS)
import SQLite3
#else
import CSQLite
#endif

public enum FTSRecordCacheError: Error, Equatable, Sendable {
    case openFailed(String)
    case wrongOrg(expected: String, found: String)
    case sql(String)
}

/// One org's search index on disk. Rows live in an FTS5 table keyed by org id.
///
/// Keystroke ranking still uses `FuzzyMatcher` over those rows. FTS5 MATCH is prefix-only
/// and would drop the typo and acronym hits the command bar is built around. `matchingIDs`
/// is the direct FTS5 query, used to prove the index is real.
public final class FTSRecordCache: @unchecked Sendable {
    public let orgID: String
    public let fileURL: URL
    private var db: OpaquePointer?
    private var memory = RecordStore(records: [])
    private var loaded = false
    private let lock = NSLock()

    public convenience init(directory: URL, orgID: String) throws {
        try self.init(file: Self.fileURL(directory: directory, orgID: orgID), orgID: orgID)
    }

    public init(file: URL, orgID: String) throws {
        self.orgID = orgID
        self.fileURL = file
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(file.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let handle { sqlite3_close(handle) }
            throw FTSRecordCacheError.openFailed(message)
        }
        self.db = handle
        do {
            try exec("""
                CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE VIRTUAL TABLE IF NOT EXISTS records USING fts5(
                    record_id UNINDEXED,
                    kind UNINDEXED,
                    title,
                    subtitle,
                    type_label,
                    object_name UNINDEXED,
                    object_label UNINDEXED,
                    object_plural UNINDEXED,
                    url UNINDEXED,
                    tokenize = 'unicode61 remove_diacritics 2'
                );
                """)
            if let found = try meta("org_id") {
                guard found == orgID else {
                    throw FTSRecordCacheError.wrongOrg(expected: orgID, found: found)
                }
            } else {
                try setMeta("org_id", orgID)
            }
        } catch {
            sqlite3_close(handle)
            self.db = nil
            throw error
        }
    }

    deinit { if let db { sqlite3_close(db) } }

    public static func fileURL(directory: URL, orgID: String) -> URL {
        let safe = orgID.map { $0.isLetter || $0.isNumber ? $0 : "_" }.reduce(into: "") { $0.append($1) }
        return directory.appendingPathComponent("fts-\(safe).sqlite")
    }

    public static func removeFile(directory: URL, orgID: String) {
        try? FileManager.default.removeItem(at: fileURL(directory: directory, orgID: orgID))
    }

    public func replace(_ records: [Record]) throws {
        lock.lock()
        defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE")
        do {
            try exec("DELETE FROM records")
            for record in records { try insert(record) }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        memory = RecordStore(records: records)
        loaded = true
    }

    public func records() throws -> [Record] {
        try ensureLoaded()
        return memory.records
    }

    /// Fuzzy search over the rows stored for this org. Same ranking as `RecordStore`.
    public func search(_ query: String, limit: Int? = nil) throws -> [Record] {
        try ensureLoaded()
        return memory.search(query, limit: limit)
    }

    /// FTS5 prefix query. `"acme"*` matches Acme; it does not typo-match.
    public func matchingIDs(prefix: String) throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let token = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return [] }
        let query = "\"" + token.replacingOccurrences(of: "\"", with: "\"\"") + "\"*"
        let sql = "SELECT record_id FROM records WHERE records MATCH ? ORDER BY rank"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw FTSRecordCacheError.sql(message())
        }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, query)
        var ids: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let c = sqlite3_column_text(statement, 0) { ids.append(String(cString: c)) }
        }
        return ids
    }

    private func ensureLoaded() throws {
        lock.lock()
        defer { lock.unlock() }
        if loaded { return }
        var statement: OpaquePointer?
        let sql = "SELECT record_id, kind, title, subtitle, type_label, object_name, object_label, object_plural, url FROM records"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw FTSRecordCacheError.sql(message())
        }
        defer { sqlite3_finalize(statement) }
        var rows: [Record] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = text(statement, 0)
            let kind = RecordKind(rawValue: text(statement, 1)) ?? .other
            let objectName = optionalText(statement, 5)
            let objectLabel = optionalText(statement, 6)
            let objectPlural = optionalText(statement, 7)
            let urlString = optionalText(statement, 8)
            rows.append(Record(
                id: id,
                kind: kind,
                title: text(statement, 2),
                subtitle: text(statement, 3),
                url: urlString.flatMap(URL.init(string:)),
                objectName: objectName,
                objectLabel: objectLabel,
                objectPlural: objectPlural
            ))
        }
        memory = RecordStore(records: rows)
        loaded = true
    }

    private func insert(_ record: Record) throws {
        let sql = """
            INSERT INTO records (record_id, kind, title, subtitle, type_label, object_name, object_label, object_plural, url)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw FTSRecordCacheError.sql(message())
        }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, record.id)
        bind(statement, 2, record.kind.rawValue)
        bind(statement, 3, record.title)
        bind(statement, 4, record.subtitle)
        bind(statement, 5, record.typeLabel)
        bind(statement, 6, record.objectName ?? "")
        bind(statement, 7, record.objectLabel ?? "")
        bind(statement, 8, record.objectPlural ?? "")
        bind(statement, 9, record.url?.absoluteString ?? "")
        guard sqlite3_step(statement) == SQLITE_DONE else { throw FTSRecordCacheError.sql(message()) }
    }

    private func meta(_ key: String) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = ?", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw FTSRecordCacheError.sql(message()) }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, key)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return text(statement, 0)
    }

    private func setMeta(_ key: String, _ value: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO meta (key, value) VALUES (?, ?)", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw FTSRecordCacheError.sql(message()) }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, key)
        bind(statement, 2, value)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw FTSRecordCacheError.sql(message()) }
    }

    private func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &error)
        if rc != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? self.message()
            sqlite3_free(error)
            throw FTSRecordCacheError.sql(message)
        }
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
        let destructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, destructor) }
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let c = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: c)
    }

    private func optionalText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        let value = text(statement, index)
        return value.isEmpty ? nil : value
    }

    private func message() -> String {
        guard let db else { return "sqlite" }
        return String(cString: sqlite3_errmsg(db))
    }
}
