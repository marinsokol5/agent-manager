import XCTest
@testable import AgentManagerCore

/// The token-max engine is the heart of journey 4, so it carries a full property
/// suite.
final class ScheduleEngineTests: XCTestCase {
    let w = defaultWindowMinutes

    func mins(_ p: [Ping]) -> [Int] { p.map(\.atMin) }
    func ids(_ n: Int) -> [String] { (0..<n).map { "a\($0)" } }
    func block(_ s: Int, _ e: Int) -> Block { Block(start: s, end: e) }

    // MARK: - blocks

    func testBlocksMergeContiguousHours() {
        XCTAssertEqual(ScheduleEngine.slotsToBlocks([8, 9, 10, 11]), [block(480, 720)])
        // unsorted + two disjoint blocks (8-12 and 14-18)
        XCTAssertEqual(
            ScheduleEngine.slotsToBlocks([15, 8, 9, 16, 10, 11, 14, 17]),
            [block(480, 720), block(840, 1080)])
        XCTAssertEqual(ScheduleEngine.slotsToBlocks([]), [])
    }

    // MARK: - single account

    func testSingleBlock8To12MatchesHandDerivation() {
        // Work 08:00–12:00 (4h), window 5h. Expect pings 05:00 and 10:00 → 2 batches.
        let pings = ScheduleEngine.planDay([block(480, 720)], window: w)
        XCTAssertEqual(mins(pings), [300, 600])
        XCTAssertEqual(fmtMin(pings[0].atMin), "05:00")
        XCTAssertEqual(fmtMin(pings[1].atMin), "10:00")
    }

    func testSingleBlock8To16GivesThreeBatches() {
        let pings = ScheduleEngine.planDay([block(480, 960)], window: w)
        XCTAssertEqual(mins(pings), [270, 570, 870]) // 04:30, 09:30, 14:30
        XCTAssertEqual(pings.count, 3)
        XCTAssertTrue(pings[0].atMin < 480, "first ping must be a pre-ping")
        XCTAssertTrue(pings[1...].allSatisfy { $0.atMin >= 480 && $0.atMin < 960 })
    }

    func testFirstPingIsAlwaysPrePingAndWindowLiveAtStart() {
        for (s, e) in [(480, 720), (480, 960), (540, 1020), (0, 300)] {
            let pings = ScheduleEngine.planDay([block(s, e)], window: w)
            let t0 = pings[0].atMin
            XCTAssertTrue(t0 < s, "pre-ping \(t0) must be before work start \(s)")
            XCTAssertTrue(t0 + w > s, "window from pre-ping must still be live at work start")
        }
    }

    func testBatchCountIsMaximal() {
        // Max distinct budgets overlapping a single block = 1 + ceil(len/window).
        for lenH in 1...12 {
            let len = lenH * 60
            let pings = ScheduleEngine.planDay([block(480, 480 + len)], window: w)
            let expected = 1 + (len + w - 1) / w
            XCTAssertEqual(pings.count, expected, "len \(lenH)h should yield \(expected) batches")
        }
    }

    func testAfternoonBlockRidesMorningWindowThenRepings() {
        // 08:00–12:00 and 14:00–18:00. The 10:00 window covers until 15:00, so the
        // afternoon block needs no pre-ping; it re-pings at 15:00.
        let pings = ScheduleEngine.planDay([block(480, 720), block(840, 1080)], window: w)
        XCTAssertEqual(mins(pings), [300, 600, 900]) // 05:00, 10:00, 15:00
    }

    // MARK: - regression: phantom mid-window pings

