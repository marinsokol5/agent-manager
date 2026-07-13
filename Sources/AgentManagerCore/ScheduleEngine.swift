import Foundation

// The token-max planning engine.
//
// Pure, Foundation-light, timezone-agnostic. Everything works in **local
// minutes-from-midnight** (an `Int`); a ping time may be negative (it falls on
// the previous calendar day) or `>= 1440` (next day). Mapping those minutes to
// real timezone-aware datetimes + launchd jobs is the job of higher layers
// (`LaunchAgentPlanner`).
//
// ## The idea (token-maxxing)
//
// A subscription usage window starts on first use and lasts `window` minutes
// (default 300 = 5h); usage *within* a window never moves its boundary. So the
// only lever we have is *when the first request of each window lands*. We place
// pings so the maximum number of fresh window budgets overlap the hours you
// actually work — including a **pre-ping before work starts** so a full, unused
// budget is already live the moment you sit down.
//
// "Maximum" is tempered by one knob: the **budget-slice floor** (`minSlice`,
// default `minSliceFloorMinutes`, user-configurable via
// `WorkSchedule.minSliceMinutes`). One account's window starts can never be
// closer than `window` apart, so every interior slice of a work block is a
// full window and only the two *edge* slices can shrink — and an edge sliver
// too short to actually spend (30 minutes of a 5-hour budget) costs a ping
// without buying usable time. Raising the floor folds those slivers away:
// fewer, longer budgets, and strictly fewer pings. Coverage always beats the
// floor — a work minute is never left uncovered to honor it.

/// Default rolling-window length in minutes (5 hours).
public let defaultWindowMinutes = 300

/// The lowest the budget-slice floor may go (minutes): the shortest stretch of
/// one account's token budget the planner will ever anchor a ping for, or the
/// recommender hand out before suggesting a switch — below ~15 min a budget
/// stops being one (an account switch costs re-auth and context). Also the
/// engine functions' *parameter* default, i.e. the un-floored token-max
/// baseline; the product default a fresh `schedule.json` resolves to is
/// `defaultMinSliceMinutes`. Hour-granular blocks always clear 15-minute
/// edges, so this bound never constrains placement — only raising the knob
/// moves pings (always fewer, never more).
public let minSliceFloorMinutes = 15

/// What `WorkSchedule.minSliceMinutes` resolves to until the user touches the
/// "Min token block" stepper. An hour is long enough to actually get something
/// done in a fresh budget: out of the box a 6h day folds its two 30-min edge
/// slivers into 3h + 3h on two pings — the layout that motivated the knob —
/// and anyone token-maxxing can still step down to `minSliceFloorMinutes`.
public let defaultMinSliceMinutes = 60

/// A half-open work interval `[start, end)` in local minutes-from-midnight.
public struct Block: Equatable, Sendable {
    public var start: Int
    public var end: Int
    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

/// A planned ping: a window-anchoring request for one account at a local minute.
public struct Ping: Equatable, Sendable, Codable {
    /// Local minutes-from-midnight. May be negative (previous day).
    public var atMin: Int
    public init(atMin: Int) { self.atMin = atMin }
}

/// One account's pings for a day.
public struct AccountDayPlan: Equatable, Sendable {
    public var accountID: String
    public var pings: [Ping]
    public init(accountID: String, pings: [Ping]) {
        self.accountID = accountID
        self.pings = pings
    }
}

/// A recommended stretch of work time to spend on one account's token batch.
public struct UsageSegment: Equatable, Sendable {
    public var accountID: String
    /// 1-based index into that account's daily ping/batch list.
    public var batchIndex: Int
    public var startMin: Int
    public var endMin: Int
    /// Which **parallel lane** this segment belongs to (0-based). A lane is one
    /// concurrent stream of work; with `parallelism = 1` everything is lane 0 (a
    /// single serial rotation), and lanes run simultaneously, so segments from
    /// different lanes legitimately overlap in time.
    public var lane: Int
    public init(accountID: String, batchIndex: Int, startMin: Int, endMin: Int, lane: Int = 0) {
        self.accountID = accountID
        self.batchIndex = batchIndex
        self.startMin = startMin
        self.endMin = endMin
        self.lane = lane
    }
}

/// A full day plan: real pings per account plus a usage recommendation.
public struct MultiDayPlan: Equatable, Sendable {
    public var accounts: [AccountDayPlan]
    public var usage: [UsageSegment]
    public init(accounts: [AccountDayPlan], usage: [UsageSegment]) {
        self.accounts = accounts
        self.usage = usage
    }
}

public enum ScheduleEngine {
    /// Merge a set of selected hour slots (0..=23) into contiguous work blocks.
    /// Selecting hour `h` means "I work during [h:00, (h+1):00)".
    ///
    /// `selectedHours` need not be sorted or unique.
    public static func slotsToBlocks(_ selectedHours: [Int]) -> [Block] {
        var hours = selectedHours.filter { $0 >= 0 && $0 < 24 }
        hours.sort()
        var blocks: [Block] = []
        var lastHour: Int? = nil
        for h in hours {
            if h == lastHour { continue } // dedup
            lastHour = h
            let start = h * 60
            let end = start + 60
            if var last = blocks.last, last.end == start {
                last.end = end
                blocks[blocks.count - 1] = last
            } else {
                blocks.append(Block(start: start, end: end))
            }
        }
        return blocks
    }

