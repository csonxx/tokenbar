import Foundation

/// Parses Codex's JSONL rollouts under `~/.codex/sessions` (live, nested by
/// date) and `~/.codex/archived_sessions` (flat, once a session ends).
/// Each rollout contains `event_msg` records with `payload.type == "token_count"`
/// whose `info.total_token_usage` is a monotonically increasing cumulative
/// total for the session; we emit one sample per record using the delta
/// against the previous record. Reads are offset-incremental, keyed by
/// filename so a session survives its move from sessions/ to archived_sessions/.
///
/// Real Codex rollouts can run into the multiple gigabytes (a long session's
/// `response_item` records embed full tool output/diffs). Everything here is
/// deliberately streamed in bounded chunks rather than loading a file's
/// remaining content into memory as one `String` - a single 8GB session file
/// materialized whole was enough to make the whole app appear to hang.
final class CodexSource: TokenSource {
    let tool: ToolKind = .codex
    private let home: URL
    private let progress: SourceProgress

    init(home: URL, progress: SourceProgress) {
        self.home = home
        self.progress = progress
    }

    private struct CodexLine: Decodable {
        struct Payload: Decodable {
            struct TokenInfo: Decodable {
                struct Usage: Codable {
                    let input_tokens: Int?
                    let cached_input_tokens: Int?
                    let cache_write_input_tokens: Int?
                    let output_tokens: Int?
                    let reasoning_output_tokens: Int?
                    let total_tokens: Int?
                }
                let last_token_usage: Usage?
                let total_token_usage: Usage?
            }
            let type: String?
            let info: TokenInfo?
        }
        let type: String?
        let timestamp: String?
        let payload: Payload?
    }

    private struct SessionMeta: Decodable {
        let type: String?
        let payload: SessionMetaPayload?
        struct SessionMetaPayload: Decodable {
            let model_provider: String?
            /// Present when this rollout was forked from another session.
            /// Codex replays the *entire* parent history's token_count events
            /// into the new file at fork time (all stamped at the fork
            /// instant, in a dense sub-second burst), then continues live.
            /// That replayed prefix was already counted under the parent's
            /// own rollout, so counting it again here double-counts a whole
            /// session (observed as a multi-billion-token spike dumped into
            /// the single minute the fork happened).
            let forked_from_id: String?
        }
    }

    /// A gap larger than this between consecutive `token_count` events marks
    /// the end of a fork's replayed history burst: the replay is a mechanical
    /// dump with sub-second spacing, while real generation checkpoints are
    /// seconds apart (5-15s in practice, never sub-second). Comfortably above
    /// the former, below the latter.
    private static let forkReplayGapThreshold: TimeInterval = 2.0

    private struct TurnContext: Decodable {
        let type: String?
        let payload: TurnContextPayload?
        struct TurnContextPayload: Decodable {
            let model: String?
        }
    }

    private struct Increment {
        let inputTokens: Int
        let outputTokens: Int
        let reasoning: Int
        let cacheRead: Int
        let cacheWrite: Int
        let totalTokens: Int
    }

    // Most lines in a rollout are large `response_item` records (full message/
    // tool-output text) that never match any of these markers. A byte-level
    // *substring* search still has to scan the entire line to confirm a
    // marker is absent - fine for short lines, but real rollouts can have
    // single `response_item` lines that are multiple megabytes (embedded
    // diffs/tool output). The outer JSON `"type"` field always appears near
    // the very start of the line though (right after `timestamp`), so
    // extracting just that value from a small bounded prefix lets us skip
    // irrelevant lines in ~O(1) instead of O(line length).
    private static let tokenCountMarker: [UInt8] = Array("\"token_count\"".utf8)
    private static let typeKeyPrefixScanWindow = 200

    private static func line(_ line: Substring, contains marker: [UInt8]) -> Bool {
        line.utf8.firstRange(of: marker) != nil
    }

    /// Extracts the outer `"type": "..."` value from the start of a rollout
    /// line without scanning its (potentially huge) remainder.
    private static func outerType(of line: Substring) -> Substring? {
        let window = line.prefix(typeKeyPrefixScanWindow)
        guard let keyRange = window.range(of: "\"type\"", options: .literal) else { return nil }
        guard let colon = window[keyRange.upperBound...].firstIndex(of: ":") else { return nil }
        let afterColon = window[window.index(after: colon)...]
        guard let openQuote = afterColon.firstIndex(of: "\""),
              let closeQuote = afterColon[afterColon.index(after: openQuote)...].firstIndex(of: "\"") else { return nil }
        return afterColon[afterColon.index(after: openQuote)..<closeQuote]
    }

