import XCTest
@testable import AgentManagerCore

/// Drives the resident scheduler daemon tick-by-tick with an injected clock and
/// a recording ping runner — no processes spawned, no real time waited. Uses a
/// fixed UTC calendar; 2026-07-06 is a Monday, and the default schedule (Mon
/// 08:00–12:00, one account) plans pings at Mon 05:00 and 10:00.
final class SchedulerDaemonTests: XCTestCase {
    var tmp: URL!
    let fm = FileManager.default

    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date
        init(_ d: Date) { current = d }
        var now: Date {
            get { lock.lock(); defer { lock.unlock() }; return current }
            set { lock.lock(); current = newValue; lock.unlock() }
        }
    }

    final class PingRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [SchedulerDaemon.PingRequest] = []
        func append(_ r: SchedulerDaemon.PingRequest) { lock.lock(); recorded.append(r); lock.unlock() }
        var requests: [SchedulerDaemon.PingRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    }

    final class BridgeRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [TimeInterval] = []
        func append(_ seconds: TimeInterval) { lock.lock(); recorded.append(seconds); lock.unlock() }
        var holds: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return recorded }
    }

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("am-daemon-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: tmp) }

    func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    func seedWorkspace(ids: [String] = ["a1"], hours: [Int] = [8, 9, 10, 11], active: Bool = true) throws -> Workspace {
        let ws = Workspace(root: tmp.appendingPathComponent("ws", isDirectory: true))
        let store = AccountStore(workspace: ws)
        for (i, id) in ids.enumerated() {
            try store.insert(Account(id: id, label: id, provider: .claude, home: ws.managedHome(forAccountID: id).path, rank: i, status: .connected))
        }
        var sched = WorkSchedule()
        sched.set(weekday: 0, hours: hours)
        try ScheduleStore(workspace: ws).save(sched)
        try SchedulerConfigStore(workspace: ws).save(SchedulerConfig(active: active))
        return ws
    }

    func makeDaemon(
        _ ws: Workspace,
        clock: TestClock,
        recorder: PingRecorder,
        bridge: (@Sendable (TimeInterval) -> Void)? = nil,
        outcome: PingOutcome = .anchored,
        cloudSyncer: CloudFallbackSyncer? = nil,
        executablePath: String? = nil)
        -> SchedulerDaemon
    {
        SchedulerDaemon(
            workspace: ws,
            calendar: cal,
            now: { clock.now },
            pingRunner: { recorder.append($0); return outcome },
            // Default to a no-op (not the real caffeinate spawner) so tests
            // stay hermetic even if a scenario wanders into the bridge window.
            wakeBridge: bridge ?? { _ in },
            // Likewise: never construct the live engine in tests.
            cloudSyncer: cloudSyncer ?? { _ in },
            executablePath: executablePath)
    }

    /// Write a fake `am` binary and pin its mtime relative to the test clock
    /// (the daemon's settle check compares file mtime against the injected
    /// clock, so both must live on the same timeline).
    func writeBinary(_ url: URL, contents: String, mtime: Date) throws {
        try Data(contents.utf8).write(to: url)
        try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
    }

    func testFiresDueEntryOnceWithPlannedTime() async throws {
        let ws = try seedWorkspace()
        let clock = TestClock(date(2026, 7, 6, 4, 50)) // Monday, before the 05:00 slot
        let recorder = PingRecorder()
        let daemon = makeDaemon(ws, clock: clock, recorder: recorder)

        let sleep = await daemon.tick()
        XCTAssertTrue(recorder.requests.isEmpty)
        XCTAssertLessThanOrEqual(sleep, 20) // chunked: never past the poll interval

        clock.now = date(2026, 7, 6, 5, 0, 30) // 30s past the slot: due, within grace
        _ = await daemon.tick()
        XCTAssertEqual(recorder.requests, [.init(accountID: "a1", scheduledFor: date(2026, 7, 6, 5, 0))])

        // Same time again: the watermark stops a refire.
        _ = await daemon.tick()
        XCTAssertEqual(recorder.requests.count, 1)

        // The heartbeat file carries the watermark and the next planned fire.
        let status = SchedulerStatusStore(workspace: ws).load()
        XCTAssertEqual(status?.lastHandled["a1"], date(2026, 7, 6, 5, 0))
        XCTAssertEqual(status?.upcoming.first?.fireAt, date(2026, 7, 6, 10, 0))
    }

    func testSleptThroughEntriesAreDroppedAndLoggedOnce() async throws {
        let ws = try seedWorkspace()
        let clock = TestClock(date(2026, 7, 6, 4, 50))
        let recorder = PingRecorder()
        let daemon = makeDaemon(ws, clock: clock, recorder: recorder)
        _ = await daemon.tick()

        clock.now = date(2026, 7, 6, 12, 0) // "woke" hours later: both slots stale
        _ = await daemon.tick()
        XCTAssertTrue(recorder.requests.isEmpty)

        // One grouped skip line per account, not one per missed slot.
        let records = ActivityLog(workspace: ws).readRecent(limit: 10)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].accountID, "a1")
        XCTAssertFalse(records[0].anchored)
        XCTAssertTrue(records[0].detail.contains("2 stale pings"), records[0].detail)

        // The queue moved on to next week.
        let status = SchedulerStatusStore(workspace: ws).load()
        XCTAssertEqual(status?.upcoming.first?.fireAt, date(2026, 7, 13, 5, 0))
    }

    func testInactiveDaemonFiresNothing() async throws {
        let ws = try seedWorkspace(active: false)
        let clock = TestClock(date(2026, 7, 6, 5, 0, 30))
        let recorder = PingRecorder()
        _ = await makeDaemon(ws, clock: clock, recorder: recorder).tick()
        XCTAssertTrue(recorder.requests.isEmpty)

        let status = SchedulerStatusStore(workspace: ws).load()
        XCTAssertEqual(status?.active, false)
        XCTAssertEqual(status?.upcoming, [])
    }

    func testActivatingLateDoesNotFireOrLogPastSlots() async throws {
        let ws = try seedWorkspace(active: false)
        let clock = TestClock(date(2026, 7, 6, 6, 0)) // 05:00 slot already an hour gone
        let recorder = PingRecorder()
        let daemon = makeDaemon(ws, clock: clock, recorder: recorder)
        _ = await daemon.tick()

        try SchedulerConfigStore(workspace: ws).save(SchedulerConfig(active: true))
        clock.now = date(2026, 7, 6, 6, 1)
        _ = await daemon.tick()
        // Turning the scheduler on resets the horizon: the stale 05:00 neither
        // fires nor logs; the still-ahead 10:00 is next.
        XCTAssertTrue(recorder.requests.isEmpty)
        XCTAssertTrue(ActivityLog(workspace: ws).readRecent(limit: 10).isEmpty)
        XCTAssertEqual(SchedulerStatusStore(workspace: ws).load()?.upcoming.first?.fireAt, date(2026, 7, 6, 10, 0))
    }

    func testActivatingWithinGraceFiresTheJustMissedSlot() async throws {
        let ws = try seedWorkspace(active: false)
        let clock = TestClock(date(2026, 7, 6, 4, 0))
        let recorder = PingRecorder()
        let daemon = makeDaemon(ws, clock: clock, recorder: recorder)
        _ = await daemon.tick()

        // The user turns the scheduler on 5 minutes after a planned slot: still
        // worth anchoring (matches the launchd-era grace behavior).
        try SchedulerConfigStore(workspace: ws).save(SchedulerConfig(active: true))
        clock.now = date(2026, 7, 6, 5, 5)
        _ = await daemon.tick()
        XCTAssertEqual(recorder.requests, [.init(accountID: "a1", scheduledFor: date(2026, 7, 6, 5, 0))])
    }

    func testScheduleRepaintRebuildsQueue() async throws {
        let ws = try seedWorkspace()
        let clock = TestClock(date(2026, 7, 6, 3, 0))
        let recorder = PingRecorder()
        let daemon = makeDaemon(ws, clock: clock, recorder: recorder)
        _ = await daemon.tick()
        XCTAssertEqual(SchedulerStatusStore(workspace: ws).load()?.upcoming.first?.fireAt, date(2026, 7, 6, 5, 0))

        // Repaint to the afternoon (Mon 14:00–18:00 → pings 11:00 & 16:00); the
        // daemon notices the file change on its next tick, no poke needed.
        var repainted = WorkSchedule()
        repainted.set(weekday: 0, hours: [14, 15, 16, 17])
        try ScheduleStore(workspace: ws).save(repainted)
        clock.now = date(2026, 7, 6, 3, 5)
        _ = await daemon.tick()
        XCTAssertEqual(SchedulerStatusStore(workspace: ws).load()?.upcoming.first?.fireAt, date(2026, 7, 6, 11, 0))
    }

    func testImminentFireSpawnsWakeBridgeOnce() async throws {
        let ws = try seedWorkspace()
        let clock = TestClock(date(2026, 7, 6, 4, 59, 0)) // 05:00 fire in 60 s
        let recorder = PingRecorder()
        let bridge = BridgeRecorder()
        let daemon = makeDaemon(ws, clock: clock, recorder: recorder, bridge: { bridge.append($0) })

        _ = await daemon.tick()
        // Inside the 90 s window: one assertion for lead (60 s) + tail (60 s).
        XCTAssertEqual(bridge.holds.count, 1)
        XCTAssertEqual(bridge.holds[0], 120, accuracy: 1)

        // Later ticks before the same fire don't re-spawn.
        clock.now = date(2026, 7, 6, 4, 59, 40)
        _ = await daemon.tick()
        XCTAssertEqual(bridge.holds.count, 1)

        // The fire itself drains normally; the next fire (10:00) is far out of
        // the window, so no new bridge.
        clock.now = date(2026, 7, 6, 5, 0, 10)
        _ = await daemon.tick()
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(bridge.holds.count, 1)
    }

    func testRestartDoesNotRefireHandledEntry() async throws {
        let ws = try seedWorkspace()
        let clock = TestClock(date(2026, 7, 6, 5, 0, 30))
        let recorder = PingRecorder()
        _ = await makeDaemon(ws, clock: clock, recorder: recorder).tick() // fires 05:00
        XCTAssertEqual(recorder.requests.count, 1)

        // A KeepAlive relaunch moments later: the persisted watermark holds.
        clock.now = date(2026, 7, 6, 5, 1)
        _ = await makeDaemon(ws, clock: clock, recorder: recorder).tick()
        XCTAssertEqual(recorder.requests.count, 1)
    }

    // MARK: - cloud fallback integration

    final class SyncRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [CloudFallbackSyncRequest] = []
        func append(_ r: CloudFallbackSyncRequest) { lock.lock(); recorded.append(r); lock.unlock() }
        var requests: [CloudFallbackSyncRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    }

    func testCloudCoveredFireSkipsTheLocalPing() async throws {
        // The Mac slept from before 05:00 until 05:06 — past the fire's 05:05
        // cloud backstop, still inside the 15-minute grace. The routine already
        // anchored the window from Anthropic's side; a local ping would be a
        // redundant burned turn.
        let ws = try seedWorkspace()
        try CloudFallbackConfigStore(workspace: ws).save(CloudFallbackConfig(enabled: true))
        var seed = CloudFallbackState()
        seed.accounts["a1"] = AccountCloudFallbackState(
            triggerID: "trig_1", environmentID: "env_1", armedFor: date(2026, 7, 6, 5, 5))
        CloudFallbackStateStore(workspace: ws).save(seed)

        let clock = TestClock(date(2026, 7, 6, 5, 6))
        let recorder = PingRecorder()
        let syncs = SyncRecorder()
        let daemon = makeDaemon(ws, clock: clock, recorder: recorder, cloudSyncer: { syncs.append($0) })
        _ = await daemon.tick()

        XCTAssertTrue(recorder.requests.isEmpty) // no local ping spawned
        let records = ActivityLog(workspace: ws).readRecent(limit: 10)
        XCTAssertEqual(records.count, 1)
        XCTAssertTrue(records[0].anchored) // the cloud anchored it
        XCTAssertTrue(records[0].detail.contains("cloud routine"), records[0].detail)

        // The covered fire counts as anchored, so the post-drain sync may
        // advance the routine to the next fire (10:00 → backstop 10:05).
        XCTAssertEqual(syncs.requests.last?.lastAnchoredFireAt, date(2026, 7, 6, 5, 0))
        XCTAssertEqual(syncs.requests.last?.nextFireAt, date(2026, 7, 6, 10, 0))
    }

    func testCloudBackstopNotDueYetStillPingsLocally() async throws {
        // Awake at 05:00:30 with a backstop armed for 05:05: the local ping
        // runs as normal — covering only kicks in once the armed moment passed.
        let ws = try seedWorkspace()
        try CloudFallbackConfigStore(workspace: ws).save(CloudFallbackConfig(enabled: true))
        var seed = CloudFallbackState()
        seed.accounts["a1"] = AccountCloudFallbackState(
            triggerID: "trig_1", environmentID: "env_1", armedFor: date(2026, 7, 6, 5, 5))
        CloudFallbackStateStore(workspace: ws).save(seed)

        let clock = TestClock(date(2026, 7, 6, 5, 0, 30))
        let recorder = PingRecorder()
        let syncs = SyncRecorder()
        let daemon = makeDaemon(ws, clock: clock, recorder: recorder, cloudSyncer: { syncs.append($0) })
        _ = await daemon.tick()

        XCTAssertEqual(recorder.requests.count, 1)
        // The anchored outcome flows into the sync so the engine can re-arm.
        XCTAssertEqual(syncs.requests.last?.lastAnchoredFireAt, date(2026, 7, 6, 5, 0))
    }

    func testFailedPingWithholdsAnchorSignal() async throws {
        let ws = try seedWorkspace()
        try CloudFallbackConfigStore(workspace: ws).save(CloudFallbackConfig(enabled: true))
        let clock = TestClock(date(2026, 7, 6, 5, 0, 30))
        let recorder = PingRecorder()
        let syncs = SyncRecorder()
        let daemon = makeDaemon(
            ws, clock: clock, recorder: recorder, outcome: .failed,
            cloudSyncer: { syncs.append($0) })
        _ = await daemon.tick()

        XCTAssertEqual(recorder.requests.count, 1)
        // No anchor observed → the engine's planner will hold the backstop.
        XCTAssertNil(syncs.requests.last?.lastAnchoredFireAt)
        XCTAssertEqual(syncs.requests.last?.nextFireAt, date(2026, 7, 6, 10, 0))
    }

    func testFeatureOffSendsDisableSignalForClaudeAccounts() async throws {
        // cloud-fallback.json absent (= disabled): every Claude account still
        // gets a sync with a nil nextFireAt, which is the disable signal — how
        // a routine armed before the toggle flipped off gets cleaned up.
        let ws = try seedWorkspace()
        let clock = TestClock(date(2026, 7, 6, 4, 0))
        let recorder = PingRecorder()
        let syncs = SyncRecorder()
        let daemon = makeDaemon(ws, clock: clock, recorder: recorder, cloudSyncer: { syncs.append($0) })
        _ = await daemon.tick()

        XCTAssertEqual(syncs.requests.count, 1)
        XCTAssertEqual(syncs.requests[0].accountID, "a1")
        XCTAssertNil(syncs.requests[0].nextFireAt)
    }

    // MARK: - self-restart on binary update

    func testUpdatedBinaryRequestsRestartOnceSettled() async throws {
        let ws = try seedWorkspace(active: false)
        let clock = TestClock(date(2026, 7, 6, 4, 0))
        let exe = tmp.appendingPathComponent("am")
        try writeBinary(exe, contents: "v1", mtime: clock.now.addingTimeInterval(-3600))
        let daemon = makeDaemon(ws, clock: clock, recorder: PingRecorder(), executablePath: exe.path)

        _ = await daemon.tick()
        let unchanged = await daemon.wantsRestart
        XCTAssertFalse(unchanged)

        // Rebuilt, but too fresh — could still be mid-copy/codesign.
        try writeBinary(exe, contents: "v2 bigger", mtime: clock.now.addingTimeInterval(-5))
        _ = await daemon.tick()
        let fresh = await daemon.wantsRestart
        XCTAssertFalse(fresh)

        // Same new binary, now settled: exit for the KeepAlive relaunch.
        clock.now = clock.now.addingTimeInterval(60)
        _ = await daemon.tick()
        let settled = await daemon.wantsRestart
        XCTAssertTrue(settled)
        let audit = AuditLog(workspace: ws).readRecent(limit: 10)
        XCTAssertTrue(audit.contains { $0.action == "scheduler.restart" }, "\(audit.map(\.action))")
    }

    func testMissingBinaryNeverRequestsRestart() async throws {
        // Mid-reassembly of the .app bundle the file can vanish briefly;
        // exiting then would relaunch into nothing.
        let ws = try seedWorkspace(active: false)
        let clock = TestClock(date(2026, 7, 6, 4, 0))
        let exe = tmp.appendingPathComponent("am")
        try writeBinary(exe, contents: "v1", mtime: clock.now.addingTimeInterval(-3600))
        let daemon = makeDaemon(ws, clock: clock, recorder: PingRecorder(), executablePath: exe.path)

        try fm.removeItem(at: exe)
        clock.now = clock.now.addingTimeInterval(120)
        _ = await daemon.tick()
        let gone = await daemon.wantsRestart
        XCTAssertFalse(gone)
    }

    func testImminentFireDefersRestartUntilAfterTheFire() async throws {
        let ws = try seedWorkspace()
        let clock = TestClock(date(2026, 7, 6, 4, 59)) // 05:00 fire 60s out
        let recorder = PingRecorder()
        let exe = tmp.appendingPathComponent("am")
        try writeBinary(exe, contents: "v1", mtime: clock.now.addingTimeInterval(-7200))
        let daemon = makeDaemon(ws, clock: clock, recorder: recorder, executablePath: exe.path)
        try writeBinary(exe, contents: "v2 bigger", mtime: clock.now.addingTimeInterval(-3600))

        // Inside the bridge window of the 05:00 fire: hold the restart so it
        // can't race an RTC wake or the due entry.
        _ = await daemon.tick()
        let deferred = await daemon.wantsRestart
        XCTAssertFalse(deferred)
        XCTAssertTrue(recorder.requests.isEmpty)

        // Past the fire: the ping ran first, then the restart is requested.
        clock.now = date(2026, 7, 6, 5, 0, 30)
        _ = await daemon.tick()
        XCTAssertEqual(recorder.requests.count, 1)
        let afterFire = await daemon.wantsRestart
        XCTAssertTrue(afterFire)
    }
}
