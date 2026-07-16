import Foundation

/// How Agent Manager delivers the tiny turn used to test or anchor an account.
///
/// `terminal` remains the safe default because the interactive subscription path
/// is the only method verified to move providers' rolling windows. The other
/// methods are deliberately selectable experiments: scheduled pings still use
/// post-turn usage evidence, never process success alone, to claim an anchor.
public enum PingMethod: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Drive the provider's real interactive TUI over a PTY.
    case terminal
    /// Run `claude -p` / `codex exec` and consume their structured output.
    case headless
    /// Drive the official provider SDK through a workspace helper script.
    case sdk

    public var id: String { rawValue }
}
