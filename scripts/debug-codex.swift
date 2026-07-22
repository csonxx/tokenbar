import Foundation
// Ad-hoc debug runner to inspect Codex sample counts.

let home = FileManager.default.homeDirectoryForCurrentUser
let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
let progress = SourceProgress(storeURL: supportDir.appendingPathComponent("TokenBar/dbgsrc.json"))
let src = CodexSource(home: home, progress: progress)

let sem = DispatchSemaphore(value: 0)
Task {
    do {
        let r = try await src.collect()
        print("files=\(r.fileCount) samples=\(r.samples.count)")
        for s in r.samples.prefix(3) {
            print("  \(s.tool.rawValue) ts=\(s.timestamp) in=\(s.inputTokens) out=\(s.outputTokens) cacheR=\(s.cacheReadTokens) cacheW=\(s.cacheWriteTokens)")
        }
    } catch {
        print("error \(error)")
    }
    sem.signal()
}
sem.wait()
exit(0)