    func testShortBlockThenGapRephasesToKeepEveryUsableBudget() {
        // The field report: Mon 10:00–11:00 + 14:00–17:00 at the product-default
        // 60-min floor. The 1h block centres its window (08:00–13:00 — expired
        // before the afternoon block, but with hours of post-block slack), and
        // the afternoon block's *ideal* pre-ping (10:30) lands inside it. A real
        // ping there anchors nothing — usage within a window never moves its
        // boundary — so the old plan [08:00, 10:30, 15:30] promised a phantom
        // 10:30–15:30 batch and left 14:00–15:30 of painted work uncovered. A
        // forward-only clamp to [08:00, 13:00] is physical but still throws away
        // a usable budget: rephase the whole day to three 5h-spaced anchors whose
        // painted slices are exactly 60m, 120m, 60m.
        let day = [block(600, 660), block(840, 1020)]
        let pings = ScheduleEngine.planDay(day, window: w, minSlice: 60)
        XCTAssertEqual(mins(pings), [360, 660, 960]) // 06:00, 11:00, 16:00
        XCTAssertEqual(pings.map { ping in
            day.reduce(0) { total, b in
                total + max(0, min(ping.atMin + w, b.end) - max(ping.atMin, b.start))
            }
        }, [60, 120, 60])
        assertCovers(pings, day, "10–11 + 14–17, floor 60")
    }

    func testParallelLanesInheritTheWholeDayRephase() {
        // Full parallelism = lanes of one account, each on the single-account
        // planner — the exact configuration the field report ran (3 of 3).
        let plan = ScheduleEngine.planDay(
            forAccountIDs: ids(3), workBlocks: [block(600, 660), block(840, 1020)],
            window: w, parallelism: 3, minSlice: 60)
        for a in plan.accounts {
            XCTAssertEqual(mins(a.pings), [360, 660, 960], a.accountID)
        }
    }

    func testSmallModelNeverLeavesAnActionableBudgetOnTheTable() {
        // Exhaustive, implementation-independent oracle over every non-empty
        // 7-minute work bitmap and every floor for a 4-minute window. Enumerate
        // every possible physical anchor subset, retain the plans that cover all
        // work and give every window a contiguous floor-sized stretch, then
        // require the real planner to expose at least that many actionable
        // budgets. (Its coverage-first fallback may also contain load-bearing
        // sub-floor windows when no all-actionable plan exists.)
        // The compressed units exercise the same interval geometry as hours/5h
        // while keeping the brute-force search tiny and deterministic.
        let slots = 7
        let window = 4

        func blocksForMask(_ mask: Int) -> [Block] {
            var result: [Block] = []
            var start: Int?
            for t in 0...slots {
                let selected = t < slots && (mask & (1 << t)) != 0
                if selected, start == nil {
                    start = t
                } else if !selected, let s = start {
                    result.append(block(s, t))
                    start = nil
                }
            }
            return result
        }

        func longestBlockRun(anchor: Int, blocks: [Block]) -> Int {
            blocks.map {
                max(0, min(anchor + window, $0.end) - max(anchor, $0.start))
            }.max() ?? 0
        }

        func oracleMaximum(mask: Int, blocks: [Block], floor: Int) -> Int {
            let work = (0..<slots).filter { (mask & (1 << $0)) != 0 }
            let candidates = Array((work.first! - window + 1)...work.last!)
            var best = 0
            for subset in 1..<(1 << candidates.count) {
                let count = subset.nonzeroBitCount
                if count <= best { continue }
                let anchors = candidates.indices.compactMap {
                    (subset & (1 << $0)) != 0 ? candidates[$0] : nil
                }
                guard zip(anchors, anchors.dropFirst()).allSatisfy({ $0.1 - $0.0 >= window }),
                      work.allSatisfy({ t in
                          anchors.contains { $0 <= t && t < $0 + window }
                      }),
                      anchors.allSatisfy({
                          longestBlockRun(anchor: $0, blocks: blocks) >= floor
                      })
                else { continue }
                best = max(best, anchors.count)
            }
            return best
        }

        for mask in 1..<(1 << slots) {
            let blocks = blocksForMask(mask)
            for floor in 1...window {
                let oracle = oracleMaximum(mask: mask, blocks: blocks, floor: floor)
                let pings = ScheduleEngine.planDay(blocks, window: window, minSlice: floor)
                let actionable = pings.filter {
                    longestBlockRun(anchor: $0.atMin, blocks: blocks) >= floor
                }.count
                XCTAssertGreaterThanOrEqual(
                    actionable, oracle,
                    "mask \(String(mask, radix: 2)), floor \(floor): pings \(mins(pings)), oracle \(oracle)")
            }
        }
    }

