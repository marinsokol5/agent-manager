import Foundation

/// How an account's rolling window gets anchored — one question, one list.
///
/// Three of these are *local drivers*: different ways this Mac delivers the
/// tiny turn. `terminal` remains the safe default because the interactive
/// subscription path is the only local method verified to move providers'
/// rolling windows; `headless` and `sdk` are deliberately selectable
/// experiments, and scheduled pings still use post-turn usage evidence, never
/// process success alone, to claim an anchor.
///
/// `routine` is the odd one out, and it belongs in the same list precisely
/// because it answers the same question — the turn just runs on Anthropic's
/// side. Picking it means the scheduler daemon keeps a one-shot claude.ai
/// routine armed at each planned fire and **never spawns a local ping** for
/// that account: the mode for a Mac that can't be trusted to be awake at the
/// planned minute (chronic sleep races; a closed lid on battery, where the
/// firmware blocks RTC wakes altogether). It is Claude-only
/// (`Provider.supportsCloudAnchorRoutines`), and it never delivers a turn
/// *here*: anything that must run now — Test ping, a hand-run `am ping` —
/// uses `localDriver` instead.
public enum PingMethod: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Drive the provider's real interactive TUI over a PTY.
    case terminal
    /// Run `claude -p` / `codex exec` and consume their structured output.
    case headless
    /// Drive the official provider SDK through a workspace helper script.
    case sdk
    /// Let a one-shot claude.ai routine anchor each scheduled slot from
    /// Anthropic's cloud; no local ping runs for the account (Claude only).
    case routine

    public var id: String { rawValue }

    /// Does this provider offer the method? Only Claude has cloud routines.
    public func isAvailable(for provider: Provider) -> Bool {
        self != .routine || provider.supportsCloudAnchorRoutines
    }

    /// The methods to offer for `provider`, in display order (local drivers
    /// first, the cloud routine last).
    public static func available(for provider: Provider) -> [PingMethod] {
        allCases.filter { $0.isAvailable(for: provider) }
    }

    /// Coerce a method the provider doesn't offer back to the verified default.
    /// A hand-edited `preferences.json` can name `routine` for a provider that
    /// has no routines; this is what keeps that from reaching the daemon as
    /// "never ping this account, and nothing anchors it either".
    public func sanitized(for provider: Provider) -> PingMethod {
        isAvailable(for: provider) ? self : .terminal
    }

    /// The driver to use when a turn has to run on *this* Mac. `.routine`
    /// schedules a cloud run — it cannot deliver a turn now — so local turns
    /// under that preference fall back to the verified terminal driver.
    public var localDriver: PingMethod {
        self == .routine ? .terminal : self
    }

    /// The account is anchored by a claude.ai routine instead of a local turn.
    public var usesCloudRoutine: Bool { self == .routine }
}
