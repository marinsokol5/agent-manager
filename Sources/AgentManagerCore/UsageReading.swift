import Foundation

/// Normalised usage snapshot for one account, covering both the short (5h /
/// primary) window and the long (7-day / secondary) window.  All values are
/// provider-agnostic: Claude `utilization` (0–1) and Codex `used_percent`
/// (0–100) are both converted to an integer 0–100 used-percent.
public struct UsageReading: Codable, Sendable, Equatable {
    /// Percent of the primary window already used (0–100). `nil` = no data.
    public let primaryUsedPercent: Int?
    /// When the primary window resets. `nil` = not reported by the API.
    public let primaryResetsAt: Date?
    /// Percent of the secondary (weekly) window already used (0–100).
    public let secondaryUsedPercent: Int?
    /// When the secondary window resets.
    public let secondaryResetsAt: Date?
    /// Wall-clock time this reading was fetched.
    public let fetchedAt: Date

    public init(
        primaryUsedPercent: Int?,
        primaryResetsAt: Date?,
        secondaryUsedPercent: Int?,
        secondaryResetsAt: Date?,
        fetchedAt: Date = Date())
    {
        self.primaryUsedPercent = primaryUsedPercent
        self.primaryResetsAt = primaryResetsAt
        self.secondaryUsedPercent = secondaryUsedPercent
        self.secondaryResetsAt = secondaryResetsAt
        self.fetchedAt = fetchedAt
    }

    public var primaryRemainingPercent: Int? { primaryUsedPercent.map { 100 - $0 } }
    public var secondaryRemainingPercent: Int? { secondaryUsedPercent.map { 100 - $0 } }

    /// Whether the primary (5h) window this reading describes has already reset.
    /// `primaryResetsAt` is the *end* of the window the figures belong to, so a
    /// reset at/before `now` means those figures describe a window that's over.
    /// A missing reset = unknown, so we don't claim expiry (err toward the raw value).
    public func primaryWindowExpired(now: Date = Date()) -> Bool {
        guard let resets = primaryResetsAt else { return false }
        return resets <= now
    }

    /// Whether the secondary (weekly) window has already reset.
    public func secondaryWindowExpired(now: Date = Date()) -> Bool {
        guard let resets = secondaryResetsAt else { return false }
        return resets <= now
    }

    /// Primary used %, but reported as **0 once the window has reset**. A window
    /// that has ended carries no spend into the next one — you can't have used
    /// anything in a window that hasn't started — so the stale figure from the
    /// finished window would only mislead (it's what made the menu bar show "8%
    /// left" when in fact a full fresh window is available). You are technically
    /// between windows until the next billed turn anchors a new one, but the
    /// honest "what you'd get if you start now" answer is a full window.
    public func effectivePrimaryUsedPercent(now: Date = Date()) -> Int? {
        guard let used = primaryUsedPercent else { return nil }
        return primaryWindowExpired(now: now) ? 0 : used
    }

    /// Primary remaining %, expiry-aware: 100 once the window has reset. This is
    /// what every surface (menu bar, sidebar, rows, recommender) should show.
    public func effectivePrimaryRemainingPercent(now: Date = Date()) -> Int? {
        effectivePrimaryUsedPercent(now: now).map { 100 - $0 }
    }

    /// Secondary used %, reported as 0 once the weekly window has reset.
    public func effectiveSecondaryUsedPercent(now: Date = Date()) -> Int? {
        guard let used = secondaryUsedPercent else { return nil }
        return secondaryWindowExpired(now: now) ? 0 : used
    }

    /// Secondary remaining %, expiry-aware: 100 once the weekly window has reset.
    public func effectiveSecondaryRemainingPercent(now: Date = Date()) -> Int? {
        effectiveSecondaryUsedPercent(now: now).map { 100 - $0 }
    }

    /// Human-readable "resets in Xh Ym" / "resets in Xd Yh" for a reset date,
    /// or `nil` when the date is in the past or absent.
    public static func resetCountdown(to date: Date?, now: Date = Date()) -> String? {
        guard let date, date > now else { return nil }
        let total = Int(date.timeIntervalSince(now))
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return "resets in \(days)d \(hours)h" }
        if hours > 0 { return "resets in \(hours)h \(minutes)m" }
        return "resets in \(minutes)m"
    }

    /// Freshness label: "Xs ago" / "Xm ago" / "Xh ago".
    public func freshnessLabel(now: Date = Date()) -> String {
        let age = Int(now.timeIntervalSince(fetchedAt))
        if age < 60 { return "\(age)s ago" }
        if age < 3600 { return "\(age / 60)m ago" }
        return "\(age / 3600)h ago"
    }
}