    /// Pick the offset `a` (minutes from the block start `s` to the first window
    /// boundary that lands *after* `s`) for a single work block of length `len`.
    ///
    /// The batch count comes first: the most window budgets whose two **edge**
    /// slices both reach `minSlice`. Interior slices are always a full `window`
    /// (window starts can't be closer than `window` apart), so only the edges
    /// can sliver — with `n` batches they sum to `len - window*(n-2)`. Coverage
    /// beats the floor: the count never drops below what spanning the block
    /// requires, so an unsatisfiable floor bends (edges stay balanced, merely
    /// shorter than asked) rather than leaving work minutes uncovered. The edge
    /// budget is then split evenly — the midpoint is robust (no fragile
    /// slivers) and, at the default floor, reproduces the pre-floor layout for
    /// every hour-granular block.
    ///
    /// When the floor caps the count at one (`len <= window` and two
    /// floor-length slices don't fit), the single window is centred on the
    /// block — equal slack on both sides, boundary at or past the block end so
    /// `planDay` adds no re-ping.
    ///
    /// Returns `a` in `1...window`. The pre-ping is then `s - window + a`.
    static func firstBoundaryOffset(len: Int, window: Int, minSlice: Int = minSliceFloorMinutes) -> Int {
        let floorPerEdge = max(minSlice, 1)
        // Most batches whose two edge slices can both reach the floor…
        let nFloor = len >= 2 * floorPerEdge ? 2 + (len - 2 * floorPerEdge) / window : 1
        // …but never fewer than covering the whole block needs.
        let nCover = max((len + window - 1) / window, 1)
        let n = max(nFloor, nCover)

        if n == 1 {
            // One window covers the whole block: centre it, `a >= len` so the
            // boundary lands at/past the block end and no re-ping fires.
            return min(max((len + window) / 2, len), window)
        }
        // Split the edge budget evenly; clamp so the trailing edge fits inside
        // one window and stays strictly positive (all `n` batches materialise).
        let edgeSum = len - window * (n - 2)
        return min(max(edgeSum / 2, max(edgeSum - window, 1)), min(edgeSum - 1, window))
    }

    /// Plan one day's pings for a **single account**.
    ///
    /// `workBlocks` are half-open intervals, assumed sorted and non-overlapping
    /// (as produced by `slotsToBlocks`). Returns the ping times (local minutes,
    /// possibly negative) that anchor windows to maximise fresh-budget overlap
    /// under the `minSlice` budget-slice floor (see `firstBoundaryOffset`),
    /// pre-pinging before the first block.
    ///
    /// The floor shapes each block's *own* layout; a window riding in from a
    /// previous block still re-pings at its expiry wherever that falls —
    /// coverage across the gap is worth more than the floor, so a sub-floor
    /// tail can survive there.
    ///
    /// Anchors are physical: one account's pings are never closer than
    /// `window` apart (a ping inside a still-open window anchors nothing), so
    /// a fresh block's ideal pre-ping clamps forward to the previous window's
    /// expiry when the two collide — mirroring `appendBlockPings` on the
    /// multi-account path. That greedy clamp is only the safety baseline: if it
    /// loses a floor-sized budget that a different phase could preserve,
    /// spends an extra ping a different phase makes unnecessary, or leaves the
    /// smallest of equally many batches unnecessarily short, a bounded
    /// whole-day search rephases the anchors. Batch count remains the primary
    /// token-max objective; max-min painted work per batch breaks count ties.
    public static func planDay(_ workBlocks: [Block], window: Int, minSlice: Int = minSliceFloorMinutes) -> [Ping] {
        precondition(window > 0, "window must be positive")
        let pings = greedyDayPings(workBlocks, window: window, minSlice: minSlice)

        // A collision can be made physically valid by clamping yet still lose a
        // real budget. In the field-report shape, centring 10–11h at 08:00 makes
        // the 14–17h ideal collide; clamping yields only 08:00/13:00, while
        // rephasing the day to 06:00/11:00/16:00 gives three legal windows whose
        // work slices are 60/120/60 minutes. Search the whole day for that class
        // of improvement. Single blocks already have a closed-form optimum; for
        // multi-block days, cheap geometric + total-work bounds keep the minute
        // search off every plan that cannot possibly improve.
        let actionableGreedy = actionablePingCount(
            pings, workBlocks: workBlocks, window: window, minSlice: minSlice)
        let greedyChoice = actionablePlanChoice(
            pings, workBlocks: workBlocks, window: window, minSlice: minSlice)
        let totalWork = workBlocks.reduce(0) { total, block in
            total + max(block.end - block.start, 0)
        }
        let maxMinMayImprove: Bool
        if let greedyChoice, !greedyChoice.workMinutes.isEmpty {
            // No equal-count plan can make its smallest batch exceed the
            // average. Reaching that bound proves the greedy phase is already
            // max-min optimal and keeps the minute search off the hot path.
            maxMinMayImprove = (greedyChoice.workMinutes.first ?? 0)
                < totalWork / greedyChoice.workMinutes.count
        } else {
            maxMinMayImprove = false
        }
        let actionableUpperBound = maximumActionablePingUpperBound(
            workBlocks, window: window, minSlice: minSlice)
        let shouldOptimize = pings.count > actionableGreedy
            || actionableUpperBound > actionableGreedy
            || maxMinMayImprove
        guard workBlocks.filter({ $0.end > $0.start }).count > 1,
              shouldOptimize
        else { return pings }

        // Most equal-count rephases are a translation of one consecutive chain.
        // If such a phase reaches the average painted time, it attains the
        // mathematical max-min ceiling and no recursive search can improve it.
        if actionableUpperBound == pings.count,
           let greedyChoice,
           let translated = bestConsecutivePhase(
               count: pings.count,
               workBlocks: workBlocks,
               window: window,
               minSlice: minSlice),
           translated.workMinutes.first == totalWork / pings.count,
           isBetterBatchWorkDistribution(translated, than: greedyChoice)
        {
            return translated.anchors.map(Ping.init(atMin:))
        }

        if let improved = maximalActionablePlan(
            workBlocks, window: window, minSlice: minSlice),
           // Every searched window clears the floor, so its anchor count is its
           // actionable-budget count. Replace greedy only for a strict
           // lexicographic win: more batches; equally many batches on fewer
           // pings; or equal count with a better max-min work distribution.
           improved.anchors.count > actionableGreedy
               || (improved.anchors.count == actionableGreedy
                   && improved.anchors.count < pings.count)
               || (improved.anchors.count == pings.count
                   && greedyChoice.map {
                       isBetterBatchWorkDistribution(improved, than: $0)
                   } == true)
        {
            return improved.anchors.map(Ping.init(atMin:))
        }
        return pings
    }

