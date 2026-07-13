import Foundation

// Compile the weekly plan into launchd terms.
//
// There is exactly **one** LaunchAgent — `com.agent-manager.scheduler`, a
// KeepAlive resident daemon (`SchedulerDaemon`) that fires every account's
// pings from an in-process queue. It used to be one calendar job per account,
// but macOS 13+ posts a "background items added" notification every time a
// LaunchAgent is (re)registered, so N per-account jobs meant N notifications on
// every Schedule click. The single agent is registered once and never churned;
// Schedule/Clear only edit the daemon's queue inputs (`scheduler.json`).
//
// The per-account weekly triggers (`CalEntry`) survive as the *plan* currency:
// the daemon resolves them to concrete fire dates (`PingQueuePlanner`), and the
// UI renders them. They keep launchd's `Weekday`/`Hour`/`Minute` convention
// (Sunday = 0) in **local** time — the user picks hours in their own timezone
// and the Mac's local time matches. Planning itself runs on a continuous weekly
// minute line, so a window crossing midnight — including Sunday → Monday — is
// never forgotten merely because the painted grid changed columns. Modular
// arithmetic in `toCalEntry` turns the resulting absolute week minutes back
// into launchd fields.

/// A concrete launchd calendar trigger. `weekday` uses launchd's convention:
/// 0 = Sunday .. 6 = Saturday.
public struct CalEntry: Equatable, Sendable {
    public var weekday: Int
    public var hour: Int
    public var minute: Int
    public init(weekday: Int, hour: Int, minute: Int) {
        self.weekday = weekday
        self.hour = hour
        self.minute = minute
    }
}

public enum LaunchAgentPlanner {
    private static let minutesPerDay = 1440
    private static let minutesPerWeek = 7 * minutesPerDay

    /// Prefix for every launchd Label / plist filename this app owns
    /// (variant-scoped so a dev build never collides with the released app).
    public static let labelPrefix = AppVariant.labelPrefix

    /// The one LaunchAgent this app installs: the resident scheduler daemon.
    public static let schedulerLabel = labelPrefix + "scheduler"

    /// Plist filename for the scheduler agent.
    public static let schedulerFilename = schedulerLabel + ".plist"

    /// Map a `(weekdayMon0, atMin)` plan point — where `weekdayMon0` is
    /// 0 = Monday .. 6 = Sunday and `atMin` may be negative (previous day) or
    /// `>= 1440` (next day) — to a launchd `CalEntry`.
    public static func toCalEntry(weekdayMon0: Int, atMin: Int) -> CalEntry {
        let dayShift = floorDiv(atMin, minutesPerDay)
        let minuteOfDay = atMin - dayShift * minutesPerDay
        let wdMon0 = floorMod(weekdayMon0 + dayShift, 7)
        // Mon0 (0=Mon..6=Sun) -> launchd (0=Sun..6=Sat): Mon->1, .., Sat->6, Sun->0.
        let launchdWd = (wdMon0 + 1) % 7
        return CalEntry(weekday: launchdWd, hour: minuteOfDay / 60, minute: minuteOfDay % 60)
    }

    /// All launchd calendar entries for one account across the whole week, in
    /// trigger-time order (Monday → Sunday). `accountIDs` is the rank-ordered set
    /// of *all* scheduled accounts (the stagger depends on the full set), and
    /// `accountID` is the one we want entries for.
    ///
    /// Weekdays cannot be planned independently: a Monday 23:00 window remains
    /// live on Tuesday, and Tuesday's ideal pre-ping may land inside it. The same
    /// interaction exists across Sunday → Monday because these entries repeat.
    /// `weeklyPings` therefore plans every chain of interacting blocks on one
    /// absolute weekly timeline before this method performs calendar mapping.
    public static func entries(forAccountID accountID: String, accountIDs: [String], schedule: WorkSchedule) -> [CalEntry] {
        entriesByAccount(accountIDs: accountIDs, schedule: schedule)[accountID] ?? []
    }

    /// Compute the shared multi-account geometry once. Queue/status callers need
    /// every account; replanning the same week once per ID is both wasteful and,
    /// after whole-week optimisation, large enough to delay a scheduler tick.
    static func entriesByAccount(
        accountIDs: [String],
        schedule: WorkSchedule)
        -> [String: [CalEntry]]
    {
        weeklyPings(accountIDs: accountIDs, schedule: schedule).reduce(into: [:]) {
            result, plan in
            result[plan.accountID] = plan.pings.map {
                toCalEntry(weekdayMon0: 0, atMin: $0.atMin)
            }
        }
    }

