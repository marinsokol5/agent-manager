import Foundation

/// How an account's rolling window gets anchored — one question, one list.
///
/// Four of these are *local drivers*: different ways this Mac delivers the
/// tiny turn. `headless` is what a fresh install starts on
/// (`Preferences.default`) — it needs nothing installed beyond the provider's
/// own CLI, and it reads a documented structured result instead of scraping a
/// TUI, so it is the least likely to break under either provider. `terminal`
/// drives the real interactive path — the first method verified to move a
/// rolling window, still what installs made before that default keep, and the
/// fallback wherever a stored choice can't be honored (see `sanitized` and
/// `localDriver`). `sdk` is the outlier that needs a user-installed dependency.
/// `custom` is the user's own executable (an eval, a daily job) run under the
/// managed home instead of a throwaway turn — see `CustomPingRunner`; it is a
/// local driver too, so `localDriver` leaves it alone.
/// Whichever runs, scheduled pings claim an anchor only from post-turn usage
/// evidence, never from process success.
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
/// Declaration order is display order — the default first (see `available`).
public enum PingMethod: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Run `claude -p` / `codex exec` and consume their structured output.
    case headless
    /// Drive the provider's real interactive TUI over a PTY.
    case terminal
    /// Drive the official provider SDK through a workspace helper script.
    case sdk
    /// Run the user's own command (`Preferences.customCommand(forAccount:provider:)`
    /// — the account override's command, else its provider's) under
    /// the managed home and let usage verification decide if it anchored.
    case custom
    /// Let a one-shot claude.ai routine anchor each scheduled slot from
    /// Anthropic's cloud; no local ping runs for the account (Claude only).
    case routine

    public var id: String { rawValue }

    /// Does this provider offer the method? Only Claude has cloud routines.
    public func isAvailable(for provider: Provider) -> Bool {
        self != .routine || provider.supportsCloudAnchorRoutines
    }

    /// The methods to offer for `provider`, in display order: the default
    /// local driver first, then the other local drivers, the cloud routine
    /// last.
    public static func available(for provider: Provider) -> [PingMethod] {
        allCases.filter { $0.isAvailable(for: provider) }
    }

    /// Coerce a method the provider doesn't offer back to the verified driver.
    /// A hand-edited `preferences.json` can name `routine` for a provider that
    /// has no routines; this is what keeps that from reaching the daemon as
    /// "never ping this account, and nothing anchors it either". It lands on
    /// `terminal`, not on the fresh-install default: a value we can't honor
    /// says nothing about which method this install wants, so it gets the one
    /// verified to anchor.
    public func sanitized(for provider: Provider) -> PingMethod {
        isAvailable(for: provider) ? self : .terminal
    }

    /// The driver to use when a turn has to run on *this* Mac. `.routine`
    /// schedules a cloud run — it cannot deliver a turn now — so local turns
    /// under that preference fall back to the verified terminal driver. That
    /// fallback deliberately doesn't follow the fresh-install default: what
    /// reaches it is a Test ping or a hand-run `am ping`, i.e. someone checking
    /// that a turn *works*, which is the one place to spend the interactive
    /// path this account isn't otherwise using.
    public var localDriver: PingMethod {
        self == .routine ? .terminal : self
    }

    /// The account is anchored by a claude.ai routine instead of a local turn.
    public var usesCloudRoutine: Bool { self == .routine }
}