    /// The greedy block-local pass planDay starts from: pre-ping each block
    /// (clamped to the previous window's expiry) and re-ping at every expiry
    /// inside it. Extracted so the multi-account planner can ask whether the
    /// whole-day search overrode this geometry for the day.
    private static func greedyDayPings(_ workBlocks: [Block], window: Int, minSlice: Int) -> [Ping] {
        var pings: [Ping] = []
        // The instant the currently-active window expires. Nothing active to start.
        var activeUntil = Int.min

        for block in workBlocks {
            let (s, e) = (block.start, block.end)
            if e <= s { continue }
            // If no window is live at this block's start, lay down a fresh one with
            // a pre-ping before `s`. If a prior block's window still covers `s`, we
            // ride it (re-pinging at its expiry below) — can't re-anchor mid-window.
            if activeUntil <= s {
                let a = firstBoundaryOffset(len: e - s, window: window, minSlice: minSlice)
                let ideal = s - window + a
                // The ideal pre-ping can still land *inside* the previous block's
                // window: a short early block centres its window with slack past
                // the block end, so the window can expire before `s` yet after the
                // ideal anchor (e.g. 10–11h centres 08:00–13:00; a 14–17h block's
                // ideal pre-ping is 10:30). A ping there anchors nothing — usage
                // inside a window never moves its boundary — burning a turn and
                // promising a batch that never exists. Clamp to the expiry: the
                // earliest legal anchor and the closest to the ideal. Coverage of
                // `s` survives the clamp — whichever bound wins is ≤ `s` (this
                // branch) and > `s - window` (a ≥ 1; a binding clamp means
                // `activeUntil` exceeds the ideal, which already is).
                let t0 = max(ideal, activeUntil)
                pings.append(Ping(atMin: t0))
                activeUntil = t0 + window
            }
            // Re-ping at each expiry that falls strictly inside the work block, so
            // a new budget opens the moment the previous one runs out.
            while activeUntil < e {
                pings.append(Ping(atMin: activeUntil))
                activeUntil += window
            }
        }
        return pings
    }

    // MARK: - whole-day single-account optimisation

    /// One complete suffix plan. Count is the primary objective, the sorted
    /// work vector provides exact max-min fairness, and centring only stabilizes
    /// ties whose batch-time distributions are identical.
    private struct ActionablePlanChoice {
        var anchors: [Int]
        /// Painted work minutes assigned to each physical window. Count is
        /// fixed before these are compared; sorting them least-first gives the
        /// exact max-min batch-time objective.
        var workMinutes: [Int]
        var centringCost: Int64

        static let empty = ActionablePlanChoice(
            anchors: [], workMinutes: [], centringCost: 0)
    }

    private struct WindowWorkStats {
        /// Total painted work minutes inside this window (possibly across blocks).
        var total: Int
        /// Longest contiguous painted stretch inside the window. The floor is a
        /// usable *block*, so two tiny stretches separated by a gap do not fake
        /// one actionable budget.
        var longestBlockRun: Int
        /// Doubled-centre distance between the window and the outer span of work
        /// it contains; avoids floating point and centres one-window plans exactly.
        var centringCost: Int64
    }

    /// Find the maximum-cardinality plan in which every window contains at
    /// least one contiguous `minSlice` stretch and all painted work is covered.
    /// Requiring every searched window to clear the floor is deliberate: when
    /// coverage makes that impossible, the block-local baseline remains the
    /// authority and preserves its documented balanced-edge fallback. Windows
    /// are generated in chronological order and the recursion's cursor is the
    /// previous expiry, so physical spacing is structural rather than checked
    /// after the fact.
    ///
    /// The search is minute-granular but tightly bounded: for the next uncovered
    /// minute only the `window` possible anchors that contain it are candidates,
    /// and memoisation visits each cursor once. A 24-hour grid is therefore tiny
    /// enough to recompute live while painting.
    private static func maximalActionablePlan(
        _ workBlocks: [Block],
        window: Int,
        minSlice: Int)
        -> ActionablePlanChoice?
    {
        let blocks = workBlocks.filter { $0.end > $0.start }
        guard let first = blocks.first, let last = blocks.last else { return .empty }
        let floor = max(minSlice, 1)
        let initialCursor = first.start - window + 1
        let maximumCursor = last.end + window
        var memo = [ActionablePlanChoice?](
            repeating: nil, count: maximumCursor - initialCursor + 1)
        var visited = [Bool](repeating: false, count: memo.count)
        var statsMemo = [WindowWorkStats?](
            repeating: nil, count: last.end - initialCursor + 1)

        func stats(at anchor: Int) -> WindowWorkStats {
            let index = anchor - initialCursor
            if let cached = statsMemo[index] { return cached }
            let computed = windowWorkStats(
                anchor: anchor, window: window, workBlocks: blocks)
            statsMemo[index] = computed
            return computed
        }

        func solve(cursor: Int) -> ActionablePlanChoice? {
            let index = cursor - initialCursor
            if visited[index] { return memo[index] }
            visited[index] = true
            guard let nextWork = nextWorkMinute(atOrAfter: cursor, in: blocks) else {
                memo[index] = .empty
                return .empty
            }

            // The next anchor must be late enough not to overlap the previous
            // window, yet early enough that its window contains `nextWork`.
            let lower = max(cursor, nextWork - window + 1)
            var best: ActionablePlanChoice?
            for anchor in lower...nextWork {
                let windowStats = stats(at: anchor)
                guard windowStats.longestBlockRun >= floor,
                      let suffix = solve(cursor: anchor + window)
                else { continue }

                let candidate = ActionablePlanChoice(
                    anchors: [anchor] + suffix.anchors,
                    workMinutes: insertingLeastFirst(
                        windowStats.total, into: suffix.workMinutes),
                    centringCost: windowStats.centringCost + suffix.centringCost)
                if best == nil || isBetterActionablePlan(candidate, than: best!) {
                    best = candidate
                }
            }

            if let best {
                memo[index] = best
                return best
            }
            return nil
        }

        // `+ 1` is the earliest integer-minute anchor whose half-open window
        // still contains the first painted minute.
        return solve(cursor: initialCursor)
    }

