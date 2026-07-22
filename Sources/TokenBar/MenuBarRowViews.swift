import SwiftUI

/// Shared, observable state for the status-bar NSMenu's live content (window
/// pills + tool grid). Both hosted views bind to the same instance so
/// picking a different window updates the grid's numbers in place, without
/// closing/reopening the menu.
@MainActor
final class MenuContentState: ObservableObject {
    @Published var window: DisplayWindow
    let snapshot: UsageSnapshot

    init(window: DisplayWindow, snapshot: UsageSnapshot) {
        self.window = window
        self.snapshot = snapshot
    }

    var rollup: DailyAggregate { snapshot.rollup(for: window) }
}

/// Both the pills row and the tool grid below share this outer width so
/// their content lines up and centers consistently - previously they used
/// different frame widths (350 vs 302), which left the grid sitting flush
/// left with a visible gap on the right instead of matching the pills row.
enum MenuLayout {
    static let contentWidth: CGFloat = 320

    /// Height of the 2-column tool grid, computed from how many tools there
    /// are rather than hardcoded - it silently overflowed a fixed height
    /// once a 5th tool wrapped the grid to a 3rd row.
    static var gridHeight: CGFloat {
        let cardHeight: CGFloat = 100
        let rowSpacing: CGFloat = 8
        let bottomPadding: CGFloat = 10
        let rows = (ToolKind.allCases.count + 1) / 2
        return CGFloat(rows) * cardHeight + CGFloat(max(0, rows - 1)) * rowSpacing + bottomPadding
    }
}

/// Horizontal row of window-selector pills at the top of the status-bar
/// NSMenu, replacing the previous vertical list of checkable NSMenuItems.
/// Tapping a pill updates the shared state (and persists the choice) but
/// deliberately does *not* close the menu, so the tool grid below can be
/// compared across a few windows in one glance without reopening it.
struct MenuWindowPills: View {
    @ObservedObject var state: MenuContentState

    var body: some View {
        HStack(spacing: 5) {
            ForEach(DisplayWindow.allCases) { w in
                let isActive = w == state.window
                Button {
                    state.window = w
                    var p = DisplayWindowPrefs.load()
                    p.window = w
                    p.save()
                } label: {
                    Text(w.shortName)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(isActive ? Color.accentColor : Color.secondary.opacity(0.12))
                        )
                        .foregroundStyle(isActive ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 8)
        .frame(width: MenuLayout.contentWidth, height: 38)
    }
}

/// One tool's card inside the 2-column grid: icon + name, a mini sparkline,
/// the window's billable total for that tool (the headline number, matching
/// what the menu bar itself shows), with cache-hit rate and the raw total
/// as secondary context underneath.
struct MenuToolCard: View {
    let tool: ToolKind
    let aggregate: ToolAggregate?
    let sparkline: [TrendBucket]

    private var hasData: Bool { (aggregate?.totalTokens ?? 0) > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                ToolIconView(tool: tool, size: 15)
                Text(tool.rawValue)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            if hasData {
                Sparkline(buckets: sparkline, tool: tool)
                    .frame(height: 20)
            } else {
                // An all-zero sparkline renders no visible bars, which read
                // as a layout bug (empty gap) rather than "no activity" - a
                // flat baseline makes the zero state legible instead.
                Rectangle()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: 1)
                    .frame(height: 20, alignment: .center)
            }
            Text(TokenFormatter.short(aggregate?.billableTokens ?? 0))
                .font(.system(size: 16, weight: .bold, design: .rounded))
            if hasData, let aggregate {
                Text("命中 \(TokenFormatter.percent(aggregate.cacheHitRatio)) · 总 \(TokenFormatter.short(aggregate.totalTokens))")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            } else {
                Text("暂无数据")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .frame(width: 138, height: 100, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
    }
}

/// 2x2 grid of tool cards shown in the status-bar NSMenu. Reads `state.window`
/// reactively, so it updates live when a pill above it is tapped. Sparklines
/// are always "last 24h" regardless of the selected window, so only the
/// per-card totals/cache-hit numbers change.
struct MenuToolGrid: View {
    @ObservedObject var state: MenuContentState

    private static let columns = [GridItem(.fixed(138), spacing: 8), GridItem(.fixed(138), spacing: 8)]

    var body: some View {
        let rollup = state.rollup
        LazyVGrid(columns: Self.columns, spacing: 8) {
            ForEach(ToolKind.allCases) { tool in
                MenuToolCard(tool: tool, aggregate: rollup.byTool[tool], sparkline: state.snapshot.sparkline(for: tool))
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.bottom, 10)
        .frame(width: MenuLayout.contentWidth, height: MenuLayout.gridHeight)
    }
}
