import XCTest
@testable import AgentManagerCore

/// `PingQueuePlanner` — weekly `CalEntry` triggers resolved to concrete dates.
/// Uses a fixed UTC gregorian calendar so results don't depend on the machine's
/// timezone. 2026-07-06 is a Monday.
final class PingQueueTests: XCTestCase {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    func monSchedule(_ hours: [Int] = [8, 9, 10, 11]) -> WorkSchedule {
        var s = WorkSchedule()
        s.set(weekday: 0, hours: hours) // Mon 08:00–12:00 by default
        return s
    }

    func testNextOccurrenceSameDayThenWrapsToNextWeek() {
        let monday0430 = CalEntry(weekday: 1, hour: 4, minute: 30)
        // Just after Monday midnight → that same Monday 04:30.
        XCTAssertEqual(
            PingQueuePlanner.nextOccurrence(of: monday0430, after: date(2026, 7, 6), calendar: cal),
            date(2026, 7, 6, 4, 30))
        // After the minute passed → the following Monday.
        XCTAssertEqual(
            PingQueuePlanner.nextOccurrence(of: monday0430, after: date(2026, 7, 6, 5, 0), calendar: cal),
            date(2026, 7, 13, 4, 30))
        // Strictly after: the exact minute itself counts as already passed.
        XCTAssertEqual(
            PingQueuePlanner.nextOccurrence(of: monday0430, after: date(2026, 7, 6, 4, 30), calendar: cal),
            date(2026, 7, 13, 4, 30))
    }

    func testQueueIsSortedAndEachTriggerAppearsOnce() {
        var sched = monSchedule()
        sched.parallelism = 1 // serial stagger: a1 [04:00, 09:00], a2 [05:00, 10:00]
        let queue = PingQueuePlanner.queue(
            accountIDs: ["a1", "a2"], schedule: sched,
            after: date(2026, 7, 5, 12, 0), // Sunday noon
            calendar: cal)
        XCTAssertEqual(queue, [
            QueueEntry(fireAt: date(2026, 7, 6, 4, 0), accountID: "a1"),
            QueueEntry(fireAt: date(2026, 7, 6, 5, 0), accountID: "a2"),
            QueueEntry(fireAt: date(2026, 7, 6, 9, 0), accountID: "a1"),
            QueueEntry(fireAt: date(2026, 7, 6, 10, 0), accountID: "a2"),
        ])
    }

    func testQueueUsesContinuousPlanAcrossMidnight() {
        var schedule = WorkSchedule()
        schedule.set(weekday: 0, hours: [23])
        schedule.set(weekday: 1, hours: [3, 4, 5])
        let queue = PingQueuePlanner.queue(
            accountIDs: ["a"],
            schedule: schedule,
            after: date(2026, 7, 6, 18, 0),
            calendar: cal)

        XCTAssertEqual(queue, [
            QueueEntry(fireAt: date(2026, 7, 6, 19, 0), accountID: "a"),
            QueueEntry(fireAt: date(2026, 7, 7, 0, 0), accountID: "a"),
            QueueEntry(fireAt: date(2026, 7, 7, 5, 0), accountID: "a"),
        ])
        XCTAssertFalse(queue.contains(
            QueueEntry(fireAt: date(2026, 7, 6, 23, 30), accountID: "a")))
    }

    func testSimultaneousFiresKeepAccountPriorityOrder() {
        // Default parallelism (auto = each account its own lane): both accounts
        // plan the identical 05:00/10:00 — the queue must break the tie by the
        // incoming priority order, since the daemon drains sequentially.
        let queue = PingQueuePlanner.queue(
            accountIDs: ["a1", "a2"], schedule: monSchedule(),
            after: date(2026, 7, 5, 12, 0),
            calendar: cal)
        XCTAssertEqual(queue.map(\.accountID), ["a1", "a2", "a1", "a2"])
        XCTAssertEqual(queue[0].fireAt, queue[1].fireAt)
    }

    func testNotBeforeFloorExcludesHandledEntries() {
        var sched = monSchedule()
        sched.parallelism = 1
        let queue = PingQueuePlanner.queue(
            accountIDs: ["a1", "a2"], schedule: sched,
            after: date(2026, 7, 5, 12, 0),
            notBefore: ["a1": date(2026, 7, 6, 4, 0)], // a1's 04:00 already handled
            calendar: cal)
        // a1's 04:00 is gone (its trigger resolves to next week); the rest stand.
        XCTAssertEqual(queue.first, QueueEntry(fireAt: date(2026, 7, 6, 5, 0), accountID: "a2"))
        XCTAssertTrue(queue.contains(QueueEntry(fireAt: date(2026, 7, 6, 9, 0), accountID: "a1")))
        XCTAssertTrue(queue.contains(QueueEntry(fireAt: date(2026, 7, 13, 4, 0), accountID: "a1")))
    }

    func testEmptyScheduleYieldsEmptyQueue() {
        let queue = PingQueuePlanner.queue(
            accountIDs: ["a1"], schedule: WorkSchedule(),
            after: date(2026, 7, 5), calendar: cal)
        XCTAssertTrue(queue.isEmpty)
    }
}
