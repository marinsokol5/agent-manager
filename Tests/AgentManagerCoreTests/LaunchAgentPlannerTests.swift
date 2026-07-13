import XCTest
@testable import AgentManagerCore

/// Launchd plist planning tests, plus `WorkSchedule` store round-trips.
final class LaunchAgentPlannerTests: XCTestCase {
    let minutesPerWeek = 7 * 24 * 60

    func scheduleMon(_ hours: [Int]) -> WorkSchedule {
        var s = WorkSchedule()
        s.set(weekday: 0, hours: hours)
        return s
    }

    func weekMinute(_ entry: CalEntry) -> Int {
        let weekdayMon0 = (entry.weekday + 6) % 7
        return weekdayMon0 * 1440 + entry.hour * 60 + entry.minute
    }

    func assertPhysicalAndCovered(
        _ entries: [CalEntry],
        schedule: WorkSchedule,
        file: StaticString = #filePath,
        line: UInt = #line)
    {
        let anchors = entries.map(weekMinute).sorted()
        XCTAssertFalse(anchors.isEmpty, file: file, line: line)
        for pair in zip(anchors, anchors.dropFirst()) {
            XCTAssertGreaterThanOrEqual(
                pair.1 - pair.0, schedule.windowMinutes,
                "anchors \(anchors)", file: file, line: line)
        }
        if let first = anchors.first, let last = anchors.last {
            XCTAssertGreaterThanOrEqual(
                first + minutesPerWeek - last, schedule.windowMinutes,
                "weekly seam: anchors \(anchors)", file: file, line: line)
        }

        for weekday in 0..<7 {
            for hour in schedule.hours(forWeekday: weekday) {
                for minute in (weekday * 1440 + hour * 60)..<(weekday * 1440 + (hour + 1) * 60) {
                    XCTAssertTrue(
                        anchors.contains {
                            (minute - $0 + minutesPerWeek) % minutesPerWeek
                                < schedule.windowMinutes
                        },
                        "work minute \(minute) uncovered by \(anchors)",
                        file: file,
                        line: line)
                }
            }
        }
    }

    // MARK: - weekday/time mapping

    func testWeekdayAndTimeMapping() {
        // Monday (mon0=0) at 04:30 → launchd Monday(1), 04:30, same day.
        XCTAssertEqual(LaunchAgentPlanner.toCalEntry(weekdayMon0: 0, atMin: 270),
                       CalEntry(weekday: 1, hour: 4, minute: 30))
    }

    func testNegativePrePingRollsToPreviousDay() {
        // Monday work, pre-ping at -90 (22:30 the night before) → Sunday(0), 22:30.
        XCTAssertEqual(LaunchAgentPlanner.toCalEntry(weekdayMon0: 0, atMin: -90),
                       CalEntry(weekday: 0, hour: 22, minute: 30))
        // Sunday (mon0=6) pre-ping rolling back → Saturday(6).
        XCTAssertEqual(LaunchAgentPlanner.toCalEntry(weekdayMon0: 6, atMin: -30).weekday, 6)
    }

    func testEntriesMatchEngineForAWeekday() {
        let schedule = scheduleMon([8, 9, 10, 11, 12, 13, 14, 15]) // Mon 08:00–16:00
        let entries = LaunchAgentPlanner.entries(forAccountID: "c", accountIDs: ["c"], schedule: schedule)
        // 04:30, 09:30, 14:30 — all Monday(1).
        XCTAssertEqual(entries, [
            CalEntry(weekday: 1, hour: 4, minute: 30),
            CalEntry(weekday: 1, hour: 9, minute: 30),
            CalEntry(weekday: 1, hour: 14, minute: 30),
        ])
    }

    func testAdjacentWeekdaysRephaseOnOneContinuousTimeline() {
        // The midnight field report: Monday's 21:00 anchor is live until Tuesday
        // 02:00, so Tuesday's independently-derived Monday 23:30 pre-ping would
        // be phantom. Planning the two columns together rephases the chain to
        // three real windows: Monday 19:00, Tuesday 00:00, Tuesday 05:00.
        var schedule = WorkSchedule()
        schedule.set(weekday: 0, hours: [23])
        schedule.set(weekday: 1, hours: [3, 4, 5])
        let ids = ["a1", "a2", "a3"] // default = three fully parallel lanes
        let expected = [
            CalEntry(weekday: 1, hour: 19, minute: 0),
            CalEntry(weekday: 2, hour: 0, minute: 0),
            CalEntry(weekday: 2, hour: 5, minute: 0),
        ]

        for id in ids {
            let entries = LaunchAgentPlanner.entries(
                forAccountID: id, accountIDs: ids, schedule: schedule)
            XCTAssertEqual(entries, expected, id)
            XCTAssertFalse(entries.contains(
                CalEntry(weekday: 1, hour: 23, minute: 30)), id)
            assertPhysicalAndCovered(entries, schedule: schedule)
        }
    }

    func testSundayToMondayUsesTheSameContinuousWeekInvariant() {
        var schedule = WorkSchedule()
        schedule.set(weekday: 6, hours: [23])
        schedule.set(weekday: 0, hours: [3, 4, 5])
        let entries = LaunchAgentPlanner.entries(
            forAccountID: "a", accountIDs: ["a"], schedule: schedule)

        // Returned in canonical trigger order (Monday → Sunday); cyclically this
        // is Sunday 19:00 → Monday 00:00 → Monday 05:00.
        XCTAssertEqual(entries, [
            CalEntry(weekday: 1, hour: 0, minute: 0),
            CalEntry(weekday: 1, hour: 5, minute: 0),
            CalEntry(weekday: 0, hour: 19, minute: 0),
        ])
        assertPhysicalAndCovered(entries, schedule: schedule)
    }

    func testPhysicalCoverageHoldsAcrossEveryWeekdayBoundary() {
        for weekday in 0..<7 {
            var schedule = WorkSchedule()
            schedule.set(weekday: weekday, hours: [23])
            schedule.set(weekday: (weekday + 1) % 7, hours: [3, 4, 5])
            let entries = LaunchAgentPlanner.entries(
                forAccountID: "a", accountIDs: ["a"], schedule: schedule)
            XCTAssertEqual(entries.count, 3, "boundary after weekday \(weekday)")
            assertPhysicalAndCovered(entries, schedule: schedule)
        }
    }

    func testDenseWeekWithoutAnIndependentSeamStaysPhysicalAndCovered() {
        // Fifteen painted hours followed by nine off-hours every day: the gap is
        // shorter than the planner's proof-safe 9h58m seam, so weekly planning
        // must use repeated context instead of silently resetting each column.
        var schedule = WorkSchedule()
        for weekday in 0..<7 {
            schedule.set(weekday: weekday, hours: Array(0..<15))
        }
        let entries = LaunchAgentPlanner.entries(
            forAccountID: "a", accountIDs: ["a"], schedule: schedule)
        assertPhysicalAndCovered(entries, schedule: schedule)
    }

    // MARK: - display projection (coverage screen / am plan)

    func testDisplayPlanMatchesPerDayEngineWhenDaysAreIndependent() {
        // Ordinary schedules (overnight gaps beyond the seam threshold) must
        // render exactly as the per-day engine always has — pings and usage.
        var schedule = scheduleMon([8, 9, 10, 11])
        schedule.parallelism = 1
        let ids = ["a1", "a2"]
        let weekly = LaunchAgentPlanner.weeklyPings(accountIDs: ids, schedule: schedule)
        let projected = LaunchAgentPlanner.displayPlan(forWeekday: 0, weekly: weekly, schedule: schedule)
        let direct = ScheduleEngine.planDay(
            forAccountIDs: ids, workBlocks: schedule.blocks(forWeekday: 0),
            window: schedule.windowMinutes,
            parallelism: schedule.resolvedParallelism(accountCount: ids.count),
            minSlice: schedule.resolvedMinSliceMinutes)
        XCTAssertEqual(projected.accounts, direct.accounts)
        XCTAssertEqual(projected.usage, direct.usage)

        for weekday in 1..<7 {
            let empty = LaunchAgentPlanner.displayPlan(forWeekday: weekday, weekly: weekly, schedule: schedule)
            XCTAssertTrue(empty.accounts.allSatisfy(\.pings.isEmpty), "weekday \(weekday)")
            XCTAssertTrue(empty.usage.isEmpty, "weekday \(weekday)")
        }
    }

    func testDisplayPlanKeepsMaxMinRephaseForSeparatedBlocks() {
        // Coverage-screen reproduction: Thu 10:00–12:00 + 13:00–16:00 must
        // project the same balanced two-window phase as ScheduleEngine, not the
        // old block-local 06:00/11:00 split.
        var schedule = WorkSchedule()
        schedule.set(weekday: 3, hours: [10, 11, 13, 14, 15])
        let weekly = LaunchAgentPlanner.weeklyPings(
            accountIDs: ["claude"], schedule: schedule)
        let projected = LaunchAgentPlanner.displayPlan(
            forWeekday: 3, weekly: weekly, schedule: schedule)

        XCTAssertEqual(
            projected.accounts.first?.pings.map(\.atMin),
            [510, 810]) // 08:30, 13:30
    }

    func testDisplayPlanShowsOnlyFirableAnchorsAcrossMidnight() {
        // The daemon fires Mon 19:00 / Tue 00:00 / Tue 05:00 for this shape.
        // The coverage screen must show exactly those, each on the day whose
        // work its window covers — never the phantom per-day 23:30 pre-ping.
        var schedule = WorkSchedule()
        schedule.set(weekday: 0, hours: [23])
        schedule.set(weekday: 1, hours: [3, 4, 5])
        let weekly = LaunchAgentPlanner.weeklyPings(accountIDs: ["a"], schedule: schedule)

        let monday = LaunchAgentPlanner.displayPlan(forWeekday: 0, weekly: weekly, schedule: schedule)
        XCTAssertEqual(monday.accounts.first?.pings.map(\.atMin), [1140]) // 19:00
        XCTAssertEqual(monday.usage, [
            UsageSegment(accountID: "a", batchIndex: 1, startMin: 1380, endMin: 1440),
        ])

        let tuesday = LaunchAgentPlanner.displayPlan(forWeekday: 1, weekly: weekly, schedule: schedule)
        XCTAssertEqual(tuesday.accounts.first?.pings.map(\.atMin), [0, 300]) // 00:00, 05:00
        XCTAssertEqual(tuesday.usage, [
            UsageSegment(accountID: "a", batchIndex: 1, startMin: 180, endMin: 300),
            UsageSegment(accountID: "a", batchIndex: 2, startMin: 300, endMin: 360),
        ])
    }

    func testDisplayPlanProjectsTheSundayWrapOntoMonday() {
        var schedule = WorkSchedule()
        schedule.set(weekday: 6, hours: [23])
        schedule.set(weekday: 0, hours: [3, 4, 5])
        let weekly = LaunchAgentPlanner.weeklyPings(accountIDs: ["a"], schedule: schedule)
        XCTAssertEqual(
            LaunchAgentPlanner.displayPlan(forWeekday: 6, weekly: weekly, schedule: schedule)
                .accounts.first?.pings.map(\.atMin), [1140]) // Sun 19:00
        XCTAssertEqual(
            LaunchAgentPlanner.displayPlan(forWeekday: 0, weekly: weekly, schedule: schedule)
                .accounts.first?.pings.map(\.atMin), [0, 300]) // Mon 00:00, 05:00
    }

    func testDisplayPlanShowsAWindowSpanningMidnightWorkOnBothDays() {
        // Mon 23:00–24:00 + Tue 00:00–01:00 is one continuous block; at a
        // 90-minute floor it earns a single centred window (21:30–02:30)
        // covering work on both sides of midnight — so both days show the same
        // anchor: Monday as 21:30, Tuesday as 21:30 (−1d).
        var schedule = WorkSchedule()
        schedule.set(weekday: 0, hours: [23])
        schedule.set(weekday: 1, hours: [0])
        schedule.minSliceMinutes = 90
        let weekly = LaunchAgentPlanner.weeklyPings(accountIDs: ["a"], schedule: schedule)
        XCTAssertEqual(
            LaunchAgentPlanner.displayPlan(forWeekday: 0, weekly: weekly, schedule: schedule)
                .accounts.first?.pings.map(\.atMin), [1290])
        XCTAssertEqual(
            LaunchAgentPlanner.displayPlan(forWeekday: 1, weekly: weekly, schedule: schedule)
                .accounts.first?.pings.map(\.atMin), [-150])
    }

    func testEntriesAreStaggeredPerAccount() {
        var schedule = scheduleMon([8, 9, 10, 11]) // Mon 08:00-12:00
        schedule.parallelism = 1                    // serial: one lane of both accounts
        let ids = ["a1", "a2"]
        XCTAssertEqual(LaunchAgentPlanner.entries(forAccountID: "a1", accountIDs: ids, schedule: schedule), [
            CalEntry(weekday: 1, hour: 4, minute: 0),
            CalEntry(weekday: 1, hour: 9, minute: 0),
        ])
        XCTAssertEqual(LaunchAgentPlanner.entries(forAccountID: "a2", accountIDs: ids, schedule: schedule), [
            CalEntry(weekday: 1, hour: 5, minute: 0),
            CalEntry(weekday: 1, hour: 10, minute: 0),
        ])
    }

    func testEntriesFullyParallelFireTogether() {
        // Default (parallelism nil → auto = all accounts in parallel): each account
        // is its own lane, so both fire at the single-account optimal 05:00/10:00 —
        // no stagger, unlike `testEntriesAreStaggeredPerAccount`.
        let schedule = scheduleMon([8, 9, 10, 11]) // parallelism nil → 2 lanes
        let ids = ["a1", "a2"]
        let e1 = LaunchAgentPlanner.entries(forAccountID: "a1", accountIDs: ids, schedule: schedule)
        let e2 = LaunchAgentPlanner.entries(forAccountID: "a2", accountIDs: ids, schedule: schedule)
        XCTAssertEqual(e1, [CalEntry(weekday: 1, hour: 5, minute: 0), CalEntry(weekday: 1, hour: 10, minute: 0)])
        XCTAssertEqual(e1, e2)
    }

    // MARK: - the scheduler agent plist

    func testSchedulerPlistBakesDaemonArgsAndKeepAlive() {
        let p = LaunchAgentPlanner.renderSchedulerAgentPlist(
            program: "/usr/local/bin/am",
            root: "/ws/root",
            logDir: "/ws/root/logs",
            environment: ["PATH": "/opt/homebrew/bin:/usr/bin"])
        XCTAssertTrue(p.contains("<string>\(LaunchAgentPlanner.schedulerLabel)</string>"))
        XCTAssertTrue(p.contains("<string>/usr/local/bin/am</string>"))
        XCTAssertTrue(p.contains("<string>scheduler</string>"))
        XCTAssertTrue(p.contains("<string>run</string>"))
        // The workspace root travels as env, never as an argument — `am` owns
        // no flags, so `am run` passthrough stays verbatim.
        XCTAssertFalse(p.contains("--root"))
        XCTAssertTrue(p.contains("<key>AGENT_MANAGER_ROOT</key><string>/ws/root</string>"))
        XCTAssertTrue(p.contains("<key>KeepAlive</key>"))
        XCTAssertTrue(p.contains("<key>RunAtLoad</key>"))
        XCTAssertTrue(p.contains("<key>PATH</key><string>/opt/homebrew/bin:/usr/bin</string>"))
        XCTAssertTrue(p.contains("scheduler.out.log"))
        // The resident daemon has no calendar triggers — the queue lives in-process.
        XCTAssertFalse(p.contains("StartCalendarInterval"))
    }

    func testSchedulerPlistBakesRootEvenWithNoOtherEnv() {
        let p = LaunchAgentPlanner.renderSchedulerAgentPlist(
            program: "/usr/local/bin/am", root: "/ws", logDir: "/ws/logs")
        XCTAssertTrue(p.contains("<key>EnvironmentVariables</key>"))
        XCTAssertTrue(p.contains("<key>AGENT_MANAGER_ROOT</key><string>/ws</string>"))
    }

    /// The no-notification invariant depends on the rendering being a pure
    /// function of its inputs — identical inputs must render identical bytes.
    func testSchedulerPlistIsByteStableAcrossRenders() {
        let render = {
            LaunchAgentPlanner.renderSchedulerAgentPlist(
                program: "/usr/local/bin/am", root: "/ws", logDir: "/ws/logs",
                environment: ["PATH": "/usr/bin", "SHELL": "/bin/zsh", "HOME": "/Users/x"])
        }
        XCTAssertEqual(render(), render())
    }

    // MARK: - WorkSchedule store + helpers

    func testScheduleStoreRoundTrips() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("am-sched-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = ScheduleStore(workspace: Workspace(root: tmp))

        // Empty when nothing saved yet.
        XCTAssertEqual(try store.load().totalSelectedHours, 0)

        var s = WorkSchedule()
        s.set(weekday: 0, hours: [8, 9, 10, 11, 12, 13, 14, 15])
        s.copyMondayToWeekdays()
        try store.save(s)

        let back = try store.load()
        XCTAssertEqual(back.hours(forWeekday: 0), [8, 9, 10, 11, 12, 13, 14, 15])
        XCTAssertEqual(back.hours(forWeekday: 4), [8, 9, 10, 11, 12, 13, 14, 15]) // Fri
        XCTAssertEqual(back.hours(forWeekday: 5), []) // Sat untouched
        XCTAssertEqual(back.windowMinutes, defaultWindowMinutes)
    }

    func testToggleAndClear() {
        var s = WorkSchedule()
        s.toggle(weekday: 0, hour: 9)
        s.toggle(weekday: 0, hour: 8)
        s.toggle(weekday: 0, hour: 9) // off again
        XCTAssertEqual(s.hours(forWeekday: 0), [8])
        s.clearAll()
        XCTAssertEqual(s.totalSelectedHours, 0)
    }

    // MARK: - parallelism preference

    func testResolvedParallelismDefaultsToAllAccounts() {
        var s = WorkSchedule()
        XCTAssertNil(s.parallelism)
        XCTAssertEqual(s.resolvedParallelism(accountCount: 4), 4) // auto = max
        XCTAssertEqual(s.resolvedParallelism(accountCount: 0), 1) // always ≥ 1 lane
        s.parallelism = 2
        XCTAssertEqual(s.resolvedParallelism(accountCount: 4), 2)
        XCTAssertEqual(s.resolvedParallelism(accountCount: 1), 1) // clamp down to accounts
        s.parallelism = 0
        XCTAssertEqual(s.resolvedParallelism(accountCount: 3), 1) // clamp up to ≥ 1
    }

    func testParallelismPersistsAndOldFilesDefaultToAuto() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("am-par-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = ScheduleStore(workspace: Workspace(root: tmp))

        var s = WorkSchedule()
        s.set(weekday: 0, hours: [8, 9, 10, 11])
        s.parallelism = 2
        try store.save(s)
        XCTAssertEqual(try store.load().parallelism, 2)

        // A pre-parallelism file (no key) decodes to nil = auto.
        let legacy = #"{"version":1,"windowMinutes":300,"hoursByWeekday":[[],[],[],[],[],[],[]]}"#
        let decoded = try JSONDecoder().decode(WorkSchedule.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.parallelism)
        XCTAssertEqual(decoded.resolvedParallelism(accountCount: 3), 3)
    }
}
