import Foundation
import SQLite3

/// OpenCode stores its data in a local SQLite database at
/// `~/.local/share/opencode/opencode.db`. The `message` table holds *per-message*
/// token records (tokens.input / output / reasoning / cache.read / cache.write)
/// along with a unix-millisecond `time_created` and the assistant's model info.
///
/// We previously read the `session` table which held cumulative per-session
/// counters — that lumped a session's entire cache_read into its `time_updated`
/// day, producing multi-million-token days that didn't match real usage. The
/// message table gives us per-message granularity: one sample per assistant
/// turn, with the actual timestamp.
final class OpenCodeSource: TokenSource {
    let tool: ToolKind = .opencode
    private let home: URL
    private let progress: SourceProgress
    private let messageCursor: OpenCodeMessageCursor

    static let sharedCursor = OpenCodeMessageCursor()

    init(home: URL, progress: SourceProgress, cursor: OpenCodeMessageCursor? = nil) {
        self.home = home
        self.progress = progress
        self.messageCursor = cursor ?? Self.sharedCursor
    }

    func collect() async throws -> SourceResult {
        let dbURL = home.appendingPathComponent(".local/share/opencode/opencode.db")
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            return SourceResult.empty(note: "OpenCode 数据库 (~/.local/share/opencode/opencode.db) 不存在")
        }

        guard let db = openDatabase(dbURL) else {
            return SourceResult.empty(note: "无法打开 OpenCode 数据库")
        }
        defer { sqlite3_close(db) }

        // Cursor is keyed on `time_created` (a unix-ms timestamp), NOT the
        // message id. OpenCode's message ids are not lexicographically
        // monotonic over time - their prefix wrapped around between late July
        // and August (ids went from "msg_f92..." to "msg_042..."), so the old
        // "skip id <= lastSeenId" logic silently stopped ingesting anything
        // new for over a month once the wrap happened. Timestamps don't wrap.
        let (pos, legacyId) = await messageCursor.load()
        var seedTime: Int64 = -1
        var seedId = ""
        var firstScan = false
        if let pos {
            seedTime = pos.time
            seedId = pos.id
        } else if let legacyId, let t = timeCreated(db, forID: legacyId) {
            // Migrate a pre-time-based cursor: resume from the timestamp of
            // the last id it recorded, so already-ingested rows aren't
            // recounted and the backlog since then is picked up.
            seedTime = t
            seedId = legacyId
        } else {
            firstScan = true
        }

        // Tie-break on id at the exact same millisecond so we neither skip nor
        // repeat rows that share a `time_created`.
        let sql = """
        SELECT id, time_created, data
        FROM message
        WHERE json_extract(data, '$.role') = 'assistant'
          AND (time_created > ?1 OR (time_created = ?1 AND id > ?2))
        ORDER BY time_created ASC, id ASC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return SourceResult(samples: [], fileCount: 1,
                                note: "OpenCode 查询失败: \(lastError(db))")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, seedTime)
        sqlite3_bind_text(stmt, 2, seedId, -1, Self.sqliteTransient)

        var samples: [TokenSample] = []
        var newTime: Int64? = nil
        var newId: String? = nil

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let timeMs = sqlite3_column_int64(stmt, 1)
            let dataCStr = sqlite3_column_text(stmt, 2)
            let data = dataCStr.flatMap { String(cString: $0) } ?? ""
            // Advance the cursor past every row we step, even ones that
            // don't parse into a sample (zero-token / malformed), so they
            // aren't rescanned forever.
            newTime = timeMs
            newId = id

            guard let sample = parseMessage(timeMs: timeMs, data: data) else { continue }
            samples.append(sample)
        }

        if let newTime, let newId {
            await messageCursor.save(time: newTime, id: newId)
        }

        let note: String?
        if samples.isEmpty && !firstScan {
            note = "OpenCode 没有新增消息"
        } else {
            note = nil
        }
        return SourceResult(samples: samples, fileCount: 1, note: note)
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Looks up a single message's `time_created`, used once to migrate a
    /// legacy id-only cursor onto the timestamp-based cursor.
    private func timeCreated(_ db: OpaquePointer?, forID id: String) -> Int64? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT time_created FROM message WHERE id = ? LIMIT 1", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, Self.sqliteTransient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    private func parseMessage(timeMs: Int64, data: String) -> TokenSample? {
        guard let dict = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] else {
            return nil
        }
        let tokens = dict["tokens"] as? [String: Any]
        let input = (tokens?["input"] as? Int) ?? 0
        let output = (tokens?["output"] as? Int) ?? 0
        let reasoning = (tokens?["reasoning"] as? Int) ?? 0
        let cache = tokens?["cache"] as? [String: Any]
        let cacheRead = (cache?["read"] as? Int) ?? 0
        let cacheWrite = (cache?["write"] as? Int) ?? 0

        if input == 0 && output == 0 && cacheRead == 0 && cacheWrite == 0 { return nil }

        let modelID = (dict["modelID"] as? String) ?? "opencode"
        let providerID = (dict["providerID"] as? String) ?? "unknown"
        let model = "\(providerID)/\(modelID)"

        let ts = Date(timeIntervalSince1970: Double(timeMs) / 1000.0)

        return TokenSample(
            tool: .opencode,
            model: model,
            timestamp: ts,
            inputTokens: input,
            outputTokens: output,
            reasoningTokens: reasoning,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite
        )
    }

    private func openDatabase(_ url: URL) -> OpaquePointer? {
        var db: OpaquePointer?
        if sqlite3_open(url.path, &db) != SQLITE_OK { return nil }
        return db
    }

    private func lastError(_ db: OpaquePointer?) -> String {
        guard let db, let cstr = sqlite3_errmsg(db) else { return "unknown" }
        return String(cString: cstr)
    }
}

/// Persists how far the OpenCode scan has advanced, as a `time_created`
/// timestamp plus the id at that timestamp for tie-breaking. We only ever
/// scan forward; the message table is append-only in practice.
///
/// Earlier versions stored only the last message id and compared ids
/// lexicographically - that broke permanently once OpenCode's id prefix
/// wrapped, since new ids sorted *before* the stored one. A legacy id-only
/// cursor is migrated to the timestamp form on first load (see `collect`).
actor OpenCodeMessageCursor {
    struct Position: Sendable { var time: Int64; var id: String }

    private var loaded = false
    private var position: Position?
    private var legacyId: String?
    private let overrideURL: URL?

    init(storeURL: URL? = nil) {
        self.overrideURL = storeURL
    }

    private var url: URL {
        if let overrideURL { return overrideURL }
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                    in: .userDomainMask,
                                                    appropriateFor: nil,
                                                    create: true))
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("TokenBar/opencode_message_cursor.json")
    }

    /// Returns the current timestamp cursor, and - only when no timestamp
    /// cursor has been written yet - any legacy id-only value to migrate from.
    func load() -> (position: Position?, legacyId: String?) {
        ensureLoaded()
        return (position, legacyId)
    }

    func save(time: Int64, id: String) {
        ensureLoaded()
        position = Position(time: time, id: id)
        legacyId = nil
        let payload: [String: Any] = ["lastTime": time, "lastId": id]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    func reset() {
        position = nil
        legacyId = nil
        loaded = false
        try? FileManager.default.removeItem(at: url)
    }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        if let t = (payload["lastTime"] as? NSNumber)?.int64Value,
           let id = payload["lastId"] as? String {
            position = Position(time: t, id: id)
        } else if let old = payload["lastMessageID"] as? String {
            legacyId = old
        }
    }
}
