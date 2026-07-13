import Foundation

/// Did a ping's turn actually anchor a fresh window? Pure classification over
/// the usage readings the scheduled ping child fetches around its turn.
///
/// Why this exists: "the TUI turn succeeded" and "the 5h window advanced" are
/// different facts. A turn dispatched into a *still-open* window succeeds and
/// anchors nothing (usage inside a window never moves its boundary) — the
/// phantom this whole feature exists to kill. The discriminator is
/// `resets_at`: it moves **only** when a new window anchors, so comparing the
/// pre-turn and post-turn readings says definitively whether this turn did.
public enum AnchorVerification {
    public enum Verdict: Equatable, Sendable {
        /// The post-turn reading shows a live window the pre-turn state didn't
        /// have (or had with a different boundary): this turn anchored it.
        case verified(expiresAt: Date)
        /// The pre-turn window was live and the post-turn boundary never
        /// moved: the turn burned inside the open window and anchored nothing.
        case phantom(openUntil: Date)
        /// No usable post-turn reading (fetch failed, no `resets_at`, or an
        /// inconsistent snapshot) — can't say either way. Callers schedule
        /// conservatively around it and never report it as an anchor.
        case unknown
    }

    /// - Parameters:
    ///   - pre: the account's cached reading from *before* the turn;
    ///     `nil` = no prior knowledge.
    ///   - post: the reading fetched right after the turn completed.
    ///   - turnStartedAt: conservative lower bound captured before the TUI
    ///     runner starts; provider dispatch/completion happens at or after it.
    ///   - turnFinishedAt: upper bound captured when the TUI runner returns.
    public static func classify(
        pre: UsageReading?,
        post: UsageReading?,
        turnStartedAt: Date,
        turnFinishedAt: Date,
        window: TimeInterval,
        clockTolerance: TimeInterval = 60)
        -> Verdict
    {
        guard let postResets = post?.primaryResetsAt else { return .unknown }
        // A response captured before this attempt is not postflight evidence,
        // even if its reset happens to be in the future.
        guard let postFetchedAt = post?.fetchedAt,
              postFetchedAt >= turnStartedAt.addingTimeInterval(-clockTolerance)
        else { return .unknown }
        // A turn just ran, yet the freshest reading shows no window reaching
        // past it? Either the API lagged the anchor or the snapshot is stale —
        // inconclusive, never "verified".
        guard postResets > turnStartedAt else { return .unknown }
        if let preResets = pre?.primaryResetsAt, preResets > turnStartedAt, postResets == preResets {
            return .phantom(openUntil: postResets)
        }
        // With no matching preflight boundary, attribution comes from the
        // reset itself. A derived anchor materially before this attempt proves
        // a phantom even if the cache missed it; an anchor inside the attempt
        // verifies success. Allow one minute for provider clock/whole-minute
        // rounding around the attempt boundaries.
        let derivedAnchor = postResets.addingTimeInterval(-window)
        if derivedAnchor < turnStartedAt.addingTimeInterval(-clockTolerance) {
            return .phantom(openUntil: postResets)
        }
        guard derivedAnchor <= turnFinishedAt.addingTimeInterval(clockTolerance) else {
            return .unknown
        }
        return .verified(expiresAt: postResets)
    }
}