    /// Canonical per-account anchors in `0..<minutesPerWeek`, ordered from
    /// Monday 00:00 — the single geometry every surface derives from: the
    /// daemon maps it to launchd triggers, and display callers project it onto
    /// weekdays with `displayPlan(forWeekday:weekly:schedule:)` (cache this
    /// value across those calls; compiling the week is the expensive step).
    public static func weeklyPings(accountIDs: [String], schedule: WorkSchedule) -> [AccountDayPlan] {
        guard !accountIDs.isEmpty else { return [] }
        let blocks = absoluteWeekBlocks(schedule: schedule)
        guard !blocks.isEmpty else {
            return accountIDs.map { AccountDayPlan(accountID: $0, pings: []) }
        }

        let window = schedule.windowMinutes
        precondition(window > 0, "window must be positive")
        let parallelism = schedule.resolvedParallelism(accountCount: accountIDs.count)
        var anchorsByAccount: [String: [Int]] = [:]

        if let groups = independentBlockGroups(
            blocks, period: minutesPerWeek, window: window)
        {
            for group in groups {
                let plan = ScheduleEngine.planDay(
                    forAccountIDs: accountIDs,
                    workBlocks: group,
                    window: window,
                    parallelism: parallelism,
                    minSlice: schedule.resolvedMinSliceMinutes)
                for account in plan.accounts {
                    anchorsByAccount[account.accountID, default: []]
                        .append(contentsOf: account.pings.map(\.atMin))
                }
            }
        } else {
            // A schedule with no provably independent weekly seam (for example,
            // painted work around the clock) needs context on both sides of the
            // arbitrary Monday boundary. Plan three copies and retain the middle
            // trigger week; the outer copies supply the live-window state that an
            // isolated week would otherwise forget.
            let repeated = mergeBlocks((-1...1).flatMap { repetition in
                blocks.map {
                    Block(
                        start: $0.start + repetition * minutesPerWeek,
                        end: $0.end + repetition * minutesPerWeek)
                }
            })
            let plan = ScheduleEngine.planDay(
                forAccountIDs: accountIDs,
                workBlocks: repeated,
                window: window,
                parallelism: parallelism,
                minSlice: schedule.resolvedMinSliceMinutes)
            for account in plan.accounts {
                anchorsByAccount[account.accountID] = account.pings.compactMap {
                    (0..<minutesPerWeek).contains($0.atMin) ? $0.atMin : nil
                }
            }
        }

        return accountIDs.map { accountID in
            let canonical = Array(Set(anchorsByAccount[accountID, default: []].map {
                floorMod($0, minutesPerWeek)
            })).sorted()
            let physical = physicallySpacedCycle(
                canonical,
                workBlocks: blocks,
                period: minutesPerWeek,
                window: window,
                minSlice: schedule.resolvedMinSliceMinutes)
            return AccountDayPlan(
                accountID: accountID,
                pings: physical.map(Ping.init(atMin:)))
        }
    }

