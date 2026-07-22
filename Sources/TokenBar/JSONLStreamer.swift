import Foundation

/// Reads a file in bounded chunks, calling back once per newline-delimited
/// line as soon as it's available - never holding more than one chunk (plus
/// at most one very long line) in memory, regardless of how large the file or
/// the scanned range is.
///
/// Shared by every JSONL-based `TokenSource` so none of them has to reinvent
/// memory-safe incremental reads: a single multi-gigabyte session file loaded
/// whole via `readDataToEndOfFile()` was once enough to make the whole app
/// appear to hang.
enum ChunkedLineReader {
    private static let chunkSize = 4 * 1024 * 1024 // 4MB

    struct StreamResult {
        let newOffset: UInt64
        let hadNewBytes: Bool
    }

    /// Reads `url` from `startingOffset` up to `upperBound` (or EOF, if nil).
    static func stream(url: URL, startingOffset: UInt64, upperBound: UInt64? = nil, perLine: (Substring) -> Void) -> StreamResult? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        var start = startingOffset
        if upperBound == nil, start > size {
            // file rotated/truncated - rescan fully but baseline must reset
            start = 0
        }
        let limit = min(upperBound ?? size, size)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: start) } catch { return nil }
        guard start < limit else {
            return StreamResult(newOffset: start, hadNewBytes: false)
        }

        var pending = Data()
        var totalRead: UInt64 = 0
        while totalRead < limit - start {
            let wanted = min(UInt64(chunkSize), (limit - start) - totalRead)
            guard let chunk = try? handle.read(upToCount: Int(wanted)), !chunk.isEmpty else { break }
            totalRead += UInt64(chunk.count)
            pending.append(chunk)
            var searchStart = pending.startIndex
            while let newlineIndex = pending[searchStart...].firstIndex(of: 0x0A) {
                let lineData = pending[searchStart..<newlineIndex]
                if let s = String(data: lineData, encoding: .utf8), !s.isEmpty {
                    perLine(Substring(s))
                }
                searchStart = pending.index(after: newlineIndex)
            }
            if searchStart > pending.startIndex {
                pending.removeSubrange(pending.startIndex..<searchStart)
            }
        }
        if upperBound == nil, !pending.isEmpty, let s = String(data: pending, encoding: .utf8), !s.isEmpty {
            // Only treat a trailing chunk without a final newline as a whole
            // line when reading to true EOF; a bounded (upperBound) scan's
            // leftover bytes are just where the cut-off landed mid-line.
            perLine(Substring(s))
        }
        return StreamResult(newOffset: start + totalRead, hadNewBytes: totalRead > 0)
    }
}
