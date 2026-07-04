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
                XCTAssertGreaterThanOrEqual(u.endMin - u.startMin, minUsageSegmentMinutes,
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
        let m = minUsageSegmentMinutes
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
        let raw = usageWithMin(3, [block(480, 540)], w, 1)
        XCTAssertTrue(raw.contains { $0.endMin - $0.startMin < minUsageSegmentMinutes })

        let floored = ScheduleEngine.planDay(forAccountIDs: ids(3), workBlocks: [block(480, 540)], window: w).usage
        XCTAssertEqual(floored.count, 2, "1h / 30min floor → two segments")
        XCTAssertTrue(floored.allSatisfy { $0.endMin - $0.startMin >= minUsageSegmentMinutes })
        XCTAssertEqual(floored.first?.startMin, 480)
        XCTAssertEqual(floored.last?.endMin, 540)
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