    /// Project the continuous weekly plan onto one weekday for display (the
    /// app's coverage screen, `am plan`).
    ///
    /// An anchor belongs to a weekday's plan iff its window overlaps that day's
    /// painted work — the same membership rule the per-day engine used, so a
    /// schedule whose days are independent renders exactly as before. Anchors
    /// are day-relative minutes (negative = previous day, like the engine's own
    /// pre-pings), so a window crossing midnight over work on both sides
    /// appears on both days: that is the truth of one continuous timeline —
    /// bars clip to the visible day while labels keep the real times. The
    /// weekly ping *count* is the canonical anchor count, not the sum of these
    /// per-day lists.
    ///
    /// The usage rotation is rebuilt per lane exactly as the day engine builds
    /// it, from the projected day pings and the day's blocks.
    public static func displayPlan(
        forWeekday weekday: Int,
        weekly: [AccountDayPlan],
        schedule: WorkSchedule)
        -> MultiDayPlan
    {
        let blocks = schedule.blocks(forWeekday: weekday)
        let window = schedule.windowMinutes
        let origin = weekday * minutesPerDay

        func dayPings(_ canonical: [Ping]) -> [Ping] {
            var relatives: Set<Int> = []
            for ping in canonical {
                // The -period image is a late-Sunday anchor whose window wraps
                // into Monday. A +period image can never reach back: its
                // day-relative start is at least 1440, past the day's blocks.
                for cycle in [-minutesPerWeek, 0] {
                    let rel = ping.atMin + cycle - origin
                    if blocks.contains(where: { rel < $0.end && rel + window > $0.start }) {
                        relatives.insert(rel)
                    }
                }
            }
            return relatives.sorted().map(Ping.init(atMin:))
        }

        let accounts = weekly.map {
            AccountDayPlan(accountID: $0.accountID, pings: dayPings($0.pings))
        }
        guard !accounts.isEmpty else { return MultiDayPlan(accounts: [], usage: []) }

        let ids = accounts.map(\.accountID)
        let pingsByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.accountID, $0.pings) })
        let parallelism = schedule.resolvedParallelism(accountCount: ids.count)
        let lanes = ScheduleEngine.partitionLanes(ids, into: min(max(parallelism, 1), ids.count))
        var usage: [UsageSegment] = []
        for (laneIdx, laneIDs) in lanes.enumerated() {
            let laneUsage = ScheduleEngine.computeUsage(
                accountIDs: laneIDs,
                workBlocks: blocks,
                window: window,
                pingsByAccount: laneIDs.map { pingsByID[$0] ?? [] },
                minSeg: schedule.resolvedMinSliceMinutes)
            usage.append(contentsOf: laneUsage.map {
                UsageSegment(
                    accountID: $0.accountID, batchIndex: $0.batchIndex,
                    startMin: $0.startMin, endMin: $0.endMin, lane: laneIdx)
            })
        }
        return MultiDayPlan(accounts: accounts, usage: usage)
    }

    /// Flatten the painted weekday columns and merge midnight-adjacent hours.
    /// Treating Monday 23:00–24:00 + Tuesday 00:00–01:00 as one block matters to
    /// the floor: there is no real discontinuity from which to manufacture two
    /// separate edge slices.
    private static func absoluteWeekBlocks(schedule: WorkSchedule) -> [Block] {
        mergeBlocks((0..<7).flatMap { weekday in
            schedule.blocks(forWeekday: weekday).map {
                Block(
                    start: $0.start + weekday * minutesPerDay,
                    end: $0.end + weekday * minutesPerDay)
            }
        })
    }

    private static func mergeBlocks(_ blocks: [Block]) -> [Block] {
        var merged: [Block] = []
        for block in blocks.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) })
            where block.end > block.start
        {
            if var last = merged.last, block.start <= last.end {
                last.end = max(last.end, block.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(block)
            }
        }
        return merged
    }

    /// Partition the weekly circle only at gaps where *any* anchors touching the
    /// work on opposite sides are guaranteed to be at least one window apart.
    ///
    /// An anchor touching the earlier block can be as late as `end - 1`; one
    /// touching the later block can be as early as `start - window + 1`. Their
    /// worst-case distance is therefore `gap - window + 2`, which reaches one
    /// full window exactly when `gap >= 2 * window - 2`. Such a seam is genuinely
    /// independent, so splitting there preserves both token-max optimality and
    /// existing account staggering. Smaller gaps stay in one continuous group.
    /// Returns `nil` only when the entire weekly circle has no independent seam.
    private static func independentBlockGroups(
        _ blocks: [Block],
        period: Int,
        window: Int)
        -> [[Block]]?
    {
        guard !blocks.isEmpty else { return [] }
        let independentGap = max(2 * window - 2, 0)
        let safeAfter = blocks.indices.map { index in
            let nextStart = index + 1 < blocks.count
                ? blocks[index + 1].start
                : blocks[0].start + period
            let gap = nextStart - blocks[index].end
            // Zero is continuous painted work, never an independent seam (the
            // distinction only matters for a one-minute test window, where the
            // algebraic threshold itself is also zero).
            return gap > 0 && gap >= independentGap
        }
        guard let firstSafe = safeAfter.firstIndex(of: true) else { return nil }

        let firstIndex = (firstSafe + 1) % blocks.count
        var groups: [[Block]] = []
        var current: [Block] = []
        for offset in 0..<blocks.count {
            let index = (firstIndex + offset) % blocks.count
            let shift = index < firstIndex ? period : 0
            let shifted = Block(
                start: blocks[index].start + shift,
                end: blocks[index].end + shift)
            // `absoluteWeekBlocks` merges ordinary midnight adjacency. Rotation
            // makes the cyclic Sunday → Monday adjacency linear as well, so merge
            // it here before the floor measures contiguous painted time.
            if var last = current.last, last.end == shifted.start {
                last.end = shifted.end
                current[current.count - 1] = last
            } else {
                current.append(shifted)
            }
            if safeAfter[index] {
                groups.append(current)
                current = []
            }
        }
        precondition(current.isEmpty, "rotation must end at its opening safe seam")
        return groups
    }

    /// The grouped path is physical by construction. The context path can still
    /// expose a mathematically impossible periodic edge case: if a dense weekly
    /// pattern does not admit the middle copy's phase at its own repeat seam, its
    /// final and first anchors collide modulo one week. Drop the less useful edge
    /// anchor instead of publishing a ping that provably cannot reset anything.
    /// Internal anchors are already separated by `ScheduleEngine`; after either
    /// endpoint is removed, the enlarged wrap gap is physical, so at most one
    /// removal is normally needed.
    private static func physicallySpacedCycle(
        _ anchors: [Int],
        workBlocks: [Block],
        period: Int,
        window: Int,
        minSlice: Int)
        -> [Int]
    {
        guard window <= period else { return [] }
        var result = anchors
        while result.count > 1,
              result[0] + period - result[result.count - 1] < window
        {
            let withoutFirst = Array(result.dropFirst())
            let withoutLast = Array(result.dropLast())
            result = isBetterPhysicalCycle(
                withoutFirst,
                than: withoutLast,
                workBlocks: workBlocks,
                period: period,
                window: window,
                minSlice: minSlice)
                ? withoutFirst
                : withoutLast
        }
        return result
    }

    private static func isBetterPhysicalCycle(
        _ lhs: [Int],
        than rhs: [Int],
        workBlocks: [Block],
        period: Int,
        window: Int,
        minSlice: Int)
        -> Bool
    {
        func score(_ anchors: [Int]) -> (covered: Int, actionable: Int) {
            var covered = 0
            for block in workBlocks {
                for minute in block.start..<block.end where anchors.contains(where: {
                    floorMod(minute - $0, period) < window
                }) {
                    covered += 1
                }
            }

            let floor = max(minSlice, 1)
            let actionable = anchors.filter { anchor in
                workBlocks.contains { block in
                    let copies = [-period, 0, period]
                    return copies.contains { shift in
                        let a = max(anchor, block.start + shift)
                        let b = min(anchor + window, block.end + shift)
                        return b - a >= floor
                    }
                }
            }.count
            return (covered, actionable)
        }

        let l = score(lhs)
        let r = score(rhs)
        if l.covered != r.covered { return l.covered > r.covered }
        if l.actionable != r.actionable { return l.actionable > r.actionable }
        return lhs.lexicographicallyPrecedes(rhs)
    }

    /// Render the one `com.agent-manager.scheduler.plist` this app installs: a
    /// `KeepAlive` agent running `am scheduler run` — the resident daemon that
    /// fires all scheduled pings itself. The workspace root travels as
    /// `AGENT_MANAGER_ROOT` in the baked environment, never as an argument —
    /// `am` deliberately owns no flags (so `am run` passthrough stays verbatim),
    /// and env vars are the one workspace-targeting channel everywhere.
    ///
    /// This plist must stay **byte-stable across applies**: `Scheduler.apply`
    /// rewrites/re-bootstraps it only when this rendering differs from what's on
    /// disk, because any launchd (re)registration makes macOS re-notify
    /// "background items added". Everything schedule-shaped therefore lives in
    /// the workspace files the daemon watches, never in here; the plist changes
    /// only when the `am` path or the baked environment does.
    ///
    /// `environment` is baked into `EnvironmentVariables` so the daemon (and the
    /// ping children it spawns) inherit a usable `PATH` + any provider binary
    /// override (launchd otherwise passes an almost-empty env).
    public static func renderSchedulerAgentPlist(
        program: String,
        root: String,
        logDir: String,
        environment: [String: String] = [:])
        -> String
    {
        var programArgs = ""
        for a in [program, "scheduler", "run"] {
            programArgs += "    <string>\(xmlEscape(a))</string>\n"
        }

        var env = environment.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        env["AGENT_MANAGER_ROOT"] = root
        var envBlock = "  <key>EnvironmentVariables</key>\n  <dict>\n"
        for key in env.keys.sorted() {
            envBlock += "    <key>\(xmlEscape(key))</key><string>\(xmlEscape(env[key]!))</string>\n"
        }
        envBlock += "  </dict>\n"

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>\(schedulerLabel)</string>
          <key>ProgramArguments</key>
          <array>
        \(programArgs)  </array>
        \(envBlock)  <key>RunAtLoad</key>
          <true/>
          <key>KeepAlive</key>
          <true/>
          <key>StandardOutPath</key>
          <string>\(logDir)/scheduler.out.log</string>
          <key>StandardErrorPath</key>
          <string>\(logDir)/scheduler.err.log</string>
          <key>ProcessType</key>
          <string>Background</string>
        </dict>
        </plist>

        """
    }

}

/// Floored integer division (matches Rust's `div_euclid` for our positive divisor).
private func floorDiv(_ a: Int, _ b: Int) -> Int {
    Int(floor(Double(a) / Double(b)))
}

/// Floored modulo in `0..<b` (matches Rust's `rem_euclid` for positive `b`).
private func floorMod(_ a: Int, _ b: Int) -> Int {
    let r = a % b
    return r < 0 ? r + b : r
}

// Internal (not private): the wake-helper installer renders its LaunchDaemon
// plist with the same escaping.
func xmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}
