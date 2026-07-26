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

    /// Select Claude's `routine` ping method: scheduled Claude slots are
    /// anchored by a claude.ai one-shot and the daemon spawns no local Claude
    /// ping at all. This is the single switch behind every cloud-routine
    /// behaviour below — it lives in `preferences.json` next to the other
    /// methods, not in a feature file of its own.
    func useCloudRoutineMethod(_ ws: Workspace) {
        PreferencesStore(workspace: ws).save(Preferences(claudePingMethod: .routine))
    }

    /// Pretend the engine already armed this account's one-shot. The routine is
    /// armed *at* its fire, so `armedFor` is a planned fire time.
    func seedArmedRoutine(
        _ ws: Workspace, id: String = "a1", armedFor: Date, lastError: String? = nil)
    {
        var seed = CloudFallbackState()
        seed.accounts[id] = AccountCloudFallbackState(
            triggerID: "trig_1", environmentID: "env_1", armedFor: armedFor,
            lastError: lastError, lastErrorAt: lastError == nil ? nil : armedFor)
        CloudFallbackStateStore(workspace: ws).save(seed)
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

    /// A connected account marked `excludedFromScheduling` never enters the
    /// daemon's queue: the week is planned as if it didn't exist, so the
    /// remaining account keeps the single-account plan (05:00/10:00) and no
    /// ping is ever requested for the excluded one.
    func testExcludedAccountIsNeverQueuedOrPinged() async throws {
        let ws = try seedWorkspace(ids: ["a1", "a2"])
        let store = AccountStore(workspace: ws)
        var a2 = try XCTUnwrap(store.find("a2"))
        a2.excludedFromScheduling = true
        try store.upsert(a2)

        let clock = TestClock(date(2026, 7, 6, 4, 50))
        let recorder = PingRecorder()
        let daemon = makeDaemon(ws, clock: clock, recorder: recorder)
        _ = await daemon.tick()

        clock.now = date(2026, 7, 6, 5, 0, 30)
        _ = await daemon.tick()
        XCTAssertEqual(recorder.requests, [.init(accountID: "a1", scheduledFor: date(2026, 7, 6, 5, 0))])

        let status = SchedulerStatusStore(workspace: ws).load()
        XCTAssertTrue(status?.upcoming.allSatisfy { $0.accountID == "a1" } ?? false,
                      "excluded account leaked into the queue: \(status?.upcoming ?? [])")
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

    // MARK: - cloud routine ping method

    final class SyncRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [CloudFallbackSyncRequest] = []
        func append(_ r: CloudFallbackSyncRequest) { lock.lock(); recorded.append(r); lock.unlock() }
        var requests: [CloudFallbackSyncRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    }

    func testPassedRoutineFireResolvesTheSlotWithoutPinging() async throws {
        // The routine armed for the 05:00 slot has fired (it's 05:06). The
        // window is anchored from Anthropic's side, so the slot resolves with
        // no local turn — and the next fire is pushed past the window that run
        // opened (05:00 + 5h + margin).
        let ws = try seedWorkspace()
        useCloudRoutineMethod(ws)
        seedArmedRoutine(ws, armedFor: date(2026, 7, 6, 5, 0))

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

        let status = SchedulerStatusStore(workspace: ws).load()
        XCTAssertEqual(status?.lastResolvedFire?["a1"], date(2026, 7, 6, 5, 0))
        XCTAssertEqual(syncs.requests.last?.nextFireAt, date(2026, 7, 6, 10, 1))
    }

    func testRoutineMethodSuppressesTheLocalPingAndArmsAtTheExactFire() async throws {
        // The 05:00 slot is due and no routine is confirmed for it yet (never
        // armed, or its arm is erroring). The daemon must NOT fall back to a
        // local Claude ping — that flaky turn is the thing this method exists
        // to avoid — and it arms the next routine at the planned minute itself.
        let ws = try seedWorkspace()
        useCloudRoutineMethod(ws)

        let clock = TestClock(date(2026, 7, 6, 5, 0, 30)) // 05:00 slot, due, within grace
        let recorder = PingRecorder()
        let syncs = SyncRecorder()
        let daemon = makeDaemon(ws, clock: clock, recorder: recorder, cloudSyncer: { syncs.append($0) })
        _ = await daemon.tick()

        XCTAssertTrue(recorder.requests.isEmpty) // no local Claude ping spawned
        let records = ActivityLog(workspace: ws).readRecent(limit: 10)
        XCTAssertEqual(records.count, 1)
        XCTAssertFalse(records[0].anchored) // nothing anchored from our side
        XCTAssertTrue(records[0].detail.contains("cloud routine method"), records[0].detail)

        // Armed at the planned minute (10:00) — the routine is the anchor, so
        // there is no lead to leave room for a local turn.
        XCTAssertEqual(syncs.requests.last?.nextFireAt, date(2026, 7, 6, 10, 0))
    }

    func testRoutineMethodLeavesCodexPingingLocally() async throws {
        // Codex has no cloud routines, so Claude's method must not touch it —
        // it keeps firing local pings exactly as before.
        let ws = Workspace(root: tmp.appendingPathComponent("ws-codex", isDirectory: true))
        let store = AccountStore(workspace: ws)
        try store.insert(Account(
            id: "cx", label: "cx", provider: .codex,
            home: ws.managedHome(forAccountID: "cx").path, rank: 0, status: .connected))
        var sched = WorkSchedule()
        sched.set(weekday: 0, hours: [8, 9, 10, 11])
        try ScheduleStore(workspace: ws).save(sched)
        try SchedulerConfigStore(workspace: ws).save(SchedulerConfig(active: true))
        useCloudRoutineMethod(ws)

        let clock = TestClock(date(2026, 7, 6, 5, 0, 30))
        let recorder = PingRecorder()
        let daemon = makeDaemon(ws, clock: clock, recorder: recorder)
        _ = await daemon.tick()

        XCTAssertEqual(recorder.requests, [.init(accountID: "cx", scheduledFor: date(2026, 7, 6, 5, 0))])
    }

    func testCloudUsageResetTightensACloudFireDetectedHoursLate() async throws {
        // The Mac comes back two hours after the 05:00 one-shot. Detection
        // time + window would pretend the window lasts until noon and swallow
        // the useful 10:00 re-anchor; exact usage says it really resets 10:05.
        let ws = try seedWorkspace()
        useCloudRoutineMethod(ws)
        seedArmedRoutine(ws, armedFor: date(2026, 7, 6, 5, 0))

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
        // The Mac notices the 05:00 one-shot two hours late and the read-only
        // usage probe fails. The event time is still known from `armedFor`:
        // falling back to 07:00 + 5h would waste the useful 10:00 boundary.
        let ws = try seedWorkspace()
        useCloudRoutineMethod(ws)
        seedArmedRoutine(ws, armedFor: date(2026, 7, 6, 5, 0))

        let clock = TestClock(date(2026, 7, 6, 7, 0))
        let recorder = PingRecorder()
        let daemon = makeDaemon(ws, clock: clock, recorder: recorder)

        _ = await daemon.tick()

        XCTAssertTrue(recorder.requests.isEmpty)
        let status = SchedulerStatusStore(workspace: ws).load()
        XCTAssertEqual(status?.windowStates?["a1"]?.evidence, .conservative)
        XCTAssertEqual(status?.windowStates?["a1"]?.expiresAt, date(2026, 7, 6, 10, 0))
        XCTAssertEqual(status?.upcoming.first?.fireAt, date(2026, 7, 6, 10, 1))
        XCTAssertEqual(status?.upcoming.first?.plannedAt, date(2026, 7, 6, 10, 0))
    }

    func testLaterExactWindowSupersedesCloudArmedTimeFallback() async throws {
        // While the Mac slept, another real use anchored at 07:00 after the
        // 05:00 cloud event. Its exact 12:00 reset is current ground truth and
        // must not be shortened back to the cloud estimate of 10:00.
        let ws = try seedWorkspace()
        useCloudRoutineMethod(ws)
        seedArmedRoutine(ws, armedFor: date(2026, 7, 6, 5, 0))

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

    func testPassedRoutineInsideAnOpenWindowDoesNotConsumeTheSlot() async throws {
        // Runtime evidence says the window is open until 05:10, so the 05:00
        // fire is deferred to 05:11 — but the routine already ran at 05:00,
        // inside that window. That run is itself a phantom: resolve it (so the
        // engine can re-arm forward) while keeping the 05:00 slot pending.
        let ws = try seedWorkspace()
        useCloudRoutineMethod(ws)
        seedUsage(
            ws, id: "a1", resetsAt: date(2026, 7, 6, 5, 10),
            fetchedAt: date(2026, 7, 6, 4, 50))
        seedArmedRoutine(ws, armedFor: date(2026, 7, 6, 5, 0))

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
        XCTAssertEqual(syncs.requests.last?.nextFireAt, date(2026, 7, 6, 5, 11))

        let records = ActivityLog(workspace: ws).readRecent(limit: 10)
        XCTAssertEqual(records.count, 1)
        XCTAssertFalse(records[0].anchored)
        XCTAssertTrue(records[0].detail.contains("already-open"), records[0].detail)
    }

    func testPassedRoutineAfterAnErroredArmStillBecomesTheAnchor() async throws {
        // Tick 1: the routine's state carries a sync error, so its armed 05:00
        // moment can't be trusted — the slot is consumed without a local ping
        // (the method's rule) and watermarked. Tick 2: the error cleared, and
        // the passed one-shot must still be reconciled onto that already
        // watermarked slot instead of being missed.
        let ws = try seedWorkspace()
        useCloudRoutineMethod(ws)
        seedArmedRoutine(ws, armedFor: date(2026, 7, 6, 5, 0), lastError: "boom")

        let clock = TestClock(date(2026, 7, 6, 5, 0, 30))
        let recorder = PingRecorder()
        let daemon = makeDaemon(ws, clock: clock, recorder: recorder)
        _ = await daemon.tick()

        XCTAssertTrue(recorder.requests.isEmpty)
        XCTAssertEqual(
            SchedulerStatusStore(workspace: ws).load()?.lastHandled["a1"],
            date(2026, 7, 6, 5, 0))
        XCTAssertNil(SchedulerStatusStore(workspace: ws).load()?.lastResolvedFire?["a1"])

        // The next successful engine sync clears the error.
        seedArmedRoutine(ws, armedFor: date(2026, 7, 6, 5, 0))
        clock.now = date(2026, 7, 6, 5, 6)
        _ = await daemon.tick()

        let status = SchedulerStatusStore(workspace: ws).load()
        XCTAssertEqual(status?.lastResolvedFire?["a1"], date(2026, 7, 6, 5, 0))
        XCTAssertEqual(status?.windowStates?["a1"]?.expiresAt, date(2026, 7, 6, 10, 0))
        XCTAssertEqual(status?.upcoming.first?.fireAt, date(2026, 7, 6, 10, 1))
        XCTAssertTrue(ActivityLog(workspace: ws).readRecent(limit: 10).contains { $0.anchored })
    }

    func testLocalMethodPingsNormallyAndDisarmsALingeringRoutine() async throws {
        // The other side of the switch: with a local driver selected, a routine
        // left armed by a previous run must not suppress or cover anything —
        // the local ping fires, and the sync carries the disable signal (nil
        // `nextFireAt`) that stands the leftover routine down.
        let ws = try seedWorkspace() // no preferences file → terminal
        seedArmedRoutine(ws, armedFor: date(2026, 7, 6, 5, 0))

        let clock = TestClock(date(2026, 7, 6, 5, 6))
        let recorder = PingRecorder()
        let syncs = SyncRecorder()
        let daemon = makeDaemon(ws, clock: clock, recorder: recorder, cloudSyncer: { syncs.append($0) })
        _ = await daemon.tick()

        XCTAssertEqual(recorder.requests, [.init(accountID: "a1", scheduledFor: date(2026, 7, 6, 5, 0))])
        XCTAssertEqual(syncs.requests.count, 1)
        XCTAssertEqual(syncs.requests[0].accountID, "a1")
        XCTAssertNil(syncs.requests[0].nextFireAt)
    }

    func testLocalMethodSendsDisableSignalForClaudeAccounts() async throws {
        // Nothing armed, method not `routine`: every Claude account still gets
        // a sync with a nil nextFireAt, which is the disable signal — how a
        // routine armed before the method changed gets cleaned up.
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

    func testTailSliceAtTheFloorSurvivesTheDeferralMargin() async throws {
        // Painted Mon 08:00–10:00 plans 04:00 + 09:00, and the 09:00 slot's
        // slice is *exactly* the one-hour floor — the planner rebalances every
        // block that way. The 04:00 window expires right at 09:00, so the 09:00
        // fire defers to 09:01, where only 59 painted minutes remain. Re-testing
        // the planner's floor verbatim dropped the slot every time: as a covered
        // skip once due, and — hours earlier — as a silent disappearance from the
        // published queue, which is what the cloud routine arms from.
        let ws = try seedWorkspace(hours: [8, 9])
        seedUsage(ws, id: "a1", resetsAt: date(2026, 7, 6, 9, 0), fetchedAt: date(2026, 7, 6, 4, 30))
        let clock = TestClock(date(2026, 7, 6, 8, 55))
        let recorder = PingRecorder()
        let daemon = makeDaemon(ws, clock: clock, recorder: recorder)

        _ = await daemon.tick()
        XCTAssertTrue(recorder.requests.isEmpty)
        // Still queued, deferred one margin past the real expiry — not dropped,
        // and not silently replaced by next week's first slot.
        XCTAssertEqual(
            SchedulerStatusStore(workspace: ws).load()?.upcoming.first?.fireAt,
            date(2026, 7, 6, 9, 1))

        clock.now = date(2026, 7, 6, 9, 1, 10)
        _ = await daemon.tick()
        XCTAssertEqual(
            recorder.requests,
            [.init(accountID: "a1", scheduledFor: date(2026, 7, 6, 9, 1))])
        // The watermark still advances to the nominal minute, so the weekly
        // slot is consumed exactly once.
        XCTAssertEqual(
            SchedulerStatusStore(workspace: ws).load()?.lastHandled["a1"],
            date(2026, 7, 6, 9, 0))
    }

    func testTailSliceSurvivesRealAnchorLatencyNotJustTheMargin() async throws {
        // The general case of the above: a local ping doesn't anchor at its
        // planned minute but at planned + latency (dispatch, or a whole turn for
        // Codex), so the 04:00 window expires at 09:01:30 and the tail slice
        // measures 57 minutes rather than 60. That drift is jitter, not a real
        // shortfall — the slot must still fire, at 09:02:30.
        let ws = try seedWorkspace(hours: [8, 9])
        seedUsage(
            ws, id: "a1", resetsAt: date(2026, 7, 6, 9, 1, 30),
            fetchedAt: date(2026, 7, 6, 4, 30))
        let clock = TestClock(date(2026, 7, 6, 8, 55))
        let recorder = PingRecorder()
        let daemon = makeDaemon(ws, clock: clock, recorder: recorder)

        _ = await daemon.tick()
        XCTAssertEqual(
            SchedulerStatusStore(workspace: ws).load()?.upcoming.first?.fireAt,
            date(2026, 7, 6, 9, 2, 30))

        clock.now = date(2026, 7, 6, 9, 2, 40)
        _ = await daemon.tick()
        XCTAssertEqual(
            recorder.requests,
            [.init(accountID: "a1", scheduledFor: date(2026, 7, 6, 9, 2, 30))])
    }

    func testAnchorUnknownDefersConservativelyAroundTheUnverifiedTurn() async throws {
        // A turn ran but couldn't be verified (exit 5): schedule around it as
        // if it anchored (defer the successor) without ever reporting an anchor.
        let ws = try seedWorkspace()
        let clock = TestClock(date(2026, 7, 6, 5, 0, 30))
        let recorder = PingRecorder()
        let daemon = makeDaemon(
            ws, clock: clock, recorder: recorder, outcome: .anchorUnknown)
        _ = await daemon.tick()

        XCTAssertEqual(recorder.requests.count, 1)
        let status = SchedulerStatusStore(workspace: ws).load()
        XCTAssertEqual(status?.upcoming.first?.fireAt, date(2026, 7, 6, 10, 1, 30))
        XCTAssertEqual(status?.upcoming.first?.plannedAt, date(2026, 7, 6, 10, 0))
    }

    func testPostflightPhantomRemainsPendingAndResolvesItsCloudFire() async throws {
        // A fresh exact reading can prove that an exit-5 turn was a phantom
        // even when preflight missed it. The nominal slot must remain pending
        // for the real reset, and the fire is booked as cloud-resolved so a
        // routine covering it could never be reconciled onto it twice.
        let ws = try seedWorkspace()

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
        let status = SchedulerStatusStore(workspace: ws).load()
        XCTAssertEqual(status?.lastResolvedFire?["a1"], date(2026, 7, 6, 5, 0))
        XCTAssertNil(status?.lastHandled["a1"])
        XCTAssertEqual(status?.upcoming.first?.fireAt, date(2026, 7, 6, 5, 11))
        XCTAssertEqual(status?.upcoming.first?.plannedAt, date(2026, 7, 6, 5, 0))
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
