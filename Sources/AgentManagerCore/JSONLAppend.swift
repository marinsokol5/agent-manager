import Foundation

/// The one way a JSONL record gets appended to a shared log file.
///
/// Why not `FileHandle` + `seekToEnd()`: the three JSONL logs are written by
/// several independent processes at once — the app, the `am` CLI, and the
/// scheduler daemon, often within the same second when the app refreshes all
/// accounts in parallel. Seek-then-write is two steps, so two writers can
/// resolve the same "end", then land on top of each other — the losing record
/// survives only as a torn tail glued to the winner's line. `O_APPEND` moves
/// the repositioning *inside* each `write(2)`, where the kernel does it
/// atomically, so whole-record appends from any number of writers stay intact.
///
/// Best-effort like the logs themselves: any failure (open, short write) is
/// swallowed, because logging must never break the flow it observes. A short
/// write can still tear a line in pathological cases (disk full); readers
/// already skip undecodable lines, so that degrades to one lost record.
enum JSONLAppend {
    /// Append one already-encoded JSON object as one `\n`-terminated line,
    /// creating the parent directory and the file if needed.
    static func appendLine(_ json: Data, to fileURL: URL, fileManager: FileManager = .default) {
        var data = json
        data.append(0x0A) // newline-delimited JSON

        let dir = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let fd = open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }

        // One write(2) per record keeps the line contiguous; loop only to
        // resume after EINTR or a short write (both rare on a local file).
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let n = write(fd, base + written, buffer.count - written)
                if n > 0 {
                    written += n
                } else if n == -1 && errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }
}
