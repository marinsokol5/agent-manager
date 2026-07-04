import XCTest
@testable import AgentManagerCore

/// Launchd plist planning tests, plus `WorkSchedule` store round-trips.
final class LaunchAgentPlannerTests: XCTestCase {
    func scheduleMon(_ hours: [Int]) -> WorkSchedule {
        var s = WorkSchedule()
        s.set(weekday: 0, hours: hours)
        return s
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
        XCTAssertTrue(p.contains("<string>--root</string>"))
        XCTAssertTrue(p.contains("<string>/ws/root</string>"))
        XCTAssertTrue(p.contains("<key>KeepAlive</key>"))
        XCTAssertTrue(p.contains("<key>RunAtLoad</key>"))
        XCTAssertTrue(p.contains("<key>PATH</key><string>/opt/homebrew/bin:/usr/bin</string>"))
        XCTAssertTrue(p.contains("scheduler.out.log"))
        // The resident daemon has no calendar triggers — the queue lives in-process.
        XCTAssertFalse(p.contains("StartCalendarInterval"))
    }

    func testSchedulerPlistOmitsEnvBlockWhenNoEnv() {
        let p = LaunchAgentPlanner.renderSchedulerAgentPlist(
            program: "/usr/local/bin/am", root: "/ws", logDir: "/ws/logs")
        XCTAssertFalse(p.contains("EnvironmentVariables"))
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
