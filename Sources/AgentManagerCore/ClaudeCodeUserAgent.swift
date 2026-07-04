#if canImport(Darwin)
import Darwin
#endif
import Foundation

/// Produces the exact `claude-cli/<version> (external, cli)` User-Agent the real
/// Claude CLI sends to the Anthropic OAuth usage endpoint (captured from the
/// wire). Sending our own app's default URLSession UA to that client-gated
/// endpoint is exactly the kind of anomaly that gets an account throttled, so we
/// mirror the CLI byte-for-byte.
///
/// The version is detected once (by running `claude --version`) and cached; the
/// detection runs off the calling actor so it never blocks the UI, and falls
/// back to a constant if `claude` can't be found or is slow.
public actor ClaudeCodeUserAgent {
    public static let shared = ClaudeCodeUserAgent()

    /// Used when detection fails; the real detected version is preferred whenever
    /// the CLI is reachable.
    public static let fallbackVersion = "2.1.191"

    private var cached: String?

    public func value() async -> String {
        if let cached { return cached }
        let version = await Task.detached(priority: .utility) {
            Self.detectVersion() ?? Self.fallbackVersion
        }.value
        let ua = "claude-cli/\(version) (external, cli)"
        cached = ua
        return ua
    }

    /// Run `claude --version` and return the leading semver token (e.g. `2.1.0`
    /// from `2.1.0 (Claude Code)`), or `nil` on any failure.
    private static func detectVersion(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        guard let path = ExecutableResolver.resolve("claude", environment: environment) else {
            return nil
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["--version"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        proc.standardInput = nil

        let done = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in done.signal() }
        do { try proc.run() } catch { return nil }

        if done.wait(timeout: .now() + 5) != .success {
            if proc.isRunning { proc.terminate() }
            return nil
        }
        guard proc.terminationStatus == 0,
              let line = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                  .split(whereSeparator: \.isNewline).first
        else { return nil }
        let token = line.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? String(line)
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