    func testPingsNeverCloserThanAWindowAcrossBlockShapesAndFloors() {
        // The moat invariant, swept: one account's anchors can never be closer
        // than `window` (a ping inside a live window anchors nothing), and no
        // work minute may lose coverage — across two-block day shapes × floors.
        // One origin is sufficient: adding a constant to every block only adds
        // that constant to every ping, so repeating the same geometry at seven
        // clock offsets adds runtime, not coverage.
        let s1 = 360
        for len1 in [60, 120, 180] {
            for gap in stride(from: 60, through: 360, by: 60) {
                for len2 in [60, 180, 300, 360] {
                    let blocks = [block(s1, s1 + len1),
                                  block(s1 + len1 + gap, s1 + len1 + gap + len2)]
                    for minSlice in [minSliceFloorMinutes, 30, 60, 90, 150] {
                        let ctx = "len1 \(len1) gap \(gap) len2 \(len2) floor \(minSlice)"
                        let pings = ScheduleEngine.planDay(blocks, window: w, minSlice: minSlice)
                        for pair in zip(pings, pings.dropFirst()) {
                            XCTAssertGreaterThanOrEqual(pair.1.atMin - pair.0.atMin, w,
                                "\(ctx): pings \(mins(pings))")
                        }
                        assertCovers(pings, blocks, ctx)
                    }
                }
            }
        }
    }

    func testCoverageHasNoGapsDuringWork() {
        let blocks = [block(480, 960), block(1020, 1140)]
        let pings = ScheduleEngine.planDay(blocks, window: w)
        for b in blocks {
            for t in b.start..<b.end {
                let covered = pings.contains { $0.atMin <= t && t < $0.atMin + w }
                XCTAssertTrue(covered, "minute \(t) (\(fmtMin(t))) uncovered")
            }
        }
    }

    func testFmtHandlesDayRollover() {
        XCTAssertEqual(fmtMin(300), "05:00")
        XCTAssertEqual(fmtMin(-60), "23:00 (-1d)")
        XCTAssertEqual(fmtMin(1470), "00:30 (+1d)")

        // The day-roll suffix survives the 12-hour clock style.
        XCTAssertEqual(fmtMin(300, clockStyle: .twelveHour), "5am")
        XCTAssertEqual(fmtMin(-60, clockStyle: .twelveHour), "11pm (-1d)")
        XCTAssertEqual(fmtMin(1470, clockStyle: .twelveHour), "12:30am (+1d)")
    }

    // MARK: - multi account

    func testMultiAccountSingleAccountPathMatchesExistingPlanner() {
        let plan = ScheduleEngine.planDay(forAccountIDs: ["a1"], workBlocks: [block(480, 720)], window: w)
        XCTAssertEqual(plan.accounts.count, 1)
        XCTAssertEqual(mins(plan.accounts[0].pings), [300, 600])
        XCTAssertEqual(plan.usage, [
            UsageSegment(accountID: "a1", batchIndex: 1, startMin: 480, endMin: 600),
            UsageSegment(accountID: "a1", batchIndex: 2, startMin: 600, endMin: 720),
        ])
    }

    func testTwoAccounts8To12StaggerIntoHourlyBatches() {
        let plan = ScheduleEngine.planDay(forAccountIDs: ["a1", "a2"], workBlocks: [block(480, 720)], window: w)
        XCTAssertEqual(mins(plan.accounts[0].pings), [240, 540]) // 04:00, 09:00
        XCTAssertEqual(mins(plan.accounts[1].pings), [300, 600]) // 05:00, 10:00
        XCTAssertEqual(plan.usage, [
            UsageSegment(accountID: "a1", batchIndex: 1, startMin: 480, endMin: 540),
            UsageSegment(accountID: "a2", batchIndex: 1, startMin: 540, endMin: 600),
            UsageSegment(accountID: "a1", batchIndex: 2, startMin: 600, endMin: 660),
            UsageSegment(accountID: "a2", batchIndex: 2, startMin: 660, endMin: 720),
        ])
    }

