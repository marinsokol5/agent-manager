import XCTest
@testable import AgentManagerCore

/// The "first ping of the day only" planner mode
/// (`WorkSchedule.firstPingOfDayOnly`): `LaunchAgentPlanner.weeklyPings` keeps
/// only each account's earliest anchor per *workday* — a day defined by the
/// painted work a ping serves, not by the calendar date it fires on.
final class FirstPingOfDayTests: XCTestCase {
    let day = 1440

    func weekly(_ schedule: WorkSchedule, ids: [String] = ["a"], firstOnly: Bool) -> [String: [Int]] {
        var s = schedule
        s.firstPingOfDayOnly = firstOnly ? true : nil
        return LaunchAgentPlanner.weeklyPings(accountIDs: ids, schedule: s)
            .reduce(into: [:]) { $0[$1.accountID] = $1.pings.map(\.atMin) }
    }

    func weekdays9to18() -> WorkSchedule {
        var s = WorkSchedule()
        for d in 0..<5 { s.set(weekday: d, hours: Array(9..<18)) }
        return s
    }

    /// The mode only ever *drops* pings: what survives is a subset of today's
    /// plan, so the engine's placement is untouched.
    func assertSubset(_ on: [String: [Int]], of off: [String: [Int]], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Set(on.keys), Set(off.keys), file: file, line: line)
        for (id, pings) in on {
            XCTAssertTrue(Set(pings).isSubset(of: Set(off[id] ?? [])), "\(id): \(pings) ⊄ \(off[id] ?? [])", file: file, line: line)
        }
    }

    func testTypicalWorkweekKeepsOnlyEachDaysEarliestPing() {
        let schedule = weekdays9to18()
        let off = weekly(schedule, firstOnly: false)["a"]!
        let on = weekly(schedule, firstOnly: true)["a"]!
        XCTAssertEqual(off.count, 15) // pre-ping + two top-ups, Mon–Fri
        XCTAssertEqual(on.count, 5)
        for d in 0..<5 {
            let earliest = off.filter { $0 >= d * day && $0 < (d + 1) * day }.min()
            XCTAssertEqual(on[d], earliest, "weekday \(d)")
        }
        XCTAssertEqual(on, [360, 1800, 3240, 4680, 6120]) // 06:00 each day
    }

    func testPreviousEveningPrePingIsTheMorningsFirstPing() {
        // Monday work from midnight to 08:00 needs a Sunday-evening pre-ping
        // (canonical minute near the end of the week). It is Monday's first
        // ping even though Monday's own 01:30 anchor has a smaller minute.
        var schedule = WorkSchedule()
        schedule.set(weekday: 0, hours: Array(0..<8))
        schedule.set(weekday: 2, hours: Array(9..<18))
        let off = weekly(schedule, firstOnly: false)["a"]!
        let on = weekly(schedule, firstOnly: true)["a"]!
        XCTAssertEqual(off, [90, 390, 3240, 3540, 3840, 9870])
        XCTAssertEqual(on, [3240, 9870]) // Sun 20:30 (for Mon), Wed 06:00
    }

    func testMidnightCrossingSessionBelongsToTheDayItStarted() {
        // Mon 22:00–Tue 02:00, then Tue 09:00–18:00. Tuesday 00:00 is a top-up
        // of Monday's session, not Tuesday's first ping.
        var schedule = WorkSchedule()
        schedule.set(weekday: 0, hours: [22, 23])
        schedule.set(weekday: 1, hours: [0, 1] + Array(9..<18))
        XCTAssertEqual(weekly(schedule, firstOnly: false)["a"], [1140, 1440, 1800, 2100, 2400])
        XCTAssertEqual(weekly(schedule, firstOnly: true)["a"], [1140, 1800]) // Mon 19:00, Tue 06:00
    }

    func testSundayToMondaySeamSessionBelongsToSunday() {
        // Sun 22:00–Mon 02:00 wraps the weekly seam; Monday 00:00 belongs to
        // Sunday's session and Monday 09:00–18:00 gets its own first ping.
        var schedule = WorkSchedule()
        schedule.set(weekday: 6, hours: [22, 23])
        schedule.set(weekday: 0, hours: [0, 1] + Array(9..<18))
        XCTAssertEqual(weekly(schedule, firstOnly: false)["a"], [0, 360, 660, 960, 9780])
        XCTAssertEqual(weekly(schedule, firstOnly: true)["a"], [360, 9780]) // Mon 06:00, Sun 19:00
    }

    func testLunchSplitDayIsOneWorkday() {
        var schedule = WorkSchedule()
        schedule.set(weekday: 0, hours: [9, 10, 11, 13, 14, 15, 16, 17])
        XCTAssertEqual(weekly(schedule, firstOnly: false)["a"], [360, 660, 960])
        XCTAssertEqual(weekly(schedule, firstOnly: true)["a"], [360])
    }

    func testEveryAccountKeepsItsOwnFirstPingWhenLanesRotate() {
        var schedule = weekdays9to18()
        schedule.parallelism = 1 // three accounts serially rotated in one lane
        let ids = ["a", "b", "c"]
        let off = weekly(schedule, ids: ids, firstOnly: false)
        let on = weekly(schedule, ids: ids, firstOnly: true)
        assertSubset(on, of: off)
        for id in ids {
            XCTAssertEqual(on[id]?.count, 5, id)
            for d in 0..<5 {
                let earliest = off[id]!.filter { $0 >= d * day && $0 < (d + 1) * day }.min()
                XCTAssertEqual(on[id]?[d], earliest, "\(id) weekday \(d)")
            }
        }
    }

    func testOffIsExactlyTodaysPlan() {
        var lunch = WorkSchedule()
        lunch.set(weekday: 0, hours: [9, 10, 11, 13, 14, 15, 16, 17])
        var serial = weekdays9to18()
        serial.parallelism = 1
        for schedule in [weekdays9to18(), lunch, serial] {
            let ids = ["a", "b"]
            var explicitFalse = schedule
            explicitFalse.firstPingOfDayOnly = false
            let baseline = LaunchAgentPlanner.weeklyPings(accountIDs: ids, schedule: schedule)
            XCTAssertNil(schedule.firstPingOfDayOnly)
            XCTAssertEqual(LaunchAgentPlanner.weeklyPings(accountIDs: ids, schedule: explicitFalse), baseline)
        }
    }

    func testAroundTheClockWeekKeepsOnePingPerCalendarDay() {
        // No session start anywhere: the week is cut into plain calendar days
        // rather than collapsing to one ping per week.
        var schedule = WorkSchedule()
        for d in 0..<7 { schedule.set(weekday: d, hours: Array(0..<24)) }
        let off = weekly(schedule, firstOnly: false)["a"]!
        let on = weekly(schedule, firstOnly: true)["a"]!
        XCTAssertEqual(on.count, 7)
        XCTAssertEqual(on.map { $0 / day }, Array(0..<7))
        for d in 0..<7 {
            XCTAssertEqual(on[d], off.filter { $0 / day == d }.min())
        }
    }

    func testFilterOnRawAnchorsFollowsSessionsNotCalendarDays() {
        // Direct check of the rule: Mon 09–12, Mon 13–18 (lunch) and
        // Mon 22:00–Tue 02:00 all *start* on Monday, so the three sessions
        // share one workday — even the Tuesday 01:00 anchor inside the last.
        let blocks = [
            Block(start: 540, end: 720), Block(start: 780, end: 1080),
            Block(start: 1320, end: 1560),
        ]
        let week = 7 * day
        XCTAssertEqual(
            LaunchAgentPlanner.firstAnchorPerWorkday(
                [360, 660, 1200, 1500], workBlocks: blocks, period: week),
            [360])
        // A session starting Tuesday is its own workday, and its pre-ping on
        // Monday evening (after Monday's last session ends) belongs to it.
        let twoDays = [Block(start: 540, end: 1080), Block(start: 1500, end: 1800)]
        XCTAssertEqual(
            LaunchAgentPlanner.firstAnchorPerWorkday(
                [360, 660, 1260, 1560], workBlocks: twoDays, period: week),
            [360, 1260])
    }

    // MARK: - persistence

    func testOldJSONWithoutKeyDecodesAsOff() throws {
        let json = #"{"version":1,"windowMinutes":300,"hoursByWeekday":[[8,9],[],[],[],[],[],[]]}"#
        let s = try JSONDecoder().decode(WorkSchedule.self, from: Data(json.utf8))
        XCTAssertNil(s.firstPingOfDayOnly)
        XCTAssertFalse(s.keepsOnlyFirstPingOfDay)
    }

    func testEncodingOmitsKeyWhenOffAndRoundTripsWhenOn() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("am-first-ping-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("schedule.json")
        let store = ScheduleStore(fileURL: file)

        var s = WorkSchedule()
        s.set(weekday: 0, hours: [9, 10])
        try store.save(s)
        let untouched = try Data(contentsOf: file)
        XCTAssertFalse(String(decoding: untouched, as: UTF8.self).contains("firstPingOfDayOnly"))

        s.firstPingOfDayOnly = true
        try store.save(s)
        XCTAssertTrue(try store.load().keepsOnlyFirstPingOfDay)

        // Turning it off stores nil again: byte-identical to the untouched file.
        s.firstPingOfDayOnly = nil
        try store.save(s)
        XCTAssertEqual(try Data(contentsOf: file), untouched)
    }
}
