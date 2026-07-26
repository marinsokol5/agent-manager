import Foundation

// Closing the loop between the *planned* ping schedule and the *real* rolling
// window.
//
// The planner (`ScheduleEngine`) places re-pings at exactly the previous
// window's ideal expiry, and the daemon used to execute those minutes
// verbatim. But a real window anchors at fire time **plus latency** — PTY
// spawn, CLI boot, dispatch (Claude), or the whole completed turn (Codex) —
// and a grace-late fire or a cloud-covered fire (armed at `fire + 5 min` by
// design) shifts it minutes further. Once the real boundary trails the planned
// one, the next fixed-time ping lands *inside* the still-open window and
// anchors nothing: a phantom that burns a turn, logs a false "anchored", and
// silently forfeits the following ~5 h budget slice on an unattended Mac.
//
// The fix is feedback, not planner slack (plan-time slack can't absorb a
// 5–15 minute runtime shift without wasting coverage): the daemon tracks each
// account's best-known real expiry (`AccountWindowState`) and this policy
// shifts any queue entry that would land before it to `expiry + margin` —
// firing at the true boundary, which is exactly where a token-maxxing anchor
// belongs. Everything here is pure so the whole decision surface is testable;
// the daemon supplies the evidence and executes the adjusted queue.

/// Best-known real state of one account's rolling usage window at runtime.
///
/// `expiresAt` is the window *end* (the API's `resets_at`); persisting the
/// expiry rather than the anchor keeps the value meaningful even if the
/// configured window length changes later.
public struct AccountWindowState: Codable, Sendable, Equatable {
    /// How trustworthy `expiresAt` is.
    public enum Evidence: String, Codable, Sendable {
        /// Exact: a usage reading's `resets_at` (ground truth from the API).
        case usage
        /// Event-derived rather than API-verified: normally the upper bound
        /// "a local anchor finished by `observedAt`, so its window cannot
        /// outlive completion + window"; for a passed cloud one-shot it is the
        /// known `armedFor + window` boundary. Always replaced by the next
        /// exact usage reading.
        case conservative
    }

    public var expiresAt: Date
    public var evidence: Evidence
    /// When the evidence was obtained (a reading's `fetchedAt`, or the moment
    /// the daemon observed the anchoring event). Newest observation wins.
    public var observedAt: Date

    public init(expiresAt: Date, evidence: Evidence, observedAt: Date) {
        self.expiresAt = expiresAt
        self.evidence = evidence
        self.observedAt = observedAt
    }
}

/// The pure decision core the scheduler daemon runs every tick: merge window
/// evidence, and bend the nominal queue around known-open windows.
public enum RuntimeAnchorPolicy {
    /// The provider quantizes a rolling window's **start** down to this
    /// granularity. Observed, not documented: every `five_hour.resets_at` this
    /// app has ever recorded lands on a 10-minute mark (:00/:10/:20/:30/:40/:50)
    /// — ~120 distinct boundaries over three weeks of `network.jsonl`, with no
    /// exception. A turn at 05:35 anchors the window 05:30–10:30.
    ///
    /// Two consequences the rest of this policy depends on:
    ///
    /// - A window's expiry lands on the same grid, because the window length is
    ///   itself a multiple of the quantum.
    /// - The *implied* anchor of an exact expiry (`expiresAt - window`) can sit
    ///   up to one full quantum **before** the turn that actually produced it.
    ///   So attributing a window to a turn must compare floored values, never
    ///   allow a small clock tolerance — that mistake reads a real anchor as a
    ///   phantom (see `SchedulerDaemon.exactWindowPredates`).
    ///
    /// Everything here treats this as "*at most* this much quantization", so if
    /// Anthropic tightens or drops the grid, flooring degrades to a no-op
    /// instead of breaking attribution.
    public static let anchorQuantum: TimeInterval = 10 * 60

