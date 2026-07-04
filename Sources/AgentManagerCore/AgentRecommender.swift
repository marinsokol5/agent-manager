import Foundation

/// Picks the agent to run *right now* from a set of agents and their latest usage
/// readings. Pure and dependency-free (no SwiftUI/AppKit) so both the menu-bar app
/// and the `am` CLI can share one definition of "which agent should I use?".
///
/// Rule: among **connected** agents that still have usable session headroom, prefer
/// the one whose 5-hour window resets **soonest** — perishable budget first. Resets
/// within `buffer` of that soonest reset count as simultaneous, and are decided by
/// the **most tokens remaining** (a sooner reset breaks any further tie). An agent
/// whose reset is unknown or already in the past isn't perishable, so it only wins
/// when *nobody* has a live reset, on headroom alone.
public enum AgentRecommender {
    /// How close two resets count as "the same" before remaining tokens decide.
    public static let defaultExpiryBuffer: TimeInterval = 10 * 60

    /// The id of the recommended agent, or `nil` when nothing is connected / has a
    /// usable reading.
    ///
    /// - Parameters:
    ///   - accounts: every known agent (only `.connected` ones are considered).
    ///   - readings: latest usage per agent id.
    ///   - buffer: expiry tolerance; resets within this of the soonest tie on tokens.
    ///   - now: clock, injectable for tests; a reset at or before `now` is treated as
    ///     stale (no live window).
    public static func recommendedAgentID(
        accounts: [Account],
        readings: [String: UsageReading],
        buffer: TimeInterval = defaultExpiryBuffer,
        now: Date = Date()
    ) -> String? {
        struct Candidate { let id: String; let remaining: Int; let resetsAt: Date? }

        let candidates: [Candidate] = accounts.compactMap { account in
            guard account.status == .connected,
                  let reading = readings[account.id],
                  // Expiry-aware: an expired window means a full fresh window is
                  // available (100% headroom), not the stale figure it last held.
                  let remaining = reading.effectivePrimaryRemainingPercent(now: now),
                  remaining > 0 else { return nil }
            // A reset at/in the past is stale data, not a live window — ignore it.
            let resetsAt = reading.primaryResetsAt.flatMap { $0 > now ? $0 : nil }
            return Candidate(id: account.id, remaining: remaining, resetsAt: resetsAt)
        }
        guard !candidates.isEmpty else { return nil }

        // No live reset anywhere → fall back to the most headroom.
        guard let soonest = candidates.compactMap(\.resetsAt).min() else {
            return candidates.max { $0.remaining < $1.remaining }?.id
        }

        // The "soonest bucket": agents resetting within `buffer` of that soonest
        // reset. Non-perishable agents (no live reset) sit out of the bucket.
        let cutoff = soonest.addingTimeInterval(buffer)
        let bucket = candidates.filter { ($0.resetsAt ?? .distantFuture) <= cutoff }
        return bucket.max {
            if $0.remaining != $1.remaining { return $0.remaining < $1.remaining }
            // Equal tokens → prefer the one expiring sooner (more urgent to spend).
            return ($0.resetsAt ?? .distantFuture) > ($1.resetsAt ?? .distantFuture)
        }?.id
    }
}
