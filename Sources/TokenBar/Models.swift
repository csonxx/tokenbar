import Foundation
import SwiftUI
import AppKit

enum ToolKind: String, CaseIterable, Codable, Identifiable {
    case codex = "Codex"
    case claudeCode = "Claude Code"
    case opencode = "OpenCode"
    case trae = "TRAE"
    case cliProxyAPI = "CLIProxyAPI"
    case workbuddy = "WorkBuddy"

    var id: String { rawValue }

    /// True when this source's upstream data is consume-once / non-persistent,
    /// so TokenBar's own sample store holds the *only* copy. CLIProxyAPI's
    /// `/v0/management/usage-queue` is a pop-on-read, in-memory queue with a
    /// short retention window, so once TokenBar has drained a record it exists
    /// nowhere else. File/DB-backed sources (Codex/Claude/OpenCode) can always
    /// be re-scanned from their on-disk source, so they're safe to wipe on a
    /// cache reset; ephemeral ones must be preserved across resets.
    var sourceIsEphemeral: Bool {
        switch self {
        case .cliProxyAPI: return true
        case .codex, .claudeCode, .opencode, .trae, .workbuddy: return false
        }
    }

    var systemImage: String {
        switch self {
        case .codex: return "terminal"
        case .claudeCode: return "bubble.left.and.bubble.right.fill"
        case .opencode: return "chevron.left.forwardslash.chevron.right"
        case .trae: return "hammer.fill"
        case .cliProxyAPI: return "network"
        case .workbuddy: return "briefcase.fill"
        }
    }

    /// Single source of truth for this tool's accent color, used by every
    /// card, chart, and legend so the mapping can't drift between views.
    var tintColor: Color {
        switch self {
        case .codex: return .blue
        case .claudeCode: return .orange
        case .opencode: return .purple
        case .trae: return .green
        case .cliProxyAPI: return .teal
        case .workbuddy: return .pink
        }
    }

    private var productIconFileName: String? {
        switch self {
        case .codex: return "tool-codex"
        case .claudeCode: return "tool-claude"
        case .opencode: return "tool-opencode"
        case .trae: return "tool-trae"
        case .cliProxyAPI: return nil
        case .workbuddy: return "tool-workbuddy"
        }
    }

