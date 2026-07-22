import XCTest
@testable import TokenBar

final class ClaudeCodeSourceTests: XCTestCase {
    private func line(id: String, ts: String, input: Int, output: Int, cacheRead: Int, cacheWrite: Int) -> String {
        #"{"type":"assistant","timestamp":"\#(ts)","message":{"id":"\#(id)","model":"claude-sonnet-4-5","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":\#(cacheRead),"cache_creation_input_tokens":\#(cacheWrite)}}}"#
    }

    /// One real API call is written out as several `assistant` lines (one per
    /// content block) that share the same `message.id` and an identical
    /// `usage` object. Counting every line would inflate usage 3-4x.
    func testDuplicateContentBlockLinesCountOnce() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tokenbar-test-\(UUID().uuidString)")
        let home = tmp.appendingPathComponent("home")
        let projectDir = home.appendingPathComponent(".claude/projects/proj1")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let sessionURL = projectDir.appendingPathComponent("session.jsonl")

        let lines = [
            line(id: "msg_1", ts: "2026-07-20T08:00:00Z", input: 100, output: 50, cacheRead: 20, cacheWrite: 10),
            line(id: "msg_1", ts: "2026-07-20T08:00:00Z", input: 100, output: 50, cacheRead: 20, cacheWrite: 10),
            line(id: "msg_1", ts: "2026-07-20T08:00:00Z", input: 100, output: 50, cacheRead: 20, cacheWrite: 10),
            line(id: "msg_2", ts: "2026-07-20T08:01:00Z", input: 200, output: 80, cacheRead: 30, cacheWrite: 5)
        ].joined(separator: "\n") + "\n"
        try lines.write(to: sessionURL, atomically: true, encoding: .utf8)

        let progress = SourceProgress(storeURL: tmp.appendingPathComponent("progress.json"))
        let src = ClaudeCodeSource(home: home, progress: progress)
        let r = try await src.collect()

        XCTAssertEqual(r.samples.count, 2, "repeated content-block lines for the same message must count once")
        XCTAssertEqual(r.samples[0].inputTokens, 100)
        XCTAssertEqual(r.samples[0].cacheReadTokens, 20)
        XCTAssertEqual(r.samples[1].inputTokens, 200)
        XCTAssertEqual(r.samples[1].cacheReadTokens, 30)
    }

    /// If a message's repeated content-block lines straddle two separate
    /// `collect()` calls (i.e. the first content block was read in one pass
    /// and a later one arrives in the next), the resumed read must recognize
    /// the message id it already counted and skip the repeat.
    func testResumeDoesNotDoubleCountStraddlingMessage() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tokenbar-test-\(UUID().uuidString)")
        let home = tmp.appendingPathComponent("home")
        let projectDir = home.appendingPathComponent(".claude/projects/proj1")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let sessionURL = projectDir.appendingPathComponent("session.jsonl")

        let firstBatch = [
            line(id: "msg_1", ts: "2026-07-20T08:00:00Z", input: 100, output: 50, cacheRead: 20, cacheWrite: 10),
            line(id: "msg_1", ts: "2026-07-20T08:00:00Z", input: 100, output: 50, cacheRead: 20, cacheWrite: 10)
        ].joined(separator: "\n") + "\n"
        try firstBatch.write(to: sessionURL, atomically: true, encoding: .utf8)

        let progress = SourceProgress(storeURL: tmp.appendingPathComponent("progress.json"))
        let src = ClaudeCodeSource(home: home, progress: progress)
        let r1 = try await src.collect()
        XCTAssertEqual(r1.samples.count, 1)
        XCTAssertEqual(r1.samples[0].inputTokens, 100)

        // A late-arriving repeat of msg_1's content block, followed by a
        // genuinely new message.
        let secondBatch = [
            line(id: "msg_1", ts: "2026-07-20T08:00:00Z", input: 100, output: 50, cacheRead: 20, cacheWrite: 10),
            line(id: "msg_2", ts: "2026-07-20T08:01:00Z", input: 200, output: 80, cacheRead: 30, cacheWrite: 5)
        ].joined(separator: "\n") + "\n"
        let handle = try FileHandle(forWritingTo: sessionURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(secondBatch.utf8))
        try handle.close()

        let r2 = try await src.collect()
        XCTAssertEqual(r2.samples.count, 1, "the straddling repeat of msg_1 must be skipped")
        XCTAssertEqual(r2.samples[0].inputTokens, 200)
    }
}
