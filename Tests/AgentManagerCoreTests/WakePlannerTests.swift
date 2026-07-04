import XCTest
import WakeHelperCore

/// The wake helper's pure planning + file readers — the entirety of what the
/// root binary decides, exercised without root or IOKit.
final class WakePlannerTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func testWakeDatesApplyLeadAndDropPastAndBeyondHorizon() {
        let fires = [
            at(-3600),                       // already gone
            at(30),                          // wake would land in the past (30 − 45)
            at(600),                         // → wake at 555
            at(49 * 3600),                   // beyond the 48 h horizon
        ]
        XCTAssertEqual(WakePlanner.wakeDates(forFires: fires, now: t0), [at(600 - 45)])
    }

    func testMinuteDedupeKeepsEarliestWake() {
        // Three parallel accounts on one slot plus a straggler 30 s later —
        // their wakes land in the same minute and must collapse to one.
        let fires = [at(600), at(600), at(630)]
        XCTAssertEqual(WakePlanner.wakeDates(forFires: fires, now: t0), [at(555)])
    }

    func testCapAndOrdering() {
        let manyHourly = (1...40).map { at(TimeInterval($0) * 3600) }.shuffled()
        let wakes = WakePlanner.wakeDates(forFires: manyHourly, now: t0)
        XCTAssertEqual(wakes.count, WakePlanner.defaultCap)
        XCTAssertEqual(wakes, wakes.sorted())
        XCTAssertEqual(wakes.first, at(3600 - 45)) // earliest kept, extras dropped from the tail
    }

    func testPlanGatesOnOptInAndHeartbeat() {
        let fires = [at(600)]
        // Not opted in.
        XCTAssertEqual(WakePlanner.plan(.init(enabled: false, statusUpdatedAt: t0, fires: fires), now: t0), [])
        // No daemon heartbeat at all — nobody would fire the ping we wake for.
        XCTAssertEqual(WakePlanner.plan(.init(enabled: true, statusUpdatedAt: nil, fires: fires), now: t0), [])
        // Heartbeat from a long-dead daemon (9 days) — the queue is fiction.
        XCTAssertEqual(WakePlanner.plan(
            .init(enabled: true, statusUpdatedAt: t0.addingTimeInterval(-9 * 24 * 3600), fires: fires), now: t0), [])
        // Live daemon → wakes.
        XCTAssertEqual(WakePlanner.plan(.init(enabled: true, statusUpdatedAt: t0, fires: fires), now: t0), [at(555)])
    }

    // MARK: - file readers

    func testReadParsesRealWorkspaceFiles() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("am-wake-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try Data(#"{"enabled" : true, "version" : 1}"#.utf8)
            .write(to: tmp.appendingPathComponent("wake.json"))
        // The exact shape SchedulerStatusStore writes (extra fields ignored).
        let status = #"""
        {
          "active" : true,
          "horizonFloor" : "2026-07-02T15:25:31Z",
          "lastHandled" : {},
          "pid" : 123,
          "startedAt" : "2026-07-02T12:36:41Z",
          "upcoming" : [
            { "accountID" : "a1", "fireAt" : "2026-07-03T00:30:00Z" },
            { "accountID" : "a2", "fireAt" : "2026-07-03T00:30:00Z" }
          ],
          "updatedAt" : "2026-07-02T16:05:31Z",
          "version" : 1
        }
        """#
        try Data(status.utf8).write(to: tmp.appendingPathComponent("scheduler-status.json"))

        let iso = ISO8601DateFormatter()
        let snapshot = WakeInputs.read(root: tmp)
        XCTAssertTrue(snapshot.enabled)
        XCTAssertEqual(snapshot.statusUpdatedAt, iso.date(from: "2026-07-02T16:05:31Z"))
        XCTAssertEqual(snapshot.fires, [
            iso.date(from: "2026-07-03T00:30:00Z")!,
            iso.date(from: "2026-07-03T00:30:00Z")!,
        ])
    }

    func testStandardWorkspaceRootsDiscoversPerUserWorkspaces() throws {
        // A fake /Users: two homes with a workspace, one without, plus the
        // usual /Users/Shared noise — only real workspaces come back, sorted.
        let fm = FileManager.default
        let users = fm.temporaryDirectory.appendingPathComponent("am-users-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: users) }
        let suffix = "Library/Application Support/AgentManager"
        try fm.createDirectory(at: users.appendingPathComponent("bob/\(suffix)", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: users.appendingPathComponent("alice/\(suffix)", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: users.appendingPathComponent("Shared", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: users.appendingPathComponent("noagent/Library", isDirectory: true), withIntermediateDirectories: true)

        let roots = WakeInputs.standardWorkspaceRoots(under: users)
        XCTAssertEqual(roots.map(\.lastPathComponent), ["AgentManager", "AgentManager"])
        XCTAssertEqual(roots.map { $0.path.contains("alice") }, [true, false]) // sorted: alice before bob
    }

    func testReadFailsQuiet() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("am-wake-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // Nothing on disk → disabled, no fires.
        XCTAssertEqual(WakeInputs.read(root: tmp), WakeInputs.Snapshot(enabled: false))

        // Disabled short-circuits: the queue isn't even parsed.
        try Data(#"{"enabled" : false}"#.utf8).write(to: tmp.appendingPathComponent("wake.json"))
        try Data("not json".utf8).write(to: tmp.appendingPathComponent("scheduler-status.json"))
        XCTAssertEqual(WakeInputs.read(root: tmp), WakeInputs.Snapshot(enabled: false))

        // Enabled but garbage status → enabled with no fires (plans nothing).
        try Data(#"{"enabled" : true}"#.utf8).write(to: tmp.appendingPathComponent("wake.json"))
        XCTAssertEqual(WakeInputs.read(root: tmp), WakeInputs.Snapshot(enabled: true))
    }
}
