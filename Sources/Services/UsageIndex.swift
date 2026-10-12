import Foundation
import SQLite3

/// Token totals for any slice of recorded requests.
struct TokenTotals: Hashable, Sendable {
    var input: Int64 = 0
    var output: Int64 = 0
    var cacheRead: Int64 = 0
    var cacheCreation: Int64 = 0
    var requests: Int64 = 0

    /// Every token the API reported: input + output + cache reads + cache writes.
    var total: Int64 { input + output + cacheRead + cacheCreation }

    static func + (lhs: TokenTotals, rhs: TokenTotals) -> TokenTotals {
        TokenTotals(input: lhs.input + rhs.input, output: lhs.output + rhs.output, cacheRead: lhs.cacheRead + rhs.cacheRead,
                    cacheCreation: lhs.cacheCreation + rhs.cacheCreation, requests: lhs.requests + rhs.requests)
    }

    static func += (lhs: inout TokenTotals, rhs: TokenTotals) { lhs = lhs + rhs }
}

/// One aggregated slot: 15 minutes of one profile and one model.
struct UsageSlot: Hashable, Sendable {
    var slotStart: Date
    var profileID: UUID
    var model: String
    var totals: TokenTotals
}

enum UsageIndexError: Error, LocalizedError {
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case let .sqlite(message): "Usage index error: \(message)"
        }
    }
}