    /// Describe an existing plan in the same objective space as the whole-day
    /// search. A nil result means at least one ping fails the floor, so it cannot
    /// participate in an equal-actionable-count max-min comparison.
    private static func actionablePlanChoice(
        _ pings: [Ping],
        workBlocks: [Block],
        window: Int,
        minSlice: Int)
        -> ActionablePlanChoice?
    {
        let floor = max(minSlice, 1)
        var workMinutes: [Int] = []
        var centringCost: Int64 = 0
        for ping in pings {
            let stats = windowWorkStats(
                anchor: ping.atMin, window: window, workBlocks: workBlocks)
            guard stats.longestBlockRun >= floor else { return nil }
            workMinutes.append(stats.total)
            centringCost += stats.centringCost
        }
        return ActionablePlanChoice(
            anchors: pings.map(\.atMin),
            workMinutes: workMinutes.sorted(),
            centringCost: centringCost)
    }

    /// Cheapest exact solution for the common case: translate a fixed number
    /// of back-to-back windows across the work span and retain the best
    /// floor-clearing phase. Callers may accept it without the general search
    /// only when its smallest batch reaches the average, the global max-min
    /// ceiling.
    private static func bestConsecutivePhase(
        count: Int,
        workBlocks: [Block],
        window: Int,
        minSlice: Int)
        -> ActionablePlanChoice?
    {
        let blocks = workBlocks.filter { $0.end > $0.start }
        guard count > 0, let first = blocks.first, let last = blocks.last else {
            return count == 0 ? .empty : nil
        }
        let lower = last.end - count * window
        let upper = first.start
        guard lower <= upper else { return nil }

        var best: ActionablePlanChoice?
        for firstAnchor in lower...upper {
            let pings = (0..<count).map {
                Ping(atMin: firstAnchor + $0 * window)
            }
            guard let candidate = actionablePlanChoice(
                pings,
                workBlocks: blocks,
                window: window,
                minSlice: minSlice)
            else { continue }
            if best == nil || isBetterActionablePlan(candidate, than: best!) {
                best = candidate
            }
        }
        return best
    }

    private static func insertingLeastFirst(_ value: Int, into sorted: [Int]) -> [Int] {
        var result = sorted
        let index = result.firstIndex { $0 >= value } ?? result.endIndex
        result.insert(value, at: index)
        return result
    }

    private static func nextWorkMinute(atOrAfter minute: Int, in workBlocks: [Block]) -> Int? {
        for block in workBlocks {
            if block.end <= minute { continue }
            return max(block.start, minute)
        }
        return nil
    }

    private static func windowWorkStats(
        anchor: Int,
        window: Int,
        workBlocks: [Block])
        -> WindowWorkStats
    {
        let expiry = anchor + window
        var total = 0
        var longest = 0
        var firstCovered: Int?
        var lastCovered: Int?
        for block in workBlocks {
            let a = max(anchor, block.start)
            let b = min(expiry, block.end)
            guard b > a else { continue }
            total += b - a
            longest = max(longest, b - a)
            firstCovered = firstCovered.map { min($0, a) } ?? a
            lastCovered = lastCovered.map { max($0, b) } ?? b
        }

        let centreCost: Int64
        if let firstCovered, let lastCovered {
            let windowCentre2 = Int64(anchor) * 2 + Int64(window)
            let workCentre2 = Int64(firstCovered) + Int64(lastCovered)
            centreCost = abs(windowCentre2 - workCentre2)
        } else {
            centreCost = 0
        }
        return WindowWorkStats(
            total: total, longestBlockRun: longest, centringCost: centreCost)
    }

    private static func actionablePingCount(
        _ pings: [Ping],
        workBlocks: [Block],
        window: Int,
        minSlice: Int)
        -> Int
    {
        let floor = max(minSlice, 1)
        return pings.reduce(into: 0) { count, ping in
            if windowWorkStats(
                anchor: ping.atMin, window: window, workBlocks: workBlocks
            ).longestBlockRun >= floor {
                count += 1
            }
        }
    }

    /// Exact upper bound on floor-sized budgets before requiring full coverage.
    /// A window has a contiguous `minSlice` overlap with a block precisely when
    /// its anchor lies in `[block.start + floor - window, block.end - floor]`.
    /// Greedily packing earliest anchors across the union of those intervals is
    /// optimal for fixed minimum spacing; ignoring coverage can only overstate
    /// what the full planner can achieve, which is exactly what this guard needs.
    private static func maximumActionablePingUpperBound(
        _ workBlocks: [Block],
        window: Int,
        minSlice: Int)
        -> Int
    {
        let floor = max(minSlice, 1)
        let intervals = workBlocks.compactMap { block -> ClosedRange<Int>? in
            guard block.end - block.start >= floor else { return nil }
            return (block.start + floor - window)...(block.end - floor)
        }.sorted { $0.lowerBound < $1.lowerBound }
        guard !intervals.isEmpty else { return 0 }

        var merged: [ClosedRange<Int>] = []
        for interval in intervals {
            if let last = merged.last,
               interval.lowerBound <= last.upperBound + 1
            {
                merged[merged.count - 1] = last.lowerBound...max(
                    last.upperBound, interval.upperBound)
            } else {
                merged.append(interval)
            }
        }

        var count = 0
        var nextAnchor = Int.min
        for interval in merged {
            var anchor = max(interval.lowerBound, nextAnchor)
            while anchor <= interval.upperBound {
                count += 1
                anchor += window
                nextAnchor = anchor
            }
        }
        return count
    }

