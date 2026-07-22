import Foundation

/// Parses Claude Code's JSONL session logs.
///
/// Each `assistant` line's `message.usage` reports the token cost of that one
/// API call (Anthropic's `input_tokens`/`output_tokens`/
/// `cache_creation_input_tokens`/`cache_read_input_tokens` are independent,
/// non-overlapping counters for that single call, NOT a running session
/// total). A single API call is written out as several `assistant` lines that
/// share the same `message.id` and an identical `usage` object (one line per
/// content block); we de-duplicate by `message.id` and take each unique
/// message's usage at face value instead of diffing against the previous
/// line.
final class ClaudeCodeSource: TokenSource {
    let tool: ToolKind = .claudeCode
    private let home: URL
    private let progress: SourceProgress

    init(home: URL, progress: SourceProgress) {
        self.home = home
        self.progress = progress
    }

    private struct ClaudeUsage: Decodable {
        let input_tokens: Int?
        let cache_creation_input_tokens: Int?
        let cache_read_input_tokens: Int?
        let output_tokens: Int?
    }

    private struct ClaudeMessage: Decodable {
        let id: String?
        let model: String?
        let usage: ClaudeUsage?
    }

    private struct ClaudeLine: Decodable {
        let type: String?
        let timestamp: String?
        let message: ClaudeMessage?
    }

    func collect() async throws -> SourceResult {
        let projectsDir = home.appendingPathComponent(".claude/projects")
        guard FileManager.default.fileExists(atPath: projectsDir.path) else {
            return SourceResult.empty(note: "~/.claude/projects 不存在")
        }
        let projectDirs = (try? FileManager.default.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil)) ?? []
        var samples: [TokenSample] = []
        var fileCount = 0
        for dir in projectDirs {
            let jsonls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "jsonl" } ?? []
            for url in jsonls {
                fileCount += 1
                let key = "claude:\(url.path)"
                let identity = FileIdentity.of(url)
                let prior = await progress.get(key)
                var startOffset: UInt64 = 0
                if let prior, prior.identity == identity {
                    startOffset = prior.offset
                }

                // Repeated content-block lines for the same API call share
                // the same message id and usage; only count each message once.
                var lastMessageID: String? = startOffset > 0
                    ? loadLastMessageID(url: url, upTo: startOffset)
                    : nil

                guard let stream = ChunkedLineReader.stream(url: url, startingOffset: startOffset, perLine: { line in
                    guard let rec = try? JSONDecoder().decode(ClaudeLine.self, from: Data(line.utf8)) else { return }
                    guard rec.type == "assistant", let msg = rec.message, let usage = msg.usage, let msgID = msg.id else { return }
                    if msgID == lastMessageID { return }
                    lastMessageID = msgID
                    let ts = parseTimestamp(rec.timestamp) ?? Date()
                    let input = usage.input_tokens ?? 0
                    let output = usage.output_tokens ?? 0
                    let cacheRead = usage.cache_read_input_tokens ?? 0
                    let cacheWrite = usage.cache_creation_input_tokens ?? 0
                    if input == 0 && output == 0 && cacheRead == 0 && cacheWrite == 0 { return }
                    samples.append(TokenSample(
                        tool: .claudeCode,
                        model: msg.model ?? "claude",
                        timestamp: ts,
                        // Anthropic's input_tokens already excludes cached
                        // tokens (they're reported separately), so no
                        // subtraction is needed here unlike Codex.
                        inputTokens: input,
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
        let note = fileCount == 0 ? "未发现 ~/.claude/projects 下的会话 JSONL" : nil
        return SourceResult(samples: samples, fileCount: fileCount, note: note)
    }

    /// Scans up to `offset` and returns the last `message.id` seen, so a
    /// resumed read can tell whether its first new line is a repeated
    /// content-block for a message that was already counted. Bounded to the
    /// already-processed prefix (not the whole file) and chunked so it stays
    /// memory-safe even for a large, mostly-already-scanned session log.
    private func loadLastMessageID(url: URL, upTo offset: UInt64) -> String? {
        var latestID: String? = nil
        _ = ChunkedLineReader.stream(url: url, startingOffset: 0, upperBound: offset) { line in
            guard let rec = try? JSONDecoder().decode(ClaudeLine.self, from: Data(line.utf8)) else { return }
            guard rec.type == "assistant", let id = rec.message?.id, rec.message?.usage != nil else { return }
            latestID = id
        }
        return latestID
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