    func testTwoAccounts8To16StaggerIntoSixBatches() {
        let plan = ScheduleEngine.planDay(forAccountIDs: ["a1", "a2"], workBlocks: [block(480, 960)], window: w)
        XCTAssertEqual(mins(plan.accounts[0].pings), [240, 540, 840]) // 04:00, 09:00, 14:00
        XCTAssertEqual(mins(plan.accounts[1].pings), [300, 600, 900]) // 05:00, 10:00, 15:00
        XCTAssertEqual(plan.usage, [
            UsageSegment(accountID: "a1", batchIndex: 1, startMin: 480, endMin: 540),
            UsageSegment(accountID: "a2", batchIndex: 1, startMin: 540, endMin: 600),
            UsageSegment(accountID: "a1", batchIndex: 2, startMin: 600, endMin: 720),
            UsageSegment(accountID: "a2", batchIndex: 2, startMin: 720, endMin: 840),
            UsageSegment(accountID: "a1", batchIndex: 3, startMin: 840, endMin: 900),
            UsageSegment(accountID: "a2", batchIndex: 3, startMin: 900, endMin: 960),
        ])
    }

    // A representative spread of account counts × block shapes.
    let cases: [(Int, [Block])] = [
        (1, [Block(start: 480, end: 720)]),
        (2, [Block(start: 480, end: 720)]),
        (2, [Block(start: 480, end: 960)]),
        (3, [Block(start: 480, end: 720)]),
        (2, [Block(start: 480, end: 720), Block(start: 840, end: 1080)]), // multi-block, 2h gap
        (2, [Block(start: 480, end: 720), Block(start: 780, end: 1020)]), // multi-block, 1h gap
        (4, [Block(start: 480, end: 781)]),                                // 5h01m block
        (2, [Block(start: 480, end: 1200)]),                               // 12h
        (3, [Block(start: 480, end: 960), Block(start: 1020, end: 1200)]),
        (1, [Block(start: 600, end: 660), Block(start: 840, end: 1020)]),  // short block + gap (field report)
        (3, [Block(start: 600, end: 660), Block(start: 840, end: 1020)]),
    ]

    func usageWithMin(_ n: Int, _ blocks: [Block], _ window: Int, _ minSeg: Int) -> [UsageSegment] {
        let names = ids(n)
        let plan = ScheduleEngine.planDay(forAccountIDs: names, workBlocks: blocks, window: window)
        let pingsByAccount = plan.accounts.map(\.pings)
        return ScheduleEngine.computeUsage(accountIDs: names, workBlocks: blocks, window: window, pingsByAccount: pingsByAccount, minSeg: minSeg)
    }

    func testAccountPingsNeverCloserThanAWindow() {
        for (n, blocks) in cases {
            let plan = ScheduleEngine.planDay(forAccountIDs: ids(n), workBlocks: blocks, window: w)
            for a in plan.accounts {
                for pair in zip(a.pings, a.pings.dropFirst()) {
                    XCTAssertGreaterThanOrEqual(pair.1.atMin - pair.0.atMin, w,
                        "\(a.accountID): pings \(pair.0.atMin) and \(pair.1.atMin) closer than a window")
                }
            }
        }
    }

    func testAccountsAreNeverScheduledIdentically() {
        for n in 2...4 {
            for len in [120, 240, 300, 301, 480, 600, 720, 900] {
                let plan = ScheduleEngine.planDay(forAccountIDs: ids(n), workBlocks: [block(480, 480 + len)], window: w)
                for i in 0..<n {
                    for j in (i + 1)..<n {
                        XCTAssertNotEqual(plan.accounts[i].pings, plan.accounts[j].pings,
                            "n \(n), len \(len): accounts \(i) and \(j) scheduled identically")
                    }
                }
            }
        }
    }

