import Foundation
import AppKit

// Entry point: when invoked with --cli, run a one-shot scan of all sources and
// print the resulting aggregates. Without --cli, launch the regular menu bar app.
let arguments = CommandLine.arguments

if arguments.contains("--cli") {
    let home: URL = {
        if let p = ProcessInfo.processInfo.environment["TOKENBAR_TEST_HOME"] {
            return URL(fileURLWithPath: p)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }()
    let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory
    let progressURL: URL
    if ProcessInfo.processInfo.environment["TOKENBAR_CLI_NO_OFFSET"] != nil {
        progressURL = supportDir.appendingPathComponent("TokenBar/cli_source_progress_fresh.json")
        try? FileManager.default.removeItem(at: progressURL)
    } else {
        progressURL = supportDir.appendingPathComponent("TokenBar/cli_source_progress.json")
    }
    let progress = SourceProgress(storeURL: progressURL)
    let sources: [TokenSource] = [
        CodexSource(home: home, progress: progress),
        ClaudeCodeSource(home: home, progress: progress),
        OpenCodeSource(home: home, progress: progress),
        TraeSource(home: home, progress: progress),
        WorkBuddySource(home: home, progress: progress)
    ]
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        var all: [TokenSample] = []
        var statuses: [String: String] = [:]
        for s in sources {
            do {
                let r = try await s.collect()
                statuses[s.tool.rawValue] = "files=\(r.fileCount) new_samples=\(r.samples.count) note=\(r.note ?? "-")"
                all.append(contentsOf: r.samples)
            } catch {
                statuses[s.tool.rawValue] = "error: \(error)"
            }
        }
        let rollup = Aggregator.aggregateWindow(samples: all, window: .today)
        let history = Aggregator.aggregateDaily(samples: all)
        var lines: [String] = []
        for (k, v) in statuses.sorted(by: { $0.key < $1.key }) {
            lines.append("[\(k)] \(v)")
        }
        lines.append("")
        lines.append("TODAY \(CLI.dayFmt.string(from: rollup.date))")
        lines.append("  total=\(rollup.totalTokens) billable=\(rollup.billableTokens) cacheHit=\(TokenFormatter.percent(rollup.cacheHitRatio))")
        for tool in ToolKind.allCases {
            if let agg = rollup.byTool[tool] {
                lines.append("  - \(tool.rawValue): total=\(agg.totalTokens) cache=\(TokenFormatter.percent(agg.cacheHitRatio))")
            }
        }
        lines.append("HISTORY (\(history.count) days)")
        for d in history.suffix(7) {
            lines.append("  \(CLI.dayFmt.string(from: d.date)) total=\(d.totalTokens)")
        }
        print(lines.joined(separator: "\n"))
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

// Otherwise, start the SwiftUI App lifecycle normally.
TokenBarApp.main()

enum CLI {
    static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