    /// Floor a date onto the provider's anchor grid — i.e. the anchor a turn at
    /// `date` actually produces (see `anchorQuantum`). Absolute, so it is
    /// independent of the local calendar; the epoch itself sits on the grid.
    public static func flooredToAnchorGrid(
        _ date: Date,
        quantum: TimeInterval = RuntimeAnchorPolicy.anchorQuantum)
        -> Date
    {
        guard quantum > 0 else { return date }
        let t = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: (t / quantum).rounded(.down) * quantum)
    }

    /// How far past a known expiry a deferred fire lands. The acceptance
    /// invariant of this whole feature: whenever a live reset is known, no
    /// automated turn starts before `reset + margin`.
    ///
    /// The margin is **free** up to one `anchorQuantum`. A known expiry always
    /// sits on the anchor grid, and a turn anywhere in
    /// `[expiry, expiry + quantum)` floors back to exactly `expiry` — so it
    /// anchors the very same window a hypothetical instant-at-expiry turn
    /// would, and forfeits no budget at all. Two minutes therefore buys real
    /// slack for nothing: clock skew against the provider, PTY spawn and CLI
    /// boot for a local ping, and the tens of seconds claude.ai takes to
    /// dispatch a `run_once_at` routine (35–45 s observed).
    ///
    /// It must stay *strictly* under `anchorQuantum`: one second past it and
    /// the anchor slips into the next bucket, which really does cost 10 minutes
    /// of every window that follows.
    public static let margin: TimeInterval = 120

    /// How far *below* the planner's minimum slice a deferred fire may land and
    /// still be worth anchoring.
    ///
    /// The planner rebalances each painted block into slices at or just above
    /// `minSliceMinutes`, so a block's final slice is routinely packed to
    /// *exactly* the floor. Meanwhile this policy refires a colliding entry at
    /// `expiry + margin`, and a conservative (non-`usage`) bound can overstate
    /// the real expiry by up to one `anchorQuantum` — the provider floors the
    /// anchor down, but a bound derived from an observed *event* can only floor
    /// the moment we noticed it. So the tail slot of every block measures a
    /// little short once deferred, and re-testing the planner's own floor
    /// against the shifted time would drop it *every time* — silently
    /// forfeiting the last budget slice of the day (and, under the `routine`
    /// ping method, leaving that window with neither a local ping nor an armed
    /// routine).
    ///
    /// So the budget is exactly the worst *legitimate* shift — one quantum of
    /// conservative overstatement plus one refire margin. That keeps the
    /// planner's decision stable under jitter while still dropping genuine
    /// shortfalls, which are tens of minutes: a window that outlives its
    /// planned fire by an hour leaves far more than this missing.
    public static var maxSliceShortfall: TimeInterval {
        RuntimeAnchorPolicy.anchorQuantum + RuntimeAnchorPolicy.margin
    }

    /// Whether an expiry can describe a window that is live at `now`.
    /// Besides being in the future, it cannot be more than one full rolling
    /// window plus a small clock tolerance away: an anchor cannot happen in
    /// the future, but the provider and Mac clocks need not agree to the
    /// second. The daemon and scheduled child share this check so a corrupt
    /// cache cannot make the child defer forever while the daemon distrusts
    /// the same value and immediately respawns it.
    public static func isPlausibleLiveExpiry(
        _ expiresAt: Date,
        at now: Date,
        window: TimeInterval,
        clockTolerance: TimeInterval = RuntimeAnchorPolicy.margin)
        -> Bool
    {
        expiresAt > now && expiresAt <= now.addingTimeInterval(window + clockTolerance)
    }

    /// Combine two pieces of window evidence: the newer observation wins
    /// outright (a fresh usage reading must be able to *shorten* a
    /// conservative bound); at the same instant, exact `usage` evidence beats
    /// a `conservative` bound, and equal-quality ties keep the later expiry
    /// (the safer defer).
    public static func merged(
        _ current: AccountWindowState?,
        _ candidate: AccountWindowState)
        -> AccountWindowState
    {
        guard let current else { return candidate }
        if candidate.observedAt != current.observedAt {
            return candidate.observedAt > current.observedAt ? candidate : current
        }
        if candidate.evidence != current.evidence {
            return candidate.evidence == .usage ? candidate : current
        }
        return candidate.expiresAt > current.expiresAt ? candidate : current
    }

    /// The adjusted work list for one tick.
    public struct AdjustedQueue: Equatable, Sendable {
        /// Entries to fire, shifted where a known-open window collides;
        /// sorted by effective fire time (ties keep the input priority order).
        public var entries: [QueueEntry]
        /// Entries whose *nominal* moment has passed but whose slice has no
        /// planner-worthy work left after the open window — resolve as skips
        /// (advance the nominal watermark, log once) instead of deferring them
        /// into a pointless anchor. Like shifted runnable entries, these carry
        /// the effective boundary in `fireAt` and nominal identity in
        /// `plannedAt`, so cloud-routine resolution follows the right time.
        public var covered: [QueueEntry]

        public init(entries: [QueueEntry] = [], covered: [QueueEntry] = []) {
            self.entries = entries
            self.covered = covered
        }
    }

    /// Bend the nominal queue around the known-open windows.
    ///
    /// For each entry whose planned minute falls inside its account's
    /// best-known window, the effective fire moves to `expiresAt + margin`.
    /// A shifted entry can become pointless two ways: the shift reaches the
    /// account's *next* nominal entry (which will anchor anyway — two anchors
    /// can't share a window), or no usable painted-work slice remains between
    /// the shifted fire and the next opportunity (deferring into off-hours or
    /// for a below-floor sliver wastes an anchor). Those resolve as `covered`
    /// once nominally due;
    /// until then they simply drop out of `entries` and are reconsidered on
    /// every rebuild, so corrected evidence restores them automatically.
    ///
    /// Evidence is distrusted wholesale when physically impossible — a rolling
    /// window's expiry can never exceed `now + window + margin` (its anchor
    /// can't be materially in the future) — so a corrupt state file degrades
    /// to fixed-time behavior instead of silently eating the schedule as
    /// "covered".
    ///
    /// - Parameters:
    ///   - queue: nominal entries from `PingQueuePlanner` (sorted, `plannedAt`
    ///     nil — their `fireAt` *is* the planned minute).
    ///   - nextNominalFire: optional cyclic successor lookup. The daemon uses
    ///     it to bridge the concrete queue's last-entry→next-week-first seam.
    ///   - hasPaintedWork: does a planner-worthy painted-work slice overlap
    ///     `[from, to)`? Injected because mapping Dates onto the painted week
    ///     and applying its minimum-slice floor needs the daemon's calendar +
    ///     schedule. The caller is expected to relax that floor by
    ///     `maxSliceShortfall`, since this policy measures the slice from the
    ///     *deferred* fire — see that constant for why.
    public static func adjust(
        _ queue: [QueueEntry],
        windowStates: [String: AccountWindowState],
        window: TimeInterval,
        now: Date,
        margin: TimeInterval = RuntimeAnchorPolicy.margin,
        nextNominalFire: ((QueueEntry) -> Date?)? = nil,
        hasPaintedWork: (Date, Date) -> Bool)
        -> AdjustedQueue
    {
        var result = AdjustedQueue()
        for (index, entry) in queue.enumerated() {
            let planned = entry.nominalFireAt
            guard let state = windowStates[entry.accountID],
                  state.expiresAt <= now.addingTimeInterval(window + margin)
            else {
                result.entries.append(entry)
                continue
            }

            let effective = state.expiresAt.addingTimeInterval(margin)
            // The safety margin belongs to the invariant too. An entry at the
            // exact reset instant (or a few seconds after it) must still move
            // to `reset + margin`; otherwise the boundary race survives.
            guard effective > planned else {
                result.entries.append(entry)
                continue
            }
            // The daemon supplies the cyclic successor so the last entry in
            // this week's concrete queue can still see next week's first
            // entry. Without that Sunday→Monday seam, a deferral crossing the
            // week boundary could leave two nominal slots competing for the
            // same physical anchor. Pure callers may omit it and retain the
            // linear-queue behavior.
            let successorPlanned = nextNominalFire?(entry) ?? queue[(index + 1)...]
                .first { $0.accountID == entry.accountID }?
                .nominalFireAt

            let reachesSuccessor = successorPlanned.map { effective >= $0 } ?? false
            let cap = min(
                successorPlanned ?? .distantFuture,
                effective.addingTimeInterval(window))
            if reachesSuccessor || !hasPaintedWork(effective, cap) {
                // The open window covers everything this entry was for. Only a
                // nominally-due entry is *resolved* (watermarked + logged);
                // a future one just sits out this rebuild.
                if planned <= now {
                    // Preserve both identities here too: the cloud routine may
                    // already be armed from a previously published effective
                    // time, so resolving only the nominal time could fail to
                    // move that later, now-pointless one-shot.
                    var coveredEntry = entry
                    coveredEntry.plannedAt = planned
                    coveredEntry.fireAt = effective
                    result.covered.append(coveredEntry)
                }
                continue
            }

            var shifted = entry
            shifted.plannedAt = planned
            shifted.fireAt = effective
            result.entries.append(shifted)
        }

        // Deferrals can reorder across accounts; ties keep the input
        // (priority) order, mirroring `PingQueuePlanner.queue`.
        result.entries = result.entries.enumerated()
            .sorted { a, b in
                a.element.fireAt == b.element.fireAt
                    ? a.offset < b.offset
                    : a.element.fireAt < b.element.fireAt
            }
            .map(\.element)
        return result
    }
}