    func testUsageTilesEachBlockAndStaysWithinItsWindow() {
        for (n, blocks) in cases {
            let plan = ScheduleEngine.planDay(forAccountIDs: ids(n), workBlocks: blocks, window: w)

            for u in plan.usage {
                let acct = plan.accounts.first { $0.accountID == u.accountID }!
                let ping = acct.pings[u.batchIndex - 1].atMin
                XCTAssertGreaterThan(u.endMin, u.startMin)
                XCTAssertGreaterThanOrEqual(u.endMin - u.startMin, minSliceFloorMinutes,
                    "segment \(u) is shorter than the switch floor")
                XCTAssertTrue(u.startMin >= ping && u.endMin <= ping + w,
                    "segment \(u) escapes its window [\(ping),\(ping + w)]")
            }

            for b in blocks {
                var segs = plan.usage.filter { $0.startMin < b.end && $0.endMin > b.start }
                    .map { ($0.startMin, $0.endMin) }
                segs.sort { $0 < $1 }
                var cur = b.start
                for (a, bb) in segs {
                    XCTAssertEqual(a, cur, "gap/overlap in block [\(b.start),\(b.end)] at \(cur)")
                    cur = bb
                }
                XCTAssertEqual(cur, b.end, "block [\(b.start),\(b.end)] not covered to its end")
            }
        }
    }

    func testUsageNeverStarvesAnAvailableBudget() {
        for (n, blocks) in cases {
            let plan = ScheduleEngine.planDay(forAccountIDs: ids(n), workBlocks: blocks, window: w)
            let usage = usageWithMin(n, blocks, w, 1)
            let used = Set(usage.map { "\($0.accountID)#\($0.batchIndex)" })
            for a in plan.accounts {
                for (i, p) in a.pings.enumerated() {
                    let overlaps = blocks.contains { p.atMin < $0.end && p.atMin + w > $0.start }
                    if overlaps {
                        XCTAssertTrue(used.contains("\(a.accountID)#\(i + 1)"),
                            "\(a.accountID) batch \(i + 1) overlaps work but is never used (n \(n))")
                    }
                }
            }
        }
    }

    func testSingleBlockTouchesNTimesTheSingleAccountBudgetCount() {
        for n in 1...3 {
            for len in [120, 240, 300, 480, 600, 720] {
                let blocks = [block(480, 480 + len)]
                let perAccount = ScheduleEngine.planDay(blocks, window: w).count
                let usage = usageWithMin(n, blocks, w, 1)
                let distinct = Set(usage.map { "\($0.accountID)#\($0.batchIndex)" })
                XCTAssertEqual(distinct.count, n * perAccount,
                    "n \(n), len \(len): touched \(distinct.count) distinct budgets, want \(n * perAccount)")
            }
        }
    }

    func testFloorKeepsEverySegmentActionable() {
        let m = 30 // a raised floor (the default is minSliceFloorMinutes)
        for n in 1...4 {
            for start in [0, 360, 420, 480, 540] {
                for len in [60, 120, 180, 240, 300, 360, 480, 600, 660, 720, 900] {
                    let (s, e) = (start, start + len)
                    let usage = usageWithMin(n, [block(s, e)], w, m)
                    var segs = usage.map { ($0.startMin, $0.endMin) }
                    segs.sort { $0 < $1 }
                    var cur = s
                    for (a, b) in segs {
                        XCTAssertEqual(a, cur, "gap/overlap (n \(n), block [\(s),\(e)]) at \(cur)")
                        XCTAssertGreaterThanOrEqual(b - a, m, "sub-floor segment \(a)–\(b) (n \(n))")
                        cur = b
                    }
                    XCTAssertEqual(cur, e, "block [\(s),\(e)] not covered to its end (n \(n))")
                }
            }
        }
    }

    func testShortBlockFloorsInsteadOfSlivering() {
        // Unfloored, a 1h block over three staggered accounts hands out
        // sub-floor slivers; the default floor folds them into usable segments
        // that still tile the block edge to edge.
        let raw = usageWithMin(3, [block(480, 540)], w, 1)
        XCTAssertTrue(raw.contains { $0.endMin - $0.startMin < minSliceFloorMinutes })

        let floored = ScheduleEngine.planDay(forAccountIDs: ids(3), workBlocks: [block(480, 540)], window: w).usage
        XCTAssertTrue(floored.allSatisfy { $0.endMin - $0.startMin >= minSliceFloorMinutes })
        var cur = 480
        for u in floored.sorted(by: { $0.startMin < $1.startMin }) {
            XCTAssertEqual(u.startMin, cur, "gap/overlap at \(cur)")
            cur = u.endMin
        }
        XCTAssertEqual(cur, 540)
    }

