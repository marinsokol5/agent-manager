import Foundation

/// Decides whether a *scheduled* ping is "stale" — i.e. the Mac slept through
/// its planned moment and the fire is happening long after the fact.
///
/// Why skip a late fire instead of anchoring "better late than never": once
/// you're past the scheduled moment, anchoring now pre-heats nothing your own
/// first request wouldn't (it lands at roughly the same time), while it still
/// spends tokens, can burn one of the account's scarce daily resets, and
/// **desyncs** the account's real 5h window from the plan's fixed re-ping
/// times (see [[status-refresh-anchors-window]]).
///
/// The planned moment always comes from the scheduler daemon itself
/// (`am ping … --scheduled-for <epoch>` for the child; the queue entry's
/// `fireAt` inside the daemon) — the daemon knows its own intent, so staleness
/// is a direct comparison, never a reconstruction.
public enum StalePingPolicy {
    /// A scheduled ping firing more than this long after its scheduled minute
    /// is treated as slept-through and skipped.
    public static let defaultGrace: TimeInterval = 15 * 60

    /// Whether a scheduled ping firing at `now` is stale and should be skipped.
    /// A `nil` `scheduledFire` (no planned time supplied) is treated as *not*
    /// stale — fail-open, so a manual or oddly-invoked ping is never silently
    /// suppressed.
    public static func isStale(
        scheduledFire: Date?,
        now: Date,
        grace: TimeInterval = defaultGrace)
        -> Bool
    {
        guard let scheduledFire else { return false }
        return now.timeIntervalSince(scheduledFire) > grace
    }
}
