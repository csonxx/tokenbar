import Foundation

/// Parses WorkBuddy's JSONL session logs under `~/.workbuddy/projects` and
/// `~/.workbuddy-ai/projects` (the current and legacy data dirs).
///
/// Unlike Claude Code, WorkBuddy attaches per-call usage to `function_call`
/// lines (the tool call an assistant turn emits), not to a separate assistant
/// message line. Each such line carries a clean `message.usage` object:
/// `{input_tokens, output_tokens, total_tokens, cache_read_input_tokens}`,
/// where `input_tokens` INCLUDES the cached portion (OpenAI/Codex-style,
/// verified: input_tokens - cache_read_input_tokens == the provider's own
/// `prompt_cache_miss_tokens`). We subtract the cache here so `inputTokens`
/// uniformly means "fresh, uncached input" like every other source.
///
/// A single API call can emit several parallel `function_call` lines that
/// share one `providerData.messageId` and repeat the same usage; we
/// de-duplicate by that id so a call is counted once.
final class WorkBuddySource: TokenSource {
    let tool: ToolKind = .workbuddy
    private let home: URL
    private let progress: SourceProgress

    init(home: URL, progress: SourceProgress) {
        self.home = home
        self.progress = progress
    }

    private struct WBUsage: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
        let cache_read_input_tokens: Int?
        let cache_creation_input_tokens: Int?
    }

    private struct WBMessage: Decodable {
        let usage: WBUsage?
    }

    private struct WBProviderData: Decodable {
        let messageId: String?
        let model: String?
    }

    private struct WBLine: Decodable {
        let id: String?
        let type: String?
        /// Unix epoch milliseconds.
        let timestamp: Double?
        let message: WBMessage?
        let providerData: WBProviderData?
    }

    func collect() async throws -> SourceResult {
        let projectDirs = [
            home.appendingPathComponent(".workbuddy/projects"),
            home.appendingPathComponent(".workbuddy-ai/projects")
        ].filter { FileManager.default.fileExists(atPath: $0.path) }

        guard !projectDirs.isEmpty else {
            return SourceResult.empty(note: "未发现 WorkBuddy 数据目录 (~/.workbuddy/projects)")
        }

        var samples: [TokenSample] = []
        var fileCount = 0
        for dir in projectDirs {
            for url in allSessionFiles(in: dir) {
                fileCount += 1
                let key = "workbuddy:\(url.path)"
                let identity = FileIdentity.of(url)
                let prior = await progress.get(key)
                var startOffset: UInt64 = 0
                if let prior, prior.identity == identity {
                    startOffset = prior.offset
                }

                // Parallel tool calls in one API turn share a messageId and
                // repeat the same usage; count each unique id once. Recover
                // the last-seen id from the already-processed prefix so a
                // resume across that boundary doesn't recount it.
                var lastMessageID: String? = startOffset > 0
                    ? loadLastMessageID(url: url, upTo: startOffset)
                    : nil

                guard let stream = ChunkedLineReader.stream(url: url, startingOffset: startOffset, perLine: { line in
                    guard let rec = try? JSONDecoder().decode(WBLine.self, from: Data(line.utf8)),
                          let usage = rec.message?.usage else { return }
                    let msgID = rec.providerData?.messageId ?? rec.id
                    if let msgID, msgID == lastMessageID { return }
                    lastMessageID = msgID

                    let rawInput = usage.input_tokens ?? 0
                    let output = usage.output_tokens ?? 0
                    let cacheRead = usage.cache_read_input_tokens ?? 0
                    let cacheWrite = usage.cache_creation_input_tokens ?? 0
                    // input_tokens is cache-inclusive (OpenAI-style) - subtract
                    // to uphold the "inputTokens = fresh, uncached input" contract.
                    let uncachedInput = max(0, rawInput - cacheRead)
                    if uncachedInput == 0 && output == 0 && cacheRead == 0 && cacheWrite == 0 { return }

                    let ts = rec.timestamp.map { Date(timeIntervalSince1970: $0 / 1000.0) } ?? Date()
                    samples.append(TokenSample(
                        tool: .workbuddy,
                        model: rec.providerData?.model ?? "workbuddy",
                        timestamp: ts,
                        inputTokens: uncachedInput,
                        outputTokens: output,
                        reasoningTokens: 0,
                        cacheReadTokens: cacheRead,
                        cacheWriteTokens: cacheWrite
                    ))
                }) else { continue }

                guard stream.hadNewBytes else { continue }
                await progress.update(key, offset: stream.newOffset, identity: identity)
            }
        }
        await progress.flush()
        let note = fileCount == 0 ? "未发现 WorkBuddy 会话 JSONL" : nil
        return SourceResult(samples: samples, fileCount: fileCount, note: note)
    }

    /// Recursively finds every `*.jsonl` session file under `dir`
    /// (`projects/<workspace>/<session-uuid>.jsonl`).
    private func allSessionFiles(in dir: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            out.append(url)
        }
        return out
    }

    /// Scans the already-processed prefix (bounded, chunked) and returns the
    /// last usage-bearing `messageId`, so a resumed read can tell whether its
    /// first new line repeats an already-counted API call.
    private func loadLastMessageID(url: URL, upTo offset: UInt64) -> String? {
        var latestID: String? = nil
        _ = ChunkedLineReader.stream(url: url, startingOffset: 0, upperBound: offset) { line in
            guard let rec = try? JSONDecoder().decode(WBLine.self, from: Data(line.utf8)),
                  rec.message?.usage != nil else { return }
            if let id = rec.providerData?.messageId ?? rec.id { latestID = id }
        }
        return latestID
    }
}