    private static func isBetterBatchWorkDistribution(
        _ lhs: ActionablePlanChoice,
        than rhs: ActionablePlanChoice)
        -> Bool
    {
        guard lhs.workMinutes.count == rhs.workMinutes.count else {
            return lhs.workMinutes.count > rhs.workMinutes.count
        }
        for (left, right) in zip(lhs.workMinutes, rhs.workMinutes) where left != right {
            return left > right
        }
        return false
    }

    private static func isBetterActionablePlan(
        _ lhs: ActionablePlanChoice,
        than rhs: ActionablePlanChoice)
        -> Bool
    {
        if lhs.anchors.count != rhs.anchors.count {
            return lhs.anchors.count > rhs.anchors.count
        }
        if lhs.workMinutes != rhs.workMinutes {
            return isBetterBatchWorkDistribution(lhs, than: rhs)
        }
        if lhs.centringCost != rhs.centringCost {
            return lhs.centringCost < rhs.centringCost
        }
        // Exact ties choose the earlier phase, matching `firstBoundaryOffset`'s
        // floor division when two integer-minute centres are equally close.
        return lhs.anchors.lexicographicallyPrecedes(rhs.anchors)
    }

    /// Plan one day's pings for multiple accounts.
    ///
    /// The single-account case intentionally delegates to `planDay` so existing
    /// behavior stays stable. With multiple accounts, every account still
    /// receives the maximum number of batches the `minSlice` floor allows for
    /// each work block, but the first expiry for each account is staggered
    /// across the first equal slices of the block. That makes short blocks like
    /// 08:00-12:00 with two accounts land on 04:00/05:00 pings instead of
    /// duplicating the same 05:00 phase.
    ///
    /// The floor and the stagger meet in two places: the floor sets each
    /// account's batch count (fewer batches → fewer pings), while the stagger
    /// geometry itself stays floor-agnostic — a staggered first expiry can
    /// still cut one account's window into a sub-floor sliver, which the usage
    /// allocator (also fed `minSlice`) then folds out of the recommendation.
    /// Lanes of one account (full parallelism) get exact floor-aware placement.
    ///
    /// Days where the whole-day search overrides the greedy block-local
    /// geometry (see the single-account `planDay`) skip the stagger entirely:
    /// every account anchors together on the rephased day plan, because the
    /// stagger's block-local clamps would re-lose exactly the budgets the
    /// rephase recovered.
    public static func planDay(forAccountIDs accountIDs: [String], workBlocks: [Block], window: Int, minSlice: Int = minSliceFloorMinutes) -> MultiDayPlan {
        precondition(window > 0, "window must be positive")

        let ids = accountIDs
        if ids.isEmpty {
            return MultiDayPlan(accounts: [], usage: [])
        }

        if ids.count == 1 {
            let pings = planDay(workBlocks, window: window, minSlice: minSlice)
            let usage = computeUsage(
                accountIDs: ids, workBlocks: workBlocks, window: window,
                pingsByAccount: [pings], minSeg: minSlice)
            return MultiDayPlan(
                accounts: [AccountDayPlan(accountID: ids[0], pings: pings)],
                usage: usage)
        }

        let n = ids.count
        var pingsByAccount = Array(repeating: [Ping](), count: n)

        // The block-local stagger below inherits every loss the greedy geometry
        // has: its forward clamps drop the same cross-block budgets a whole-day
        // rephase preserves — and can even collapse every account onto one
        // degraded phase (each clamp binding at the same expiry). When the
        // day-level plan overrides the greedy geometry (see planDay), extend
        // the single-budget precedent: every account anchors together on the
        // rephased plan (the parallel-lane shape) and the usage allocator
        // splits the shared blocks — budgets are worth more than stagger.
        let dayPlan = planDay(workBlocks, window: window, minSlice: minSlice)
        if dayPlan != greedyDayPings(workBlocks, window: window, minSlice: minSlice) {
            for accountIdx in 0..<n {
                pingsByAccount[accountIdx] = dayPlan
            }
        } else {
            for block in workBlocks {
                let (s, e) = (block.start, block.end)
                if e <= s { continue }

                let len = e - s
                // Use planDay's own output as the authority on how many batches
                // actually fit (the closed-form `1 + ceil(len/window)` over-counts by
                // one when `len` sits just past a window multiple, e.g. 5h01m → claims
                // 3, only 2 fit).
                let batchesPerAccount = planDay([Block(start: s, end: e)], window: window, minSlice: minSlice).count
                // A raised floor can cap a block at a single budget per account.
                // Staggering would only manufacture the sub-floor slivers the floor
                // exists to remove, so every account anchors together on the
                // single-account placement (the same shape parallel lanes produce
                // over equal hours); the usage allocator splits the shared block.
                if batchesPerAccount == 1 {
                    let a = firstBoundaryOffset(len: len, window: window, minSlice: minSlice)
                    for accountIdx in 0..<n {
                        appendBlockPings(&pingsByAccount[accountIdx], firstPing: s - window + a, blockStart: s, blockEnd: e, window: window)
                    }
                    continue
                }
                let maxOff = maxFirstExpiryOffset(len: len, window: window, batchesPerAccount: batchesPerAccount)
                // Cap the stagger unit so `n` accounts get *distinct* first-expiry
                // offsets (without the cap, a small slack + many accounts collapses
                // every offset onto `maxOff`, scheduling all accounts identically).
                let unit = min(
                    multiAccountOffsetUnit(len: len, window: window, batchesPerAccount: batchesPerAccount, accountCount: n),
                    max(maxOff / n, 1))

                for accountIdx in 0..<n {
                    let offset = min(max((accountIdx + 1) * unit, 1), maxOff)
                    appendBlockPings(&pingsByAccount[accountIdx], firstPing: s - window + offset, blockStart: s, blockEnd: e, window: window)
                }
            }
        }

        let usage = computeUsage(
            accountIDs: ids, workBlocks: workBlocks, window: window,
            pingsByAccount: pingsByAccount, minSeg: minSlice)
        let accounts = zip(ids, pingsByAccount).map { AccountDayPlan(accountID: $0, pings: $1) }
        return MultiDayPlan(accounts: accounts, usage: usage)
    }

