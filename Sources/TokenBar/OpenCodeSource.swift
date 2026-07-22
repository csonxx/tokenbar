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

    init(home: URL, progress: SourceProgress) {
        self.home = home
        self.progress = progress
        self.messageCursor = Self.sharedCursor
    }

    func collect() async throws -> SourceResult {
        let dbURL = home.appendingPathComponent(".local/share/opencode/opencode.db")
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            return SourceResult.empty(note: "OpenCode 数据库 (~/.local/share/opencode/opencode.db) 不存在")
        }

        let lastSeenID = await messageCursor.loadLastMessageID()
        let firstScan = (lastSeenID == nil)

        guard let db = openDatabase(dbURL) else {
            return SourceResult.empty(note: "无法打开 OpenCode 数据库")
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT id, time_created, data
        FROM message
        WHERE json_extract(data, '$.role') = 'assistant'
        ORDER BY id ASC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return SourceResult(samples: [], fileCount: 1,
                                note: "OpenCode 查询失败: \(lastError(db))")
        }
        defer { sqlite3_finalize(stmt) }

        var samples: [TokenSample] = []
        var newLastID = lastSeenID

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            if !firstScan, let lastSeenID, id <= lastSeenID { continue }

            let timeMs = sqlite3_column_int64(stmt, 1)
            let dataCStr = sqlite3_column_text(stmt, 2)
            let data = dataCStr.flatMap { String(cString: $0) } ?? ""

            guard let sample = parseMessage(timeMs: timeMs, data: data) else { continue }
            samples.append(sample)
            newLastID = id
        }

        // Persist cursor.
        if let newLastID {
            await messageCursor.saveLastMessageID(newLastID)
        }

        let note: String?
        if !FileManager.default.fileExists(atPath: dbURL.path) {
            note = "OpenCode 数据库不存在"
        } else if samples.isEmpty && !firstScan {
            note = "OpenCode 没有新增消息"
        } else {
            note = nil
        }
        return SourceResult(samples: samples, fileCount: 1, note: note)
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

/// Persists the highest-seen OpenCode message id as a simple JSON file.
/// Keyed by a single global cursor (we only ever scan forward; the message
/// table is append-only in practice).
actor OpenCodeMessageCursor {
    private var loaded = false
    private var lastMessageID: String?

    private var url: URL {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                    in: .userDomainMask,
                                                    appropriateFor: nil,
                                                    create: true))
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("TokenBar/opencode_message_cursor.json")
    }

    func loadLastMessageID() -> String? {
        ensureLoaded()
        return lastMessageID
    }

    func saveLastMessageID(_ id: String) {
        ensureLoaded()
        lastMessageID = id
        let payload = ["lastMessageID": id]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    func reset() {
        lastMessageID = nil
        loaded = false
        try? FileManager.default.removeItem(at: url)
    }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: url),
           let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let v = payload["lastMessageID"] as? String {
            lastMessageID = v
        }
    }
}
