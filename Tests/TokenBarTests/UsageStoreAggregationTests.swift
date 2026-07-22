import XCTest
@testable import TokenBar

final class UsageStoreAggregationTests: XCTestCase {
    /// Regression test for a bug where every `DisplayWindow` ended up showing
    /// the exact same total. Distinct windows must roll up to distinct totals
    /// when the underlying samples actually span more than one day.
    func testDifferentWindowsProduceDifferentTotals() {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)

        let sampleToday = TokenSample(tool: .codex, model: "gpt-5", timestamp: today.addingTimeInterval(3600),
                                       inputTokens: 100, outputTokens: 0, reasoningTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0)
        let sample5DaysAgo = TokenSample(tool: .codex, model: "gpt-5", timestamp: calendar.date(byAdding: .day, value: -5, to: today)!.addingTimeInterval(3600),
                                          inputTokens: 1000, outputTokens: 0, reasoningTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0)
        let sample20DaysAgo = TokenSample(tool: .codex, model: "gpt-5", timestamp: calendar.date(byAdding: .day, value: -20, to: today)!.addingTimeInterval(3600),
                                           inputTokens: 10000, outputTokens: 0, reasoningTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0)

        let state = UsageStore.fold(samples: [sampleToday, sample5DaysAgo, sample20DaysAgo], into: UsageStore.BucketState())
        let derived = UsageStore.deriveSnapshotData(dayBuckets: state.dayBuckets, hourBuckets: state.hourBuckets, now: now)

        XCTAssertEqual(derived.rollups[.today]?.totalTokens, 100)
        XCTAssertEqual(derived.rollups[.last7d]?.totalTokens, 1100)
        XCTAssertEqual(derived.rollups[.last30d]?.totalTokens, 11100)
        XCTAssertEqual(derived.rollups[.all]?.totalTokens, 11100)

        // The whole point of the bug: these must NOT all be equal.
        let totals = Set([derived.rollups[.today]?.totalTokens, derived.rollups[.last7d]?.totalTokens, derived.rollups[.last30d]?.totalTokens])
        XCTAssertTrue(totals.count > 1, "different windows produced identical totals - the caching/derivation is broken again")
    }

    /// Regression test for a bug where the trend chart's "今天" and "24h"
    /// pills rendered pixel-identical charts: both used hour granularity, but
    /// the derivation never actually branched on which window it was - both
    /// computed "the 24 hours ending at the current hour" instead of "今天"
    /// meaning the calendar day since midnight.
    func testTodayAndLast24hTrendsCoverDifferentHourRanges() {
        let calendar = Calendar.current
        // Pick a "now" partway through the day so midnight-aligned and
        // rolling-24h ranges are guaranteed to differ.
        let now = calendar.date(bySettingHour: 15, minute: 0, second: 0, of: Date())!

        let todayTrend = UsageStore.trend(for: .today, dayBuckets: [:], hourBuckets: [:], now: now, calendar: calendar)
        let last24hTrend = UsageStore.trend(for: .last24h, dayBuckets: [:], hourBuckets: [:], now: now, calendar: calendar)

        XCTAssertEqual(todayTrend.first?.id, calendar.startOfDay(for: now), "今天 should start at midnight")
        XCTAssertNotEqual(todayTrend.first?.id, last24hTrend.first?.id, "今天 and 24h must cover different hour ranges, not render identical charts")
    }

    /// Folding a small incremental batch into already-bootstrapped bucket
    /// state must add to it, not replace it - this is what makes each
    /// refresh cycle O(new samples) instead of O(all samples ever seen).
    func testFoldIsIncrementalNotReplacing() {
        let now = Date()
        let bootstrapSample = TokenSample(tool: .codex, model: "gpt-5", timestamp: now,
                                           inputTokens: 500, outputTokens: 0, reasoningTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0)
        let bootstrapped = UsageStore.fold(samples: [bootstrapSample], into: UsageStore.BucketState())

        let newSample = TokenSample(tool: .codex, model: "gpt-5", timestamp: now,
                                     inputTokens: 50, outputTokens: 0, reasoningTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0)
        let updated = UsageStore.fold(samples: [newSample], into: bootstrapped)

        let derived = UsageStore.deriveSnapshotData(dayBuckets: updated.dayBuckets, hourBuckets: updated.hourBuckets, now: now)
        XCTAssertEqual(derived.rollups[.today]?.totalTokens, 550, "incremental fold must add to, not replace, existing bucket state")
    }
}