    /// Plan one day for `parallelism` accounts live **at the same time**.
    ///
    /// `parallelism` is the number of concurrent lanes the user wants (N). The
    /// accounts are split into N contiguous, balanced lanes; **within** a lane the
    /// accounts serially rotate via the multi-account planner above (today's
    /// stagger, so the lane is always freshly anchored — it behaves as one
    /// continuous "virtual account"); the N lanes then run **in parallel**, giving
    /// depth-N coverage. Each lane independently produces its own optimal schedule,
    /// so two lanes covering the same hours land on the same ping times (identical
    /// when a block is ≤ the window — staggering them apart would only cost a
    /// budget, never help). Usage segments carry their lane index.
    ///
    /// Degenerate cases bracket today's behaviour: `parallelism == 1` is exactly
    /// the serial planner (one lane of every account); `parallelism >= count` puts
    /// each account in its own lane (full parallelism). Out-of-range values clamp
    /// into `1...count`.
    public static func planDay(forAccountIDs accountIDs: [String], workBlocks: [Block], window: Int, parallelism: Int, minSlice: Int = minSliceFloorMinutes) -> MultiDayPlan {
        precondition(window > 0, "window must be positive")
        let total = accountIDs.count
        if total == 0 { return MultiDayPlan(accounts: [], usage: []) }

        let lanes = min(max(parallelism, 1), total)
        // One lane = today's serial behaviour, byte-for-byte (back-compat).
        if lanes == 1 {
            return planDay(forAccountIDs: accountIDs, workBlocks: workBlocks, window: window, minSlice: minSlice)
        }

        var accounts: [AccountDayPlan] = []
        var usage: [UsageSegment] = []
        for (laneIdx, laneIDs) in partitionLanes(accountIDs, into: lanes).enumerated() {
            let lanePlan = planDay(forAccountIDs: laneIDs, workBlocks: workBlocks, window: window, minSlice: minSlice)
            accounts.append(contentsOf: lanePlan.accounts)
            usage.append(contentsOf: lanePlan.usage.map {
                UsageSegment(accountID: $0.accountID, batchIndex: $0.batchIndex, startMin: $0.startMin, endMin: $0.endMin, lane: laneIdx)
            })
        }
        return MultiDayPlan(accounts: accounts, usage: usage)
    }

    /// Split `ids` into `n` contiguous, size-balanced lanes (the first `count % n`
    /// lanes get the extra account), preserving the input (priority) order. e.g.
    /// 6 ids into 2 → `[[0,1,2],[3,4,5]]`; 6 into 4 → `[[0,1],[2,3],[4],[5]]`.
    static func partitionLanes(_ ids: [String], into n: Int) -> [[String]] {
        guard n > 0 else { return ids.isEmpty ? [] : [ids] }
        let base = ids.count / n
        let rem = ids.count % n
        var lanes: [[String]] = []
        var i = 0
        for j in 0..<n {
            let size = base + (j < rem ? 1 : 0)
            lanes.append(Array(ids[i..<(i + size)]))
            i += size
        }
        return lanes
    }

    /// Convenience: plan a day directly from selected hour slots (single account).
    public static func planDay(fromHours selectedHours: [Int], window: Int, minSlice: Int = minSliceFloorMinutes) -> [Ping] {
        planDay(slotsToBlocks(selectedHours), window: window, minSlice: minSlice)
    }

    // MARK: - stagger helpers

    private static func divRound(_ n: Int, _ d: Int) -> Int {
        (n + d / 2) / d
    }

    private static func multiAccountOffsetUnit(len: Int, window: Int, batchesPerAccount: Int, accountCount: Int) -> Int {
        let n = accountCount
        if batchesPerAccount == 2 {
            return max(divRound(len, 2 * n), 1)
        } else {
            return max(divRound(len - window * (batchesPerAccount - 2), n + 1), 1)
        }
    }

    private static func maxFirstExpiryOffset(len: Int, window: Int, batchesPerAccount: Int) -> Int {
        // To get the last batch before the block ends, the first expiry must leave
        // enough room for the later account resets. Keep at least one minute for
        // very small blocks, matching planDay's integer-minute behavior.
        max(len - window * (batchesPerAccount - 2) - 1, 1)
    }

    private static func appendBlockPings(_ pings: inout [Ping], firstPing: Int, blockStart: Int, blockEnd: Int, window: Int) {
        var firstPing = firstPing
        if let last = pings.last {
            firstPing = max(firstPing, last.atMin + window)
        }
        while firstPing + window <= blockStart {
            firstPing += window
        }

        var t = firstPing
        while t < blockEnd {
            let farEnoughFromLast = pings.last.map { t >= $0.atMin + window } ?? true
            if t + window > blockStart && farEnoughFromLast {
                pings.append(Ping(atMin: t))
            }
            t += window
        }
    }

    // MARK: - usage allocation (max-min-fair, earliest-deadline-first)

    /// One token batch (a single account's window) clipped to a work block:
    /// usable for consumption during `[rel, ddl)`.
    private struct BlockBatch {
        var accountIdx: Int
        /// 1-based index into that account's daily ping list.
        var batchIndex: Int
        /// Earliest usable minute within the block.
        var rel: Int
        /// Expiry, clipped to the block end.
        var ddl: Int
    }

