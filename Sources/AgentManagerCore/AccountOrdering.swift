import Foundation

/// The single canonical priority order for agents, shared by every surface — the
/// menu-bar app list, the CLI `account list`, and the scheduler's token-window
/// stagger. Agents always *appear* in the same order they're *served* tokens in,
/// and that order is the user's to change (reorder in the app, `--rank` in CLI).
extension Account {
    /// Explicit `rank` ascending wins; unranked accounts sort last; ties break by
    /// creation time then id, so the order is always total and stable.
    public static func priorityPrecedes(_ lhs: Account, _ rhs: Account) -> Bool {
        let lr = lhs.rank ?? Int.max
        let rr = rhs.rank ?? Int.max
        if lr != rr { return lr < rr }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id < rhs.id
    }
}

extension Array where Element == Account {
    /// These accounts in canonical priority order (see `Account.priorityPrecedes`).
    public func inPriorityOrder() -> [Account] {
        sorted(by: Account.priorityPrecedes)
    }
}
