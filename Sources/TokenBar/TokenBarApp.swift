import SwiftUI
import AppKit

struct TokenBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var dashboardWindow: NSWindow?
    private var hosting: NSHostingController<DashboardView>?
    private var store: UsageStore!
    /// Keeps the currently-open status menu's live state alive; the hosted
    /// SwiftUI views already retain it themselves, this is just extra
    /// insurance since it's cheap and avoids relying on that alone.
    private var menuContentState: MenuContentState?

    private func makeStore() -> UsageStore {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return MainActor.assumeIsolated { UsageStore(home: home) }
    }

    override init() {
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = makeStore()
        // LSUIElement = YES via Info.plist keeps us out of the Dock; regular
        // activation policy stays so the full-dashboard window can receive focus.
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.image = NSImage(systemSymbolName: MenuBarConfig.load().headline.systemImage, accessibilityDescription: "TokenBar")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.action = #selector(handleClick)
        statusItem.button?.target = self
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        updateMenuBarText()
        Task { @MainActor [weak self] in
            while true {
                self?.updateMenuBarText()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        store.start()
    }

    // MARK: - Click handling

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        // Both left- and right-click show the same native NSMenu summary;
        // it's lighter than a popover and lets users see data without taking
        // over their focus.
        showStatusMenu()
    }

    /// Build a native NSMenu from the current snapshot. Window selector is
    /// inline; tools/models are flat lists with totals and billable.
    private func showStatusMenu() {
        // Pull snapshot on the main actor since UsageStore is @MainActor.
        let (snapshot, window) = MainActor.assumeIsolated {
            (store.snapshot, DisplayWindowPrefs.load().window)
        }
        guard let snapshot else { return }

        let menu = NSMenu()
        menu.autoenablesItems = false

        // Pills and grid share one observable state object: tapping a pill
        // updates `state.window`, and since both hosted views bind to the
        // same instance, the grid's numbers refresh in place - the menu
        // never closes just from picking a different window.
        let state = MainActor.assumeIsolated { MenuContentState(window: window, snapshot: snapshot) }
        self.menuContentState = state

        let pillsHosting = NSHostingView(rootView: MenuWindowPills(state: state))
        pillsHosting.frame = NSRect(x: 0, y: 0, width: MenuLayout.contentWidth, height: 38)
        let pillsItem = NSMenuItem()
        pillsItem.view = pillsHosting
        menu.addItem(pillsItem)
        menu.addItem(.separator())

        // Grid of tool cards (icon+name, sparkline, total, cache hit).
        let gridHosting = NSHostingView(rootView: MenuToolGrid(state: state))
        gridHosting.frame = NSRect(x: 0, y: 0, width: MenuLayout.contentWidth, height: MenuLayout.gridHeight)
        let gridItem = NSMenuItem()
        gridItem.view = gridHosting
        menu.addItem(gridItem)
        menu.addItem(.separator())

        // Actions
        // ("菜单栏显示项目…" used to be a second menu item here pointing at the
        // same `openDashboardWindow` action as "打开完整面板…" - a leftover from
        // before the menu-bar metric picker moved inside the dashboard, which
        // just duplicated it under a misleading label instead of jumping
        // straight to that section. Removed rather than kept as a decoy.)
        menu.addItem(withTitle: "打开完整面板…", action: #selector(openDashboardWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "立即刷新 (R)", action: #selector(forceRefresh), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "重置历史缓存…", action: #selector(resetCaches), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 TokenBar (Q)", action: #selector(quitApp), keyEquivalent: "q").target = self

        // Present the menu. Don't clear it immediately — when an item's action
        // closes the menu (e.g. "open dashboard window"), we want the action
        // to fire *before* the menu reference drops. Instead, clear the menu
        // after a short delay that lets the action run first.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            // Only clear if the menu wasn't replaced in the meantime.
            if self?.statusItem.menu === menu {
                self?.statusItem.menu = nil
            }
        }
    }

    // MARK: - Full Dashboard window

    @objc func openDashboardWindow() {
        // Already on main thread when invoked from NSMenu. Build the window
        // here directly. Sync, no Task wrapper — it must take effect before
        // the menu's `nil`-clear happens 50 ms later.
        Self.log("openDashboardWindow invoked from menu")

        let initialSize = NSSize(width: 880, height: 720)

        // Reuse the existing window as-is. Its DashboardView already observes
        // the store via @ObservedObject, so it stays live without rebuilding
        // the hosting controller. Crucially we do NOT reassign
        // `contentViewController` here: doing so made AppKit re-derive the
        // window size from the controller's fitting size and collapse the
        // window to just its title bar on every reopen.
        if let existing = dashboardWindow {
            Self.log("reusing existing window \(existing.title)")
            if existing.frame.width < existing.contentMinSize.width || existing.frame.height < existing.contentMinSize.height {
                existing.setContentSize(initialSize)
                existing.center()
            }
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let host = NSHostingController(rootView: DashboardView(store: store))
        // Stop the hosting controller from driving the window's size off the
        // SwiftUI content's fitting size. The dashboard's root is a
        // ScrollView, whose minimal fitting height is ~0, so the default
        // `.preferredContentSize`/`.minSize` behaviour shrank the window to
        // its title bar. With no sizing options the window keeps whatever
        // size we set explicitly.
        host.sizingOptions = []
        host.view.translatesAutoresizingMaskIntoConstraints = false
        self.hosting = host

        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        let frame = NSRect(origin: .zero, size: initialSize)
        let window = NSWindow(
            contentRect: frame,
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        window.title = "TokenBar"
        window.subtitle = "Token usage dashboard"
        window.contentViewController = host
        window.contentMinSize = NSSize(width: 700, height: 560)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unified
        window.center()
        // Restores whatever frame was last saved under this name - including,
        // if one was ever persisted, a frame smaller than `contentMinSize`.
        // `contentMinSize` only constrains interactive resizing, not this
        // programmatic restore, so a stale/corrupted saved frame (observed as
        // the window opening collapsed to just its title bar) would otherwise
        // persist forever. Snap back to the default size whenever the
        // restored frame falls below the enforced minimum.
        window.setFrameAutosaveName("TokenBarDashboard")
        if window.frame.width < window.contentMinSize.width || window.frame.height < window.contentMinSize.height {
            window.setContentSize(initialSize)
            window.center()
        }
        window.delegate = self
        window.collectionBehavior = [.fullScreenPrimary]

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.dashboardWindow = window
        Self.log("created dashboard window frame=\(window.frame)")
    }

    /// Tiny internal logger so we can verify the menu action actually runs.
    private static let logURL: URL = {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("TokenBar/tokenbar.log")
    }()

    private static func log(_ msg: String) {
        let line = "[\(Date())] \(msg)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let h = try? FileHandle(forWritingTo: logURL) {
                    h.seekToEndOfFile()
                    try? h.write(contentsOf: data)
                    try? h.close()
                }
            } else {
                try? data.write(to: logURL, options: .atomic)
            }
        }
    }

    @objc private func forceRefresh() {
        Task { @MainActor [weak self] in await self?.store.refresh() }
    }

    @objc private func resetCaches() {
        let alert = NSAlert()
        alert.messageText = "确认重置？"
        alert.informativeText = "将清空已缓存的 token 历史并强制全量重扫所有数据源。下次刷新可能较慢。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "重置")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            Task { @MainActor [weak self] in await self?.store.resetCaches() }
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func updateMenuBarText() {
        guard let store = store else { return }
        let snapshot = MainActor.assumeIsolated { store.snapshot }
        let config = MainActor.assumeIsolated { MenuBarConfig.load() }
        let window = MainActor.assumeIsolated { DisplayWindowPrefs.load().window }

        statusItem.button?.image = NSImage(systemSymbolName: config.headline.systemImage, accessibilityDescription: config.headline.displayName)
        statusItem.button?.image?.isTemplate = true

        guard let snapshot else {
            statusItem.button?.title = "…"
            return
        }
        let rollup = snapshot.rollup(for: window)
        statusItem.button?.title = Self.renderMetric(config.headline, rollup: rollup, snapshot: snapshot)
    }

    /// The status item's icon already communicates *which* metric is shown
    /// (it tracks `MenuBarMetric.systemImage`), so this only needs to render
    /// the bare value - no emoji or symbol prefix required.
    static func renderMetric(_ metric: MenuBarMetric, rollup: DailyAggregate, snapshot: UsageSnapshot?) -> String {
        switch metric {
        case .totalTokens:
            return TokenFormatter.short(rollup.totalTokens)
        case .billableTokens:
            return TokenFormatter.short(rollup.billableTokens)
        case .cacheHit:
            guard rollup.inputTokensTotal > 0 else { return "—" }
            let pct = Int((rollup.cacheHitRatio * 100).rounded())
            return "\(pct)%"
        case .calls:
            let count = rollup.byTool.values.reduce(0) { $0 + $1.messageCount }
            return "\(count)"
        case .lastUpdated:
            guard let snapshot else { return "—" }
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            return f.string(from: snapshot.generatedAt)
        }
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let w = notification.object as? NSWindow, w === dashboardWindow {
            // Don't release the window; user may reopen quickly.
            // Hide rather than deallocate.
        }
    }
}

enum TokenFormatter {
    static func short(_ n: Int) -> String {
        let value = Double(n)
        let sign = n < 0 ? "-" : ""
        switch abs(n) {
        case 1_000_000_000...:
            return "\(sign)\(format(value / 1_000_000_000))B"
        case 1_000_000...:
            return "\(sign)\(format(value / 1_000_000))M"
        case 1_000...:
            return "\(sign)\(format(value / 1_000))k"
        default:
            return "\(n)"
        }
    }

    private static func format(_ v: Double) -> String {
        if v >= 100 { return String(format: "%.0f", v) }
        if v >= 10 { return String(format: "%.0f", v) }
        return String(format: "%.2f", v)
    }

    static func full(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func percent(_ ratio: Double) -> String {
        String(format: "%.1f%%", ratio * 100)
    }
}
