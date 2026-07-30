import Foundation

enum Aggregator {
    static func dayKey(for date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date)
    }

    static func hourKey(for date: Date, calendar: Calendar = .current) -> Date {
        let comps = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        return calendar.date(from: comps) ?? date
    }

    /// Aggregates samples into daily buckets, ALWAYS (regardless of window).
    /// Used to build the per-tool/per-model rollups. Empty days are not emitted.
    static func aggregateDaily(samples: [TokenSample], calendar: Calendar = .current) -> [DailyAggregate] {
        var byDay: [Date: DailyAggregate] = [:]
        for s in samples {
            let day = dayKey(for: s.timestamp, calendar: calendar)
            var bucket = byDay[day] ?? DailyAggregate(date: day)
            accumulate(sample: s, into: &bucket)
            byDay[day] = bucket
        }
        return byDay.keys.sorted().map { byDay[$0]! }
    }

    /// Aggregates samples within a window into a single roll-up.
    static func aggregateWindow(samples: [TokenSample], window: DisplayWindow, calendar: Calendar = .current, now: Date = Date()) -> DailyAggregate {
        var bucket = DailyAggregate(date: calendar.startOfDay(for: now))
        guard let start = window.startDate(now: now, calendar: calendar) else {
            // .all - no lower bound
            for s in samples {
                accumulate(sample: s, into: &bucket)
            }
            return bucket
        }
        for s in samples where s.timestamp >= start {
            accumulate(sample: s, into: &bucket)
        }
        return bucket
    }

    /// Builds the trend buckets appropriate for a window.
    static func trendBuckets(
        samples: [TokenSample],
        window: DisplayWindow,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> [TrendBucket] {
        let granularity = window.bucketGranularity
        let count = window.bucketCount

        switch granularity {
        case .hour:
            // Hourly buckets covering the last `count` hours, including the
            // current one. Lower bound = now - (count-1) hours, snapped to hour.
            let currentHour = hourKey(for: now, calendar: calendar)
            let firstHour = currentHour.addingTimeInterval(-Double(count - 1) * 3600)
            var buckets: [TrendBucket] = []
            for i in 0..<count {
                let hourStart = firstHour.addingTimeInterval(Double(i) * 3600)
                var agg = DailyAggregate(date: hourStart)
                for s in samples where s.timestamp >= hourStart && s.timestamp < hourStart.addingTimeInterval(3600) {
                    accumulate(sample: s, into: &agg)
                }
                buckets.append(TrendBucket(id: hourStart, granularity: .hour, aggregate: agg))
            }
            return buckets

        case .day:
            // Daily buckets covering the last `count` days, including today.
            let today = calendar.startOfDay(for: now)
            let firstDay = calendar.date(byAdding: .day, value: -(count - 1), to: today) ?? today
            var byDay: [Date: DailyAggregate] = [:]
            for s in samples {
                let day = dayKey(for: s.timestamp, calendar: calendar)
                guard day >= firstDay && day <= today else { continue }
                var bucket = byDay[day] ?? DailyAggregate(date: day)
                accumulate(sample: s, into: &bucket)
                byDay[day] = bucket
            }
            var ordered: [TrendBucket] = []
            for i in 0..<count {
                let day = calendar.date(byAdding: .day, value: i, to: firstDay) ?? firstDay
                let agg = byDay[day] ?? DailyAggregate(date: day)
                ordered.append(TrendBucket(id: day, granularity: .day, aggregate: agg))
            }
            return ordered
        }
    }

    /// Builds a per-tool sparkline series for the given window.
    static func sparkline(
        samples: [TokenSample],
        tool: ToolKind,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> [TrendBucket] {
        let today = calendar.startOfDay(for: now)
        var byHour: [Date: DailyAggregate] = [:]
        for s in samples where s.tool == tool {
            let hour = hourKey(for: s.timestamp, calendar: calendar)
            var bucket = byHour[hour] ?? DailyAggregate(date: hour)
            accumulate(sample: s, into: &bucket)
            byHour[hour] = bucket
        }
        var out: [TrendBucket] = []
        for offset in stride(from: 23, through: 0, by: -1) {
            let hour = hourKey(for: today.addingTimeInterval(-Double(offset) * 3600), calendar: calendar)
            let agg = byHour[hour] ?? DailyAggregate(date: hour)
            out.append(TrendBucket(id: hour, granularity: .hour, aggregate: agg))
        }
        return out
    }

    /// Folds one sample into a bucket. Exposed (not `private`) so `UsageStore`
    /// can maintain incremental day/hour buckets itself instead of rescanning
    /// the entire sample history on every refresh cycle.
    static func accumulate(sample s: TokenSample, into bucket: inout DailyAggregate) {
        bucket.totalTokens += s.totalTokens
        bucket.uncachedInputTokens += s.uncachedInputTokens
        bucket.outputTokens += s.outputTokens
        bucket.reasoningTokens += s.reasoningTokens
        bucket.cacheReadTokens += s.cacheReadTokens
        bucket.cacheWriteTokens += s.cacheWriteTokens

        var toolBucket = bucket.byTool[s.tool] ?? ToolAggregate(tool: s.tool)
        toolBucket.totalTokens += s.totalTokens
        toolBucket.uncachedInputTokens += s.uncachedInputTokens
        toolBucket.outputTokens += s.outputTokens
        toolBucket.reasoningTokens += s.reasoningTokens
        toolBucket.cacheReadTokens += s.cacheReadTokens
        toolBucket.cacheWriteTokens += s.cacheWriteTokens
        toolBucket.messageCount += 1

        // Preserve sub-bucketing (model inside tool) for the tool row.
        let modelKey = displayModelName(s.model, for: s.tool)
        var modelInTool = toolBucket.byModel[modelKey] ?? ModelAggregate(name: modelKey)
        modelInTool.totalTokens += s.totalTokens
        modelInTool.uncachedInputTokens += s.uncachedInputTokens
        modelInTool.outputTokens += s.outputTokens
        modelInTool.reasoningTokens += s.reasoningTokens
        modelInTool.cacheReadTokens += s.cacheReadTokens
        modelInTool.cacheWriteTokens += s.cacheWriteTokens
        modelInTool.messageCount += 1
        toolBucket.byModel[modelKey] = modelInTool

        bucket.byTool[s.tool] = toolBucket

        var modelBucket = bucket.byModel[modelKey] ?? ModelAggregate(name: modelKey)
        modelBucket.totalTokens += s.totalTokens
        modelBucket.uncachedInputTokens += s.uncachedInputTokens
        modelBucket.outputTokens += s.outputTokens
        modelBucket.reasoningTokens += s.reasoningTokens
        modelBucket.cacheReadTokens += s.cacheReadTokens
        modelBucket.cacheWriteTokens += s.cacheWriteTokens
        modelBucket.messageCount += 1
        bucket.byModel[modelKey] = modelBucket
    }

    /// Folds one already-aggregated bucket (e.g. one day's `DailyAggregate`)
    /// into another - used to sum a handful of day/hour buckets into a window
    /// roll-up, which is orders of magnitude cheaper than re-scanning every
    /// raw sample for every window on every refresh.
    static func merge(_ source: DailyAggregate, into target: inout DailyAggregate) {
        target.totalTokens += source.totalTokens
        target.uncachedInputTokens += source.uncachedInputTokens
        target.outputTokens += source.outputTokens
        target.reasoningTokens += source.reasoningTokens
        target.cacheReadTokens += source.cacheReadTokens
        target.cacheWriteTokens += source.cacheWriteTokens

        for (tool, toolSource) in source.byTool {
            var toolTarget = target.byTool[tool] ?? ToolAggregate(tool: tool)
            toolTarget.totalTokens += toolSource.totalTokens
            toolTarget.uncachedInputTokens += toolSource.uncachedInputTokens
            toolTarget.outputTokens += toolSource.outputTokens
            toolTarget.reasoningTokens += toolSource.reasoningTokens
            toolTarget.cacheReadTokens += toolSource.cacheReadTokens
            toolTarget.cacheWriteTokens += toolSource.cacheWriteTokens
            toolTarget.messageCount += toolSource.messageCount
            for (model, modelSource) in toolSource.byModel {
                var modelTarget = toolTarget.byModel[model] ?? ModelAggregate(name: model)
                modelTarget.totalTokens += modelSource.totalTokens
                modelTarget.uncachedInputTokens += modelSource.uncachedInputTokens
                modelTarget.outputTokens += modelSource.outputTokens
                modelTarget.reasoningTokens += modelSource.reasoningTokens
                modelTarget.cacheReadTokens += modelSource.cacheReadTokens
                modelTarget.cacheWriteTokens += modelSource.cacheWriteTokens
                modelTarget.messageCount += modelSource.messageCount
                toolTarget.byModel[model] = modelTarget
            }
            target.byTool[tool] = toolTarget
        }

        for (model, modelSource) in source.byModel {
            var modelTarget = target.byModel[model] ?? ModelAggregate(name: model)
            modelTarget.totalTokens += modelSource.totalTokens
            modelTarget.uncachedInputTokens += modelSource.uncachedInputTokens
            modelTarget.outputTokens += modelSource.outputTokens
            modelTarget.reasoningTokens += modelSource.reasoningTokens
            modelTarget.cacheReadTokens += modelSource.cacheReadTokens
            modelTarget.cacheWriteTokens += modelSource.cacheWriteTokens
            modelTarget.messageCount += modelSource.messageCount
            target.byModel[model] = modelTarget
        }
    }

    static func displayModelName(_ raw: String, for tool: ToolKind) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            switch tool {
            case .codex: return "codex"
            case .claudeCode: return "claude"
            case .opencode: return "opencode"
            case .trae: return "trae"
            case .cliProxyAPI: return "cliproxyapi"
            case .workbuddy: return "workbuddy"
            }
        }
        return trimmed
    }
}

