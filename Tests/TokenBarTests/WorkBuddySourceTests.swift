import XCTest
@testable import TokenBar

final class WorkBuddySourceTests: XCTestCase {
    /// WorkBuddy attaches per-call usage to `function_call` lines via a clean
    /// `message.usage` object whose `input_tokens` is cache-INCLUSIVE
    /// (OpenAI-style). The source must subtract the cache to yield fresh input,
    /// read the unix-millisecond timestamp, and take the model from
    /// providerData.
    func testFunctionCallUsageIsParsedAndCacheSubtracted() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tokenbar-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let progress = SourceProgress(storeURL: tmp.appendingPathComponent("progress.json"))
        let home = tmp.appendingPathComponent("home")
        let projDir = home.appendingPathComponent(".workbuddy/projects/ws")
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)
        let session = projDir.appendingPathComponent("s1.jsonl")

        // input_tokens 28409 includes cached 17856 -> fresh uncached 10553.
        let call = #"{"id":"m1","type":"function_call","timestamp":1785381222426,"providerData":{"messageId":"m1","model":"glm-5.2"},"message":{"usage":{"input_tokens":28409,"output_tokens":300,"total_tokens":28709,"cache_read_input_tokens":17856}}}"#
        // A non-usage line and a user message must be ignored.
        let noise = #"{"id":"x","type":"reasoning","timestamp":1785381222000}"#
        try ([noise, call].map { $0 + "\n" }.joined()).write(to: session, atomically: true, encoding: .utf8)

        let src = WorkBuddySource(home: home, progress: progress)
        let r = try await src.collect()
        XCTAssertEqual(r.samples.count, 1)
        let s = r.samples[0]
        XCTAssertEqual(s.inputTokens, 10553, "input_tokens is cache-inclusive; cache must be subtracted")
        XCTAssertEqual(s.cacheReadTokens, 17856)
        XCTAssertEqual(s.outputTokens, 300)
        XCTAssertEqual(s.model, "glm-5.2")
        XCTAssertEqual(s.tool, .workbuddy)
    }

    /// Parallel tool calls from one API turn repeat the same providerData
    /// messageId and the same usage; the call must be counted once.
    func testParallelToolCallsSharingMessageIdCountOnce() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tokenbar-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let progress = SourceProgress(storeURL: tmp.appendingPathComponent("progress.json"))
        let home = tmp.appendingPathComponent("home")
        let projDir = home.appendingPathComponent(".workbuddy/projects/ws")
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)
        let session = projDir.appendingPathComponent("s1.jsonl")

        let usage = #""message":{"usage":{"input_tokens":1000,"output_tokens":50,"total_tokens":1050,"cache_read_input_tokens":0}}"#
        let callA = "{\"id\":\"a\",\"type\":\"function_call\",\"timestamp\":1785381222426,\"providerData\":{\"messageId\":\"same\",\"model\":\"glm-5.2\"},\(usage)}"
        let callB = "{\"id\":\"b\",\"type\":\"function_call\",\"timestamp\":1785381222427,\"providerData\":{\"messageId\":\"same\",\"model\":\"glm-5.2\"},\(usage)}"
        try ([callA, callB].map { $0 + "\n" }.joined()).write(to: session, atomically: true, encoding: .utf8)

        let src = WorkBuddySource(home: home, progress: progress)
        let r = try await src.collect()
        XCTAssertEqual(r.samples.count, 1, "two function_calls sharing a messageId are one API call")
        XCTAssertEqual(r.samples[0].inputTokens, 1000)
    }
}
