import Foundation

/// What actually happened to one scheduled ping child, as observed by the
/// scheduler daemon from the child's exit code.
///
/// Why this exists: the cloud-fallback re-arm decision must key on *"did a
/// window actually anchor"*, and exit code 0 alone can't say that — a child
/// that skips a stale ping also exits successfully. So `am ping` reports the
/// three outcomes as three distinct codes (an internal daemon↔child contract;
/// launchd never inspects them), and the daemon maps them back here.
public enum PingOutcome: String, Sendable, Equatable {
    /// The ping dispatched a real TUI turn — the account's 5h window anchored.
    case anchored
    /// The ping ran but no turn dispatched (or the account wasn't pingable).
    case failed
    /// The child's own staleness re-check bailed before burning a turn.
    case skippedStale
    /// The child wedged and the daemon had to kill it; whether the turn
    /// dispatched first is unknown, so treat it as *not* anchored.
    case timedOut

    /// Exit codes `am ping` uses to report the outcome to the daemon.
    public static let anchoredExitCode: Int32 = 0
    public static let failedExitCode: Int32 = 2
    public static let skippedStaleExitCode: Int32 = 3

    /// Map a ping child's exit code back to an outcome. Unknown codes read as
    /// `.failed` — the conservative answer for "did a window anchor?".
    public static func fromExitCode(_ code: Int32) -> PingOutcome {
        switch code {
        case anchoredExitCode: .anchored
        case skippedStaleExitCode: .skippedStale
        default: .failed
        }
    }
}
