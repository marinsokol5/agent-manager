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
/// retired the hold with it: an armed moment still in the future can always be
/// moved, because nothing else was going to anchor that fire.)
public enum CloudFallbackPlanner {
    /// After an API/keychain error, don't retry before this much has passed —
    /// one failed arm per fire is a missed anchor; hammering the API is worse.
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
    ///   - now: injected clock.
    public static func plan(
        state: AccountCloudFallbackState,
        nextFireAt: Date?,
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
            return (state.triggerID != nil && !state.disabled) ? .disable : .none
        }

        // Whole-second granularity so the compare below and the persisted
        // `armedFor` agree — see `flooredToSecond`. Without it, a sub-second
        // `desired` (deferred/unverified fires inherit `resets_at`'s fractional
        // seconds) never equals the whole-second `armedFor` that round-trips
        // through the state store, and the routine re-`PATCH`es every tick.
        let desired = CloudFallbackPlanner.flooredToSecond(nextFireAt)
        guard let armedFor = state.armedFor, !state.disabled, state.triggerID != nil else {
            return .arm(desired) // first arm, re-enable, or recreate
        }
        // Converged — which also covers the minutes right after a one-shot
        // fires: that fire stays at the head of the queue until the daemon
        // reconciles it, so `desired` still equals `armedFor` and the routine
        // is never moved forward before its run has been accounted for.
        if armedFor == desired { return .none }
        return .arm(desired)
    }
}
