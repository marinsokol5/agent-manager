import Foundation

/// The pure decision core of the cloud anchor routine: given what's armed and
/// what's planned, decide the one action (if any) to take against the routines
/// API. No I/O — the `CloudFallbackEngine` executes the action; the
/// `SchedulerDaemon` supplies the inputs.
///
/// The invariant this planner maintains: **the account's routine is a one-shot
/// armed at its next planned fire, and nothing else.** Under the `routine` ping
/// method the cloud run *is* the anchor — there is no local ping racing it, and
/// no "did the Mac manage it?" to wait on — so convergence is the whole rule:
/// arm at the next fire, re-arm whenever that moves, disable when there is no
/// fire to anchor.
///
/// (It was more than that once. The routine used to be a dead-man's switch
/// armed five minutes *after* a local ping, which meant holding an armed
/// one-shot until that fire resolved — anchored locally, or fired in the cloud
/// — so a slept-through ping still got covered. Retiring the backstop mode
/// retired *that* reason for the hold, but not the hold: see `dispatchSettle`.
/// An armed moment still in the future can always be moved; an armed moment
/// that has just passed cannot, because the server may be about to run it.)
public enum CloudFallbackPlanner {
    /// After an API/keychain error, don't retry before this much has passed —
    /// one failed arm per fire is a missed anchor; hammering the API is worse.
    public static let errorBackoff: TimeInterval = 5 * 60

    /// How long a passed one-shot stays untouchable while its run is
    /// unaccounted for.
    ///
    /// claude.ai dispatches a `run_once_at` routine *late* — 35–45 s past the
    /// armed second, measured — and `run_once_at` is simultaneously the only
    /// handle the server has on that pending run. So patching it forward inside
    /// the dispatch gap **cancels the run**. That is not theoretical: arming at
    /// the exact fire and re-arming the moment the minute passed silently
    /// deleted every routine run on an awake Mac, and credited each one as an
    /// anchor on the way out. The routine could only ever succeed when the
    /// daemon happened to be asleep through its own fire.
    ///
    /// So nothing about an armed fire may move until it resolves — not the
    /// arming, not the queue entry, not the "covered" bookkeeping — and this is
    /// the deadline at which "still can't see it" becomes "it did not run".
    /// Sized to sit far past the observed dispatch latency yet well inside
    /// `StalePingPolicy.defaultGrace`, so a held queue entry can never be
    /// stale-dropped while it waits.
    public static let dispatchSettle: TimeInterval = 5 * 60

    /// Round a Date **up** to the whole minute — the granularity `run_once_at`
    /// actually schedules at, and the granularity the routine state store
    /// persists (`CloudFallbackStateStore` encodes `armedFor` with `.iso8601`,
    /// which drops sub-second precision anyway).
    ///
    /// Rounding *up* rather than down is deliberate: it can never place the fire
    /// before the reset it was deferred past, and the sub-minute shift is free
    /// (see `RuntimeAnchorPolicy.anchorQuantum` — it floors back to the same
    /// anchor). It also stops the routine's own page from advertising a
    /// misleading `10:30` for what we meant as "just past the 10:30 reset".
    static func ceilingToMinute(_ date: Date) -> Date {
        let minute: TimeInterval = 60
        let t = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: (t / minute).rounded(.up) * minute)
    }

    /// Would arming at `desired` instead of `armedFor` actually change anything?
    ///
    /// No, whenever both land in the same anchor bucket: the provider floors a
    /// window's start onto its grid, so two one-shots inside one bucket produce
    /// *the same anchor*, and re-`PATCH`ing from one to the other is pure churn
    /// against the customer's own routine list. That is not hypothetical — a
    /// fire recomputed from usage `resets_at` inherits both its sub-second
    /// remainder and the ±1 s jitter the provider puts on it (the same window
    /// reads as `10:29:59.576` *and* `10:30:00.848`), which re-armed a live
    /// routine from `10:30:59` to `10:31:00`, twice in five minutes, observed.
    /// Neither second would have anchored differently.
    ///
    /// Comparing buckets rather than allowing a fixed dead band is what makes
    /// this safe in the direction that matters: a deferred target is
    /// `reset + margin` and a reset always sits *on* a bucket edge, so anything
    /// sharing that bucket is necessarily at or after the reset. Keeping the
    /// existing arm can never pull the fire back inside the window it was
    /// deferred past.
    static func sameAnchorBucket(_ armedFor: Date, _ desired: Date) -> Bool {
        RuntimeAnchorPolicy.flooredToAnchorGrid(armedFor)
            == RuntimeAnchorPolicy.flooredToAnchorGrid(desired)
    }

    public enum Action: Equatable, Sendable {
        /// Nothing to do (already converged, or backing off after an error).
        case none
        /// Ensure the routine exists, is enabled, and fires at exactly `Date`.
        case arm(Date)
        /// Ensure the routine is disabled (method off / scheduler off / no plan).
        case disable
    }

    /// Decide the next action for one account.
    ///
    /// - Parameters:
    ///   - state: the account's persisted routine state.
    ///   - nextFireAt: the next planned fire, or `nil` when there is nothing to
    ///     anchor (the account's ping method isn't `routine`, the scheduler is
    ///     off, the account isn't schedulable, or the week ahead is empty) —
    ///     `nil` drives `disable`.
    ///   - resolvedFire: the latest fire whose cloud run this account has
    ///     already accounted for (`scheduler-status.json`'s `lastResolvedFire`).
    ///     An armed fire at or after this is still in flight — see
    ///     `dispatchSettle`.
    ///   - now: injected clock.
    public static func plan(
        state: AccountCloudFallbackState,
        nextFireAt: Date?,
        resolvedFire: Date? = nil,
        now: Date)
        -> Action
    {
        // Error backoff: after a failed sync, hold everything briefly. The
        // desired action will be recomputed unchanged on the next tick.
        if let at = state.lastErrorAt, now < at.addingTimeInterval(errorBackoff) {
            return .none
        }

        guard let nextFireAt else {
            // Nothing to anchor. Disable the routine if one might be live.
            // Deliberately *not* held by `dispatchSettle`: this is the user
            // turning the method (or the scheduler) off, and standing the
            // routine down is the point. Cancelling a run that was about to
            // fire is the intended outcome, not a casualty.
            return (state.triggerID != nil && !state.disabled) ? .disable : .none
        }

        // Whole-minute granularity, to match what `run_once_at` can actually
        // schedule and what the state store persists — see `ceilingToMinute`.
        let desired = CloudFallbackPlanner.ceilingToMinute(nextFireAt)
        guard let armedFor = state.armedFor, !state.disabled, state.triggerID != nil else {
            return .arm(desired) // first arm, re-enable, or recreate
        }
        // Converged — including the case where the target merely jittered within
        // its anchor bucket, which would anchor identically (`sameAnchorBucket`).
        if CloudFallbackPlanner.sameAnchorBucket(armedFor, desired) { return .none }
        // The hold: this one-shot's moment has passed and nothing has accounted
        // for its run yet, so the server may be seconds away from dispatching
        // it. Moving `run_once_at` now would cancel it. Wait for the daemon to
        // resolve the fire — or, if resolution never comes, for the settle
        // deadline, so a stuck reconciler can't freeze the routine forever.
        if now >= armedFor,
           now < armedFor.addingTimeInterval(dispatchSettle),
           (resolvedFire ?? .distantPast) < armedFor
        {
            return .none
        }
        return .arm(desired)
    }
}
