#if canImport(Darwin)
import Darwin
#endif
import Foundation

/// Low-level pseudo-terminal session: spawns a CLI attached to a PTY and exposes
/// the primitives the higher-level runners (login, ping) drive — non-blocking
/// drain, send, answer the terminal's cursor-position query, and an idempotent
/// teardown of the whole process group.
///
/// We never proxy the OAuth token — we drive the real CLI, which reads and writes
/// its own credentials.
final class PTYSession {
    enum SpawnError: Error {
        case binaryNotFound
        case openptyFailed
        case launchFailed(String)
    }

    private let primaryFD: Int32
    private let primaryHandle: FileHandle
    private let secondaryHandle: FileHandle
    private let process: Process
    private var terminated = false

    /// Everything read from the PTY so far (raw bytes; carries ANSI control codes).
    private(set) var buffer = Data()

    private static let cursorQuery = Data([0x1B, 0x5B, 0x36, 0x6E])  // ESC [ 6 n
    private static let cursorReply = "\u{1B}[1;1R"

    init(
        binary: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL? = nil,
        rows: UInt16 = 50,
        cols: UInt16 = 160) throws
    {
        guard let resolved = ExecutableResolver.resolve(binary, environment: environment) else {
            throw SpawnError.binaryNotFound
        }

        var primary: Int32 = -1
        var secondary: Int32 = -1
        var win = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&primary, &secondary, nil, nil, &win) == 0 else {
            throw SpawnError.openptyFailed
        }
        _ = fcntl(primary, F_SETFL, O_NONBLOCK)

        primaryFD = primary
        primaryHandle = FileHandle(fileDescriptor: primary, closeOnDealloc: true)
        secondaryHandle = FileHandle(fileDescriptor: secondary, closeOnDealloc: true)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: resolved)
        proc.arguments = arguments
        proc.standardInput = secondaryHandle
        proc.standardOutput = secondaryHandle
        proc.standardError = secondaryHandle
        proc.environment = environment
        // Without this the child inherits the launchd job's cwd (`/`), which the
        // CLI treats as an untrusted project root and gates behind a trust modal.
        if let workingDirectory { proc.currentDirectoryURL = workingDirectory }
        do {
            try proc.run()
        } catch {
            try? primaryHandle.close()
            try? secondaryHandle.close()
            throw SpawnError.launchFailed(error.localizedDescription)
        }
        process = proc
        _ = setpgid(proc.processIdentifier, proc.processIdentifier) // own group → kill the subtree
    }

    var isRunning: Bool { process.isRunning }

    /// Lossy UTF-8 view of everything captured so far.
    var text: String { String(decoding: buffer, as: UTF8.self) }

    var terminationStatus: Int32 { process.terminationStatus }

    /// Drain all currently-available bytes (non-blocking) into `buffer`.
    func drain() {
        var tmp = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(primaryFD, &tmp, tmp.count)
            if n > 0 { buffer.append(contentsOf: tmp.prefix(n)); continue }
            break
        }
    }

    func send(_ string: String) {
        let data = Data(string.utf8)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = write(primaryFD, base.advanced(by: offset), raw.count - offset)
                if n > 0 { offset += n; continue }
                if n == 0 { break }
                if errno == EAGAIN || errno == EWOULDBLOCK { usleep(5000); continue }
                break
            }
        }
    }

    /// If the TUI asked for the cursor position (ESC[6n), answer it so it doesn't
    /// stall, and strip the request so we don't reply to the same stale bytes.
    func answerCursorQueryIfNeeded() {
        guard let range = buffer.range(of: Self.cursorQuery) else { return }
        send(Self.cursorReply)
        buffer.removeSubrange(range)
    }

    /// Ask the CLI to exit, then signal the whole process group. Idempotent.
    func terminate() {
        guard !terminated else { return }
        terminated = true
        if process.isRunning {
            send("/exit\r")
            usleep(150_000)
        }
        try? primaryHandle.close()
        try? secondaryHandle.close()
        if process.isRunning {
            let pid = process.processIdentifier
            kill(-pid, SIGTERM)
            let killBy = Date().addingTimeInterval(2.0)
            while process.isRunning, Date() < killBy { usleep(100_000) }
            if process.isRunning { kill(-pid, SIGKILL) }
        }
        process.waitUntilExit()
    }

}
