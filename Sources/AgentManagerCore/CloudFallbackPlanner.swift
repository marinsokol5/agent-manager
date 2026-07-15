import Foundation

/// The pure decision core of the cloud fallback: given what's armed, what's
/// planned, and what just happened locally, decide the one action (if any) to
/// take against the routines API. No I/O — the `CloudFallbackEngine` executes
/// the action; the `SchedulerDaemon` supplies the inputs.
///
/// The invariant this planner maintains: **the account's routine is a one-shot
/// armed at `nextLocalFire + lead`, and it only ever moves forward past a fire
/// once that fire's coverage is resolved** — either the local ping anchored
/// (so the pending cloud run must be cancelled by re-arming forward), or the
/// armed moment itself passed (Anthropic fired the one-shot server-side; a
/// routine armed in the past *has run* — that's the dead-man property), or the
/// fire was replanned away before it ever came due (it sits in the future yet
/// is no longer next — a repaint moved the schedule, so its backstop follows).
/// Holding instead of re-arming after a local *failure* is what makes the
/// cloud run a backstop for failed pings too, not just slept-through ones.
public enum CloudFallbackPlanner {
    /// How far after a scheduled local fire its cloud backstop runs. Long
    /// enough for a healthy local ping (spawn + PTY turn, typically well under
    /// two minutes) to finish and re-arm first; short enough that a
    /// slept-through ping is still anchored near its planned minute.
    public static let lead: TimeInterval = 5 * 60

    /// After an API/keychain error, don't retry before this much has passed —
    /// one failed arm per fire is a backstop gap; hammering the API is worse.
    public static let errorBackoff: TimeInterval = 5 * 60

    /// Floor a Date to the whole second — the granularity the routine state
    /// store persists (`CloudFallbackStateStore` encodes `armedFor` with
    /// `.iso8601`, which drops sub-second precision). The arm target is passed
    /// through this before it's compared or armed so that a `desired` recomputed
    /// from an anchor-derived fire time — usage `resets_at` carries fractional
    /// seconds, so a deferred/unverified fire does too — stays bit-equal to the
    /// reloaded `armedFor` instead of drifting by that sub-second remainder and
    /// re-`PATCH`ing the routine every single tick. Flooring keeps the
    /// one-shot's minute intact; the <1 s shift is far inside the covered-fire
    /// matching tolerance and never crosses a window boundary.
    static func flooredToSecond(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.rounded(.down))
    }

    public enum Action: Equatable, Sendable {
        /// Nothing to do (already converged, or holding a pending backstop).
        case none
        /// Ensure the routine exists, is enabled, and fires at exactly `Date`.
        case arm(Date)
        /// Ensure the routine is disabled (feature off / scheduler off / no plan).
        case disable
    }

    /// Decide the next action for one account.
    ///
    /// - Parameters:
    ///   - state: the account's persisted routine state.
    ///   - nextFireAt: the next planned *local* fire, or `nil` when there is
    ///     nothing to back up (feature disabled, scheduler off, account not
    ///     schedulable, or an empty week ahead) — `nil` drives `disable`.
    ///   - lastAnchoredFireAt: the latest local-fire time whose pending
    ///     backstop is resolved: a verified local anchor, or a slot a known
    ///     live window already made unnecessary. The historical parameter name
    ///     remains for source compatibility.
    ///   - now: injected clock.
    ///   - lead: how far after the local fire to arm the backstop. The
    ///     `lead` constant (5 min) in fallback mode; `0` in cloud-primary mode,
    ///     where the routine *is* the anchor and fires at the planned minute.
    public static func plan(
        state: AccountCloudFallbackState,
        nextFireAt: Date?,
        lastAnchoredFireAt: Date?,
        now: Date,
        lead: TimeInterval = CloudFallbackPlanner.lead)
        -> Action
    {
        // Error backoff: after a failed sync, hold everything briefly. The
        // desired action will be recomputed unchanged on the next tick.
        if let at = state.lastErrorAt, now < at.addingTimeInterval(errorBackoff) {
            return .none
        }

        guard let nextFireAt else {
            // Nothing to back up. Disable the routine if one might be live.
            return (state.triggerID != nil && !state.disabled) ? .disable : .none
        }

        // Whole-second granularity so the compare below and the persisted
        // `armedFor` agree — see `flooredToSecond`. Without it, a sub-second
        // `desired` (deferred/unverified fires inherit `resets_at`'s fractional
        // seconds) never equals the whole-second `armedFor` that round-trips
        // through the state store, and the routine re-`PATCH`es every tick.
        let desired = CloudFallbackPlanner.flooredToSecond(nextFireAt.addingTimeInterval(lead))
        guard let armedFor = state.armedFor, !state.disabled, state.triggerID != nil else {
            return .arm(desired) // first arm, re-enable, or recreate
        }
        if armedFor == desired { return .none } // converged

        // Moving *earlier* is always safe (a repaint pulled the plan forward;
        // the old fire it covered no longer exists). Moving *forward* must not
        // strand an unresolved fire: only advance once the covered fire either
        // anchored locally, or its armed moment has passed (= the cloud ran
        // it), or it never got the chance to resolve at all — a fire that is
        // still *in the future* yet no longer the next planned one was
        // replanned away (a repaint pushed the schedule later, under a daemon
        // alive enough to be calling this), so holding its backstop would just
        // guarantee one pointless cloud run at the stale time. The dead-man
        // cases the hold exists for (slept-through or failed ping) both have
        // the covered fire in the *past* by the time this runs.
        if desired < armedFor { return .arm(desired) }
        if now >= armedFor { return .arm(desired) }
        if armedFor.addingTimeInterval(-lead) > now { return .arm(desired) }
        if let resolved = lastAnchoredFireAt, resolved.addingTimeInterval(lead) >= armedFor {
            return .arm(desired)
        }
        return .none // pending backstop — hold until it resolves
    }

    /// Whether a due local fire was already anchored by the cloud routine, so
    /// the daemon should *skip* the redundant local ping: true exactly when
    /// this fire's backstop (`fireAt + lead`) is what's armed and that moment
    /// has passed. An enabled one-shot whose time passed has fired server-side
    /// — Anthropic's scheduler doesn't need our Mac awake, which is the whole
    /// point. (If the user deleted the routine on the web this reads true
    /// wrongly once; the next arm's 404 recreates the routine and self-heals.)
    public static func isCovered(
        fireAt: Date,
        state: AccountCloudFallbackState,
        now: Date)
        -> Bool
    {
        guard let armedFor = state.armedFor,
              state.triggerID != nil,
              !state.disabled,
              state.lastError == nil
        else { return false }
        return armedFor == fireAt.addingTimeInterval(lead) && now >= armedFor
    }
}
