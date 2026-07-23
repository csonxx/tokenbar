import XCTest
@testable import TokenBar

final class CodexSourceTests: XCTestCase {
    /// The very first time we see a rollout file, there is no prior baseline
    /// on disk, so the first token_count record's delta is measured against
    /// zero — i.e. it emits one sample equal to the record's absolute usage
    /// (with cache subtracted out of input). This matches the product
    /// decision to fully backfill history rather than silently swallow it.
    func testFirstScanEmitsAbsoluteBaselineSample() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tokenbar-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let progress = SourceProgress(storeURL: tmp.appendingPathComponent("progress.json"))
        let home = tmp.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex/archived_sessions"), withIntermediateDirectories: true)
        let rollout = home.appendingPathComponent(".codex/archived_sessions/rollout-x.jsonl")

        let eventA = #"{"timestamp":"2026-07-20T08:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"cache_write_input_tokens":0,"output_tokens":200,"reasoning_output_tokens":0,"total_tokens":1200},"total_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"cache_write_input_tokens":0,"output_tokens":200,"reasoning_output_tokens":0,"total_tokens":1200}}}}"#
        try (eventA + "\n").write(to: rollout, atomically: true, encoding: .utf8)

        let src = CodexSource(home: home, progress: progress)
        let r = try await src.collect()
        XCTAssertEqual(r.samples.count, 1, "first scan should emit the absolute baseline as one sample")
        XCTAssertEqual(r.samples[0].inputTokens, 600)
        XCTAssertEqual(r.samples[0].outputTokens, 200)
        XCTAssertEqual(r.samples[0].cacheReadTokens, 400)
        XCTAssertEqual(r.samples[0].cacheWriteTokens, 0)

