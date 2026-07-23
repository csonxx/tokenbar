import Foundation

/// Tracks whether the on-disk cache (samples + per-file read offsets) was
/// built with the current accounting logic. Bumping `current` forces a
/// one-time reset-and-full-rescan on next launch, which is how a shipped fix
/// to the token accounting logic invalidates previously-computed (and
/// possibly wrong) history instead of leaving stale numbers mixed in forever.
struct MigrationState: Codable, Equatable {
    var schemaVersion: Int

    /// Bump this whenever a change to token accounting means previously
    /// persisted samples can no longer be trusted.
    ///
    /// v3: fixes a regression where resuming a Codex rollout whose cursor
    /// predated baseline metadata treated the next event as a delta from
    /// zero against a monotonically increasing counter, producing
    /// multi-billion-token spurious samples concentrated on whatever days
    /// happened to have active sessions.
    ///
    /// v4: adds a plausibility filter for corrupted upstream Codex data -
    /// real rollout files have been observed reporting a cumulative
    /// `cached_input_tokens` in the billions for a single turn (a bug on
    /// Codex's own side), which previously produced enormous spurious
    /// samples even with the v3 fix in place.
    ///
    /// v5: coalesces Codex's per-turn `token_count` checkpoints (which fire
    /// every 5-15 seconds *during* a turn's generation, not once per turn -
    /// confirmed against a real rollout file with 12 real turns but 148
    /// checkpoint events) into one sample per `turn_context` boundary.
    /// Previously each checkpoint became its own sample, inflating
    /// 调用次数/messageCount by roughly an order of magnitude and
    /// fragmenting a single turn's tokens across a dozen-plus rows.
    ///
    /// v6: suppresses the replayed parent history in forked Codex sessions.
    /// A fork re-emits the entire parent conversation's token_count history
    /// into the new rollout at fork time (a dense sub-second burst), which
    /// double-counted a whole already-counted session - observed in the wild
    /// as a ~3B-token spike dumped into the single minute a fork happened.
    static let current = 6

    static func load(storeURL: URL) -> MigrationState {
        guard let data = try? Data(contentsOf: storeURL),
              let state = try? JSONDecoder().decode(MigrationState.self, from: data) else {
            return MigrationState(schemaVersion: 0)
        }
        return state
    }

    func save(storeURL: URL) {
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }
}