    /// Build the batches (account windows) overlapping a work block, `(rel, ddl)`-ordered.
    private static func blockBatches(window: Int, s: Int, e: Int, pingsByAccount: [[Ping]]) -> [BlockBatch] {
        var batches: [BlockBatch] = []
        for (accountIdx, pings) in pingsByAccount.enumerated() {
            for (i, ping) in pings.enumerated() {
                let rel = max(ping.atMin, s)
                let ddl = min(ping.atMin + window, e)
                if ddl > rel {
                    batches.append(BlockBatch(accountIdx: accountIdx, batchIndex: i + 1, rel: rel, ddl: ddl))
                }
            }
        }
        batches.sort {
            ($0.rel, $0.ddl, $0.accountIdx, $0.batchIndex) < ($1.rel, $1.ddl, $1.accountIdx, $1.batchIndex)
        }
        return batches
    }

    /// Distinct event times (batch releases/expiries + block bounds) within `[s, e]`.
    private static func eventBounds(_ batches: [BlockBatch], s: Int, e: Int) -> [Int] {
        var bounds = [s, e]
        for b in batches {
            bounds.append(b.rel)
            bounds.append(b.ddl)
        }
        bounds = bounds.filter { $0 >= s && $0 <= e }
        bounds.sort()
        var deduped: [Int] = []
        for v in bounds where deduped.last != v { deduped.append(v) }
        return deduped
    }

    /// Recommend how to spend each work block across its available batches.
    ///
    /// Base allocation is **max-min fair** (maximise the least-served batch, so we
    /// touch the most distinct budgets and split shared stretches evenly), laid
    /// out **earliest-deadline-first** (drain a budget before it expires). On top
    /// of that we enforce a **minimum segment** (`minSeg`): a recommendation that
    /// says "use this account for 10 minutes" isn't actionable, so we drop/merge
    /// sub-floor slivers (see `usageForBlock`). Pass `minSeg = 1` to recover the
    /// pure un-floored allocation.
    static func computeUsage(accountIDs: [String], workBlocks: [Block], window: Int, pingsByAccount: [[Ping]], minSeg: Int) -> [UsageSegment] {
        var usage: [UsageSegment] = []
        for block in workBlocks where block.end > block.start {
            usageForBlock(accountIDs: accountIDs, s: block.start, e: block.end, window: window, pingsByAccount: pingsByAccount, minSeg: minSeg, out: &usage)
        }
        return usage
    }

    private static func usageForBlock(accountIDs: [String], s: Int, e: Int, window: Int, pingsByAccount: [[Ping]], minSeg: Int, out: inout [UsageSegment]) {
        var batches = blockBatches(window: window, s: s, e: e, pingsByAccount: pingsByAccount)
        if batches.isEmpty { return }

        // Lay the block out, then suppress sub-floor slivers. A budget is a
        // "sliver maker" only if its *entire* contribution to this block is under
        // the floor (a budget that also earns a real chunk is kept; just its tail
        // is folded in below). We drop the least-useful such budget first — the one
        // with the shortest live span, so the longest-reaching one survives to
        // cover its edge for at least the floor — but never one the rest can't
        // cover without. Max-min fair re-spreads the freed time over the
        // survivors, so tiles stay even.
        var cells = tileBlock(batches, s: s, e: e)
        while true {
            var total = Array(repeating: 0, count: batches.count)
            for cell in cells { total[cell.batch] += cell.end - cell.start }
            var sliverMakers = (0..<batches.count).filter { total[$0] > 0 && total[$0] < minSeg }
            sliverMakers.sort { (batches[$0].ddl - batches[$0].rel) < (batches[$1].ddl - batches[$1].rel) }

            let victim = sliverMakers.first { batches.count > 1 && unionCovers(batches, skip: $0, s: s, e: e) }
            if let bi = victim {
                batches.remove(at: bi)
                cells = tileBlock(batches, s: s, e: e)
            } else {
                break
            }
        }

        // Any sliver still standing is load-bearing for coverage (its budget can't
        // be dropped); fold it into an adjacent tile whose window legally spans it.
        coalesceSlivers(&cells, batches: batches, minSeg: minSeg)

        for cell in cells {
            pushUsageSegment(&out, accountID: accountIDs[batches[cell.batch].accountIdx], batch: batches[cell.batch], startMin: cell.start, endMin: cell.end)
        }
    }

    /// A laid-out tile: `(batch index into batches, start, end)`.
    private struct Cell {
        var batch: Int
        var start: Int
        var end: Int
    }

    /// Lay a fixed batch set across `[s, e]`: max-min-fair service drained
    /// earliest-deadline-first. Returns cells with abutting same-batch runs merged.
    private static func tileBlock(_ batches: [BlockBatch], s: Int, e: Int) -> [Cell] {
        var cells: [Cell] = []
        if batches.isEmpty { return cells }
        var remaining = maxminFairService(batches, s: s, e: e)
        let bounds = eventBounds(batches, s: s, e: e)

        for w in 0..<max(bounds.count - 1, 0) {
            var c0 = bounds[w]
            let c1 = bounds[w + 1]
            if c1 <= c0 { continue }
            // Batches usable across this whole cell, earliest-deadline first.
            var idxs = (0..<batches.count).filter { batches[$0].rel <= c0 && batches[$0].ddl >= c1 }
            idxs.sort { (batches[$0].ddl, batches[$0].accountIdx, batches[$0].batchIndex) < (batches[$1].ddl, batches[$1].accountIdx, batches[$1].batchIndex) }

            for i in idxs {
                if c0 >= c1 { break }
                let take = min(remaining[i], c1 - c0)
                if take > 0 {
                    pushCell(&cells, batch: i, a: c0, b: c0 + take)
                    remaining[i] -= take
                    c0 += take
                }
            }
            // If fair service rounded down and left a sliver, hand it to the
            // earliest-deadline batch present so work is never left uncovered.
            if c0 < c1, let i = idxs.first {
                pushCell(&cells, batch: i, a: c0, b: c1)
            }
        }
        return cells
    }