        let eventB = #"{"timestamp":"2026-07-20T08:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"cache_write_input_tokens":0,"output_tokens":250,"reasoning_output_tokens":0,"total_tokens":1250},"total_token_usage":{"input_tokens":2500,"cached_input_tokens":900,"cache_write_input_tokens":0,"output_tokens":500,"reasoning_output_tokens":0,"total_tokens":3000}}}}"#
        let handle = try FileHandle(forWritingTo: rollout)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((eventB + "\n").utf8))
        try handle.close()

        let r2 = try await src.collect()
        XCTAssertEqual(r2.samples.count, 1)
        let sample = r2.samples[0]
        XCTAssertEqual(sample.inputTokens, 1000)
        XCTAssertEqual(sample.outputTokens, 300)
        XCTAssertEqual(sample.cacheReadTokens, 500)
        XCTAssertEqual(sample.cacheWriteTokens, 0)
    }

    /// Regression test for the bug where the resume baseline was read from
    /// `last_token_usage` (single most-recent turn) while the live delta used
    /// `total_token_usage` (session cumulative). Across a resume boundary the
    /// two must agree, otherwise the very next sample spikes far above the
    /// real per-interval usage.
    func testResumeBaselineUsesCumulativeTotal() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tokenbar-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let progress = SourceProgress(storeURL: tmp.appendingPathComponent("progress.json"))
        let home = tmp.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex/archived_sessions"), withIntermediateDirectories: true)
        let rollout = home.appendingPathComponent(".codex/archived_sessions/rollout-multiturn.jsonl")

        // A `turn_context` line between A and B marks them as two distinct
        // turns, so the per-turn coalescing in `collect()` flushes them as
        // two separate samples instead of merging their deltas into one.
        let turnContext = #"{"timestamp":"2026-07-20T08:00:30Z","type":"turn_context","payload":{"model":"gpt-5"}}"#
        let eventA = #"{"timestamp":"2026-07-20T08:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"cache_write_input_tokens":0,"output_tokens":200,"reasoning_output_tokens":0,"total_tokens":1200},"total_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"cache_write_input_tokens":0,"output_tokens":200,"reasoning_output_tokens":0,"total_tokens":1200}}}}"#
        // Event B's last_token_usage (this turn only) is much smaller than its
        // total_token_usage (session cumulative) - this is the shape that
        // exposed the bug.
        let eventB = #"{"timestamp":"2026-07-20T08:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"cache_write_input_tokens":0,"output_tokens":250,"reasoning_output_tokens":0,"total_tokens":1250},"total_token_usage":{"input_tokens":2500,"cached_input_tokens":900,"cache_write_input_tokens":0,"output_tokens":500,"reasoning_output_tokens":0,"total_tokens":3000}}}}"#
        try ((eventA + "\n") + (turnContext + "\n") + (eventB + "\n")).write(to: rollout, atomically: true, encoding: .utf8)

        let src = CodexSource(home: home, progress: progress)
        let r = try await src.collect()
        XCTAssertEqual(r.samples.count, 2)

        let eventC = #"{"timestamp":"2026-07-20T08:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1200,"cached_input_tokens":500,"cache_write_input_tokens":0,"output_tokens":280,"reasoning_output_tokens":0,"total_tokens":1480},"total_token_usage":{"input_tokens":4000,"cached_input_tokens":1500,"cache_write_input_tokens":0,"output_tokens":800,"reasoning_output_tokens":0,"total_tokens":4800}}}}"#
        let handle = try FileHandle(forWritingTo: rollout)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((eventC + "\n").utf8))
        try handle.close()

        let r2 = try await src.collect()
        XCTAssertEqual(r2.samples.count, 1, "only the newly appended event should be emitted")
        let sample = r2.samples[0]
        // Correct: delta measured against B's total_token_usage (2500/900/500).
        // The pre-fix bug would have measured against B's last_token_usage
        // (1000/400/250) instead, producing inputTokens=1900 / outputTokens=550.
        XCTAssertEqual(sample.inputTokens, 900)
        XCTAssertEqual(sample.outputTokens, 300)
        XCTAssertEqual(sample.cacheReadTokens, 600)
    }

    /// Regression test for a bug introduced while optimizing resume
    /// performance: persisting the running baseline in cursor metadata means
    /// a file whose cursor pre-dates that change has an offset but no
    /// metadata. Treating that as "no baseline" (delta from zero) against a
    /// monotonically increasing cumulative counter produced one enormous
    /// spurious sample (observed in the wild as single samples in the
    /// billions of tokens). The fix must recover the baseline by scanning the
    /// already-processed prefix instead.
    func testResumeRecoversBaselineWhenMetadataMissing() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tokenbar-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let progress = SourceProgress(storeURL: tmp.appendingPathComponent("progress.json"))
        let home = tmp.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex/archived_sessions"), withIntermediateDirectories: true)
        let rollout = home.appendingPathComponent(".codex/archived_sessions/rollout-legacy.jsonl")

        let eventA = #"{"timestamp":"2026-07-20T08:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"cache_write_input_tokens":0,"output_tokens":200,"reasoning_output_tokens":0,"total_tokens":1200}}}}"#
        let eventB = #"{"timestamp":"2026-07-20T08:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2500,"cached_input_tokens":900,"cache_write_input_tokens":0,"output_tokens":500,"reasoning_output_tokens":0,"total_tokens":3000}}}}"#
        try ((eventA + "\n") + (eventB + "\n")).write(to: rollout, atomically: true, encoding: .utf8)

        // Simulate a cursor written by the pre-metadata code: it has advanced
        // past A+B, but carries no baseline.
        let sizeAfterAB = (try FileManager.default.attributesOfItem(atPath: rollout.path)[.size] as? NSNumber)?.uint64Value ?? 0
        let identity = FileIdentity.of(rollout)
        await progress.update("codex:rollout-legacy.jsonl", offset: sizeAfterAB, identity: identity, metadata: nil)

        let eventC = #"{"timestamp":"2026-07-20T08:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":4000,"cached_input_tokens":1500,"cache_write_input_tokens":0,"output_tokens":800,"reasoning_output_tokens":0,"total_tokens":4800}}}}"#
        let handle = try FileHandle(forWritingTo: rollout)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((eventC + "\n").utf8))
        try handle.close()

        let src = CodexSource(home: home, progress: progress)
        let r = try await src.collect()
        XCTAssertEqual(r.samples.count, 1, "only the newly appended event should be emitted")
        let sample = r.samples[0]
        // Correct: delta measured against B's total_token_usage (2500/900/500).
        // The bug would instead measure against zero, yielding
        // inputTokens=2500 outputTokens=800 (B+C's entire cumulative value).
        XCTAssertEqual(sample.inputTokens, 900)
        XCTAssertEqual(sample.outputTokens, 300)
        XCTAssertEqual(sample.cacheReadTokens, 600)
    }

    /// Real Codex rollout files have been observed (verified directly against
    /// raw JSONL on a real machine) containing `cached_input_tokens` in the
    /// billions for a single turn - a corruption bug on Codex's own side, not
    /// something this app's delta math can "correct". The implausible sample
    /// must be dropped, but the corrupted counter still has to be tracked so
    /// the *next*, real turn's delta is computed against it correctly.
    func testImplausibleSingleTurnDeltaIsDropped() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tokenbar-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let progress = SourceProgress(storeURL: tmp.appendingPathComponent("progress.json"))
        let home = tmp.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex/archived_sessions"), withIntermediateDirectories: true)
        let rollout = home.appendingPathComponent(".codex/archived_sessions/rollout-corrupt.jsonl")

        let eventA = #"{"timestamp":"2026-07-20T08:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"cache_write_input_tokens":0,"output_tokens":200,"reasoning_output_tokens":0,"total_tokens":1200}}}}"#
        // A `turn_context` boundary between A and the corrupt/C pair keeps
        // this test's two expected samples on opposite sides of a per-turn
        // flush, matching the coalescing in `collect()`.
        let turnContext = #"{"timestamp":"2026-07-20T08:00:30Z","type":"turn_context","payload":{"model":"gpt-5"}}"#
        // Corrupted upstream record: a cumulative counter in the billions.
        let eventCorrupt = #"{"timestamp":"2026-07-20T08:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2235225937,"cached_input_tokens":2187476992,"cache_write_input_tokens":0,"output_tokens":6265101,"reasoning_output_tokens":0,"total_tokens":2241491038}}}}"#
        let eventC = #"{"timestamp":"2026-07-20T08:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2235226937,"cached_input_tokens":2187477500,"cache_write_input_tokens":0,"output_tokens":6265301,"reasoning_output_tokens":0,"total_tokens":2241492238}}}}"#
        let contents = [eventA, turnContext, eventCorrupt, eventC].map { $0 + "\n" }.joined()
        try contents.write(to: rollout, atomically: true, encoding: .utf8)

        let src = CodexSource(home: home, progress: progress)
        let r = try await src.collect()
        // Event A (absolute baseline) and event C (a small, plausible delta
        // measured against the corrupted-but-tracked baseline) both emit;
        // the implausible jump from A to the corrupted record does not.
        XCTAssertEqual(r.samples.count, 2)
        XCTAssertEqual(r.samples[0].inputTokens, 600)
        XCTAssertEqual(r.samples[1].inputTokens, 1000 - 508) // (2235226937-2235225937) - (2187477500-2187476992)
        XCTAssertEqual(r.samples[1].outputTokens, 200)
    }

    /// `~/.codex/sessions` nests live rollouts under YYYY/MM/DD subfolders; a
    /// non-recursive directory listing missed essentially all of them.
    func testRecursiveSessionsDirectoryTraversal() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tokenbar-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let progress = SourceProgress(storeURL: tmp.appendingPathComponent("progress.json"))
        let home = tmp.appendingPathComponent("home")
        let nested = home.appendingPathComponent(".codex/sessions/2026/07/20")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let rollout = nested.appendingPathComponent("rollout-nested.jsonl")
        let event = #"{"timestamp":"2026-07-20T08:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":50,"reasoning_output_tokens":0,"total_tokens":150}}}}"#
        try (event + "\n").write(to: rollout, atomically: true, encoding: .utf8)

        let src = CodexSource(home: home, progress: progress)
        let r = try await src.collect()
        XCTAssertEqual(r.fileCount, 1)
        XCTAssertEqual(r.samples.count, 1)
        XCTAssertEqual(r.samples[0].inputTokens, 100)
        XCTAssertEqual(r.samples[0].outputTokens, 50)
    }

    /// Codex moves a rollout file from sessions/ to archived_sessions/ once a
    /// session ends, keeping the filename but changing the path. The cursor
    /// key must survive that move so the session isn't re-scanned and
    /// double-counted.
    func testArchivedSessionsDoNotDoubleCount() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tokenbar-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let progress = SourceProgress(storeURL: tmp.appendingPathComponent("progress.json"))
        let home = tmp.appendingPathComponent("home")
        let nested = home.appendingPathComponent(".codex/sessions/2026/07/20")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let archived = home.appendingPathComponent(".codex/archived_sessions")
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        let liveURL = nested.appendingPathComponent("rollout-move.jsonl")
        let event = #"{"timestamp":"2026-07-20T08:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":50,"reasoning_output_tokens":0,"total_tokens":150}}}}"#
        try (event + "\n").write(to: liveURL, atomically: true, encoding: .utf8)

        let src = CodexSource(home: home, progress: progress)
        let r = try await src.collect()
        XCTAssertEqual(r.samples.count, 1)

        let archivedURL = archived.appendingPathComponent("rollout-move.jsonl")
        try FileManager.default.moveItem(at: liveURL, to: archivedURL)

        let r2 = try await src.collect()
        XCTAssertEqual(r2.samples.count, 0, "the same session must not be re-counted after archiving")
    }

    /// `turn_context.payload.model` carries the real model name; the old code
    /// mistook `session_meta.payload.model_provider` (e.g. "openai") for it.
    func testCodexModelNameFromTurnContext() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tokenbar-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let progress = SourceProgress(storeURL: tmp.appendingPathComponent("progress.json"))
        let home = tmp.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex/archived_sessions"), withIntermediateDirectories: true)
        let rollout = home.appendingPathComponent(".codex/archived_sessions/rollout-model.jsonl")

        let sessionMeta = #"{"timestamp":"2026-07-20T07:59:00Z","type":"session_meta","payload":{"model_provider":"openai"}}"#
        let turnContext = #"{"timestamp":"2026-07-20T08:00:00Z","type":"turn_context","payload":{"model":"gpt-5.5"}}"#
        let event = #"{"timestamp":"2026-07-20T08:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":50,"reasoning_output_tokens":0,"total_tokens":150}}}}"#
        let contents = [sessionMeta, turnContext, event].map { $0 + "\n" }.joined()
        try contents.write(to: rollout, atomically: true, encoding: .utf8)

        let src = CodexSource(home: home, progress: progress)
        let r = try await src.collect()
        XCTAssertEqual(r.samples.count, 1)
        XCTAssertEqual(r.samples[0].model, "gpt-5.5")
    }

    /// Regression test for wildly inflated "调用次数": real rollouts fire a
    /// `token_count` checkpoint every 5-15 seconds *during* a single turn's
    /// generation (verified against a real file: 12 `turn_context` markers
    /// but 148 `token_count` events), not once per turn. Multiple
    /// `token_count` events between two `turn_context` boundaries must
    /// coalesce into exactly one sample per turn instead of one sample per
    /// checkpoint.
    func testMultipleTokenCountCheckpointsCoalesceIntoOneSamplePerTurn() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tokenbar-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let progress = SourceProgress(storeURL: tmp.appendingPathComponent("progress.json"))
        let home = tmp.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex/archived_sessions"), withIntermediateDirectories: true)
        let rollout = home.appendingPathComponent(".codex/archived_sessions/rollout-checkpoints.jsonl")

        let turnContext1 = #"{"timestamp":"2026-07-20T08:00:00Z","type":"turn_context","payload":{"model":"gpt-5"}}"#
        // Three checkpoints within the same turn - each a small incremental
        // delta over the last, exactly like real mid-generation snapshots.
        let checkpoint1 = #"{"timestamp":"2026-07-20T08:00:05Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":50,"reasoning_output_tokens":0,"total_tokens":150}}}}"#
        let checkpoint2 = #"{"timestamp":"2026-07-20T08:00:10Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":200,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":100,"reasoning_output_tokens":0,"total_tokens":300}}}}"#
        let checkpoint3 = #"{"timestamp":"2026-07-20T08:00:15Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":300,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":150,"reasoning_output_tokens":0,"total_tokens":450}}}}"#
        let turnContext2 = #"{"timestamp":"2026-07-20T08:00:20Z","type":"turn_context","payload":{"model":"gpt-5"}}"#
        // A second turn with a single checkpoint, still in progress at the
        // end of this batch (no closing turn_context).
        let checkpoint4 = #"{"timestamp":"2026-07-20T08:00:25Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":400,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":200,"reasoning_output_tokens":0,"total_tokens":600}}}}"#

        let contents = [turnContext1, checkpoint1, checkpoint2, checkpoint3, turnContext2, checkpoint4].map { $0 + "\n" }.joined()
        try contents.write(to: rollout, atomically: true, encoding: .utf8)

        let src = CodexSource(home: home, progress: progress)
        let r = try await src.collect()
        // 4 checkpoints across 2 turns must coalesce into 2 samples, not 4.
        XCTAssertEqual(r.samples.count, 2, "checkpoints within the same turn must coalesce into one sample")
        // First turn: sum of the three checkpoint deltas (100+100+100 input, 50+50+50 output).
        XCTAssertEqual(r.samples[0].inputTokens, 300)
        XCTAssertEqual(r.samples[0].outputTokens, 150)
        // Second turn: still in progress at batch end, flushed as its own sample.
        XCTAssertEqual(r.samples[1].inputTokens, 100)
        XCTAssertEqual(r.samples[1].outputTokens, 50)
    }

    /// A forked session replays the entire parent conversation's token_count
    /// history into the new rollout at fork time - a dense sub-second burst -
    /// before any live activity. That history was already counted under the
    /// parent, so it must be suppressed (baseline-only), and only genuinely
    /// new activity after the replay burst should emit samples. Regression
    /// for a ~3B-token spike dumped into a single minute.
    func testForkedSessionReplayIsNotDoubleCounted() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tokenbar-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let progress = SourceProgress(storeURL: tmp.appendingPathComponent("progress.json"))
        let home = tmp.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex/archived_sessions"), withIntermediateDirectories: true)
        let rollout = home.appendingPathComponent(".codex/archived_sessions/rollout-fork.jsonl")

        // Forked session_meta. Replay burst: 4 token_count events all stamped
        // within the same second (sub-second gaps), cumulative climbing to a
        // large value - this is the already-counted parent history.
        let meta = #"{"timestamp":"2026-07-20T08:00:00.000Z","type":"session_meta","payload":{"model_provider":"openai","forked_from_id":"parent-abc"}}"#
        let replay1 = #"{"timestamp":"2026-07-20T08:00:00.010Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100000,"cached_input_tokens":90000,"cache_write_input_tokens":0,"output_tokens":1000,"reasoning_output_tokens":0,"total_tokens":101000}}}}"#
        let replay2 = #"{"timestamp":"2026-07-20T08:00:00.020Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":500000,"cached_input_tokens":480000,"cache_write_input_tokens":0,"output_tokens":3000,"reasoning_output_tokens":0,"total_tokens":503000}}}}"#
        let replay3 = #"{"timestamp":"2026-07-20T08:00:00.030Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2000000,"cached_input_tokens":1950000,"cache_write_input_tokens":0,"output_tokens":8000,"reasoning_output_tokens":0,"total_tokens":2008000}}}}"#
        let replay4 = #"{"timestamp":"2026-07-20T08:00:00.040Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":5000000,"cached_input_tokens":4900000,"cache_write_input_tokens":0,"output_tokens":20000,"reasoning_output_tokens":0,"total_tokens":5020000}}}}"#
        // First live event: arrives well after the burst (a >2s gap), and its
        // delta over the last replayed cumulative is the only real new usage.
        let live = #"{"timestamp":"2026-07-20T08:00:15.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":5010000,"cached_input_tokens":4905000,"cache_write_input_tokens":0,"output_tokens":20500,"reasoning_output_tokens":0,"total_tokens":5030500}}}}"#
        let contents = [meta, replay1, replay2, replay3, replay4, live].map { $0 + "\n" }.joined()
        try contents.write(to: rollout, atomically: true, encoding: .utf8)

        let src = CodexSource(home: home, progress: progress)
        let r = try await src.collect()
        // Only the single live event's net-new delta should emit; none of the
        // multi-million-token replay history.
        XCTAssertEqual(r.samples.count, 1, "forked replay history must not be counted")
        let s = r.samples[0]
        // delta from replay4 (5,000,000 / 4,900,000 / 20,000) to live
        // (5,010,000 / 4,905,000 / 20,500): input grew 10000 with cached +5000
        // -> uncached 5000; cacheRead 5000; output 500.
        XCTAssertEqual(s.inputTokens, 5000)
        XCTAssertEqual(s.cacheReadTokens, 5000)
        XCTAssertEqual(s.outputTokens, 500)
    }
}

