import XCTest
import SQLite3
@testable import TokenBar

final class OpenCodeSourceTests: XCTestCase {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Builds a minimal OpenCode `message` table and inserts assistant rows.
    private func makeDB(at url: URL, rows: [(id: String, timeMs: Int64, input: Int, output: Int)]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "CREATE TABLE message (id TEXT, time_created INTEGER, data TEXT)", nil, nil, nil)
        for r in rows {
            let data = #"{"role":"assistant","tokens":{"input":\#(r.input),"output":\#(r.output),"cache":{"read":0,"write":0}},"modelID":"glm","providerID":"p"}"#
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO message (id,time_created,data) VALUES (?,?,?)", -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, r.id, -1, Self.transient)
            sqlite3_bind_int64(stmt, 2, r.timeMs)
            sqlite3_bind_text(stmt, 3, data, -1, Self.transient)
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
            sqlite3_finalize(stmt)
        }
    }

    /// Regression: OpenCode's message ids are not lexicographically monotonic
    /// over time - the prefix wrapped (July "msg_f92..." -> August "msg_042...")
    /// so a later message's id sorts BEFORE an earlier one's. The old
    /// id-comparison cursor stopped ingesting for over a month. A timestamp
    /// cursor must still pick up the newer (lexicographically smaller) row.
    func testNewerRowWithSmallerIdIsStillIngestedAfterCursorAdvances() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tokenbar-test-\(UUID().uuidString)")
        let home = tmp.appendingPathComponent("home")
        let dbURL = home.appendingPathComponent(".local/share/opencode/opencode.db")
        // July row (big id), then a later August row with a SMALLER id.
        let july: Int64 = 1_753_349_040_000  // ~2026-07-24
        let august: Int64 = 1_756_290_240_000 // ~2026-08-27
        makeDB(at: dbURL, rows: [
            (id: "msg_f92277cf2", timeMs: july, input: 100, output: 10),
            (id: "msg_042d2248d", timeMs: august, input: 200, output: 20)
        ])
        let progress = SourceProgress(storeURL: tmp.appendingPathComponent("progress.json"))
        let cursor = OpenCodeMessageCursor(storeURL: tmp.appendingPathComponent("oc_cursor.json"))
        let src = OpenCodeSource(home: home, progress: progress, cursor: cursor)

        // First scan ingests both.
        let r1 = try await src.collect()
        XCTAssertEqual(r1.samples.count, 2)

        // Append a THIRD, even-later row whose id is still lexicographically
        // smaller than the July cursor. It must be ingested, not skipped.
        makeDB(at: dbURL, rows: [
            (id: "msg_f92277cf2", timeMs: july, input: 100, output: 10),
            (id: "msg_042d2248d", timeMs: august, input: 200, output: 20),
            (id: "msg_042d30000", timeMs: august + 60_000, input: 300, output: 30)
        ])
        let r2 = try await src.collect()
        XCTAssertEqual(r2.samples.count, 1, "the newer row must be picked up despite a lexicographically smaller id")
        XCTAssertEqual(r2.samples.first?.outputTokens, 30)
    }

    /// A legacy id-only cursor migrates onto the timestamp cursor by resuming
    /// from that id's `time_created`, so already-counted rows aren't recounted
    /// and the backlog since then is picked up.
    func testLegacyIdCursorMigratesToTimestamp() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tokenbar-test-\(UUID().uuidString)")
        let home = tmp.appendingPathComponent("home")
        let dbURL = home.appendingPathComponent(".local/share/opencode/opencode.db")
        let july: Int64 = 1_753_349_040_000
        let august: Int64 = 1_756_290_240_000
        makeDB(at: dbURL, rows: [
            (id: "msg_f92277cf2", timeMs: july, input: 100, output: 10),
            (id: "msg_042d2248d", timeMs: august, input: 200, output: 20)
        ])
        // Seed a legacy id-only cursor pointing at the July message.
        let cursorURL = tmp.appendingPathComponent("oc_cursor.json")
        try Data(#"{"lastMessageID":"msg_f92277cf2"}"#.utf8).write(to: cursorURL)
        let progress = SourceProgress(storeURL: tmp.appendingPathComponent("progress.json"))
        let cursor = OpenCodeMessageCursor(storeURL: cursorURL)
        let src = OpenCodeSource(home: home, progress: progress, cursor: cursor)

        let r = try await src.collect()
        // Only the August row (after the July seed) should be ingested; the
        // July row must NOT be recounted.
        XCTAssertEqual(r.samples.count, 1)
        XCTAssertEqual(r.samples.first?.outputTokens, 20)
    }
}
