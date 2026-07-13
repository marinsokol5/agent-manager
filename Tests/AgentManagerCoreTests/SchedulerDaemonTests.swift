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
        cloudUsageReader: SchedulerDaemon.CloudUsageReader? = nil,
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
            cloudUsageReader: cloudUsageReader ?? { _ in nil },
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

        // The heartbeat file carries the watermark and the next fire — which
        // the anchor we just observed *defers*: a ping anchoring at 05:00:30
        // holds the window open to 10:00:30, so the nominal 10:00 re-ping
        // would land inside it (a phantom). It runs at 10:01:30 instead
        // (expiry + the one-minute margin), keeping its nominal identity.
        let status = SchedulerStatusStore(workspace: ws).load()
        XCTAssertEqual(status?.lastHandled["a1"], date(2026, 7, 6, 5, 0))
        XCTAssertEqual(status?.upcoming.first?.fireAt, date(2026, 7, 6, 10, 1, 30))
        XCTAssertEqual(status?.upcoming.first?.plannedAt, date(2026, 7, 6, 10, 0))
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
        // advance the routine to the next fire — which the cloud anchor
        // *defers*: the routine's known 05:05 armed moment makes the window
        // expire at 10:05; detection time must not add artificial drift. So
        // the nominal 10:00 re-ping would be a guaranteed phantom. It fires
        // at 10:06 (expiry + margin), and the backstop follows it.
        XCTAssertEqual(syncs.requests.last?.lastAnchoredFireAt, date(2026, 7, 6, 5, 0))
        XCTAssertEqual(syncs.requests.last?.nextFireAt, date(2026, 7, 6, 10, 6))
    }

    func testCloudUsageResetTightensACloudFireDetectedHoursLate() async throws {
        // The Mac comes back two hours after the 05:05 one-shot. Detection
        // time + window would pretend the window lasts until noon and swallow
        // the useful 10:00 re-anchor; exact usage says it really resets 10:05.
        let ws = try seedWorkspace()
        try CloudFallbackConfigStore(workspace: ws).save(CloudFallbackConfig(enabled: true))
        var seed = CloudFallbackState()
        seed.accounts["a1"] = AccountCloudFallbackState(
            triggerID: "trig_1", environmentID: "env_1", armedFor: date(2026, 7, 6, 5, 5))
        CloudFallbackStateStore(workspace: ws).save(seed)

        let clock = TestClock(date(2026, 7, 6, 7, 0))
        let recorder = PingRecorder()
        let exact = UsageReading(
            primaryUsedPercent: 1,
            primaryResetsAt: date(2026, 7, 6, 10, 5),
            secondaryUsedPercent: nil,
            secondaryResetsAt: nil,
            fetchedAt: clock.now)
        let daemon = makeDaemon(
            ws, clock: clock, recorder: recorder,
            cloudUsageReader: { _ in exact })

        _ = await daemon.tick()

        XCTAssertTrue(recorder.requests.isEmpty)
        let status = SchedulerStatusStore(workspace: ws).load()
        XCTAssertEqual(status?.windowStates?["a1"]?.evidence, .usage)
        XCTAssertEqual(status?.windowStates?["a1"]?.expiresAt, date(2026, 7, 6, 10, 5))
        XCTAssertEqual(status?.upcoming.first?.fireAt, date(2026, 7, 6, 10, 6))
        XCTAssertEqual(status?.upcoming.first?.plannedAt, date(2026, 7, 6, 10, 0))
    }

    func testCloudFireWithoutUsageStillUsesItsArmedTimeNotDetectionTime() async throws {
        // The Mac notices the 05:05 one-shot two hours late and the read-only
        // usage probe fails. The event time is still known from `armedFor`:
        // falling back to 07:00 + 5h would waste the useful 10:00 boundary.
        let ws = try seedWorkspace()
        try CloudFallbackConfigStore(workspace: ws).save(CloudFallbackConfig(enabled: true))
        var seed = CloudFallbackState()
        seed.accounts["a1"] = AccountCloudFallbackState(
            triggerID: "trig_1", environmentID: "env_1", armedFor: date(2026, 7, 6, 5, 5))
        CloudFallbackStateStore(workspace: ws).save(seed)

        let clock = TestClock(date(2026, 7, 6, 7, 0))
        let recorder = PingRecorder()
        let daemon = makeDaemon(ws, clock: clock, recorder: recorder)

        _ = await daemon.tick()

        XCTAssertTrue(recorder.requests.isEmpty)
        let status = SchedulerStatusStore(workspace: ws).load()
        XCTAssertEqual(status?.windowStates?["a1"]?.evidence, .conservative)
        XCTAssertEqual(status?.windowStates?["a1"]?.expiresAt, date(2026, 7, 6, 10, 5))
        XCTAssertEqual(status?.upcoming.first?.fireAt, date(2026, 7, 6, 10, 6))
        XCTAssertEqual(status?.upcoming.first?.plannedAt, date(2026, 7, 6, 10, 0))
    }

    func testLaterExactWindowSupersedesCloudArmedTimeFallback() async throws {
        // While the Mac slept, another real use anchored at 07:00 after the
        // 05:05 cloud event. Its exact 12:00 reset is current ground truth and
        // must not be shortened back to the cloud estimate of 10:05.
        let ws = try seedWorkspace()
        try CloudFallbackConfigStore(workspace: ws).save(CloudFallbackConfig(enabled: true))
        var seed = CloudFallbackState()
        seed.accounts["a1"] = AccountCloudFallbackState(
            triggerID: "trig_1", environmentID: "env_1", armedFor: date(2026, 7, 6, 5, 5))
        CloudFallbackStateStore(workspace: ws).save(seed)

        let clock = TestClock(date(2026, 7, 6, 7, 0))
        let exact = UsageReading(
            primaryUsedPercent: 1,
            primaryResetsAt: date(2026, 7, 6, 12, 0),
            secondaryUsedPercent: nil,
            secondaryResetsAt: nil,
            fetchedAt: clock.now)
        let daemon = makeDaemon(
            ws, clock: clock, recorder: PingRecorder(),
            cloudUsageReader: { _ in exact })

        _ = await daemon.tick()

        let status = SchedulerStatusStore(workspace: ws).load()
        XCTAssertEqual(status?.windowStates?["a1"]?.evidence, .usage)
        XCTAssertEqual(status?.windowStates?["a1"]?.expiresAt, date(2026, 7, 6, 12, 0))
    }

    func testCloudBackstopPassingWhileLocalFireIsDeferredDoesNotConsumeTheSlot() async throws {
        // Runtime evidence moves the 05:00 local fire to 05:11, but its old
        // cloud backstop is still armed for 05:05. That cloud turn runs inside
        // the already-open window, so it is itself a phantom: resolve/re-arm
        // the obsolete backstop, but keep the 05:00 nominal slot pending.
        let ws = try seedWorkspace()
        try CloudFallbackConfigStore(workspace: ws).save(CloudFallbackConfig(enabled: true))
        seedUsage(
            ws, id: "a1", resetsAt: date(2026, 7, 6, 5, 10),
            fetchedAt: date(2026, 7, 6, 4, 50))
        var seed = CloudFallbackState()
        seed.accounts["a1"] = AccountCloudFallbackState(
            triggerID: "trig_1", environmentID: "env_1", armedFor: date(2026, 7, 6, 5, 5))
        CloudFallbackStateStore(workspace: ws).save(seed)

        let clock = TestClock(date(2026, 7, 6, 5, 6))
        let recorder = PingRecorder()
        let syncs = SyncRecorder()
        let daemon = makeDaemon(ws, clock: clock, recorder: recorder, cloudSyncer: { syncs.append($0) })
        _ = await daemon.tick()

        XCTAssertTrue(recorder.requests.isEmpty)
        let status = SchedulerStatusStore(workspace: ws).load()
        XCTAssertNil(status?.lastHandled["a1"])
        XCTAssertEqual(status?.upcoming.first?.fireAt, date(2026, 7, 6, 5, 11))
        XCTAssertEqual(status?.upcoming.first?.plannedAt, date(2026, 7, 6, 5, 0))
        XCTAssertEqual(status?.lastResolvedFire?["a1"], date(2026, 7, 6, 5, 0))
        XCTAssertEqual(syncs.requests.last?.lastAnchoredFireAt, date(2026, 7, 6, 5, 0))
        XCTAssertEqual(syncs.requests.last?.nextFireAt, date(2026, 7, 6, 5, 11))

        let records = ActivityLog(workspace: ws).readRecent(limit: 10)
        XCTAssertEqual(records.count, 1)
        XCTAssertFalse(records[0].anchored)
        XCTAssertTrue(records[0].detail.contains("already-open"), records[0].detail)
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

    // MARK: - runtime anchor deferral

    /// Put one usage reading for `id` into the shared cache — the ground-truth
    /// channel the daemon folds window evidence from.
    func seedUsage(_ ws: Workspace, id: String, resetsAt: Date, fetchedAt: Date) {
        var readings = UsageCache(workspace: ws).load()
        readings[id] = UsageReading(
            primaryUsedPercent: 40, primaryResetsAt: resetsAt,
            secondaryUsedPercent: nil, secondaryResetsAt: nil, fetchedAt: fetchedAt)
        UsageCache(workspace: ws).save(readings)
    }

    func testCachedOpenWindowDefersDueFireToJustPastExpiry() async throws {
        // The cache proves a window open until 05:07 — the nominal 05:00 fire
        // would be a phantom. It must wait for 05:08 (expiry + margin), keep
        // its nominal watermark, and push the 10:00 successor past the window
        // *it* then opens.
        let ws = try seedWorkspace()
        seedUsage(ws, id: "a1", resetsAt: date(2026, 7, 6, 5, 7), fetchedAt: date(2026, 7, 6, 4, 50))
        let clock = TestClock(date(2026, 7, 6, 5, 0, 30))
        let recorder = PingRecorder()
        let daemon = makeDaemon(ws, clock: clock, recorder: recorder)

        _ = await daemon.tick()
        XCTAssertTrue(recorder.requests.isEmpty)
        var status = SchedulerStatusStore(workspace: ws).load()
        XCTAssertEqual(status?.upcoming.first?.fireAt, date(2026, 7, 6, 5, 8))
        XCTAssertEqual(status?.upcoming.first?.plannedAt, date(2026, 7, 6, 5, 0))
        let audit = AuditLog(workspace: ws).readRecent(limit: 10)
        XCTAssertTrue(audit.contains { $0.action == "ping.defer" }, "\(audit.map(\.action))")

        clock.now = date(2026, 7, 6, 5, 7, 30) // still inside the window
        _ = await daemon.tick()
        XCTAssertTrue(recorder.requests.isEmpty)

        clock.now = date(2026, 7, 6, 5, 8, 30)
        _ = await daemon.tick()
        XCTAssertEqual(recorder.requests, [.init(accountID: "a1", scheduledFor: date(2026, 7, 6, 5, 8))])
        status = SchedulerStatusStore(workspace: ws).load()
        // Watermark in nominal plan time — the 05:00 slot is consumed.
        XCTAssertEqual(status?.lastHandled["a1"], date(2026, 7, 6, 5, 0))
        // The anchor observed at 05:08:30 defers the 10:00 successor in turn.
        XCTAssertEqual(status?.upcoming.first?.fireAt, date(2026, 7, 6, 10, 9, 30))
        XCTAssertEqual(status?.upcoming.first?.plannedAt, date(2026, 7, 6, 10, 0))
    }

    func testGraceLateAnchorDefersTheChainedRePing() async throws {
        // A fire 7 minutes late (within grace) anchors a window that outlives
        // the nominal 10:00 re-ping — the deterministic phantom of the old
        // fixed-time behavior. The observed anchor now defers it to 10:08.
        let ws = try seedWorkspace()
        let clock = TestClock(date(2026, 7, 6, 5, 7))
        let recorder = PingRecorder()
        let daemon = makeDaemon(ws, clock: clock, recorder: recorder)

        _ = await daemon.tick()
        XCTAssertEqual(recorder.requests, [.init(accountID: "a1", scheduledFor: date(2026, 7, 6, 5, 0))])
        let status = SchedulerStatusStore(workspace: ws).load()
        XCTAssertEqual(status?.upcoming.first?.fireAt, date(2026, 7, 6, 10, 8))
        XCTAssertEqual(status?.upcoming.first?.plannedAt, date(2026, 7, 6, 10, 0))
    }

    func testDeferredChildOutcomeRestoresWatermarkAndRefiresAtExpiry() async throws {
        // The child's preflight can catch a live window the daemon's cache
        // didn't know about (exit 4). The entry must stay unconsumed and
        // re-fire just past the expiry the child proved — never be written off.
        let ws = try seedWorkspace()
        let clock = TestClock(date(2026, 7, 6, 5, 0, 30))
        let recorder = PingRecorder()
        final class Behavior: @unchecked Sendable {
            let lock = NSLock()
            var deferredOnce = false
            func firstCall() -> Bool {
                lock.lock(); defer { lock.unlock() }
                if deferredOnce { return false }
                deferredOnce = true
                return true
            }
        }
        let behavior = Behavior()
        let cacheURL = ws.usageCacheFile
        let provenReset = date(2026, 7, 6, 5, 9)
        let daemon = SchedulerDaemon(
            workspace: ws,
            calendar: cal,
            now: { clock.now },
            pingRunner: { request in
                recorder.append(request)
                if behavior.firstCall() {
                    // The child saves the reading it proved the window with
                    // before exiting 4 — that write is the daemon's evidence.
                    let cache = UsageCache(fileURL: cacheURL)
                    var readings = cache.load()
                    readings["a1"] = UsageReading(
                        primaryUsedPercent: 40, primaryResetsAt: provenReset,
                        secondaryUsedPercent: nil, secondaryResetsAt: nil, fetchedAt: clock.now)
                    cache.save(readings)
                    return .deferredOpenWindow
                }
                return .anchored
            },
            wakeBridge: { _ in },
            cloudSyncer: { _ in })

        _ = await daemon.tick()
        XCTAssertEqual(recorder.requests.count, 1)
        var status = SchedulerStatusStore(workspace: ws).load()
        // The slot was un-consumed and re-queued past the proven expiry.
        XCTAssertNil(status?.lastHandled["a1"])
        XCTAssertEqual(status?.upcoming.first?.fireAt, date(2026, 7, 6, 5, 10))
        XCTAssertEqual(status?.upcoming.first?.plannedAt, date(2026, 7, 6, 5, 0))
        // Nothing was skipped — no activity record for a deferral.
        XCTAssertTrue(ActivityLog(workspace: ws).readRecent(limit: 10).isEmpty)

        clock.now = date(2026, 7, 6, 5, 5)
        _ = await daemon.tick()
        XCTAssertEqual(recorder.requests.count, 1) // still waiting out the window

        clock.now = date(2026, 7, 6, 5, 10, 30)
        _ = await daemon.tick()
        XCTAssertEqual(recorder.requests.count, 2)
        XCTAssertEqual(recorder.requests.last, .init(accountID: "a1", scheduledFor: date(2026, 7, 6, 5, 10)))
        status = SchedulerStatusStore(workspace: ws).load()
        XCTAssertEqual(status?.lastHandled["a1"], date(2026, 7, 6, 5, 0))
    }

    func testInFlightCheckpointDoesNotAdvanceWatermarkEarly() async throws {
        // The durable pre-spawn checkpoint carries the attempt identity, not
        // an already-consumed slot. This is the key crash-safety invariant for
        // a child that may still return `deferredOpenWindow`.
        let ws = try seedWorkspace()
        let clock = TestClock(date(2026, 7, 6, 5, 0, 30))
        let recorder = PingRecorder()
        final class Observation: @unchecked Sendable {
            let lock = NSLock()
            var sawPendingWatermark = false
            func record(_ value: Bool) {
                lock.lock(); sawPendingWatermark = value; lock.unlock()
            }
        }
        let observation = Observation()
        let expectedNominal = date(2026, 7, 6, 5, 0)
        let daemon = SchedulerDaemon(
            workspace: ws,
            calendar: cal,
            now: { clock.now },
            pingRunner: { request in
                recorder.append(request)
                let status = SchedulerStatusStore(workspace: ws).load()
                observation.record(
                    status?.lastHandled["a1"] == nil
                        && status?.inFlight?.accountID == "a1"
                        && status?.inFlight?.nominalFireAt == expectedNominal)
                return .failed
            },
            wakeBridge: { _ in },
            cloudSyncer: { _ in },
            cloudUsageReader: { _ in nil })

        _ = await daemon.tick()

        XCTAssertTrue(observation.sawPendingWatermark)
        let resolved = SchedulerStatusStore(workspace: ws).load()
        XCTAssertNil(resolved?.inFlight)
        XCTAssertEqual(resolved?.lastHandled["a1"], date(2026, 7, 6, 5, 0))
    }

    func testRestartRecoversAbandonedDeferralFromExactWindowEvidence() async throws {
        // Simulate a daemon dying after the child checkpoint and after the
        // child saved the old live reset, but before it could report exit 4.
        // The restart must leave 05:00 pending and reconstruct the 05:10 retry.
        let ws = try seedWorkspace()
        seedUsage(
            ws, id: "a1", resetsAt: date(2026, 7, 6, 5, 9),
            fetchedAt: date(2026, 7, 6, 4, 50))
        SchedulerStatusStore(workspace: ws).save(SchedulerDaemonStatus(
            pid: 111,
            startedAt: date(2026, 7, 6, 4, 0),
            updatedAt: date(2026, 7, 6, 5, 0, 30),
            active: true,
            upcoming: [],
            lastHandled: [:],
            horizonFloor: date(2026, 7, 6, 4, 45),
            currentAccountID: "a1",
            inFlight: SchedulerInFlight(
                accountID: "a1",
                nominalFireAt: date(2026, 7, 6, 5, 0),
                effectiveFireAt: date(2026, 7, 6, 5, 0),
                startedAt: date(2026, 7, 6, 5, 0, 30),
                windowSeconds: 300 * 60)))

        let clock = TestClock(date(2026, 7, 6, 5, 1))
        let recorder = PingRecorder()
        _ = await makeDaemon(ws, clock: clock, recorder: recorder).tick()

        XCTAssertTrue(recorder.requests.isEmpty)
        let recovered = SchedulerStatusStore(workspace: ws).load()
        XCTAssertNil(recovered?.lastHandled["a1"])
        XCTAssertNil(recovered?.inFlight)
        XCTAssertEqual(recovered?.upcoming.first?.fireAt, date(2026, 7, 6, 5, 10))
        XCTAssertEqual(recovered?.upcoming.first?.plannedAt, date(2026, 7, 6, 5, 0))
    }

    func testRestartConsumesAbandonedAttemptWithoutDeferralProof() async throws {
        // If the daemon died while a TUI turn may have dispatched and there is
        // no exact evidence that an old window predated it, do not double-fire.
        let ws = try seedWorkspace()
        SchedulerStatusStore(workspace: ws).save(SchedulerDaemonStatus(
            pid: 111,
            startedAt: date(2026, 7, 6, 4, 0),
            updatedAt: date(2026, 7, 6, 5, 0, 30),
            active: true,
            upcoming: [],
            lastHandled: [:],
            horizonFloor: date(2026, 7, 6, 4, 45),
            currentAccountID: "a1",
            inFlight: SchedulerInFlight(
                accountID: "a1",
                nominalFireAt: date(2026, 7, 6, 5, 0),
                effectiveFireAt: date(2026, 7, 6, 5, 0),
                startedAt: date(2026, 7, 6, 5, 0, 30),
                windowSeconds: 300 * 60)))

        let clock = TestClock(date(2026, 7, 6, 5, 1))
        let recorder = PingRecorder()
        _ = await makeDaemon(ws, clock: clock, recorder: recorder).tick()

        XCTAssertTrue(recorder.requests.isEmpty)
        let recovered = SchedulerStatusStore(workspace: ws).load()
        XCTAssertEqual(recovered?.lastHandled["a1"], date(2026, 7, 6, 5, 0))
        XCTAssertNil(recovered?.inFlight)
        XCTAssertEqual(recovered?.upcoming.first?.fireAt, date(2026, 7, 6, 10, 0))
    }

    func testDeferralSurvivesDaemonRestart() async throws {
        // The window evidence persists in the status file: a KeepAlive
        // relaunch mid-deferral must keep waiting, not fire a phantom.
        let ws = try seedWorkspace()
        seedUsage(ws, id: "a1", resetsAt: date(2026, 7, 6, 5, 7), fetchedAt: date(2026, 7, 6, 4, 50))
        let clock = TestClock(date(2026, 7, 6, 5, 0, 30))
        let recorder = PingRecorder()
        _ = await makeDaemon(ws, clock: clock, recorder: recorder).tick()
        XCTAssertTrue(recorder.requests.isEmpty)
        XCTAssertNotNil(SchedulerStatusStore(workspace: ws).load()?.windowStates?["a1"])

        // Remove the cache so the relaunched daemon can only know the window
        // from its persisted state.
        try fm.removeItem(at: ws.usageCacheFile)
        clock.now = date(2026, 7, 6, 5, 2)
        let restarted = makeDaemon(ws, clock: clock, recorder: recorder)
        _ = await restarted.tick()
        XCTAssertTrue(recorder.requests.isEmpty)

        clock.now = date(2026, 7, 6, 5, 8, 30)
        _ = await restarted.tick()
        XCTAssertEqual(recorder.requests, [.init(accountID: "a1", scheduledFor: date(2026, 7, 6, 5, 8))])
    }

    func testDeferralMeasuresStalenessFromEffectiveTime() async throws {
        // 05:17 is 17 minutes past the nominal 05:00 (stale under the old
        // reading) but only 9 past the deferred 05:08 — the fire is *on time*
        // where it now belongs, and anchors instead of dropping.
        let ws = try seedWorkspace()
        seedUsage(ws, id: "a1", resetsAt: date(2026, 7, 6, 5, 7), fetchedAt: date(2026, 7, 6, 4, 50))
        let clock = TestClock(date(2026, 7, 6, 4, 50))
        let recorder = PingRecorder()
        let daemon = makeDaemon(ws, clock: clock, recorder: recorder)
        _ = await daemon.tick()

        clock.now = date(2026, 7, 6, 5, 17)
        _ = await daemon.tick()
        XCTAssertEqual(recorder.requests, [.init(accountID: "a1", scheduledFor: date(2026, 7, 6, 5, 8))])
        XCTAssertTrue(ActivityLog(workspace: ws).readRecent(limit: 10).isEmpty) // no stale drop
    }

    func testOpenWindowCoveringRemainingWorkSkipsTheSlot() async throws {
        // A window the user anchored runs to 12:30 — past the end of Monday's
        // painted hours (8–12). Deferring the 10:00 fire to 12:31 would anchor
        // a window nobody uses; resolve it as a covered skip instead.
        let ws = try seedWorkspace()
        seedUsage(ws, id: "a1", resetsAt: date(2026, 7, 6, 12, 30), fetchedAt: date(2026, 7, 6, 9, 50))
        let clock = TestClock(date(2026, 7, 6, 9, 55)) // fresh start: 05:00 out of scope
        let recorder = PingRecorder()
        let daemon = makeDaemon(ws, clock: clock, recorder: recorder)

        _ = await daemon.tick() // not yet due: just drops out of the published queue
        XCTAssertTrue(recorder.requests.isEmpty)
        XCTAssertEqual(SchedulerStatusStore(workspace: ws).load()?.upcoming.first?.fireAt, date(2026, 7, 13, 5, 0))

        clock.now = date(2026, 7, 6, 10, 0, 30)
        _ = await daemon.tick()
        XCTAssertTrue(recorder.requests.isEmpty)
        let records = ActivityLog(workspace: ws).readRecent(limit: 10)
        XCTAssertEqual(records.count, 1)
        XCTAssertFalse(records[0].anchored)
        XCTAssertTrue(records[0].detail.contains("no usable budget slice"), records[0].detail)
        XCTAssertEqual(SchedulerStatusStore(workspace: ws).load()?.lastHandled["a1"], date(2026, 7, 6, 10, 0))
    }

    func testDeferredRemainderBelowMinimumSliceSkipsTheSlot() async throws {
        // The known window ends at 11:30. Refiring at 11:31 would buy only 29
        // painted minutes before noon, below the default one-hour slice floor.
        let ws = try seedWorkspace()
        seedUsage(
            ws, id: "a1", resetsAt: date(2026, 7, 6, 11, 30),
            fetchedAt: date(2026, 7, 6, 9, 50))
        let clock = TestClock(date(2026, 7, 6, 10, 0, 30))
        let recorder = PingRecorder()
        let daemon = makeDaemon(ws, clock: clock, recorder: recorder)

        _ = await daemon.tick()

        XCTAssertTrue(recorder.requests.isEmpty)
        XCTAssertEqual(
            SchedulerStatusStore(workspace: ws).load()?.lastHandled["a1"],
            date(2026, 7, 6, 10, 0))
        let records = ActivityLog(workspace: ws).readRecent(limit: 10)
        XCTAssertEqual(records.count, 1)
        XCTAssertTrue(records[0].detail.contains("no usable budget slice"), records[0].detail)
    }

    func testAnchorUnknownDefersConservativelyButWithholdsCloudSignal() async throws {
        // A turn ran but couldn't be verified (exit 5): schedule around it as
        // if it anchored (defer the successor), yet never hand the cloud
        // fallback an anchor it would stand its backstop down for.
        let ws = try seedWorkspace()
        try CloudFallbackConfigStore(workspace: ws).save(CloudFallbackConfig(enabled: true))
        let clock = TestClock(date(2026, 7, 6, 5, 0, 30))
        let recorder = PingRecorder()
        let syncs = SyncRecorder()
        let daemon = makeDaemon(
            ws, clock: clock, recorder: recorder, outcome: .anchorUnknown,
            cloudSyncer: { syncs.append($0) })
        _ = await daemon.tick()

        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertNil(syncs.requests.last?.lastAnchoredFireAt)
        let status = SchedulerStatusStore(workspace: ws).load()
        XCTAssertEqual(status?.upcoming.first?.fireAt, date(2026, 7, 6, 10, 1, 30))
        XCTAssertEqual(status?.upcoming.first?.plannedAt, date(2026, 7, 6, 10, 0))
    }

    func testPostflightPhantomRemainsPendingAndCancelsItsRedundantCloudBackstop() async throws {
        // A fresh exact reading can prove that an exit-5 turn was a phantom
        // even when preflight missed it. The nominal slot must remain pending
        // for the real reset, while its 05:05 backstop moves out of the same
        // already-open window.
        let ws = try seedWorkspace()
        try CloudFallbackConfigStore(workspace: ws).save(CloudFallbackConfig(enabled: true))
        var seed = CloudFallbackState()
        seed.accounts["a1"] = AccountCloudFallbackState(
            triggerID: "trig_1", environmentID: "env_1", armedFor: date(2026, 7, 6, 5, 5))
        CloudFallbackStateStore(workspace: ws).save(seed)

        let clock = TestClock(date(2026, 7, 6, 5, 0, 30))
        let recorder = PingRecorder()
        let syncs = SyncRecorder()
        let cacheURL = ws.usageCacheFile
        let reset = date(2026, 7, 6, 5, 10)
        let daemon = SchedulerDaemon(
            workspace: ws,
            calendar: cal,
            now: { clock.now },
            pingRunner: { request in
                recorder.append(request)
                let cache = UsageCache(fileURL: cacheURL)
                var readings = cache.load()
                readings["a1"] = UsageReading(
                    primaryUsedPercent: 1,
                    primaryResetsAt: reset,
                    secondaryUsedPercent: nil,
                    secondaryResetsAt: nil,
                    fetchedAt: clock.now)
                cache.save(readings)
                return .anchorUnknown
            },
            wakeBridge: { _ in },
            cloudSyncer: { syncs.append($0) },
            cloudUsageReader: { _ in nil })

        _ = await daemon.tick()

        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(syncs.requests.last?.lastAnchoredFireAt, date(2026, 7, 6, 5, 0))
        let status = SchedulerStatusStore(workspace: ws).load()
        XCTAssertEqual(status?.lastResolvedFire?["a1"], date(2026, 7, 6, 5, 0))
        XCTAssertNil(status?.lastHandled["a1"])
        XCTAssertEqual(status?.upcoming.first?.fireAt, date(2026, 7, 6, 5, 11))
        XCTAssertEqual(status?.upcoming.first?.plannedAt, date(2026, 7, 6, 5, 0))
    }

    func testCloudBackstopAfterUnknownLocalOutcomeBecomesTheConservativeAnchor() async throws {
        // The local child ran but could not prove an anchor, so its 05:05
        // backstop deliberately remains armed. When that one-shot passes, the
        // 05:00 nominal slot is already watermarked; reconciliation must still
        // move the conservative expiry to the cloud event instead of missing it.
        let ws = try seedWorkspace()
        try CloudFallbackConfigStore(workspace: ws).save(CloudFallbackConfig(enabled: true))
        var seed = CloudFallbackState()
        seed.accounts["a1"] = AccountCloudFallbackState(
            triggerID: "trig_1", environmentID: "env_1", armedFor: date(2026, 7, 6, 5, 5))
        CloudFallbackStateStore(workspace: ws).save(seed)

        let clock = TestClock(date(2026, 7, 6, 5, 0, 30))
        let recorder = PingRecorder()
        let daemon = makeDaemon(ws, clock: clock, recorder: recorder, outcome: .anchorUnknown)
        _ = await daemon.tick()
        XCTAssertEqual(
            SchedulerStatusStore(workspace: ws).load()?.windowStates?["a1"]?.expiresAt,
            date(2026, 7, 6, 10, 0, 30))

        clock.now = date(2026, 7, 6, 5, 6)
        _ = await daemon.tick()

        let status = SchedulerStatusStore(workspace: ws).load()
        XCTAssertEqual(status?.lastHandled["a1"], date(2026, 7, 6, 5, 0))
        XCTAssertEqual(status?.lastResolvedFire?["a1"], date(2026, 7, 6, 5, 0))
        XCTAssertEqual(status?.windowStates?["a1"]?.expiresAt, date(2026, 7, 6, 10, 5))
        XCTAssertEqual(status?.upcoming.first?.fireAt, date(2026, 7, 6, 10, 6))
        XCTAssertTrue(ActivityLog(workspace: ws).readRecent(limit: 10).contains { $0.anchored })
    }

    func testLaggingPostflightReadingCannotEraseConservativeUnknownGuard() async throws {
        // A response fetched during the turn can still lag and report an old,
        // expired reset. Exit 5 means the turn may have anchored; the daemon
        // must use its conservative completion bound instead of accepting that
        // stale boundary merely because `fetchedAt` is recent.
        let ws = try seedWorkspace()
        let clock = TestClock(date(2026, 7, 6, 5, 0, 30))
        seedUsage(
            ws, id: "a1", resetsAt: date(2026, 7, 6, 4, 0),
            fetchedAt: clock.now)
        let recorder = PingRecorder()
        let daemon = makeDaemon(ws, clock: clock, recorder: recorder, outcome: .anchorUnknown)

        _ = await daemon.tick()

        let status = SchedulerStatusStore(workspace: ws).load()
        XCTAssertEqual(status?.windowStates?["a1"]?.evidence, .conservative)
        XCTAssertEqual(status?.windowStates?["a1"]?.expiresAt, date(2026, 7, 6, 10, 0, 30))
        XCTAssertEqual(status?.upcoming.first?.fireAt, date(2026, 7, 6, 10, 1, 30))
    }

    func testLaterLaggingUsageSnapshotCannotEraseLiveConservativeGuard() async throws {
        // The immediate postflight was unavailable, so exit 5 established a
        // completion-time upper bound. A later API response that still shows
        // yesterday's expired reset must not reopen the boundary race.
        let ws = try seedWorkspace()
        let clock = TestClock(date(2026, 7, 6, 5, 0, 30))
        let recorder = PingRecorder()
        let daemon = makeDaemon(ws, clock: clock, recorder: recorder, outcome: .anchorUnknown)
        _ = await daemon.tick()

        seedUsage(
            ws, id: "a1", resetsAt: date(2026, 7, 6, 4, 0),
            fetchedAt: date(2026, 7, 6, 5, 2))
        clock.now = date(2026, 7, 6, 5, 2)
        _ = await daemon.tick()

        let status = SchedulerStatusStore(workspace: ws).load()
        XCTAssertEqual(status?.windowStates?["a1"]?.evidence, .conservative)
        XCTAssertEqual(status?.windowStates?["a1"]?.expiresAt, date(2026, 7, 6, 10, 0, 30))
        XCTAssertEqual(status?.upcoming.first?.fireAt, date(2026, 7, 6, 10, 1, 30))
    }

    func testPaintedWorkOverlapUsesWallClockAcrossDSTTransitions() {
        var zagreb = Calendar(identifier: .gregorian)
        zagreb.timeZone = TimeZone(identifier: "Europe/Zagreb")!
        var schedule = WorkSchedule()
        schedule.set(weekday: 6, hours: [3]) // Sunday 03:00–04:00 wall time

        func local(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ minute: Int) -> Date {
            zagreb.date(from: DateComponents(
                year: y, month: m, day: d, hour: h, minute: minute))!
        }

        // 2026-03-29 skips 02:00; elapsed-minute arithmetic maps 03:00
        // incorrectly to 04:00. 2026-10-25 repeats 02:00 and has the inverse
        // problem. Painted 03:00 must remain 03:00 on both days.
        XCTAssertTrue(SchedulerDaemon.paintedWorkOverlaps(
            schedule: schedule, calendar: zagreb,
            from: local(2026, 3, 29, 3, 15), to: local(2026, 3, 29, 3, 45)))
        XCTAssertTrue(SchedulerDaemon.paintedWorkOverlaps(
            schedule: schedule, calendar: zagreb,
            from: local(2026, 10, 25, 3, 15), to: local(2026, 10, 25, 3, 45)))
    }

    func testLegacyStatusFileWithoutWindowStatesDecodes() throws {
        // Status files written before runtime deferral carry neither
        // `windowStates` nor per-entry `plannedAt` — they must load unchanged.
        let ws = try seedWorkspace()
        let json = """
        {
          "version": 1, "pid": 123,
          "startedAt": "2026-07-06T04:00:00Z",
          "updatedAt": "2026-07-06T04:10:00Z",
          "active": true,
          "upcoming": [{ "fireAt": "2026-07-06T05:00:00Z", "accountID": "a1" }],
          "lastHandled": {},
          "horizonFloor": "2026-07-06T03:45:00Z"
        }
        """
        try fm.createDirectory(at: ws.root, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: ws.schedulerStatusFile)
        let status = SchedulerStatusStore(workspace: ws).load()
        XCTAssertNotNil(status)
        XCTAssertNil(status?.windowStates)
        XCTAssertNil(status?.lastResolvedFire)
        XCTAssertNil(status?.inFlight)
        XCTAssertNil(status?.upcoming.first?.plannedAt)
        XCTAssertEqual(status?.upcoming.first?.nominalFireAt, date(2026, 7, 6, 5, 0))
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
