import Foundation

struct FileCursor: Sendable, Equatable {
    let offset: UInt64
    let identity: String
    let updatedAt: Date
    /// Opaque, source-defined blob (e.g. Codex's last cumulative usage +
    /// model, JSON-encoded) carried across resumes. Without this, resuming a
    /// large actively-growing file required re-reading its *entire* prefix
    /// from byte 0 on every refresh just to reconstruct a running baseline -
    /// fine for small files, but pathological for the multi-gigabyte
    /// sessions real Codex usage produces.
    var metadata: String?
}

actor SourceProgress {
    private var cursors: [String: FileCursor] = [:]
    private let storeURL: URL
    private var dirty = false

    init(storeURL: URL) {
        self.storeURL = storeURL
        // Loading synchronously via a `nonisolated static` helper - rather
        // than kicking off a detached `Task` to call an actor-isolated
        // `load()` - means cursors are populated before `init` returns, so
        // the very first `get()`/`update()` call can never race an
        // in-flight load and see an empty table for an already-scanned file.
        self.cursors = Self.loadCursors(from: storeURL)
    }

    private struct PersistedCursor: Codable {
        let offset: UInt64
        let identity: String
        let updatedAt: Date
        var metadata: String?
    }

    private nonisolated static func loadCursors(from storeURL: URL) -> [String: FileCursor] {
        guard let data = try? Data(contentsOf: storeURL),
              let map = try? JSONDecoder().decode([String: PersistedCursor].self, from: data) else {
            return [:]
        }
        var cursors: [String: FileCursor] = [:]
        for (k, v) in map {
            cursors[k] = FileCursor(offset: v.offset, identity: v.identity, updatedAt: v.updatedAt, metadata: v.metadata)
        }
        return cursors
    }

    private func persist() {
        guard dirty else { return }
        let map = cursors.reduce(into: [String: PersistedCursor]()) { acc, kv in
            acc[kv.key] = PersistedCursor(
                offset: kv.value.offset,
                identity: kv.value.identity,
                updatedAt: kv.value.updatedAt,
                metadata: kv.value.metadata
            )
        }
        if let data = try? JSONEncoder().encode(map) {
            try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: storeURL, options: .atomic)
        }
        dirty = false
    }

    func get(_ key: String) -> FileCursor? { cursors[key] }

    /// Marks the cursor dirty in memory but does not write to disk - a source
    /// scanning thousands of files (a full historical rescan) calls this once
    /// per file, and persisting the whole (growing) cursor table on every one
    /// of those calls turned into thousands of redundant full-file rewrites.
    /// Callers must call `flush()` once when they're done updating.
    func update(_ key: String, offset: UInt64, identity: String, metadata: String? = nil, updatedAt: Date = Date()) {
        cursors[key] = FileCursor(offset: offset, identity: identity, updatedAt: updatedAt, metadata: metadata)
        dirty = true
    }

    /// Writes the cursor table to disk if anything changed since the last
    /// flush. Each `TokenSource` calls this once at the end of its `collect()`
    /// rather than after every individual file's `update()`.
    func flush() {
        persist()
    }

    func clear() {
        cursors.removeAll()
        dirty = true
        persist()
    }
}

enum FileIdentity {
    static func of(_ url: URL) -> String {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let inode = attrs[.systemFileNumber] as? NSNumber {
            return "inode:\(inode.stringValue)"
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let birth = attrs[.creationDate] as? Date {
            return "birth:\(Int(birth.timeIntervalSince1970))"
        }
        return "name:\(url.lastPathComponent)"
    }
}
