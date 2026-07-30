import SwiftUI
import Charts

struct DashboardView: View {
    @ObservedObject var store: UsageStore
    @State private var menuBarConfig: MenuBarConfig = .load()
    @State private var windowPrefs: DisplayWindowPrefs = .load()
    // The trend chart has its own independent time range so it can be
    // inspected at a different granularity than the rest of the dashboard.
    @State private var trendWindow: DisplayWindow = .last7d
    @State private var trendMetric: TrendMetric = .billableTokens
    @State private var hoveredTrendBucket: TrendBucket?

    private var window: DisplayWindow { windowPrefs.window }
    private var rollup: DailyAggregate {
        store.snapshot?.rollup(for: window) ?? DailyAggregate(date: Date())
    }
    private var trendBuckets: [TrendBucket] {
        store.snapshot?.trend(for: trendWindow) ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                header
                noticeBanners
                VStack(alignment: .leading, spacing: Spacing.md) {
                    windowBar
                    menuBarConfigInline
                    cliProxyAPIConfigInline
                    heroCard
                    statsRow
                }
                toolsSection
                modelsSection
                trendSection
                footer
            }
            .padding(Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(backgroundLayer)
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .center, spacing: Spacing.lg) {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: "bolt.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.system(size: 20, weight: .bold))
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("TokenBar")
                        .font(Typography.title)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(window.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                if let snap = store.snapshot {
                    Text("更新于 " + Self.timeFormatter.string(from: snap.generatedAt) + " · 数据源 \(connectedSourceCount)/\(ToolKind.allCases.count)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("加载中…")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if store.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 28, height: 28)
                        .background(
                            Circle().fill(Color.accentColor.opacity(0.12))
                        )
                }
                .buttonStyle(.borderless)
                .help("立即刷新 (R)")
                .keyboardShortcut("r", modifiers: [])
            }
        }
    }

    // MARK: - Notice banners (migration notice / errors)

    @State private var dismissedMigrationNotice: String?
    @State private var dismissedError: String?

    @ViewBuilder
    private var noticeBanners: some View {
        if let notice = store.migrationNotice, notice != dismissedMigrationNotice {
            NoticeBanner(kind: .info, message: notice) {
                dismissedMigrationNotice = notice
            }
        }
        if let err = store.lastError, err != dismissedError {
            NoticeBanner(kind: .warning, message: err) {
                dismissedError = err
            }
        }
    }

    // MARK: - Window selector (pill bar)

    @ViewBuilder
    private var windowBar: some View {
        HStack(spacing: 6) {
            WindowPillRow(current: window) { w in
                withAnimation(Motion.standard) {
                    var p = windowPrefs
                    p.window = w
                    p.save()
                    windowPrefs = p
                }
            }
            Spacer()
            cliProxyAPIConfigToggle
            menuBarConfigToggle
        }
    }

    private var menuBarConfigToggle: some View {
        configToggleButton(title: "菜单栏", systemImage: "slider.horizontal.3", isOpen: showMenuBarConfig) {
            showMenuBarConfig.toggle()
        }
    }

    private var cliProxyAPIConfigToggle: some View {
        configToggleButton(title: "CLIProxyAPI", systemImage: "network", isOpen: showCLIProxyAPIConfig) {
            showCLIProxyAPIConfig.toggle()
        }
    }

    private func configToggleButton(title: String, systemImage: String, isOpen: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(Motion.standard) { action() }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(
                    Capsule().fill(isOpen ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10))
                )
                .foregroundStyle(isOpen ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }

    @State private var showMenuBarConfig = false
    @State private var showCLIProxyAPIConfig = false
    @State private var cliProxyAPIConfig: CLIProxyAPIConfig = .load()

    // MARK: - Hero card

