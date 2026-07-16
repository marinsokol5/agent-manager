import Foundation

/// What actually happened to one scheduled ping child, as observed by the
/// scheduler daemon from the child's exit code.
///
/// Why this exists: the cloud-fallback re-arm decision must key on *"did a
/// window actually anchor"*, and exit code 0 alone can't say that — a child
/// that skips a stale ping also exits successfully. So `am ping` reports the
/// each outcome as a distinct code (an internal daemon↔child contract;
/// launchd never inspects them), and the daemon maps them back here.
public enum PingOutcome: String, Sendable, Equatable {
    /// The selected method completed a turn and the account's 5h window
    /// verifiably anchored.
    case anchored
    /// The ping ran but no turn dispatched (or the account wasn't pingable).
    case failed
    /// The child's own staleness re-check bailed before burning a turn.
    case skippedStale
    /// The child's preflight proved the window is *still open* (a live
    /// `resets_at` in the future) and bailed before burning a phantom turn.
    /// The daemon keeps the entry and re-fires it just past the real expiry.
    case deferredOpenWindow
    /// A turn ran, but whether the window advanced could not be verified
    /// (usage unavailable). Schedule around the best available window
    /// evidence, but never treat it as an anchor for cloud-fallback purposes.
    case anchorUnknown
    /// The child wedged and the daemon had to kill it; whether the turn
    /// dispatched first is unknown, so treat it as *not* anchored.
    case timedOut

    /// Exit codes `am ping` uses to report the outcome to the daemon.
    public static let anchoredExitCode: Int32 = 0
    public static let failedExitCode: Int32 = 2
    public static let skippedStaleExitCode: Int32 = 3
    public static let deferredOpenWindowExitCode: Int32 = 4
    public static let anchorUnknownExitCode: Int32 = 5

    /// Map a ping child's exit code back to an outcome. Unknown codes read as
    /// `.failed` — the conservative answer for "did a window anchor?".
    public static func fromExitCode(_ code: Int32) -> PingOutcome {
        switch code {
        case anchoredExitCode: .anchored
        case skippedStaleExitCode: .skippedStale
        case deferredOpenWindowExitCode: .deferredOpenWindow
        case anchorUnknownExitCode: .anchorUnknown
        default: .failed
        }
    }
}
