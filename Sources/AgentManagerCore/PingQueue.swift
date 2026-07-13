import Foundation

// The scheduler daemon's work list: concrete `(fire time, account)` pairs
// resolved from the painted weekly schedule.
//
// The engine plans in local minutes-from-midnight and `LaunchAgentPlanner`
// compiles those to weekly `CalEntry` triggers (weekday/hour/minute). This file
// does the last step the resident daemon needs: turn each weekly trigger into
// its **next real `Date`** so the daemon can sleep until it. Every `CalEntry`
// occurs exactly once per week, so a full queue always spans ≤ 7 days — the
// daemon rebuilds it whenever it drains or the config changes, rather than
// tracking consumed entries.

/// One planned scheduled ping: fire `accountID` at `fireAt`.
public struct QueueEntry: Codable, Equatable, Sendable {
    /// When to actually fire. Usually the planned minute; when runtime
    /// deferral shifted the entry past a known-open window
    /// (`RuntimeAnchorPolicy`), this is the shifted *effective* time — which
    /// is what the wake helper must arm for, so it stays in this field.
    public var fireAt: Date
    public var accountID: String
    /// The nominal planned minute this entry stands for when `fireAt` was
    /// shifted; `nil` = `fireAt` is nominal. Watermarks (`lastHandled`) always
    /// advance to the *nominal* time so queue rebuilds keep consuming exactly
    /// one weekly slot per handled entry.
    public var plannedAt: Date?

    public init(fireAt: Date, accountID: String, plannedAt: Date? = nil) {
        self.fireAt = fireAt
        self.accountID = accountID
        self.plannedAt = plannedAt
    }

    /// The planned minute this entry stands for (its identity in the weekly
    /// plan), whether or not the effective fire time was shifted.
    public var nominalFireAt: Date { plannedAt ?? fireAt }
}

public enum PingQueuePlanner {
    /// The next occurrence of a weekly trigger **strictly after** `after`, in the
    /// calendar's local time (DST shifts are handled by `Calendar`; a nonexistent
    /// spring-forward time resolves to the next valid one).
    public static func nextOccurrence(
        of entry: CalEntry,
        after: Date,
        calendar: Calendar = .current)
        -> Date?
    {
        var comps = DateComponents()
        // launchd weekday (0 = Sun..6 = Sat) → Calendar weekday (1 = Sun..7 = Sat).
        comps.weekday = entry.weekday + 1
        comps.hour = entry.hour
        comps.minute = entry.minute
        comps.second = 0
        return calendar.nextDate(after: after, matching: comps, matchingPolicy: .nextTime, direction: .forward)
    }

    /// Build the fire queue: for every scheduled account, the next occurrence of
    /// each of its weekly triggers after `after` (per-account floors in
    /// `notBefore` — e.g. "already handled up to here" — raise that bound), sorted
    /// by fire time. Ties keep the accounts' priority order, so simultaneous plan
    /// times run highest-priority first when the daemon drains them sequentially.
    public static func queue(
        accountIDs: [String],
        schedule: WorkSchedule,
        after: Date,
        notBefore: [String: Date] = [:],
        calendar: Calendar = .current)
        -> [QueueEntry]
    {
        let weekly = LaunchAgentPlanner.entriesByAccount(
            accountIDs: accountIDs, schedule: schedule)
        return queue(
            accountIDs: accountIDs,
            weeklyEntries: weekly,
            after: after,
            notBefore: notBefore,
            calendar: calendar)
    }

    /// Queue from an already-compiled weekly plan. The resident daemon caches
    /// this value until `schedule.json` or `accounts.json` changes; resolving
    /// dates is cheap and happens every tick, while whole-week optimisation does
    /// not need to be repeated against identical inputs.
    static func queue(
        accountIDs: [String],
        weeklyEntries: [String: [CalEntry]],
        after: Date,
        notBefore: [String: Date] = [:],
        calendar: Calendar = .current)
        -> [QueueEntry]
    {
        var entries: [QueueEntry] = []
        for id in accountIDs {
            let floor = max(after, notBefore[id] ?? .distantPast)
            for cal in weeklyEntries[id, default: []] {
                if let fireAt = nextOccurrence(of: cal, after: floor, calendar: calendar) {
                    entries.append(QueueEntry(fireAt: fireAt, accountID: id))
                }
            }
        }
        return entries.enumerated()
            .sorted { a, b in
                a.element.fireAt == b.element.fireAt
                    ? a.offset < b.offset
                    : a.element.fireAt < b.element.fireAt
            }
            .map(\.element)
    }
}