    func testFloorOnlyDropsBudgetsNeverInventsThem() {
        for (n, blocks) in cases {
            let base = Set(usageWithMin(n, blocks, w, 1).map { "\($0.accountID)#\($0.batchIndex)" })
            for u in ScheduleEngine.planDay(forAccountIDs: ids(n), workBlocks: blocks, window: w).usage {
                XCTAssertTrue(base.contains("\(u.accountID)#\(u.batchIndex)"),
                    "floored usage touches \(u.accountID)/\(u.batchIndex) which the base allocator never did (n \(n))")
            }
        }
    }

    // MARK: - budget-slice floor (minSlice)

    /// Every work minute of `blocks` is inside some ping's window.
    func assertCovers(_ pings: [Ping], _ blocks: [Block], _ context: String) {
        for b in blocks {
            for t in b.start..<b.end where !pings.contains(where: { $0.atMin <= t && t < $0.atMin + w }) {
                return XCTFail("\(context): minute \(t) (\(fmtMin(t))) uncovered")
            }
        }
    }

    func testRaisedFloorFoldsSixHourDayToBalancedHalves() {
        // The motivating case: a 13:00–19:00 day. Default floor → 30m+5h+30m on
        // three pings (08:30, 13:30, 18:30); the moment the floor exceeds what
        // the two 30-min edges can honor, the layout folds to two balanced 3h
        // budgets on two pings (11:00, 16:00) — chunkier *and* cheaper.
        let day = [block(780, 1140)]
        XCTAssertEqual(mins(ScheduleEngine.planDay(day, window: w)), [510, 810, 1110])
        for m in [45, 60, 90, 180] {
            XCTAssertEqual(mins(ScheduleEngine.planDay(day, window: w, minSlice: m)), [660, 960],
                "floor \(m) should fold 6h into 3h + 3h")
        }
    }

    func testUnsatisfiableFloorDegradesToBalanceNeverToGaps() {
        // 6h can never honor >3h halves — the floor bends (still 3h + 3h)…
        XCTAssertEqual(mins(ScheduleEngine.planDay([block(780, 1140)], window: w, minSlice: 240)), [660, 960])
        // …and an 11h block *needs* three windows whose edges sum to 6h, so a
        // 200-min floor loses to coverage: edges balance at 3h around the full
        // middle window instead of opening a hole.
        let eleven = [block(480, 1140)]
        let pings = ScheduleEngine.planDay(eleven, window: w, minSlice: 200)
        XCTAssertEqual(mins(pings), [360, 660, 960])
        assertCovers(pings, eleven, "11h block, floor 200")
    }

    func testFloorCapsShortBlockAtOneCenteredWindow() {
        // 4h block, 2.5h floor: two 2h budgets both miss the floor, and one
        // window can cover the block outright — a single centred pre-ping
        // (07:30, window 07:30–12:30 around 08:00–12:00), no interior re-ping.
        let pings = ScheduleEngine.planDay([block(480, 720)], window: w, minSlice: 150)
        XCTAssertEqual(mins(pings), [450])
        assertCovers(pings, [block(480, 720)], "4h block, floor 150")
    }

    func testChangingFloorNeverAddsPingsAndNeverGapsCoverage() {
        // Cadence restraint: no floor setting may *add* pings over the default
        // for an hour-granular block (15 min ties it, higher removes), and no
        // work minute may ever lose coverage to it.
        for lenH in 1...12 {
            let blocks = [block(480, 480 + lenH * 60)]
            let base = ScheduleEngine.planDay(blocks, window: w).count
            for m in stride(from: minSliceFloorMinutes, through: w, by: 15) {
                let pings = ScheduleEngine.planDay(blocks, window: w, minSlice: m)
                XCTAssertLessThanOrEqual(pings.count, base, "len \(lenH)h, floor \(m): added pings")
                assertCovers(pings, blocks, "len \(lenH)h, floor \(m)")
            }
        }
    }

