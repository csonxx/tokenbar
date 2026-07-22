import Foundation

/// Polls a locally-running CLIProxyAPI instance's Management API usage queue
/// (`GET /v0/management/usage-queue`) for real per-request token usage.
///
/// This endpoint *pops* records - each poll consumes whatever has queued up
/// since the last one, so nothing is double-counted across refresh cycles.
/// The queue is an in-memory ring buffer pruned by
/// `redis-usage-queue-retention-seconds` (the user's own instance is
/// configured for a 600s/10min window), so this source relies on
/// `UsageStore`'s existing 30-second refresh cycle to poll far more often
/// than that window, rather than needing a separate faster timer.
///
/// Requires the proxy's `usage-statistics-enabled: true` config flag and a
/// non-empty `remote-management.secret-key`; without either, the endpoint
/// 404s or returns an empty queue forever, which is surfaced as a note
/// rather than an error banner since it's an expected steady state (nothing
/// new has come through the proxy) as much as a misconfiguration.
final class CLIProxyAPISource: TokenSource {
    let tool: ToolKind = .cliProxyAPI

    private static let pageSize = 500

    private struct TokensPayload: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
        let reasoning_tokens: Int?
        let cached_tokens: Int?
        let cache_read_tokens: Int?
        let cache_creation_tokens: Int?
    }

    private struct RecordPayload: Decodable {
        let timestamp: String?
        let provider: String?
        let model: String?
        let alias: String?
        // The OAuth account this request actually ran under (e.g. an email
        // like "avengers@multiego.me") - distinct from `provider`, which is
        // just the upstream API family (codex/claude/gemini/a custom
        // provider name). This is what should prefix the model name so
        // usage is attributable to a specific account, not just a provider.
        let source: String?
        let tokens: TokensPayload?
    }

    func collect() async throws -> SourceResult {
        let config = await MainActor.run { CLIProxyAPIConfig.load() }
        guard config.isConfigured else {
            return SourceResult.empty(note: "未配置 CLIProxyAPI 地址")
        }
        guard let base = config.resolvedBaseURL,
              var components = URLComponents(url: base.appendingPathComponent("v0/management/usage-queue"), resolvingAgainstBaseURL: false) else {
            return SourceResult.empty(note: "CLIProxyAPI 地址无效")
        }
        components.queryItems = [URLQueryItem(name: "count", value: "\(Self.pageSize)")]
        guard let url = components.url else {
            return SourceResult.empty(note: "CLIProxyAPI 地址无效")
        }

        var request = URLRequest(url: url, timeoutInterval: 5)
        let key = config.managementKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return SourceResult(samples: [], fileCount: 0, note: "无法连接到 CLIProxyAPI (\(config.baseURL))：\(error.localizedDescription)")
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let note: String
            switch http.statusCode {
            case 401, 403: note = "CLIProxyAPI 管理密钥无效或未授权"
            case 404: note = "CLIProxyAPI 管理接口未开启 (usage-statistics-enabled/secret-key)"
            default: note = "CLIProxyAPI 返回错误状态码 \(http.statusCode)"
            }
            return SourceResult(samples: [], fileCount: 0, note: note)
        }

        guard let records = try? JSONDecoder().decode([RecordPayload].self, from: data) else {
            return SourceResult(samples: [], fileCount: 0, note: "CLIProxyAPI 返回的数据无法解析")
        }

        var samples: [TokenSample] = []
        for rec in records {
            guard let sample = Self.makeSample(from: rec) else { continue }
            samples.append(sample)
        }

        return SourceResult(samples: samples, fileCount: 1, note: nil)
    }

    private static func makeSample(from rec: RecordPayload) -> TokenSample? {
        guard let tokens = rec.tokens else { return nil }
        let input = tokens.input_tokens ?? 0
        let output = tokens.output_tokens ?? 0
        let reasoning = tokens.reasoning_tokens ?? 0
        let cacheRead = tokens.cache_read_tokens ?? tokens.cached_tokens ?? 0
        let cacheWrite = tokens.cache_creation_tokens ?? 0
        if input == 0 && output == 0 && cacheRead == 0 && cacheWrite == 0 { return nil }

        // CLIProxyAPI fans out to several upstream providers, each with a
        // different convention for whether `input_tokens` already excludes
        // cached tokens. Anthropic-style APIs report input net of cache
        // (matching ClaudeCodeSource); OpenAI/Gemini-style APIs report
        // cached tokens as a *subset* of input (matching CodexSource), so
        // that portion must be subtracted here to uphold the same
        // "inputTokens = fresh, uncached input" contract as every other
        // source. This is a best-effort heuristic keyed on the provider
        // name string CLIProxyAPI reports, not a guarantee for providers
        // not yet seen.
        let provider = (rec.provider ?? "").lowercased()
        let isAnthropicStyle = provider.contains("claude") || provider.contains("anthropic")
        let normalizedInput = isAnthropicStyle ? input : max(0, input - cacheRead)

        // Prefixed with the account this request actually ran under (e.g.
        // "avengers@multiego.me") rather than just the provider family, so
        // usage from different accounts/credentials sharing the same model
        // and provider doesn't collapse into one indistinguishable row in
        // the by-model breakdown - matching OpenCodeSource's "x/model"
        // convention, just keyed on account instead of provider since
        // that's the more specific identity CLIProxyAPI exposes here.
        let account = rec.source?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let bareModelName = rec.alias?.isEmpty == false ? rec.alias! : (rec.model ?? "unknown")
        let prefix = account.isEmpty ? provider : account
        let modelName = prefix.isEmpty ? bareModelName : "\(prefix)/\(bareModelName)"
        let timestamp = rec.timestamp.flatMap(parseTimestamp) ?? Date()

        return TokenSample(
            tool: .cliProxyAPI,
            model: modelName,
            timestamp: timestamp,
            inputTokens: normalizedInput,
            outputTokens: output,
            reasoningTokens: reasoning,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite
        )
    }

    private static func parseTimestamp(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        // Go's RFC3339Nano can emit more fractional digits than Foundation's
        // ISO8601DateFormatter accepts - truncate to milliseconds and retry.
        if let truncated = truncatedFractionalSeconds(s), let d = iso.date(from: truncated) { return d }
        let isoNoFraction = ISO8601DateFormatter()
        isoNoFraction.formatOptions = [.withInternetDateTime]
        return isoNoFraction.date(from: s)
    }

    private static func truncatedFractionalSeconds(_ s: String) -> String? {
        guard let dotIndex = s.firstIndex(of: ".") else { return nil }
        var digitsEnd = s.index(after: dotIndex)
        while digitsEnd < s.endIndex, s[digitsEnd].isNumber { digitsEnd = s.index(after: digitsEnd) }
        let keepEnd = s.index(dotIndex, offsetBy: min(4, s.distance(from: dotIndex, to: digitsEnd)))
        return String(s[s.startIndex..<keepEnd]) + String(s[digitsEnd...])
    }
}
