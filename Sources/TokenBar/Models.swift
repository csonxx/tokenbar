import Foundation
import SwiftUI
import AppKit

enum ToolKind: String, CaseIterable, Codable, Identifiable {
    case codex = "Codex"
    case claudeCode = "Claude Code"
    case opencode = "OpenCode"
    case trae = "TRAE"
    case cliProxyAPI = "CLIProxyAPI"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .codex: return "terminal"
        case .claudeCode: return "bubble.left.and.bubble.right.fill"
        case .opencode: return "chevron.left.forwardslash.chevron.right"
        case .trae: return "hammer.fill"
        case .cliProxyAPI: return "network"
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
        }
    }

    private var productIconFileName: String? {
        switch self {
        case .codex: return "tool-codex"
        case .claudeCode: return "tool-claude"
        case .opencode: return "tool-opencode"
        case .trae: return "tool-trae"
        case .cliProxyAPI: return nil
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
    var billableTokens: Int { inputTokens + outputTokens + cacheWriteTokens }
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

    var billableTokens: Int { uncachedInputTokens + outputTokens + cacheWriteTokens }
    var cacheHitRatio: Double {
        let denom = inputTokensTotal
        guard denom > 0 else { return 0 }
        return min(1.0, Double(cacheReadTokens) / Double(denom))
    }
    var inputTokensTotal: Int { uncachedInputTokens + cacheReadTokens }
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

    var billableTokens: Int { uncachedInputTokens + outputTokens + cacheWriteTokens }
    var inputTokensTotal: Int { uncachedInputTokens + cacheReadTokens }
    /// Cache hit ratio capped at [0, 1]. Some data sources (notably OpenCode)
    /// report cacheRead per-message rather than deduplicated, so the raw
    /// ratio can exceed 100%. We clamp and surface the raw counts separately.
    var cacheHitRatio: Double {
        let denom = inputTokensTotal
        guard denom > 0 else { return 0 }
        return min(1.0, Double(cacheReadTokens) / Double(denom))
    }
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

    var billableTokens: Int { uncachedInputTokens + outputTokens + cacheWriteTokens }
    var inputTokensTotal: Int { uncachedInputTokens + cacheReadTokens }
    var cacheHitRatio: Double {
        let denom = inputTokensTotal
        guard denom > 0 else { return 0 }
        return min(1.0, Double(cacheReadTokens) / Double(denom))
    }
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