/// Persistent store of all observed samples. Reads are cheap (cached in memory)
/// after the first load. Writes are append-only and serialized through an
/// internal queue to avoid concurrent appends clobbering each other.
final class SampleStore: @unchecked Sendable {
    private let directory: URL
    private let queue = DispatchQueue(label: "TokenBar.SampleStore.io")
    private let cacheLock = NSLock()
    private var _cached: [TokenSample] = []
    // Distinct from `_cached.isEmpty`: an empty file is a valid "loaded"
    // state. Without this flag, calling `append()` before the first
    // `loadAll()` (which is exactly what every `refresh()` cycle does -
    // append each source's new samples, then load "all" of them) makes
    // `_cached` non-empty with *only* that batch, so `loadAll()`'s old
    // `!_cached.isEmpty` short-circuit would return just the newly-appended
    // samples and never read the rest of a long-running history back off
    // disk. That bug made every window (today/7d/30d/all) show an identical,
    // tiny "just this refresh's new samples" total instead of the real
    // accumulated history.
    private var _hasLoadedFromDisk = false

    init(directory: URL) {
        self.directory = directory
    }

    func append(_ newSamples: [TokenSample]) {
        guard !newSamples.isEmpty else { return }
        ensureLoadedFromDisk()
        queue.sync {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("samples.jsonl")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var data = Data()
            for s in newSamples {
                if let d = try? encoder.encode(s) {
                    data.append(d)
                    data.append(0x0A)
                }
            }
            if FileManager.default.fileExists(atPath: fileURL.path) {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: fileURL)
        }
        }
        cacheLock.lock()
        _cached.append(contentsOf: newSamples)
        cacheLock.unlock()
    }

    func loadAll() -> [TokenSample] {
        ensureLoadedFromDisk()
        cacheLock.lock()
        let copy = _cached
        cacheLock.unlock()
        return copy
    }

    /// Reads the on-disk file into `_cached` exactly once per store instance.
    /// Safe to call from both `append` and `loadAll` regardless of call
    /// order.
    private func ensureLoadedFromDisk() {
        cacheLock.lock()
        if _hasLoadedFromDisk {
            cacheLock.unlock()
            return
        }
        cacheLock.unlock()

        let url = directory.appendingPathComponent("samples.jsonl")
        var loaded: [TokenSample] = []
        if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            data.split(separator: 0x0A, omittingEmptySubsequences: true).forEach { chunk in
                if let s = try? decoder.decode(TokenSample.self, from: Data(chunk)) {
                    loaded.append(s)
                }
            }
        }

        cacheLock.lock()
        if !_hasLoadedFromDisk {
            // Preserve anything already appended (e.g. by a concurrent
            // caller) ahead of the on-disk content read here.
            _cached = loaded + _cached
            _hasLoadedFromDisk = true
        }
        cacheLock.unlock()
    }

    func clear() {
        let url = directory.appendingPathComponent("samples.jsonl")
        try? FileManager.default.removeItem(at: url)
        cacheLock.lock()
        _cached = []
        _hasLoadedFromDisk = true
        cacheLock.unlock()
    }

    /// Wipes the store but keeps samples for `preservingTools`. Used by the
    /// cache reset so a full rescan of the re-derivable file/DB sources never
    /// destroys data from an ephemeral source (CLIProxyAPI's pop-on-read
    /// queue), for which this store holds the only surviving copy.
    func clear(preservingTools: Set<ToolKind>) {
        guard !preservingTools.isEmpty else { clear(); return }
        ensureLoadedFromDisk()
        cacheLock.lock()
        let kept = _cached.filter { preservingTools.contains($0.tool) }
        cacheLock.unlock()

        queue.sync {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("samples.jsonl")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var data = Data()
            for s in kept {
                if let d = try? encoder.encode(s) {
                    data.append(d)
                    data.append(0x0A)
                }
            }
            try? data.write(to: fileURL)
        }
        cacheLock.lock()
        _cached = kept
        _hasLoadedFromDisk = true
        cacheLock.unlock()
    }
}
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published var migrationNotice: String?

    private let home: URL
    private let progress: SourceProgress
    private let sources: [TokenSource]
    private let sampleStore: SampleStore
    private let migrationURL: URL
    private var refreshTimer: Timer?

    // Incremental aggregation state carried across refresh cycles. Bucketed
    // by day/hour (at most a few thousand entries even after months of
    // continuous uptime), not by raw sample - so each cycle only has to fold
    // in the handful of newly-collected samples, never rescan the entire
    // history. Before this, every refresh (every 30s) re-scanned *all*
    // samples from scratch to rebuild every window's roll-up/trend/sparkline,
    // which for a heavy real history (millions of samples) meant the app was
    // almost continuously busy re-deriving numbers nobody had asked to see
    // change yet.
    private var dayBuckets: [Date: DailyAggregate] = [:]
    private var hourBuckets: [Date: DailyAggregate] = [:]
    private var lastSampleByTool: [ToolKind: Date] = [:]
    private var isBootstrapped = false

    init(home: URL) {
        self.home = home
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let progressURL = supportDir.appendingPathComponent("TokenBar/source_progress.json")
        self.progress = SourceProgress(storeURL: progressURL)
        self.sampleStore = SampleStore(directory: supportDir.appendingPathComponent("TokenBar/samples"))
        self.migrationURL = supportDir.appendingPathComponent("TokenBar/schema_version.json")
        let testHome = ProcessInfo.processInfo.environment["TOKENBAR_TEST_HOME"].map { URL(fileURLWithPath: $0) }
        let effectiveHome = testHome ?? home
        self.sources = [
            CodexSource(home: effectiveHome, progress: progress),
            ClaudeCodeSource(home: effectiveHome, progress: progress),
            OpenCodeSource(home: effectiveHome, progress: progress),
            TraeSource(home: effectiveHome, progress: progress),
            WorkBuddySource(home: effectiveHome, progress: progress),
            CLIProxyAPISource()
        ]
    }

    func start() {
        Task {
            var state = MigrationState.load(storeURL: migrationURL)
            if state.schemaVersion < MigrationState.current {
                await resetCaches()
                migrationNotice = "已修复 token 统计口径问题，历史数据已清空并重新全量扫描"
                state.schemaVersion = MigrationState.current
                state.save(storeURL: migrationURL)
            } else {
                await refresh()
            }
        }
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        var statusByTool: [ToolKind: SourceStatus] = [:]
        var firstError: String? = nil
        var newlyCollected: [TokenSample] = []

        for source in sources {
            do {
                // Scanning can mean parsing millions of JSONL lines on a
                // heavy user's first full rescan; run it on a detached task
                // so it never ties up the main actor / main thread and the
                // UI (menu bar clicks, opening the dashboard) stays
                // responsive while `isRefreshing` is true.
                let result = try await Task.detached(priority: .utility) {
                    try await source.collect()
                }.value
                sampleStore.append(result.samples)
                newlyCollected.append(contentsOf: result.samples)
                statusByTool[source.tool] = SourceStatus(
                    scannedAt: Date(),
                    fileCount: result.fileCount,
                    sampleCount: result.samples.count,
                    lastError: nil,
                    note: result.note
                )
            } catch {
                let message = Self.friendlyMessage(for: error)
                statusByTool[source.tool] = SourceStatus(
                    scannedAt: Date(),
                    fileCount: 0,
                    sampleCount: 0,
                    lastError: message,
                    note: nil
                )
                if firstError == nil { firstError = "\(source.tool.rawValue): \(message)" }
            }
        }

        if !isBootstrapped {
            // First refresh since launch: fold the entire persisted history
            // into day/hour buckets exactly once, off the main actor since
            // this one pass is the expensive O(all samples) step. Every
            // refresh after this only has to fold in `newlyCollected`.
            let allSamples = sampleStore.loadAll()
            let bootstrap = await Task.detached(priority: .utility) {
                Self.fold(samples: allSamples, into: BucketState())
            }.value
            dayBuckets = bootstrap.dayBuckets
            hourBuckets = bootstrap.hourBuckets
            lastSampleByTool = bootstrap.lastSampleByTool
            isBootstrapped = true
        } else if !newlyCollected.isEmpty {
            let updated = Self.fold(
                samples: newlyCollected,
                into: BucketState(dayBuckets: dayBuckets, hourBuckets: hourBuckets, lastSampleByTool: lastSampleByTool)
            )
            dayBuckets = updated.dayBuckets
            hourBuckets = updated.hourBuckets
            lastSampleByTool = updated.lastSampleByTool
        }

        let now = Date()
        let derived = Self.deriveSnapshotData(dayBuckets: dayBuckets, hourBuckets: hourBuckets, now: now)
        snapshot = UsageSnapshot(
            generatedAt: now,
            allDays: dayBuckets.keys.sorted().map { dayBuckets[$0]! },
            lastSampleByTool: lastSampleByTool,
            sourcesStatus: statusByTool,
            rollups: derived.rollups,
            trends: derived.trends,
            sparklines: derived.sparklines
        )
        lastError = firstError
    }

    struct BucketState {
        var dayBuckets: [Date: DailyAggregate] = [:]
        var hourBuckets: [Date: DailyAggregate] = [:]
        var lastSampleByTool: [ToolKind: Date] = [:]
    }

    /// Folds `samples` into a copy of `state`. Used both for the one-time
    /// full-history bootstrap and for each cycle's small incremental batch -
    /// the cost is always proportional to `samples.count`, never to however
    /// much history has accumulated in the buckets already.
    nonisolated static func fold(samples: [TokenSample], into state: BucketState) -> BucketState {
        var state = state
        let calendar = Calendar.current
        for s in samples {
            let day = Aggregator.dayKey(for: s.timestamp, calendar: calendar)
            var dayBucket = state.dayBuckets[day] ?? DailyAggregate(date: day)
            Aggregator.accumulate(sample: s, into: &dayBucket)
            state.dayBuckets[day] = dayBucket

            let hour = Aggregator.hourKey(for: s.timestamp, calendar: calendar)
            var hourBucket = state.hourBuckets[hour] ?? DailyAggregate(date: hour)
            Aggregator.accumulate(sample: s, into: &hourBucket)
            state.hourBuckets[hour] = hourBucket

            let prior = state.lastSampleByTool[s.tool] ?? .distantPast
            if s.timestamp > prior { state.lastSampleByTool[s.tool] = s.timestamp }
        }
        return state
    }

    struct Derived {
        let rollups: [DisplayWindow: DailyAggregate]
        let trends: [DisplayWindow: [TrendBucket]]
        let sparklines: [ToolKind: [TrendBucket]]
    }

    /// Derives every window's roll-up/trend and every tool's sparkline from
    /// the (small, precomputed) day/hour buckets - dictionary look-ups and a
    /// handful of merges, not a scan over raw samples.
    nonisolated static func deriveSnapshotData(dayBuckets: [Date: DailyAggregate], hourBuckets: [Date: DailyAggregate], now: Date) -> Derived {
        let calendar = Calendar.current
        var rollups: [DisplayWindow: DailyAggregate] = [:]
        var trends: [DisplayWindow: [TrendBucket]] = [:]
        for window in DisplayWindow.allCases {
            rollups[window] = rollup(for: window, dayBuckets: dayBuckets, hourBuckets: hourBuckets, now: now, calendar: calendar)
            trends[window] = trend(for: window, dayBuckets: dayBuckets, hourBuckets: hourBuckets, now: now, calendar: calendar)
        }
        var sparklines: [ToolKind: [TrendBucket]] = [:]
        for tool in ToolKind.allCases {
            sparklines[tool] = sparkline(for: tool, hourBuckets: hourBuckets, now: now, calendar: calendar)
        }
        return Derived(rollups: rollups, trends: trends, sparklines: sparklines)
    }

    nonisolated static func rollup(for window: DisplayWindow, dayBuckets: [Date: DailyAggregate], hourBuckets: [Date: DailyAggregate], now: Date, calendar: Calendar) -> DailyAggregate {
        var result = DailyAggregate(date: calendar.startOfDay(for: now))
        switch window {
        case .today:
            return dayBuckets[calendar.startOfDay(for: now)] ?? result
        case .last24h:
            // Not day-aligned, so summed from hour buckets instead (like the
            // trend bars already were) - up to an hour of edge imprecision,
            // consistent with the granularity already used for its chart.
            let cutoff = Aggregator.hourKey(for: now.addingTimeInterval(-24 * 3600), calendar: calendar)
            for (hour, agg) in hourBuckets where hour >= cutoff {
                Aggregator.merge(agg, into: &result)
            }
            return result
        default:
            guard let start = window.startDate(now: now, calendar: calendar) else {
                // .all
                for agg in dayBuckets.values { Aggregator.merge(agg, into: &result) }
                return result
            }
            for (day, agg) in dayBuckets where day >= start {
                Aggregator.merge(agg, into: &result)
            }
            return result
        }
    }

    nonisolated static func trend(for window: DisplayWindow, dayBuckets: [Date: DailyAggregate], hourBuckets: [Date: DailyAggregate], now: Date, calendar: Calendar) -> [TrendBucket] {
        let count = window.bucketCount
        switch window.bucketGranularity {
        case .hour:
            // `.today` and `.last24h` both use hour granularity but mean
            // different things: "今天" is the calendar day from midnight
            // (so later, not-yet-happened hours show as empty), while
            // "24h" is a rolling window ending at the current hour. Both
            // used to compute the identical "last 24h ending now" range,
            // making the two pills render pixel-identical charts.
            let firstHour: Date
            if window == .today {
                firstHour = calendar.startOfDay(for: now)
            } else {
                let currentHour = Aggregator.hourKey(for: now, calendar: calendar)
                firstHour = currentHour.addingTimeInterval(-Double(count - 1) * 3600)
            }
            var buckets: [TrendBucket] = []
            for i in 0..<count {
                let hourStart = firstHour.addingTimeInterval(Double(i) * 3600)
                let agg = hourBuckets[hourStart] ?? DailyAggregate(date: hourStart)
                buckets.append(TrendBucket(id: hourStart, granularity: .hour, aggregate: agg))
            }
            return buckets
        case .day:
            let today = calendar.startOfDay(for: now)
            let firstDay = calendar.date(byAdding: .day, value: -(count - 1), to: today) ?? today
            var ordered: [TrendBucket] = []
            for i in 0..<count {
                let day = calendar.date(byAdding: .day, value: i, to: firstDay) ?? firstDay
                let agg = dayBuckets[day] ?? DailyAggregate(date: day)
                ordered.append(TrendBucket(id: day, granularity: .day, aggregate: agg))
            }
            return ordered
        }
    }

    nonisolated static func sparkline(for tool: ToolKind, hourBuckets: [Date: DailyAggregate], now: Date, calendar: Calendar) -> [TrendBucket] {
        let today = calendar.startOfDay(for: now)
        var out: [TrendBucket] = []
        for offset in stride(from: 23, through: 0, by: -1) {
            let hour = Aggregator.hourKey(for: today.addingTimeInterval(-Double(offset) * 3600), calendar: calendar)
            var bucket = DailyAggregate(date: hour)
            bucket.totalTokens = hourBuckets[hour]?.byTool[tool]?.totalTokens ?? 0
            out.append(TrendBucket(id: hour, granularity: .hour, aggregate: bucket))
        }
        return out
    }

    /// Turns a raw Swift `Error` into user-facing text. Previously the
    /// dashboard displayed `String(describing: error)` directly, which for
    /// unrecognized errors dumps the Swift type/case name straight into the UI.
    private static func friendlyMessage(for error: Error) -> String {
        if let known = error as? TokenSourceError {
            return known.description
        }
        return "该数据源暂时不可用，请稍后重试"
    }

    func resetCaches() async {
        await progress.clear()
        await OpenCodeSource.sharedCursor.reset()
        // Preserve samples from ephemeral sources (CLIProxyAPI) whose upstream
        // data can't be re-fetched - a full rescan only re-derives the
        // file/DB-backed sources. Wiping everything here previously destroyed
        // all accumulated CLIProxyAPI history on a schema-migration rescan.
        let preserve = Set(ToolKind.allCases.filter { $0.sourceIsEphemeral })
        sampleStore.clear(preservingTools: preserve)
        dayBuckets = [:]
        hourBuckets = [:]
        lastSampleByTool = [:]
        isBootstrapped = false
        await refresh()
    }
}
