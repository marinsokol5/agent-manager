import Foundation

/// Pure planning for the root wake helper: given the resident scheduler's
/// upcoming fire times, when should the RTC wake the Mac?
///
/// Everything here is deliberately dumb math over `Date`s so the one piece of
/// this repo that runs as root can be unit-tested exhaustively and audited at
/// a glance. The helper's `main` is just: read two files → `plan` → reconcile
/// the system's scheduled-power-event table.
public enum WakePlanner {
    /// Wake this many seconds *before* a fire. Short on purpose: a scheduled
    /// RTC wake is a *dark* wake with a leash of roughly half a minute, and the
    /// scheduler daemon ticks within 20 s of waking — it then bridges the last
    /// stretch with its own idle assertion (`SchedulerDaemon`'s wake bridge).
    /// Waking minutes early would just let the Mac fall back asleep before the
    /// fire.
    public static let defaultLead: TimeInterval = 45

    /// Ignore fires beyond this horizon. The queue snapshot only reaches ≤ 7
    /// days out, but the RTC table is a shared, bounded system resource — and a
    /// stale snapshot (user logged out, daemon dead) must age out of it
    /// naturally rather than keep a dead schedule waking the Mac for a week.
    public static let defaultHorizon: TimeInterval = 48 * 3600

    /// Hard cap on how many wake events we will ever own at once.
    public static let defaultCap = 12

    /// A status heartbeat older than this means no daemon is alive to actually
    /// fire the pings we'd wake for — schedule nothing. Generous (the daemon
    /// heartbeats every ≤ 20 s awake, but a Mac can legitimately sleep for a
    /// long weekend) while still letting an abandoned workspace go quiet.
    public static let defaultMaxStatusAge: TimeInterval = 8 * 24 * 3600

    /// The wake moments for the given fire times: `lead` seconds before each
    /// fire, strictly in the future, within `horizon`, deduped to one wake per
    /// minute (parallel accounts fire at the same minute), earliest first,
    /// capped at `cap`.
    public static func wakeDates(
        forFires fires: [Date],
        now: Date,
        lead: TimeInterval = defaultLead,
        horizon: TimeInterval = defaultHorizon,
        cap: Int = defaultCap)
        -> [Date]
    {
        var byMinute: [Int: Date] = [:]
        for fire in fires {
            let wake = fire.addingTimeInterval(-lead)
            // "> now + 5" not "> now": arming a wake seconds away is pointless
            // (the Mac is awake — we're running) and would linger in the table.
            guard wake.timeIntervalSince(now) > 5,
                  wake.timeIntervalSince(now) <= horizon else { continue }
            let minute = Int(wake.timeIntervalSince1970 / 60)
            if let existing = byMinute[minute], existing <= wake { continue }
            byMinute[minute] = wake
        }
        return byMinute.values.sorted().prefix(cap).map { $0 }
    }

    /// The full helper policy over one workspace snapshot: nothing unless the
    /// user opted in *and* a live daemon owns the queue; otherwise the wakes
    /// for its upcoming fires.
    public static func plan(
        _ snapshot: WakeInputs.Snapshot,
        now: Date,
        lead: TimeInterval = defaultLead,
        horizon: TimeInterval = defaultHorizon,
        cap: Int = defaultCap,
        maxStatusAge: TimeInterval = defaultMaxStatusAge)
        -> [Date]
    {
        guard snapshot.enabled else { return [] }
        guard let updatedAt = snapshot.statusUpdatedAt,
              now.timeIntervalSince(updatedAt) <= maxStatusAge else { return [] }
        return wakeDates(forFires: snapshot.fires, now: now, lead: lead, horizon: horizon, cap: cap)
    }
}