    @ViewBuilder
    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.accentColor)
                Text(window.displayName + "总消耗")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(TokenFormatter.short(rollup.totalTokens))
                    .font(Typography.hero)
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                Text("tokens")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
            HStack(spacing: 14) {
                miniMetric(icon: "creditcard.fill", label: "计费", value: TokenFormatter.short(rollup.billableTokens), tint: .accentColor)
                miniMetric(icon: "tray.full.fill", label: "命中", value: TokenFormatter.percent(rollup.cacheHitRatio), tint: .green)
                miniMetric(icon: "bubble.left.and.bubble.right.fill", label: "调用", value: "\(rollup.byTool.values.reduce(0) { $0 + $1.messageCount })", tint: .purple)
            }
            .padding(.top, 8)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .fill(Color.accentColor.opacity(0.05))
        )
        .cardStyle()
        .animation(Motion.standard, value: rollup.totalTokens)
    }

    private func miniMetric(icon: String, label: String, value: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(tint)
            Text(value).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.primary)
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    // MARK: - Stats row: by tool, big numbers

    @ViewBuilder
    private var statsRow: some View {
        HStack(spacing: 12) {
            statTile(
                title: "输入 token",
                value: TokenFormatter.short(rollup.inputTokensTotal),
                subtitle: "未命中 \(TokenFormatter.short(rollup.uncachedInputTokens)) · 命中 \(TokenFormatter.short(rollup.cacheReadTokens))",
                icon: "arrow.down.circle.fill",
                tint: .orange
            )
            statTile(
                title: "输出 token",
                value: TokenFormatter.short(rollup.outputTokens),
                subtitle: "含 reasoning \(TokenFormatter.short(rollup.reasoningTokens))",
                icon: "arrow.up.circle.fill",
                tint: .pink
            )
            statTile(
                title: "缓存写入",
                value: TokenFormatter.short(rollup.cacheWriteTokens),
                subtitle: "新建缓存 (会再次计费)",
                icon: "square.stack.3d.up.fill",
                tint: .indigo
            )
        }
    }

    private func statTile(title: String, value: String, subtitle: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint)
                    .frame(width: 20, height: 20)
                    .overlay(
                        Image(systemName: icon)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                    )
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text(value)
                .font(Typography.statValue)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.lg)
        .cardStyle()
    }

    // MARK: - Menu bar config (collapsible)

    @ViewBuilder
    private var menuBarConfigInline: some View {
        if showMenuBarConfig {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("菜单栏显示一个指标")
                    .font(.subheadline.weight(.semibold))
                Picker("", selection: Binding(
                    get: { menuBarConfig.headline },
                    set: { newValue in
                        menuBarConfig.headline = newValue
                        menuBarConfig.save()
                    }
                )) {
                    ForEach(MenuBarMetric.allCases) { metric in
                        Label(metric.displayName, systemImage: metric.systemImage).tag(metric)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text("预览 · \(previewText)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(Spacing.md)
            .cardStyle()
        }
    }

    private var previewText: String {
        let snap = store.snapshot
        let r = snap?.rollup(for: window) ?? DailyAggregate(date: Date())
        return AppDelegate.renderMetric(menuBarConfig.headline, rollup: r, snapshot: snap)
    }

    // MARK: - CLIProxyAPI config (collapsible)

    @ViewBuilder
    private var cliProxyAPIConfigInline: some View {
        if showCLIProxyAPIConfig {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("CLIProxyAPI 反代地址")
                    .font(.subheadline.weight(.semibold))
                Text("留空则不扫描这个数据源；只统计它上报的 token 用量，不包含费用")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                LabeledContent("地址") {
                    TextField("localhost:8899", text: Binding(
                        get: { cliProxyAPIConfig.baseURL },
                        set: { cliProxyAPIConfig.baseURL = $0; cliProxyAPIConfig.save() }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
                LabeledContent("管理密钥") {
                    SecureField("remote-management.secret-key", text: Binding(
                        get: { cliProxyAPIConfig.managementKey },
                        set: { cliProxyAPIConfig.managementKey = $0; cliProxyAPIConfig.save() }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
            }
            .padding(Spacing.md)
            .cardStyle()
        }
    }

    // MARK: - Tools section (grouped list, matching macOS System Settings)

    @ViewBuilder
    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("按工具拆分", subtitle: window.displayName)
            VStack(spacing: 0) {
                ForEach(ToolKind.allCases) { tool in
                    ToolCard(
                        tool: tool,
                        aggregate: rollup.byTool[tool],
                        status: store.snapshot?.sourcesStatus[tool],
                        lastSample: store.snapshot?.lastSampleByTool[tool]
                    )
                    if tool != ToolKind.allCases.last {
                        Divider().padding(.leading, 56)
                    }
                }
            }
            .cardStyle()
        }
    }

    // MARK: - Models section

    @ViewBuilder
    private var modelsSection: some View {
        let models = rollup.byModel.values.sorted { $0.totalTokens > $1.totalTokens }
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("按模型拆分", subtitle: window.displayName)
            if models.isEmpty {
                // Disappearing entirely (as opposed to the tools section,
                // which always shows a "暂无数据" placeholder row) read as a
                // rendering glitch rather than "no model data in this window".
                Text("当前窗口没有模型数据")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.md)
                    .cardStyle()
            } else {
                VStack(spacing: 6) {
                    ForEach(models.prefix(8)) { m in
                        ModelRow(model: m)
                    }
                }
                .padding(Spacing.md)
                .cardStyle()
            }
        }
    }

    // MARK: - Trend

    @ViewBuilder
    private var trendSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("消耗趋势")
                    .font(.system(size: 14, weight: .semibold))
                Text("· \(trendSubtitle)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                WindowPillRow(current: trendWindow, compact: true) { w in
                    withAnimation(Motion.standard) {
                        trendWindow = w
                        // A bucket left over from hovering the *previous*
                        // window's bars won't match any bar's timestamp in
                        // the new window, which left every bar dimmed to
                        // 35% opacity - reading as "the filtered data looks
                        // wrong" rather than what it actually was (a stale
                        // hover highlight).
                        hoveredTrendBucket = nil
                    }
                }
            }
            TrendMetricPillRow(current: trendMetric) { m in
                withAnimation(Motion.standard) {
                    trendMetric = m
                }
            }
            TrendChart(
                buckets: trendBuckets,
                granularity: trendBuckets.first?.granularity ?? trendWindow.bucketGranularity,
                metric: trendMetric,
                hoveredBucket: $hoveredTrendBucket
            )
            .frame(height: 180)
            .padding(Spacing.md)
            .cardStyle()
            .animation(Motion.standard, value: trendWindow)
            .animation(Motion.standard, value: trendMetric)
        }
    }

    /// Normally the bucket granularity; while hovering a bar, swaps to show
    /// that bar's exact date and total instead.
    private var trendSubtitle: String {
        if let bucket = hoveredTrendBucket {
            let f = DateFormatter()
            f.dateFormat = bucket.granularity == .hour ? "HH:mm" : "MM-dd"
            return "\(f.string(from: bucket.id))  \(TokenFormatter.short(trendMetric.value(of: bucket.aggregate))) \(trendMetric.unitSuffix)"
        }
        let stacking = trendWindow.bucketGranularity == .hour ? "按小时堆叠" : "按天堆叠"
        return "\(trendMetric.displayName) · \(stacking)"
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack {
            Text("每 30 秒自动刷新 · 右键菜单栏可重置缓存")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Text("数据源: \(connectedSourceCount)/\(ToolKind.allCases.count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button("退出") {
                NSApp.terminate(nil)
            }
            .controlSize(.small)
        }
    }

    private var connectedSourceCount: Int {
        guard let snap = store.snapshot else { return 0 }
        // A tool's *latest* sample being within the window is sufficient to
        // prove it has data in the window (if the latest were older, every
        // other sample would be too) - an O(tools) check against the
        // already-computed `lastSampleByTool`, not a scan over every sample.
        let windowStart = window.startDate() ?? .distantPast
        return snap.lastSampleByTool.values.filter { $0 >= windowStart }.count
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, subtitle: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            if let subtitle {
                Text("· \(subtitle)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    private var backgroundLayer: some View {
        // A faint top-down accent wash gives the translucent card materials
        // something to pick up - a single flat color left them looking like
        // opaque gray tiles instead of native vibrancy.
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [Color.accentColor.opacity(0.05), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

// MARK: - Notice banner

struct NoticeBanner: View {
    enum Kind { case info, warning }
    let kind: Kind
    let message: String
    let onDismiss: () -> Void

    private var tint: Color { kind == .warning ? .orange : .accentColor }
    private var icon: String { kind == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill" }

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(message)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: Spacing.sm)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(tint.opacity(0.12))
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

// MARK: - Tool card with sparkline

/// One row in the tools grouped list - matches macOS System Settings'
/// grouped-list convention (leading icon, title + one secondary line,
/// trailing value) rather than a standalone card per tool.
struct ToolCard: View {
    let tool: ToolKind
    let aggregate: ToolAggregate?
    let status: SourceStatus?
    let lastSample: Date?

    private var hasData: Bool { (aggregate?.totalTokens ?? 0) > 0 }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ToolIconView(tool: tool, size: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tool.rawValue).font(.system(size: 13, weight: .semibold))
                    if let status, status.lastError != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption2)
                    }
                }
                Text(secondaryLine)
                    .font(.system(size: 11))
                    .foregroundStyle(status?.lastError != nil ? .orange : .secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(TokenFormatter.short(aggregate?.billableTokens ?? 0))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(hasData ? Color.primary : Color.secondary)
                if let last = lastSample {
                    Text(Self.relative.localizedString(for: last, relativeTo: Date()))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var secondaryLine: String {
        if let status, let err = status.lastError { return err }
        guard let aggregate, hasData else {
            if let status, status.sampleCount == 0, let note = status.note { return note }
            return "暂无数据"
        }
        return "命中 \(TokenFormatter.percent(aggregate.cacheHitRatio)) · 总 \(TokenFormatter.short(aggregate.totalTokens)) · \(aggregate.messageCount) turns"
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

// MARK: - Sparkline (mini bar chart, 24 hourly buckets per tool)

struct Sparkline: View {
    let buckets: [TrendBucket]
    let tool: ToolKind

    var body: some View {
        let max = (buckets.map { $0.aggregate.totalTokens }.max() ?? 0)
        Chart {
            ForEach(buckets) { b in
                BarMark(
                    x: .value("Time", b.id, unit: .hour),
                    y: .value("Tokens", b.aggregate.totalTokens)
                )
                .foregroundStyle(tool.tintColor.gradient)
                .cornerRadius(2)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...(max == 0 ? 1 : Double(max) * 1.1))
    }
}

// MARK: - Model row (inside tools card padding)

struct ModelRow: View {
    let model: ModelAggregate

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.purple)
                .frame(width: 24, height: 24)
                .overlay(
                    Image(systemName: "cpu")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .lineLimit(1)
                Text("\(TokenFormatter.short(model.totalTokens)) · \(model.messageCount) turns · 命中 \(TokenFormatter.percent(model.cacheHitRatio))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(TokenFormatter.short(model.billableTokens))
                .font(.system(.callout, design: .rounded).weight(.semibold))
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Trend metric selector (总token / 计费token / 调用次数)

enum TrendMetric: String, CaseIterable, Identifiable {
    case billableTokens, totalTokens, calls
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .billableTokens: return "计费 token"
        case .totalTokens: return "总 token"
        case .calls: return "turns"
        }
    }

    var unitSuffix: String {
        self == .calls ? "次" : "tokens"
    }

    func value(of agg: ToolAggregate) -> Int {
        switch self {
        case .billableTokens: return agg.billableTokens
        case .totalTokens: return agg.totalTokens
        case .calls: return agg.messageCount
        }
    }

    func value(of agg: DailyAggregate) -> Int {
        switch self {
        case .billableTokens: return agg.billableTokens
        case .totalTokens: return agg.totalTokens
        case .calls: return agg.byTool.values.reduce(0) { $0 + $1.messageCount }
        }
    }
}

struct TrendMetricPillRow: View {
    let current: TrendMetric
    let onSelect: (TrendMetric) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(TrendMetric.allCases) { m in
                let isActive = m == current
                Button {
                    onSelect(m)
                } label: {
                    Text(m.displayName)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(isActive ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10))
                        )
                        .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Trend chart (full height)

private struct TrendBarDatum: Identifiable {
    let id: String
    let time: Date
    let tool: ToolKind
    let value: Int
}

struct TrendChart: View {
    let buckets: [TrendBucket]
    let granularity: TrendBucket.Granularity
    let metric: TrendMetric
    /// The bucket currently under the mouse, if any. The parent view (the
    /// trend section's header) reads this to show the hovered bar's exact
    /// date and total.
    @Binding var hoveredBucket: TrendBucket?
    /// Pixel x-position of the hover, purely for placing the floating
    /// per-tool tooltip right over the hovered bar - not shared with the
    /// parent since it's meaningless outside this chart's own coordinate space.
    @State private var hoverX: CGFloat? = nil

    // Swift Charts crashes deep inside its own framework code (not a
    // catchable Swift-level error) if a bar's foreground-style domain value
    // isn't present in this scale - which is exactly what happened when
    // `CLIProxyAPI` was added as a 5th `ToolKind` but this literal (which
    // `KeyValuePairs` requires - it can't be built from `ToolKind.allCases`
    // at runtime) wasn't updated to match. Every case in `ToolKind` must
    // have an entry here.
    private static let colorScale: KeyValuePairs<String, Color> = [
        ToolKind.codex.rawValue: ToolKind.codex.tintColor,
        ToolKind.claudeCode.rawValue: ToolKind.claudeCode.tintColor,
        ToolKind.opencode.rawValue: ToolKind.opencode.tintColor,
        ToolKind.trae.rawValue: ToolKind.trae.tintColor,
        ToolKind.cliProxyAPI.rawValue: ToolKind.cliProxyAPI.tintColor,
        ToolKind.workbuddy.rawValue: ToolKind.workbuddy.tintColor
    ]

    // Flattened once, outside the chart's result builder, so Chart's builder
    // only ever sees one ForEach over plain data - nesting a second ForEach
    // with a conditional inside routinely blows past the type checker's
    // per-expression time budget for SwiftUI Charts.
    private var barData: [TrendBarDatum] {
        buckets.flatMap { b in
            ToolKind.allCases.compactMap { tool -> TrendBarDatum? in
                guard let agg = b.aggregate.byTool[tool] else { return nil }
                let value = metric.value(of: agg)
                guard value > 0 else { return nil }
                return TrendBarDatum(id: "\(metric.rawValue)-\(b.id.timeIntervalSince1970)-\(tool.rawValue)", time: b.id, tool: tool, value: value)
            }
        }
    }

    var body: some View {
        let maxValue = (buckets.map { metric.value(of: $0.aggregate) }.max() ?? 0)
        let isEmpty = maxValue == 0
        Chart(barData) { d in
            BarMark(
                x: .value("时", d.time, unit: granularity == .hour ? .hour : .day),
                y: .value("Tokens", d.value)
            )
            .foregroundStyle(by: .value("工具", d.tool.rawValue))
            .cornerRadius(3)
            .opacity(hoveredBucket == nil || hoveredBucket?.id == d.time ? 1.0 : 0.35)
        }
        .chartForegroundStyleScale(Self.colorScale)
        .chartLegend(position: .bottom, alignment: .leading, spacing: 12)
        .chartXAxis {
            switch granularity {
            case .hour:
                AxisMarks(values: .stride(by: .hour, count: 4)) { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.hour())
                }
            case .day:
                AxisMarks(values: .stride(by: .day, count: max(1, buckets.count / 7))) { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
        }
        .chartYAxis {
            // Default axis formatting renders large totals in scientific
            // notation (e.g. "5E9") - route through the same K/M/B
            // formatter used everywhere else in the app instead.
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let raw = value.as(Double.self) {
                        Text(TokenFormatter.short(Int(raw)))
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let origin = geometry[proxy.plotFrame!].origin
                            let x = location.x - origin.x
                            if let date: Date = proxy.value(atX: x) {
                                hoveredBucket = nearestBucket(to: date)
                                hoverX = location.x
                            }
                        case .ended:
                            hoveredBucket = nil
                            hoverX = nil
                        }
                    }
                if let bucket = hoveredBucket, let x = hoverX {
                    tooltip(for: bucket)
                        .position(x: clampedTooltipX(x, in: geometry.size), y: 14)
                }
            }
        }
        .overlay {
            if isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray").font(.title2).foregroundStyle(.secondary)
                    Text("当前窗口没有消耗数据").foregroundStyle(.secondary).font(.caption)
                }
            }
        }
    }

    private func nearestBucket(to date: Date) -> TrendBucket? {
        buckets.min { abs($0.id.timeIntervalSince(date)) < abs($1.id.timeIntervalSince(date)) }
    }

    /// Keeps the floating tooltip's horizontal center from clipping past the
    /// chart's left/right edges as the mouse approaches either side.
    private func clampedTooltipX(_ x: CGFloat, in size: CGSize) -> CGFloat {
        let halfWidth: CGFloat = 90
        return min(max(x, halfWidth), size.width - halfWidth)
    }

    /// One row per tool with a non-zero value in this bucket for the
    /// selected metric - a bar stacked from several tools shows all of them,
    /// not just the combined total.
    @ViewBuilder
    private func tooltip(for bucket: TrendBucket) -> some View {
        let rows = ToolKind.allCases.compactMap { tool -> (ToolKind, Int)? in
            guard let agg = bucket.aggregate.byTool[tool] else { return nil }
            let value = metric.value(of: agg)
            guard value > 0 else { return nil }
            return (tool, value)
        }
        VStack(alignment: .leading, spacing: 3) {
            Text(Self.tooltipDateFormat(bucket))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(rows, id: \.0) { tool, value in
                HStack(spacing: 5) {
                    Circle().fill(tool.tintColor).frame(width: 6, height: 6)
                    Text(tool.rawValue)
                        .font(.system(size: 10.5))
                    Spacer(minLength: 10)
                    Text("\(TokenFormatter.short(value)) \(metric.unitSuffix)")
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 2)
        .fixedSize()
        .allowsHitTesting(false)
    }

    private static func tooltipDateFormat(_ bucket: TrendBucket) -> String {
        let f = DateFormatter()
        f.dateFormat = bucket.granularity == .hour ? "HH:mm" : "MM-dd"
        return f.string(from: bucket.id)
    }
}