    func testFloorShapesEachAccountInSerialRotation() {
        // Two serial accounts on the 6h day, floor 60: each account folds to
        // two budgets (four pings/day, was six), pings stay a window apart, the
        // stagger survives, and every recommended segment clears the floor.
        let plan = ScheduleEngine.planDay(forAccountIDs: ids(2), workBlocks: [block(780, 1140)], window: w, minSlice: 60)
        for a in plan.accounts {
            XCTAssertEqual(a.pings.count, 2, a.accountID)
            for pair in zip(a.pings, a.pings.dropFirst()) {
                XCTAssertGreaterThanOrEqual(pair.1.atMin - pair.0.atMin, w)
            }
        }
        XCTAssertNotEqual(plan.accounts[0].pings, plan.accounts[1].pings, "stagger must survive the floor")
        XCTAssertTrue(plan.usage.allSatisfy { $0.endMin - $0.startMin >= 60 },
            "sub-floor recommendation in \(plan.usage)")
        var cur = 780
        for u in plan.usage.sorted(by: { $0.startMin < $1.startMin }) {
            XCTAssertEqual(u.startMin, cur, "gap/overlap at \(cur)")
            cur = u.endMin
        }
        XCTAssertEqual(cur, 1140, "block not tiled to its end")
    }

    func testFloorSingleBudgetBlockAnchorsAccountsTogether() {
        // When the floor caps a block at one budget per account, staggering
        // would only re-create the slivers the floor exists to remove — the
        // accounts anchor together (the parallel-lane shape) and the allocator
        // hands the block to as few accounts as the floor allows.
        let plan = ScheduleEngine.planDay(forAccountIDs: ids(2), workBlocks: [block(480, 720)], window: w, minSlice: 150)
        XCTAssertEqual(mins(plan.accounts[0].pings), [450])
        XCTAssertEqual(plan.accounts[0].pings, plan.accounts[1].pings)
        XCTAssertEqual(plan.usage.count, 1, "240 min can hold only one ≥150-min slice: \(plan.usage)")
        XCTAssertEqual(plan.usage.first?.startMin, 480)
        XCTAssertEqual(plan.usage.first?.endMin, 720)
    }

    func testFloorThreadsThroughParallelLanes() {
        // Full parallelism = lanes of one → each lane gets the exact
        // floor-aware single-account layout.
        let plan = ScheduleEngine.planDay(forAccountIDs: ids(2), workBlocks: [block(780, 1140)], window: w, parallelism: 2, minSlice: 60)
        XCTAssertEqual(mins(plan.accounts[0].pings), [660, 960])
        XCTAssertEqual(plan.accounts[0].pings, plan.accounts[1].pings, "parallel lanes are identical")
    }

    // MARK: - parallel lanes (N accounts live at once)

    func testParallelismOneEqualsSerialPlanner() {
        // One lane = byte-for-byte today's serial planner, for every case shape.
        for (n, blocks) in cases {
            let serial = ScheduleEngine.planDay(forAccountIDs: ids(n), workBlocks: blocks, window: w)
            let lane1 = ScheduleEngine.planDay(forAccountIDs: ids(n), workBlocks: blocks, window: w, parallelism: 1)
            XCTAssertEqual(lane1.accounts, serial.accounts, "n \(n): parallelism 1 pings must match serial")
            XCTAssertEqual(lane1.usage, serial.usage, "n \(n): parallelism 1 usage must match serial")
        }
    }

    func testFullParallelGivesEachAccountTheSingleAccountSchedule() {
        // 2 accounts, fully parallel (N=2) on 08:00–12:00 → each in its own lane,
        // both on the single-account optimal 05:00/10:00 (the agreed answer);
        // serial would stagger them to 04:00/05:00 instead.
        let single = mins(ScheduleEngine.planDay([block(480, 720)], window: w)) // [300, 600]
        let parallel = ScheduleEngine.planDay(forAccountIDs: ["a", "b"], workBlocks: [block(480, 720)], window: w, parallelism: 2)
        XCTAssertEqual(mins(parallel.accounts[0].pings), single)
        XCTAssertEqual(mins(parallel.accounts[1].pings), single)
        XCTAssertEqual(parallel.accounts[0].pings, parallel.accounts[1].pings, "fully-parallel lanes are identical")

        let serial = ScheduleEngine.planDay(forAccountIDs: ["a", "b"], workBlocks: [block(480, 720)], window: w, parallelism: 1)
        XCTAssertNotEqual(serial.accounts[0].pings, serial.accounts[1].pings, "serial lanes are staggered")
    }

