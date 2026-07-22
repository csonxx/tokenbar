import XCTest
@testable import TokenBar

final class SampleStoreTests: XCTestCase {
    /// Regression test for a bug where `refresh()`'s call order - `append()`
    /// for each source's new samples, then `loadAll()` to build the snapshot
    /// - poisoned the cache: `loadAll()` only read the on-disk file when its
    /// in-memory cache was still empty, but `append()` had already made it
    /// non-empty (with just the newly-appended batch). Every window
    /// (today/7d/30d/all) ended up showing that tiny batch instead of the
    /// real accumulated history.
    func testLoadAllAfterAppendReturnsBothOldAndNewSamples() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tokenbar-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let sample1 = TokenSample(tool: .codex, model: "gpt-5", timestamp: Date(timeIntervalSince1970: 0),
                                   inputTokens: 100, outputTokens: 50, reasoningTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0)
        let sample2 = TokenSample(tool: .codex, model: "gpt-5", timestamp: Date(),
                                   inputTokens: 200, outputTokens: 80, reasoningTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0)

        // Simulate "old history already on disk from a prior session": write
        // directly with a fresh store instance, independent of the one under
        // test below.
        let writer = SampleStore(directory: tmp)
        writer.append([sample1])

        // A brand-new store instance (as happens on every app launch/refresh
        // cycle) that appends a new sample *before* ever calling loadAll().
        let store = SampleStore(directory: tmp)
        store.append([sample2])
        let all = store.loadAll()

        XCTAssertEqual(all.count, 2, "loadAll() must return both the pre-existing on-disk sample and the newly-appended one")
        XCTAssertTrue(all.contains(sample1))
        XCTAssertTrue(all.contains(sample2))
    }

    func testLoadAllBeforeAppendStillSeesLaterAppends() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tokenbar-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let sample1 = TokenSample(tool: .codex, model: "gpt-5", timestamp: Date(timeIntervalSince1970: 0),
                                   inputTokens: 10, outputTokens: 5, reasoningTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0)
        let writer = SampleStore(directory: tmp)
        writer.append([sample1])

        let store = SampleStore(directory: tmp)
        XCTAssertEqual(store.loadAll().count, 1)

        let sample2 = TokenSample(tool: .codex, model: "gpt-5", timestamp: Date(),
                                   inputTokens: 20, outputTokens: 10, reasoningTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0)
        store.append([sample2])
        XCTAssertEqual(store.loadAll().count, 2)
    }
}