    /// Append `[a, b)` for batch `bi`, extending the previous cell if it is the
    /// same batch and abuts.
    private static func pushCell(_ cells: inout [Cell], batch bi: Int, a: Int, b: Int) {
        if b <= a { return }
        if var last = cells.last, last.batch == bi, last.end == a {
            last.end = b
            cells[cells.count - 1] = last
            return
        }
        cells.append(Cell(batch: bi, start: a, end: b))
    }

    /// Do the batches other than `skip` still cover all of `[s, e]` with no gap?
    private static func unionCovers(_ batches: [BlockBatch], skip: Int, s: Int, e: Int) -> Bool {
        var ivs = batches.enumerated().filter { $0.offset != skip }.map { ($0.element.rel, $0.element.ddl) }
        ivs.sort { $0 < $1 }
        var cur = s
        for (rel, ddl) in ivs {
            if rel > cur { return false } // gap before this interval starts
            cur = max(cur, ddl)
            if cur >= e { return true }
        }
        return cur >= e
    }

    /// Fold any remaining sub-`minSeg` cell into an adjacent cell whose budget is
    /// live across the whole sliver (so the tile never escapes its own window).
    /// Prefers extending the previous tile; falls back to pulling the next one
    /// earlier; leaves the sliver alone only if neither neighbour can legally span
    /// it.
    private static func coalesceSlivers(_ cells: inout [Cell], batches: [BlockBatch], minSeg: Int) {
        var i = 0
        while i < cells.count {
            let (a, b) = (cells[i].start, cells[i].end)
            if b - a >= minSeg || cells.count == 1 {
                i += 1
                continue
            }
            func covers(_ bi: Int) -> Bool { batches[bi].rel <= a && batches[bi].ddl >= b }
            if i > 0 && covers(cells[i - 1].batch) {
                cells[i - 1].end = b
                cells.remove(at: i)
            } else if i + 1 < cells.count && covers(cells[i + 1].batch) {
                cells[i + 1].start = a
                cells.remove(at: i)
            } else {
                i += 1
            }
        }
    }

    /// Max-min fair service time per batch on a single server, bounded by each
    /// batch's availability. Uses the classic preemptive single-machine
    /// feasibility test (total demand over every event window must fit) to find
    /// the highest equal service level, freezing batches that hit availability or a
    /// saturated window, then raising the rest — repeating until all are frozen.
    private static func maxminFairService(_ batches: [BlockBatch], s: Int, e: Int) -> [Int] {
        let n = batches.count
        let bounds = eventBounds(batches, s: s, e: e)
        let span = batches.map { $0.ddl - $0.rel }
        var service = Array(repeating: 0, count: n)
        var frozen = Array(repeating: false, count: n)

        // Does `target` service fit on one server? (For every window [t1,t2], the
        // demand of batches contained in it must not exceed the window width.)
        func fits(_ target: (Int) -> Int) -> Bool {
            for a in 0..<bounds.count {
                for b in (a + 1)..<bounds.count {
                    let (t1, t2) = (bounds[a], bounds[b])
                    var need = 0
                    for i in 0..<n where batches[i].rel >= t1 && batches[i].ddl <= t2 {
                        need += target(i)
                    }
                    if need > t2 - t1 { return false }
                }
            }
            return true
        }

        while frozen.contains(false) {
            // Highest equal level the still-active batches can all reach.
            var lo = 0
            var hi = e - s
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                let target: (Int) -> Int = { i in frozen[i] ? service[i] : min(span[i], mid) }
                if fits(target) {
                    lo = mid
                } else {
                    hi = mid - 1
                }
            }
            let level = lo
            for i in 0..<n where !frozen[i] {
                service[i] = min(span[i], level)
            }

            // Freeze batches that can't grow: capped by their own availability, or
            // contained in a now-saturated (tight) window.
            var newlyFrozen = false
            for i in 0..<n where !frozen[i] && span[i] <= level {
                frozen[i] = true
                newlyFrozen = true
            }
            for a in 0..<bounds.count {
                for b in (a + 1)..<bounds.count {
                    let (t1, t2) = (bounds[a], bounds[b])
                    let inside = (0..<n).filter { batches[$0].rel >= t1 && batches[$0].ddl <= t2 }
                    let need = inside.reduce(0) { $0 + service[$1] }
                    if need == t2 - t1 {
                        for i in inside where !frozen[i] {
                            frozen[i] = true
                            newlyFrozen = true
                        }
                    }
                }
            }
            if !newlyFrozen { break } // no further progress possible (e.g. uncovered slack)
        }
        return service
    }

    private static func pushUsageSegment(_ out: inout [UsageSegment], accountID: String, batch: BlockBatch, startMin: Int, endMin: Int) {
        if endMin <= startMin { return }
        // Extend the previous segment if it is the same account+batch, abutting.
        if var last = out.last, last.accountID == accountID, last.batchIndex == batch.batchIndex, last.endMin == startMin {
            last.endMin = endMin
            out[out.count - 1] = last
            return
        }
        out.append(UsageSegment(accountID: accountID, batchIndex: batch.batchIndex, startMin: startMin, endMin: endMin))
    }
}

/// Format a local minute offset in the given clock style — "05:00" / "5am" —
/// with `(-1d)` / `(+1d)` markers when it rolls to an adjacent day. The
/// 24-hour default keeps tests and diagnostic call sites stable; UI callers
/// pass the user's preference.
public func fmtMin(_ atMin: Int, clockStyle: ClockStyle = .twentyFourHour) -> String {
    let day = Int(floor(Double(atMin) / 1440.0))
    let m = atMin - day * 1440
    let suffix: String
    switch day {
    case 0: suffix = ""
    case let d where d < 0: suffix = " (\(d)d)"
    default: suffix = " (+\(day)d)"
    }
    return clockStyle.minuteString(m) + suffix
}