    /// Small JSON blob persisted per-file in `SourceProgress` so a resumed
    /// scan can recover its running baseline in O(1) instead of re-reading
    /// the file's entire already-processed prefix.
    private struct BaselineBlob: Codable {
        let usage: CodexLine.Payload.TokenInfo.Usage?
        let model: String?
    }

    private static func encodeBaseline(usage: CodexLine.Payload.TokenInfo.Usage?, model: String?) -> String? {
        guard usage != nil || model != nil else { return nil }
        guard let data = try? JSONEncoder().encode(BaselineBlob(usage: usage, model: model)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeBaseline(_ raw: String) -> (usage: CodexLine.Payload.TokenInfo.Usage?, model: String?) {
        guard let data = raw.data(using: .utf8),
              let blob = try? JSONDecoder().decode(BaselineBlob.self, from: data) else {
            return (nil, nil)
        }
        return (blob.usage, blob.model)
    }

    func collect() async throws -> SourceResult {
        let archived = home.appendingPathComponent(".codex/archived_sessions")
        let live = home.appendingPathComponent(".codex/sessions")
        var samples: [TokenSample] = []
        var fileCount = 0
        let directories = [archived, live].filter { FileManager.default.fileExists(atPath: $0.path) }
        for dir in directories {
            let rollouts = allRolloutFiles(in: dir)
            for url in rollouts {
                fileCount += 1
                // Keyed by filename (which embeds a stable session UUID) rather
                // than full path: Codex moves rollout files from sessions/ to
                // archived_sessions/ once a session ends, which would otherwise
                // look like a brand-new file and cause the whole session to be
                // re-scanned and double-counted.
                let key = "codex:\(url.lastPathComponent)"
                let identity = FileIdentity.of(url)
                let prior = await progress.get(key)
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0

                var startOffset: UInt64 = 0
                var lastTotal: CodexLine.Payload.TokenInfo.Usage? = nil
                var modelGuess = "codex"
                // Fork-replay suppression state. Only meaningful on a file's
                // first scan (offset 0), where the replayed parent history
                // sits as a dense burst right after `session_meta`; on a
                // resumed scan (offset > 0) that burst is already behind us,
                // so we never re-enter replay mode.
                var replayActive = false
                var lastTokenCountTs: Date? = nil
                if let prior, prior.identity == identity, prior.offset <= fileSize {
                    startOffset = prior.offset
                    if let raw = prior.metadata {
                        let decoded = Self.decodeBaseline(raw)
                        lastTotal = decoded.usage
                        if let m = decoded.model { modelGuess = m }
                    } else if prior.offset > 0 {
                        // Resuming a file that already has processed history
                        // but no persisted baseline (e.g. its cursor was
                        // written before baseline metadata existed). Treating
                        // the next token_count event as a delta from zero
                        // would be catastrophically wrong here - against a
                        // monotonically increasing cumulative counter that
                        // may already be in the tens of thousands, it
                        // produces one enormous spurious sample. Recover the
                        // real baseline once by scanning the already-read
                        // prefix, bounded to that prefix only (not the whole
                        // file) and still chunked so it stays memory-safe.
                        let recovered = recoverBaseline(url: url, upTo: prior.offset)
                        lastTotal = recovered.usage
                        if let m = recovered.model { modelGuess = m }
                    }
                }

                // Codex fires a `token_count` checkpoint roughly every 5-15
                // seconds *during* a single turn's generation - not once per
                // turn - so emitting one sample per checkpoint inflated
                // "调用次数" by roughly an order of magnitude (a single real
                // turn split across a dozen-plus rows) and fragmented that
                // turn's tokens the same way. Accumulate deltas into the
                // in-progress turn and only flush one combined sample when a
                // new `turn_context` starts the next turn (or at the end of
                // this batch, for whichever turn is still in progress).
                var pending: Increment? = nil
                var pendingTimestamp: Date? = nil
                func flushPending() {
                    guard let acc = pending, let ts = pendingTimestamp else { return }
                    pending = nil
                    pendingTimestamp = nil
                    if acc.totalTokens <= 0 && acc.inputTokens <= 0 && acc.outputTokens <= 0 { return }
                    samples.append(TokenSample(
                        tool: .codex,
                        model: modelGuess,
                        timestamp: ts,
                        inputTokens: acc.inputTokens,
                        outputTokens: acc.outputTokens,
                        reasoningTokens: acc.reasoning,
                        cacheReadTokens: acc.cacheRead,
                        cacheWriteTokens: acc.cacheWrite
                    ))
                }

                guard let stream = ChunkedLineReader.stream(url: url, startingOffset: startOffset, perLine: { line in
                    // Dispatch on the outer `"type"` field first - it's a
                    // bounded-cost check regardless of how large the line's
                    // payload is, so the overwhelming majority of lines
                    // (`response_item`, with potentially megabytes of
                    // embedded diff/tool-output text) get skipped without
                    // ever scanning their content.
                    guard let outerType = Self.outerType(of: line) else { return }
                    switch outerType {
                    case "session_meta":
                        if let meta = try? JSONDecoder().decode(SessionMeta.self, from: Data(line.utf8)) {
                            if modelGuess == "codex", let provider = meta.payload?.model_provider, !provider.isEmpty {
                                modelGuess = provider
                            }
                            // A forked session's replayed parent history is
                            // only present at the very start of the file, so
                            // only arm replay suppression on the first scan.
                            if startOffset == 0,
                               let forked = meta.payload?.forked_from_id, !forked.isEmpty {
                                replayActive = true
                            }
                        }
                    case "turn_context":
                        // A new turn is starting, so whatever was accumulated
                        // for the previous one is done - flush it under the
                        // model that was active *during* that turn, before
                        // switching `modelGuess` to the new one.
                        flushPending()
                        if let ctx = try? JSONDecoder().decode(TurnContext.self, from: Data(line.utf8)),
                           let model = ctx.payload?.model, !model.isEmpty {
                            modelGuess = model
                        }
                    case "event_msg":
                        // Use total_token_usage as our reference, because it is
                        // the monotonically increasing cumulative count of
                        // every token ever spent in this session.
                        // `last_token_usage` only reflects the most recent
                        // turn, so a current-minus-last delta against it is
                        // meaningless across turns.
                        guard Self.line(line, contains: Self.tokenCountMarker) else { return }
                        guard let rec = try? JSONDecoder().decode(CodexLine.self, from: Data(line.utf8)) else { return }
                        guard let info = rec.payload?.info else { return }
                        guard let current = referenceUsage(info) else { return }
                        let ts = parseTimestamp(rec.timestamp) ?? Date()
                        // The replayed history burst is a run of token_count
                        // events packed sub-second; the first real (live)
                        // event after it arrives seconds later. Once that gap
                        // appears, the replay is over and we start counting.
                        if replayActive, let last = lastTokenCountTs,
                           ts.timeIntervalSince(last) > Self.forkReplayGapThreshold {
                            replayActive = false
                        }
                        lastTokenCountTs = ts
                        let inc = incremental(current: current, last: lastTotal)
                        // Keep tracking the counter Codex itself reports so
                        // later, real turns in this file still get correct
                        // deltas - we just don't want to *count* an
                        // implausible one. This must happen even while
                        // suppressing replay, so the first live delta is
                        // measured against the parent's final cumulative
                        // (i.e. counts only genuinely new fork activity).
                        lastTotal = current
                        // Replayed parent history: already counted under the
                        // parent rollout, so advance the baseline (done above)
                        // but never emit or coalesce it.
                        if replayActive { return }
                        // Skip pure-zero deltas to keep the timeline honest.
                        if inc.totalTokens <= 0 && inc.inputTokens <= 0 && inc.outputTokens <= 0 { return }
                        // Guard against corrupted upstream data: real Codex
                        // logs have been observed reporting a
                        // `cached_input_tokens` in the billions for a single
                        // turn (verified against raw rollout files - this is
                        // a Codex-side bug, not a delta computed incorrectly
                        // here). No legitimate single turn plausibly
                        // processes tens of millions of tokens, let alone
                        // billions, so treat anything past a generous
                        // headroom as corrupted and drop just that sample.
                        guard Self.isPlausible(inc) else { return }
                        if let existing = pending {
                            pending = Increment(
                                inputTokens: existing.inputTokens + inc.inputTokens,
                                outputTokens: existing.outputTokens + inc.outputTokens,
                                reasoning: existing.reasoning + inc.reasoning,
                                cacheRead: existing.cacheRead + inc.cacheRead,
                                cacheWrite: existing.cacheWrite + inc.cacheWrite,
                                totalTokens: existing.totalTokens + inc.totalTokens
                            )
                        } else {
                            pending = inc
                        }
                        pendingTimestamp = ts
                    default:
                        return
                    }
                }) else { continue }
                // Whatever turn was still in progress at the end of this
                // batch (no closing `turn_context` seen yet) still counts.
                flushPending()

                guard stream.hadNewBytes else { continue }
                let metadata = Self.encodeBaseline(usage: lastTotal, model: modelGuess == "codex" ? nil : modelGuess)
                await progress.update(key, offset: stream.newOffset, identity: identity, metadata: metadata)
            }
        }

        await progress.flush()
        let note = fileCount == 0 ? "未发现 ~/.codex 下的 rollout 文件" : nil
        return SourceResult(samples: samples, fileCount: fileCount, note: note)
    }

    /// Recursively finds every `rollout-*.jsonl` file under `dir`. Codex nests
    /// live sessions under `sessions/YYYY/MM/DD/`, so a shallow directory
    /// listing (as used previously) misses nearly all of them.
    private func allRolloutFiles(in dir: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [URL] = []
        for case let url as URL in enumerator {
            if url.pathExtension == "jsonl", url.lastPathComponent.hasPrefix("rollout-") {
                out.append(url)
            }
        }
        return out
    }

    /// `total_token_usage` is the monotonically increasing cumulative count for
    /// the whole session; `last_token_usage` (single-turn) is only a fallback
    /// for older logs that lack the cumulative field. Both the live scan and
    /// the resume baseline must read the same field or their difference is
    /// meaningless.
    private func referenceUsage(_ info: CodexLine.Payload.TokenInfo) -> CodexLine.Payload.TokenInfo.Usage? {
        info.total_token_usage ?? info.last_token_usage
    }

    /// Recovers the running `total_token_usage`/model baseline for a file
    /// whose cursor has an offset but no persisted metadata, by scanning only
    /// its already-processed prefix (bounded to `upTo`, not the whole file).
    private func recoverBaseline(url: URL, upTo: UInt64) -> (usage: CodexLine.Payload.TokenInfo.Usage?, model: String?) {
        var latestUsage: CodexLine.Payload.TokenInfo.Usage? = nil
        var latestModel: String? = nil
        _ = ChunkedLineReader.stream(url: url, startingOffset: 0, upperBound: upTo) { line in
            guard let outerType = Self.outerType(of: line) else { return }
            switch outerType {
            case "turn_context":
                if let ctx = try? JSONDecoder().decode(TurnContext.self, from: Data(line.utf8)),
                   let model = ctx.payload?.model, !model.isEmpty {
                    latestModel = model
                }
            case "event_msg":
                guard Self.line(line, contains: Self.tokenCountMarker) else { return }
                if let rec = try? JSONDecoder().decode(CodexLine.self, from: Data(line.utf8)),
                   let info = rec.payload?.info, let u = referenceUsage(info) {
                    latestUsage = u
                }
            default:
                return
            }
        }
        return (latestUsage, latestModel)
    }

    /// Generous upper bound for any single field in a single turn's delta.
    /// Real single-turn usage (even an enormous cache-heavy Claude Code
    /// message) tops out in the low millions; this is purely a guard against
    /// corrupted upstream counters, not a real-world usage ceiling.
    private static let maxPlausibleSingleEventTokens = 10_000_000

    private static func isPlausible(_ inc: Increment) -> Bool {
        inc.inputTokens <= maxPlausibleSingleEventTokens
            && inc.outputTokens <= maxPlausibleSingleEventTokens
            && inc.cacheRead <= maxPlausibleSingleEventTokens
            && inc.cacheWrite <= maxPlausibleSingleEventTokens
    }

    private func incremental(current: CodexLine.Payload.TokenInfo.Usage, last: CodexLine.Payload.TokenInfo.Usage?) -> Increment {
        // Codex's `input_tokens` includes `cached_input_tokens` as a subset
        // (verified against real rollout data: input_tokens + output_tokens ==
        // total_tokens, with cached_input_tokens <= input_tokens). We subtract
        // the cache delta here so `Increment.inputTokens` uniformly means
        // "fresh, uncached input" before it ever reaches `TokenSample`.
        let inputDelta = (current.input_tokens ?? 0) - (last?.input_tokens ?? 0)
        let cachedDelta = (current.cached_input_tokens ?? 0) - (last?.cached_input_tokens ?? 0)
        let cacheWriteDelta = (current.cache_write_input_tokens ?? 0) - (last?.cache_write_input_tokens ?? 0)
        let outputDelta = (current.output_tokens ?? 0) - (last?.output_tokens ?? 0)
        let reasoningDelta = (current.reasoning_output_tokens ?? 0) - (last?.reasoning_output_tokens ?? 0)
        let totalDelta = (current.total_tokens ?? 0) - (last?.total_tokens ?? 0)
        return Increment(
            inputTokens: max(0, inputDelta - cachedDelta),
            outputTokens: max(0, outputDelta),
            reasoning: max(0, reasoningDelta),
            cacheRead: max(0, cachedDelta),
            cacheWrite: max(0, cacheWriteDelta),
            totalTokens: max(0, totalDelta)
        )
    }

    private func parseTimestamp(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    }
}
