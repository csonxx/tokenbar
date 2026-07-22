import Foundation

/// TRAE's per-call `TokenUsageEvent` lines were never observed in any local
/// log on surveyed installs. The framework's `main.log` only contains IDE
/// bootstrapping and provider routing info; AI token accounting happens on the
/// TRAE cloud, not locally. Rather than emit fabricated numbers, this source
/// returns an explanatory note and zero samples.
final class TraeSource: TokenSource {
    let tool: ToolKind = .trae
    private let home: URL
    private let progress: SourceProgress

    init(home: URL, progress: SourceProgress) {
        self.home = home
        self.progress = progress
    }

    func collect() async throws -> SourceResult {
        // Verify the TRAE log directory exists so the UI shows a meaningful
        // note instead of "no data".
        let candidates = [
            "Library/Application Support/Trae/logs",
            "Library/Application Support/TRAE SOLO/logs"
        ].map { home.appendingPathComponent($0) }
        let existing = candidates.filter { FileManager.default.fileExists(atPath: $0.path) }

        if existing.isEmpty {
            return SourceResult.empty(note: "TRAE 日志目录未找到")
        }
        // Walk the directory but emit no samples: TRAE doesn't expose usage
        // in local logs. Future versions could watch a usage-bridge endpoint.
        var fileCount = 0
        for dir in existing {
            let subdirs = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for sd in subdirs where sd.hasDirectoryPath {
                let main = sd.appendingPathComponent("main.log")
                if FileManager.default.fileExists(atPath: main.path) { fileCount += 1 }
            }
        }
        return SourceResult(
            samples: [],
            fileCount: fileCount,
            note: "TRAE 不在本地日志中记录 token 用量（仅云端统计），暂无法统计"
        )
    }
}