final class AggregatorTests: XCTestCase {
    func testDailyAggregation() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let samples = [
            TokenSample(tool: .codex, model: "gpt-5", timestamp: today.addingTimeInterval(100),
                        inputTokens: 100, outputTokens: 50, reasoningTokens: 0, cacheReadTokens: 30, cacheWriteTokens: 0),
            TokenSample(tool: .claudeCode, model: "claude-sonnet-4", timestamp: today.addingTimeInterval(200),
                        inputTokens: 200, outputTokens: 80, reasoningTokens: 0, cacheReadTokens: 100, cacheWriteTokens: 20)
        ]
        let history = Aggregator.aggregateDaily(samples: samples, calendar: cal)
        let todayAgg = Aggregator.aggregateWindow(samples: samples, window: .today, calendar: cal, now: today.addingTimeInterval(300))
        XCTAssertEqual(todayAgg.totalTokens, 580)
        XCTAssertEqual(todayAgg.cacheReadTokens, 130)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(todayAgg.byTool[.codex]?.totalTokens, 180)
        XCTAssertEqual(todayAgg.byTool[.claudeCode]?.cacheHitRatio ?? 0, 0.3333, accuracy: 0.001)
    }

    /// Billable is a cost-weighted estimate, not the raw fresh-token sum:
    /// cache reads count (discounted, not dropped) and output is weighted up,
    /// with the weights differing per provider. This is the fix for "计费
    /// 看起来太少" - the old formula silently dropped cache reads, the single
    /// biggest actually-billed component.
    func testBillableIsCostWeightedPerProvider() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        // Codex (OpenAI weights): cacheRead x0.1, cacheWrite x1.0, output x4.
        let codex = TokenSample(tool: .codex, model: "gpt-5", timestamp: today.addingTimeInterval(100),
                                inputTokens: 1000, outputTokens: 100, reasoningTokens: 0,
                                cacheReadTokens: 5000, cacheWriteTokens: 200)
        // 1000 + 5000*0.1 + 200*1.0 + 100*4 = 1000 + 500 + 200 + 400 = 2100
        XCTAssertEqual(codex.billableTokens, 2100)
        // The old drop-cache-reads formula would have given 1000+100+200 = 1300.
        XCTAssertNotEqual(codex.billableTokens, 1300)

        // Claude (Anthropic weights): cacheRead x0.1, cacheWrite x1.25, output x5.
        let claude = TokenSample(tool: .claudeCode, model: "claude-sonnet-5", timestamp: today.addingTimeInterval(200),
                                 inputTokens: 1000, outputTokens: 100, reasoningTokens: 0,
                                 cacheReadTokens: 5000, cacheWriteTokens: 200)
        // 1000 + 5000*0.1 + 200*1.25 + 100*5 = 1000 + 500 + 250 + 500 = 2250
        XCTAssertEqual(claude.billableTokens, 2250)

        // The daily rollup must sum the per-tool weighted values, not weight a
        // blended field set (which would apply one tool's weights to another's).
        let agg = Aggregator.aggregateWindow(samples: [codex, claude], window: .today, calendar: cal, now: today.addingTimeInterval(300))
        XCTAssertEqual(agg.billableTokens, 2100 + 2250)
    }
}

final class TokenFormatterTests: XCTestCase {
    func testShortFormatting() {
        XCTAssertEqual(TokenFormatter.short(500), "500")
        XCTAssertEqual(TokenFormatter.short(1500), "1.50k")
        XCTAssertEqual(TokenFormatter.short(15_000), "15k")
        XCTAssertEqual(TokenFormatter.short(150_000), "150k")
        XCTAssertEqual(TokenFormatter.short(1_500_000), "1.50M")
        XCTAssertEqual(TokenFormatter.short(2_500_000_000), "2.50B")
        XCTAssertEqual(TokenFormatter.short(15_000_000_000), "15B")
    }
}