    func testSixAccountsTwoParallelFormTwoMirroredLanesOfThree() {
        // 6 accounts, 2 in parallel → lanes [a0,a1,a2] and [a3,a4,a5]; each lane is
        // the 3-account serial stagger, and lane 2 mirrors lane 1 account-for-account.
        let plan = ScheduleEngine.planDay(forAccountIDs: ids(6), workBlocks: [block(480, 720)], window: w, parallelism: 2)
        let lane = ScheduleEngine.planDay(forAccountIDs: ids(3), workBlocks: [block(480, 720)], window: w)
        XCTAssertEqual(plan.accounts.count, 6)
        for k in 0..<3 {
            XCTAssertEqual(plan.accounts[k].pings, lane.accounts[k].pings, "lane-1 account \(k) mismatch")
            XCTAssertEqual(plan.accounts[k + 3].pings, lane.accounts[k].pings, "lane-2 account \(k) must mirror lane-1")
        }
        // Usage carries the lane index: lane 0 holds a0–a2, lane 1 holds a3–a5.
        XCTAssertEqual(Set(plan.usage.map(\.lane)), [0, 1])
        XCTAssertTrue(plan.usage.filter { $0.lane == 0 }.allSatisfy { ["a0", "a1", "a2"].contains($0.accountID) })
        XCTAssertTrue(plan.usage.filter { $0.lane == 1 }.allSatisfy { ["a3", "a4", "a5"].contains($0.accountID) })
    }

    func testDepthNCoverageEveryWorkMinute() {
        // The headline parallel guarantee: at every work minute, at least N distinct
        // accounts (one per lane) hold a live budget.
        for (total, blocks) in cases {
            for nWanted in 1...total {
                let plan = ScheduleEngine.planDay(forAccountIDs: ids(total), workBlocks: blocks, window: w, parallelism: nWanted)
                let want = min(nWanted, total)
                for b in blocks {
                    for t in b.start..<b.end {
                        let live = plan.accounts.filter { acct in acct.pings.contains { $0.atMin <= t && t < $0.atMin + w } }.count
                        XCTAssertGreaterThanOrEqual(live, want, "total \(total), N \(nWanted): minute \(t) had \(live) live, want ≥ \(want)")
                    }
                }
            }
        }
    }

    func testParallelismClampsIntoRange() {
        // More lanes than accounts → each its own lane; fewer than 1 → one serial
        // lane. Both clamp into 1...count rather than crashing.
        let over = ScheduleEngine.planDay(forAccountIDs: ids(2), workBlocks: [block(480, 720)], window: w, parallelism: 9)
        let exact = ScheduleEngine.planDay(forAccountIDs: ids(2), workBlocks: [block(480, 720)], window: w, parallelism: 2)
        XCTAssertEqual(over.accounts, exact.accounts)

        let under = ScheduleEngine.planDay(forAccountIDs: ids(3), workBlocks: [block(480, 720)], window: w, parallelism: 0)
        let one = ScheduleEngine.planDay(forAccountIDs: ids(3), workBlocks: [block(480, 720)], window: w, parallelism: 1)
        XCTAssertEqual(under.accounts, one.accounts)
        XCTAssertEqual(under.usage, one.usage)
    }

    func testPartitionLanesAreBalancedContiguousAndComplete() {
        XCTAssertEqual(ScheduleEngine.partitionLanes(ids(6), into: 2), [["a0", "a1", "a2"], ["a3", "a4", "a5"]])
        XCTAssertEqual(ScheduleEngine.partitionLanes(ids(6), into: 4), [["a0", "a1"], ["a2", "a3"], ["a4"], ["a5"]])
        XCTAssertEqual(ScheduleEngine.partitionLanes(ids(3), into: 3), [["a0"], ["a1"], ["a2"]])
        // Every id lands in exactly one lane, input order preserved.
        XCTAssertEqual(ScheduleEngine.partitionLanes(ids(7), into: 3).flatMap { $0 }, ids(7))
    }
}