/// Persistent, incremental index of per-request token usage recorded by Claude Code in each
/// profile's conversation files (`<configDir>/projects/**/*.jsonl`).
///
/// Compliance: lines are pre-filtered to assistant entries carrying `usage`, then decoded through
/// `UsageLine`, which declares only the request identifiers, timestamp, model and the four token
/// counts. Message content, prompts, tool calls and paths are never declared, so never decoded or
/// stored. The index (`usage-index.sqlite`, 0600) holds only those numbers.
///
/// Deduplication: Claude Code writes one line per content block of a response, each repeating the
/// same `usage`, and a resumed or forked conversation can carry earlier responses into a new file.
/// While a response streams, Claude Code may also write an early copy with a partial
/// `output_tokens` and later the final one (seen on ~20% of responses). Rows are keyed by
/// `message.id` + `requestId`, so every API response counts once across files and profiles, with
/// each counter at its largest (final) value and the earliest recorded time, independent of scan order.
actor UsageIndex {
    static let slotSeconds: Double = 15 * 60
    /// Two 30-day periods (current + previous) plus slack.
    static let retention: TimeInterval = 62 * 86_400

    struct ScanReport: Sendable {
        var filesScanned = 0
        var linesRead = 0
        var requestsAdded = 0
        var bytesRead: Int64 = 0
    }

    /// Closes the connection when the index goes away. Only ever used from the actor.
    private final class Connection: @unchecked Sendable {
        let pointer: OpaquePointer
        init(_ pointer: OpaquePointer) { self.pointer = pointer }
        deinit { sqlite3_close(pointer) }
    }

    private let connection: Connection
    private var db: OpaquePointer? { connection.pointer }
    let url: URL

    init(url: URL) throws {
        self.url = url
        try AtomicFile.ensureDirectory(url.deletingLastPathComponent(), permissions: 0o700)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw UsageIndexError.sqlite(message)
        }
        chmod(url.path, 0o600)
        connection = Connection(handle)
        try Self.exec(handle, """
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=NORMAL;
            CREATE TABLE IF NOT EXISTS files(
                path TEXT PRIMARY KEY, profile_id TEXT NOT NULL, inode INTEGER NOT NULL,
                size INTEGER NOT NULL, mtime REAL NOT NULL, offset INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS requests(
                dedup_key TEXT PRIMARY KEY, profile_id TEXT NOT NULL, ts REAL NOT NULL, model TEXT NOT NULL,
                input INTEGER NOT NULL, output INTEGER NOT NULL, cache_read INTEGER NOT NULL, cache_creation INTEGER NOT NULL
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS requests_ts ON requests(ts);
            """)
    }

    // MARK: Scanning

    /// Indexes everything appended since the last scan, for every profile.
    func scan(profiles: [(id: UUID, projects: URL)], now: Date = Date(), progress: (@Sendable (Int, Int) -> Void)? = nil) throws -> ScanReport {
        var report = ScanReport()
        let cutoff = now.addingTimeInterval(-Self.retention)
        var work: [(UUID, URL, FileStat)] = []
        for profile in profiles {
            for file in Self.conversationFiles(under: profile.projects) {
                guard let stat = FileStat(file), stat.mtime >= cutoff.timeIntervalSince1970 else { continue }
                work.append((profile.id, file, stat))
            }
        }
        for (index, item) in work.enumerated() {
            progress?(index, work.count)
            try scanFile(item.1, profileID: item.0, stat: item.2, cutoff: cutoff, report: &report)
        }
        progress?(work.count, work.count)
        try prune(before: cutoff)
        return report
    }

    /// Marks copied conversation files as already indexed up to `size`, so only lines appended after
    /// a handoff count toward the target profile.
    func markIndexed(_ files: [(url: URL, size: Int64)], profileID: UUID) throws {
        for file in files {
            guard let stat = FileStat(file.url) else { continue }
            try upsertFile(path: Self.canonicalPath(file.url), profileID: profileID, stat: stat, offset: min(file.size, stat.size))
        }
    }

    private func scanFile(_ url: URL, profileID: UUID, stat: FileStat, cutoff: Date, report: inout ScanReport) throws {
        let path = Self.canonicalPath(url)
        var offset: Int64 = 0
        if let known = try fileRow(path) {
            if known.inode == stat.inode, known.size == stat.size, known.mtime == stat.mtime { return }
            // Same file grew: continue where we stopped. Replaced or truncated: start over (dedup protects).
            if known.inode == stat.inode, stat.size >= known.offset { offset = known.offset }
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        report.filesScanned += 1

        try Self.exec(db, "BEGIN IMMEDIATE")
        do {
            let insert = try prepare("""
                INSERT INTO requests(dedup_key, profile_id, ts, model, input, output, cache_read, cache_creation)
                VALUES(?,?,?,?,?,?,?,?)
                ON CONFLICT(dedup_key) DO UPDATE SET
                    profile_id = CASE WHEN excluded.ts < requests.ts THEN excluded.profile_id ELSE requests.profile_id END,
                    ts = MIN(requests.ts, excluded.ts),
                    input = MAX(requests.input, excluded.input),
                    output = MAX(requests.output, excluded.output),
                    cache_read = MAX(requests.cache_read, excluded.cache_read),
                    cache_creation = MAX(requests.cache_creation, excluded.cache_creation)
                WHERE excluded.ts < requests.ts OR excluded.input > requests.input OR excluded.output > requests.output
                    OR excluded.cache_read > requests.cache_read OR excluded.cache_creation > requests.cache_creation
                """)
            defer { sqlite3_finalize(insert) }
            var carry = Data()
            var consumed = offset
            let profile = profileID.uuidString
            while true {
                let chunk = try handle.read(upToCount: 4 << 20) ?? Data()
                if chunk.isEmpty { break }
                report.bytesRead += Int64(chunk.count)
                var buffer = carry
                buffer.append(chunk)
                guard let lastNewline = buffer.lastIndex(of: 0x0A) else { carry = buffer; continue }
                let complete = buffer[buffer.startIndex...lastNewline]
                carry = Data(buffer[buffer.index(after: lastNewline)...])
                consumed += Int64(complete.count)
                for line in complete.split(separator: 0x0A, omittingEmptySubsequences: true) {
                    report.linesRead += 1
                    guard let record = UsageLine.record(from: line), record.timestamp >= cutoff.timeIntervalSince1970 else { continue }
                    sqlite3_reset(insert)
                    Self.bind(insert, 1, record.dedupKey)
                    Self.bind(insert, 2, profile)
                    sqlite3_bind_double(insert, 3, record.timestamp)
                    Self.bind(insert, 4, record.model)
                    sqlite3_bind_int64(insert, 5, record.input)
                    sqlite3_bind_int64(insert, 6, record.output)
                    sqlite3_bind_int64(insert, 7, record.cacheRead)
                    sqlite3_bind_int64(insert, 8, record.cacheCreation)
                    guard sqlite3_step(insert) == SQLITE_DONE else { throw UsageIndexError.sqlite(errorMessage) }
                    if sqlite3_changes(db) > 0 { report.requestsAdded += 1 }
                }
            }
            // A trailing line without a newline is still being written; it is read next time.
            try upsertFile(path: path, profileID: profileID, stat: stat, offset: consumed)
            try Self.exec(db, "COMMIT")
        } catch {
            try? Self.exec(db, "ROLLBACK")
            throw error
        }
    }

    private func prune(before cutoff: Date) throws {
        let statement = try prepare("DELETE FROM requests WHERE ts < ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw UsageIndexError.sqlite(errorMessage) }
    }

    /// Forgets files of profiles that no longer exist, and their requests.
    func removeProfile(_ id: UUID) throws {
        for sql in ["DELETE FROM requests WHERE profile_id = ?", "DELETE FROM files WHERE profile_id = ?"] {
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            Self.bind(statement, 1, id.uuidString)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw UsageIndexError.sqlite(errorMessage) }
        }
    }

    // MARK: Querying

    /// 15-minute slots in `[start, end)`, per profile and model.
    func slots(from start: Date, to end: Date) throws -> [UsageSlot] {
        let statement = try prepare("""
            SELECT CAST(ts / \(Int(Self.slotSeconds)) AS INTEGER) AS slot, profile_id, model,
                   SUM(input), SUM(output), SUM(cache_read), SUM(cache_creation), COUNT(*)
            FROM requests WHERE ts >= ? AND ts < ?
            GROUP BY slot, profile_id, model
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, end.timeIntervalSince1970)
        var result: [UsageSlot] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let profileText = sqlite3_column_text(statement, 1), let modelText = sqlite3_column_text(statement, 2),
                  let profile = UUID(uuidString: String(cString: profileText)) else { continue }
            result.append(UsageSlot(
                slotStart: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 0)) * Self.slotSeconds),
                profileID: profile,
                model: String(cString: modelText),
                totals: TokenTotals(input: sqlite3_column_int64(statement, 3), output: sqlite3_column_int64(statement, 4),
                                    cacheRead: sqlite3_column_int64(statement, 5), cacheCreation: sqlite3_column_int64(statement, 6),
                                    requests: sqlite3_column_int64(statement, 7))
            ))
        }
        return result
    }

    /// Exact totals for `[start, end)`, optionally filtered.
    func totals(from start: Date, to end: Date, profiles: Set<UUID>? = nil, models: Set<String>? = nil) throws -> TokenTotals {
        var sql = "SELECT SUM(input), SUM(output), SUM(cache_read), SUM(cache_creation), COUNT(*) FROM requests WHERE ts >= ? AND ts < ?"
        if let profiles { sql += " AND profile_id IN (\(profiles.map { _ in "?" }.joined(separator: ",")))" }
        if let models { sql += " AND model IN (\(models.map { _ in "?" }.joined(separator: ",")))" }
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, end.timeIntervalSince1970)
        var index: Int32 = 3
        for id in profiles ?? [] { Self.bind(statement, index, id.uuidString); index += 1 }
        for model in models ?? [] { Self.bind(statement, index, model); index += 1 }
        guard sqlite3_step(statement) == SQLITE_ROW else { return TokenTotals() }
        return TokenTotals(input: sqlite3_column_int64(statement, 0), output: sqlite3_column_int64(statement, 1),
                           cacheRead: sqlite3_column_int64(statement, 2), cacheCreation: sqlite3_column_int64(statement, 3),
                           requests: sqlite3_column_int64(statement, 4))
    }

    func indexedFileCount() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM files")
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }

    func oldestRequest() throws -> Date? {
        let statement = try prepare("SELECT MIN(ts) FROM requests")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
    }

    // MARK: Files table

    private struct FileRow { var inode: UInt64; var size: Int64; var mtime: Double; var offset: Int64 }

    private func fileRow(_ path: String) throws -> FileRow? {
        let statement = try prepare("SELECT inode, size, mtime, offset FROM files WHERE path = ?")
        defer { sqlite3_finalize(statement) }
        Self.bind(statement, 1, path)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return FileRow(inode: UInt64(bitPattern: sqlite3_column_int64(statement, 0)), size: sqlite3_column_int64(statement, 1),
                       mtime: sqlite3_column_double(statement, 2), offset: sqlite3_column_int64(statement, 3))
    }

    private func upsertFile(path: String, profileID: UUID, stat: FileStat, offset: Int64) throws {
        let statement = try prepare("""
            INSERT INTO files(path, profile_id, inode, size, mtime, offset) VALUES(?,?,?,?,?,?)
            ON CONFLICT(path) DO UPDATE SET profile_id=excluded.profile_id, inode=excluded.inode,
                size=excluded.size, mtime=excluded.mtime, offset=excluded.offset
            """)
        defer { sqlite3_finalize(statement) }
        Self.bind(statement, 1, path)
        Self.bind(statement, 2, profileID.uuidString)
        sqlite3_bind_int64(statement, 3, Int64(bitPattern: stat.inode))
        // A file that grew past `offset` keeps its old size so the next scan reads the remainder.
        sqlite3_bind_int64(statement, 4, offset < stat.size ? offset : stat.size)
        sqlite3_bind_double(statement, 5, stat.mtime)
        sqlite3_bind_int64(statement, 6, offset)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw UsageIndexError.sqlite(errorMessage) }
    }

    // MARK: Helpers

    /// One spelling per file (e.g. /var vs /private/var, symlinked profile folders).
    static func canonicalPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func conversationFiles(under projects: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: projects, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            files.append(url)
        }
        return files
    }

    private var errorMessage: String { db.map { String(cString: sqlite3_errmsg($0)) } ?? "closed" }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw UsageIndexError.sqlite(errorMessage) }
        return statement
    }

    private static func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(error)
            throw UsageIndexError.sqlite(message)
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func bind(_ statement: OpaquePointer?, _ index: Int32, _ text: String) {
        sqlite3_bind_text(statement, index, text, -1, transient)
    }
}

/// Size, inode and modification time of a file.
struct FileStat: Sendable {
    var size: Int64
    var inode: UInt64
    var mtime: Double

    init?(_ url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        size = Int64(info.st_size)
        inode = UInt64(info.st_ino)
        mtime = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
    }
}

/// The only part of a conversation line that is ever decoded.
struct UsageLine: Decodable {
    struct Message: Decodable {
        struct Usage: Decodable {
            let input_tokens: Int64?
            let output_tokens: Int64?
            let cache_creation_input_tokens: Int64?
            let cache_read_input_tokens: Int64?
        }

        let id: String?
        let model: String?
        let usage: Usage?
    }

    let type: String?
    let timestamp: String?
    let requestId: String?
    let uuid: String?
    let message: Message?

    struct Record: Equatable {
        var dedupKey: String
        var timestamp: Double
        var model: String
        var input: Int64
        var output: Int64
        var cacheRead: Int64
        var cacheCreation: Int64
    }

    private static let assistantMarker = Array(#""type":"assistant""#.utf8)
    private static let usageMarker = Array(#""usage""#.utf8)

    /// Cheap byte-level pre-filter, then a narrow decode. Nil for anything that isn't a billed response.
    static func record(from line: Data.SubSequence) -> Record? {
        guard contains(line, assistantMarker), contains(line, usageMarker),
              let decoded = try? JSONDecoder().decode(UsageLine.self, from: Data(line)),
              decoded.type == "assistant",
              let message = decoded.message, let usage = message.usage,
              let stamp = decoded.timestamp, let time = parseTimestamp(stamp) else { return nil }
        let model = message.model ?? "unknown"
        // Claude Code writes locally generated notices as "<synthetic>" responses with no usage.
        if model == "<synthetic>" { return nil }
        let input = max(0, usage.input_tokens ?? 0)
        let output = max(0, usage.output_tokens ?? 0)
        let cacheRead = max(0, usage.cache_read_input_tokens ?? 0)
        let cacheCreation = max(0, usage.cache_creation_input_tokens ?? 0)
        if input + output + cacheRead + cacheCreation == 0 { return nil }
        let key: String
        if let id = message.id, let request = decoded.requestId {
            key = "\(id):\(request)"
        } else if let id = message.id {
            key = id
        } else if let uuid = decoded.uuid {
            key = "line:\(uuid)"
        } else {
            return nil
        }
        return Record(dedupKey: String(key.prefix(200)), timestamp: time, model: String(model.prefix(80)),
                      input: input, output: output, cacheRead: cacheRead, cacheCreation: cacheCreation)
    }

    private static func contains(_ haystack: Data.SubSequence, _ needle: [UInt8]) -> Bool {
        haystack.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            return needle.withUnsafeBytes { n in memmem(base, raw.count, n.baseAddress, n.count) != nil }
        }
    }

    /// ISO 8601 in UTC as written by Claude Code: `2026-10-11T06:13:59.592Z` (fraction optional).
    static func parseTimestamp(_ text: String) -> Double? {
        let utf8 = Array(text.utf8)
        func number(_ range: Range<Int>) -> Int? {
            guard range.upperBound <= utf8.count else { return nil }
            var value = 0
            for byte in utf8[range] {
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }
        guard utf8.count >= 20, utf8[4] == 45, utf8[7] == 45, utf8[10] == 84, utf8[13] == 58, utf8[16] == 58,
              let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61 else {
            return (try? Date(text, strategy: .iso8601))?.timeIntervalSince1970
        }
        var fraction = 0.0
        var index = 19
        if index < utf8.count, utf8[index] == 46 {
            index += 1
            var scale = 0.1
            while index < utf8.count, utf8[index] >= 48, utf8[index] <= 57 {
                fraction += Double(utf8[index] - 48) * scale
                scale /= 10
                index += 1
            }
        }
        guard index < utf8.count, utf8[index] == 90 else {
            return (try? Date(text, strategy: .iso8601))?.timeIntervalSince1970
        }
        // Days from civil (Howard Hinnant's algorithm), UTC.
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        return Double(days * 86_400 + hour * 3_600 + minute * 60 + second) + fraction
    }
}