    /// The tool's actual product icon (sourced from its real, locally
    /// installed app - Claude.app, OpenCode.app, Trae.app, and the Codex
    /// icon bundled inside ChatGPT.app) rather than a generic SF Symbol
    /// standing in for it. `nil` if there's no bundled asset for this tool
    /// (e.g. CLIProxyAPI, a local reverse proxy with no distinct app icon),
    /// in which case callers should fall back to `systemImage`.
    var productIcon: NSImage? {
        guard let name = productIconFileName,
              let url = Bundle.module.url(forResource: name, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}

/// Approximate public list-price ratios for each token category, expressed
/// **relative to that model's own base (uncached) input-token price**. Used to
/// turn the four raw token counts into a single cost-weighted "计费" number in
/// units of "equivalent uncached-input tokens" - without needing absolute
/// dollar prices, which drift constantly and, for the subscription/OAuth plans
/// most of these tools use, aren't what you actually pay anyway. These are
/// rough list-price shapes, not exact billing; edit here if a provider changes.
struct TokenCostWeights {
    /// Fresh uncached input is the baseline (always 1.0).
    let cacheRead: Double
    let cacheWrite: Double
    let output: Double

    // Anthropic: cache read ~0.1x input, cache write (5-min) ~1.25x, output ~5x.
    static let anthropic = TokenCostWeights(cacheRead: 0.1, cacheWrite: 1.25, output: 5.0)
    // OpenAI/Codex: cached input heavily discounted (~0.1x), no separate
    // cache-write surcharge (~1.0x), output ~4x input.
    static let openai = TokenCostWeights(cacheRead: 0.1, cacheWrite: 1.0, output: 4.0)
    // Fallback for tools whose upstream provider we can't pin down.
    static let generic = TokenCostWeights(cacheRead: 0.1, cacheWrite: 1.0, output: 4.0)

    static func forTool(_ tool: ToolKind) -> TokenCostWeights {
        switch tool {
        case .claudeCode: return .anthropic
        case .codex: return .openai
        // OpenCode / CLIProxyAPI / TRAE fan out to mixed providers; fall back
        // to per-model inference where the model name is available instead.
        case .opencode, .cliProxyAPI, .trae, .workbuddy: return .generic
        }
    }

    static func forModel(_ name: String) -> TokenCostWeights {
        let n = name.lowercased()
        if n.contains("claude") || n.contains("anthropic") || n.contains("sonnet") || n.contains("opus") || n.contains("haiku") {
            return .anthropic
        }
        if n.contains("gpt") || n.contains("codex") || n.contains("o1") || n.contains("o3") || n.contains("o4") {
            return .openai
        }
        return .generic
    }

    func weightedBillable(uncachedInput: Int, output: Int, cacheRead: Int, cacheWrite: Int) -> Int {
        let v = Double(uncachedInput)
            + Double(cacheRead) * self.cacheRead
            + Double(cacheWrite) * self.cacheWrite
            + Double(output) * self.output
        return Int(v.rounded())
    }
}

/// Normalization contract every `TokenSource` must uphold before constructing
/// a sample, so that everything downstream (Aggregator, UI) can use one
/// tool-agnostic formula instead of branching per tool:
/// - `inputTokens` is always "fresh, uncached input" — Codex subtracts its
///   cached-token subset before this point; Claude/OpenCode already report
///   input excluding cache, so no subtraction is needed there.
/// - `reasoningTokens` is a display-only subset of `outputTokens` (currently
///   only non-zero for Codex) and must NOT be added into totals — it's
///   already counted once inside `outputTokens`.
struct TokenSample: Identifiable, Codable, Hashable {
    var id: String { "\(tool.rawValue)|\(model)|\(timestamp.timeIntervalSince1970)" }
    let tool: ToolKind
    let model: String
    let timestamp: Date
    let inputTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int

    var uncachedInputTokens: Int { inputTokens }
    var totalTokens: Int { inputTokens + cacheReadTokens + cacheWriteTokens + outputTokens }
    /// Cost-weighted estimate (see `TokenCostWeights`): unlike the raw sum, it
    /// does include cache reads - just discounted - since those really are
    /// billed, and weights output up, so it tracks actual cost far better than
    /// the old "drop cache reads entirely" formula.
    var billableTokens: Int {
        TokenCostWeights.forTool(tool).weightedBillable(
            uncachedInput: inputTokens, output: outputTokens,
            cacheRead: cacheReadTokens, cacheWrite: cacheWriteTokens)
    }
}

struct DailyAggregate: Identifiable, Codable, Hashable {
    var id: Date { date }
    let date: Date
    var totalTokens: Int = 0
    var uncachedInputTokens: Int = 0
    var outputTokens: Int = 0
    var reasoningTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheWriteTokens: Int = 0
    var byTool: [ToolKind: ToolAggregate] = [:]
    var byModel: [String: ModelAggregate] = [:]

    /// Summed from the per-tool weighted values rather than weighting the
    /// blended top-level fields, because the cost weights differ per provider
    /// (Anthropic vs OpenAI) - blending first would apply one tool's weights
    /// to another tool's tokens.
    var billableTokens: Int { byTool.values.reduce(0) { $0 + $1.billableTokens } }
    var cacheHitRatio: Double { Self.hitRatio(read: cacheReadTokens, uncachedInput: uncachedInputTokens, write: cacheWriteTokens) }
    var inputTokensTotal: Int { uncachedInputTokens + cacheReadTokens }
}

/// Fraction of input tokens that were served from cache. The denominator is
/// ALL input the model had to account for - fresh uncached input, cache reads,
/// AND cache writes (cache creation is a first-time miss that also gets stored,
/// billed at a premium, so it counts against the hit rate, not for it).
/// Excluding cache writes pinned Claude Code's rate at ~100% every window
/// (it caches so aggressively that fresh input is a couple of tokens a turn),
/// which made the number useless; including them makes it move (~96% typical).
/// Clamped to [0, 1] because some sources (notably OpenCode) report cacheRead
/// per-message rather than deduplicated, so the raw ratio can exceed 100%.
extension DailyAggregate {
    static func hitRatio(read: Int, uncachedInput: Int, write: Int) -> Double {
        let denom = uncachedInput + read + write
        guard denom > 0 else { return 0 }
        return min(1.0, Double(read) / Double(denom))
    }
}

struct ToolAggregate: Identifiable, Codable, Hashable {
    var id: ToolKind { tool }
    let tool: ToolKind
    var totalTokens: Int = 0
    var uncachedInputTokens: Int = 0
    var outputTokens: Int = 0
    var reasoningTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheWriteTokens: Int = 0
    var messageCount: Int = 0
    var byModel: [String: ModelAggregate] = [:]

    var billableTokens: Int {
        TokenCostWeights.forTool(tool).weightedBillable(
            uncachedInput: uncachedInputTokens, output: outputTokens,
            cacheRead: cacheReadTokens, cacheWrite: cacheWriteTokens)
    }
    var inputTokensTotal: Int { uncachedInputTokens + cacheReadTokens }
    var cacheHitRatio: Double { DailyAggregate.hitRatio(read: cacheReadTokens, uncachedInput: uncachedInputTokens, write: cacheWriteTokens) }
}

struct ModelAggregate: Identifiable, Codable, Hashable {
    var id: String { name }
    let name: String
    var totalTokens: Int = 0
    var uncachedInputTokens: Int = 0
    var outputTokens: Int = 0
    var reasoningTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheWriteTokens: Int = 0
    var messageCount: Int = 0

    var billableTokens: Int {
        TokenCostWeights.forModel(name).weightedBillable(
            uncachedInput: uncachedInputTokens, output: outputTokens,
            cacheRead: cacheReadTokens, cacheWrite: cacheWriteTokens)
    }
    var inputTokensTotal: Int { uncachedInputTokens + cacheReadTokens }
    var cacheHitRatio: Double { DailyAggregate.hitRatio(read: cacheReadTokens, uncachedInput: uncachedInputTokens, write: cacheWriteTokens) }
}

/// Everything the UI needs, pre-aggregated exactly once per `refresh()` cycle
/// (startup + every 30s). Earlier, `rollup`/`trend`/`sparkline` recomputed by
/// scanning the full raw sample list on demand - fine when there were a few
/// thousand samples, but with a heavy real history (millions of samples)
/// those scans ran on every SwiftUI body re-evaluation (i.e. many times a
/// second while the dashboard was open), which is what made the UI feel like
/// it had hung. Views now just look up an already-computed value.
struct UsageSnapshot {
    let generatedAt: Date
    /// All daily buckets covering every day the user has data for. Used for
    /// the "all history" view.
    let allDays: [DailyAggregate]
    let lastSampleByTool: [ToolKind: Date]
    let sourcesStatus: [ToolKind: SourceStatus]
    private let rollups: [DisplayWindow: DailyAggregate]
    private let trends: [DisplayWindow: [TrendBucket]]
    private let sparklines: [ToolKind: [TrendBucket]]

    init(
        generatedAt: Date,
        allDays: [DailyAggregate],
        lastSampleByTool: [ToolKind: Date],
        sourcesStatus: [ToolKind: SourceStatus],
        rollups: [DisplayWindow: DailyAggregate],
        trends: [DisplayWindow: [TrendBucket]],
        sparklines: [ToolKind: [TrendBucket]]
    ) {
        self.generatedAt = generatedAt
        self.allDays = allDays
        self.lastSampleByTool = lastSampleByTool
        self.sourcesStatus = sourcesStatus
        self.rollups = rollups
        self.trends = trends
        self.sparklines = sparklines
    }

    func rollup(for window: DisplayWindow) -> DailyAggregate {
        rollups[window] ?? DailyAggregate(date: generatedAt)
    }

    func trend(for window: DisplayWindow) -> [TrendBucket] {
        trends[window] ?? []
    }

    func sparkline(for tool: ToolKind) -> [TrendBucket] {
        sparklines[tool] ?? []
    }
}

struct SourceStatus: Codable, Hashable {
    let scannedAt: Date
    let fileCount: Int
    let sampleCount: Int
    let lastError: String?
    let note: String?
}
