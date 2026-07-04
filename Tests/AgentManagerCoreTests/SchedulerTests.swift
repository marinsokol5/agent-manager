import XCTest
@testable import AgentManagerCore

/// Exercises the activate/deactivate/uninstall/status orchestration with a fake
/// `launchctl` runner and temp directories — no real launchd touched.
final class SchedulerTests: XCTestCase {
    var tmp: URL!
    var launchAgents: URL!
    let fm = FileManager.default

    /// Records every launchctl invocation and reports a configurable loaded set.
    final class FakeLaunchctl: @unchecked Sendable {
        var calls: [[String]] = []
        var loaded: Set<String> = []
        func runner() -> LaunchdController.Runner {
            { [self] args in
                calls.append(args)
                if args.first == "list" {
                    let lines = loaded.map { "-\t0\t\($0)" }.joined(separator: "\n")
                    return .init(ok: true, output: lines)
                }
                return .init(ok: true, output: "")
            }
        }
    }

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("am-scheduler-\(UUID().uuidString)", isDirectory: true)
        launchAgents = tmp.appendingPathComponent("LaunchAgents", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: tmp) }

    func workspace() -> Workspace { Workspace(root: tmp.appendingPathComponent("ws", isDirectory: true)) }

    var agentPlist: URL { launchAgents.appendingPathComponent(LaunchAgentPlanner.schedulerFilename) }

    func seed(connected ids: [String], schedule: WorkSchedule) throws -> Workspace {
        let ws = workspace()
        let store = AccountStore(workspace: ws)
        for (i, id) in ids.enumerated() {
            try store.insert(Account(id: id, label: id, provider: .claude, home: ws.managedHome(forAccountID: id).path, rank: i, status: .connected))
        }
        // A disconnected account that must be excluded from scheduling.
        try store.insert(Account(id: "ghost", label: "ghost", provider: .claude, home: ws.managedHome(forAccountID: "ghost").path, status: .disconnected))
        try ScheduleStore(workspace: ws).save(schedule)
        return ws
    }

    func makeScheduler(_ ws: Workspace, _ fake: FakeLaunchctl, program: String = "/usr/local/bin/am") -> Scheduler {
        Scheduler(
            workspace: ws,
            launchAgentsDir: launchAgents,
            launchd: LaunchdController(uid: 501, runner: fake.runner()),
            program: program,
            baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": tmp.path, "SHELL": "/bin/zsh"])
    }

    /// An installed agent plus a real on-disk "binary" the plist points at —
    /// the setup every stale-daemon-restart scenario starts from.
    func installedScheduler(_ ws: Workspace, _ fake: FakeLaunchctl) throws -> (scheduler: Scheduler, program: URL) {
        let program = tmp.appendingPathComponent("am")
        fm.createFile(atPath: program.path, contents: Data("v1".utf8))
        let scheduler = makeScheduler(ws, fake, program: program.path)
        _ = try scheduler.activate()
        fake.loaded = [LaunchAgentPlanner.schedulerLabel]
        fake.calls = []
        return (scheduler, program)
    }

    func daemonStatus(startedAt: Date, updatedAt: Date, pinging: String? = nil) -> SchedulerDaemonStatus {
        SchedulerDaemonStatus(
            pid: 42, startedAt: startedAt, updatedAt: updatedAt, active: true,
            upcoming: [], lastHandled: [:], horizonFloor: startedAt, currentAccountID: pinging)
    }

    func monSchedule() -> WorkSchedule {
        var sched = WorkSchedule()
        sched.set(weekday: 0, hours: [8, 9, 10, 11]) // Mon 08:00-12:00
        return sched
    }

    func testActivateInstallsSingleAgent() throws {
        let ws = try seed(connected: ["a1", "a2"], schedule: monSchedule())
        let fake = FakeLaunchctl()

        let report = try makeScheduler(ws, fake).activate()
        XCTAssertEqual(report.accountIDs, ["a1", "a2"]) // ghost excluded
        XCTAssertTrue(report.agentUpdated)  // first install writes the plist
        XCTAssertTrue(report.agentLoaded)
        XCTAssertTrue(report.accounts.allSatisfy { $0.pingsPerWeek == 2 }) // 2 pings Mon each
        XCTAssertEqual(report.totalPingsPerWeek, 4)

        // The active flag is on and exactly one plist exists: the scheduler's,
        // with the daemon args, KeepAlive, and the baked PATH.
        XCTAssertTrue(SchedulerConfigStore(workspace: ws).load().active)
        let present = try fm.contentsOfDirectory(atPath: launchAgents.path)
        XCTAssertEqual(present, [LaunchAgentPlanner.schedulerFilename])
        let contents = try String(contentsOf: agentPlist, encoding: .utf8)
        XCTAssertTrue(contents.contains("<string>scheduler</string>"))
        XCTAssertTrue(contents.contains("<string>run</string>"))
        XCTAssertTrue(contents.contains("<string>--root</string>"))
        XCTAssertTrue(contents.contains("<string>\(ws.root.path)</string>"))
        XCTAssertTrue(contents.contains("<key>KeepAlive</key>"))
        XCTAssertTrue(contents.contains("<key>PATH</key>"))

        // bootstrap ran for the scheduler agent.
        XCTAssertTrue(fake.calls.contains { $0.first == "bootstrap" && $0.last == agentPlist.path })
    }

    /// The notification-killer invariant: re-activating with nothing changed
    /// makes **zero** launchd mutations (no bootout/bootstrap), so flipping the
    /// Scheduler toggle can never re-trigger macOS's "background items added"
    /// notification.
    func testRepeatActivationMakesNoLaunchdMutations() throws {
        let ws = try seed(connected: ["a1", "a2"], schedule: monSchedule())
        let fake = FakeLaunchctl()
        _ = try makeScheduler(ws, fake).activate()
        fake.loaded = [LaunchAgentPlanner.schedulerLabel]
        fake.calls = []

        // Repaint the schedule (a different week) — plan inputs change, the
        // agent plist must not.
        var repainted = monSchedule()
        repainted.set(weekday: 1, hours: [9, 10, 11, 12])
        try ScheduleStore(workspace: ws).save(repainted)

        let report = try makeScheduler(ws, fake).activate()
        XCTAssertFalse(report.agentUpdated)
        XCTAssertTrue(report.agentLoaded)
        XCTAssertTrue(fake.calls.allSatisfy { $0.first == "list" },
                      "unexpected launchctl mutations: \(fake.calls)")
    }

    /// If the user booted the agent out by hand (unchanged plist, not loaded),
    /// activation loads it again.
    func testActivateReloadsAgentWhenNotLoaded() throws {
        let ws = try seed(connected: ["a1"], schedule: monSchedule())
        let fake = FakeLaunchctl()
        _ = try makeScheduler(ws, fake).activate()
        fake.calls = [] // agent not in fake.loaded → activate should bootstrap

        let report = try makeScheduler(ws, fake).activate()
        XCTAssertFalse(report.agentUpdated) // plist bytes unchanged
        XCTAssertTrue(fake.calls.contains { $0.first == "bootstrap" && $0.last == agentPlist.path })
    }

    func testDeactivateSwitchesOffButKeepsAgent() throws {
        let ws = try seed(connected: ["a1"], schedule: monSchedule())
        let fake = FakeLaunchctl()
        _ = try makeScheduler(ws, fake).activate()
        fake.calls = []

        let report = try makeScheduler(ws, fake).deactivate()
        XCTAssertTrue(report.wasActive)
        XCTAssertFalse(SchedulerConfigStore(workspace: ws).load().active)
        // The agent stays installed and untouched — deactivating only empties
        // the daemon's queue.
        XCTAssertTrue(fm.fileExists(atPath: agentPlist.path))
        XCTAssertFalse(fake.calls.contains { $0.first == "bootout" && ($0.last ?? "").contains(LaunchAgentPlanner.schedulerLabel) })

        // Deactivating again reports it was already off.
        XCTAssertFalse(try makeScheduler(ws, fake).deactivate().wasActive)
    }

    func testActivateWithNoConnectedAccountsStaysInactiveWithoutInstalling() throws {
        let ws = try seed(connected: [], schedule: monSchedule())
        let fake = FakeLaunchctl()

        let report = try makeScheduler(ws, fake).activate()
        XCTAssertTrue(report.noAccounts)
        XCTAssertFalse(SchedulerConfigStore(workspace: ws).load().active)
        XCTAssertFalse(fm.fileExists(atPath: agentPlist.path)) // nothing to run → no agent
    }

    func testUninstallRemovesAgentAndDeactivates() throws {
        let ws = try seed(connected: ["a1"], schedule: monSchedule())
        let fake = FakeLaunchctl()
        _ = try makeScheduler(ws, fake).activate()

        let report = try makeScheduler(ws, fake).uninstall()
        XCTAssertEqual(report.removed, [LaunchAgentPlanner.schedulerLabel])
        XCTAssertFalse(fm.fileExists(atPath: agentPlist.path))
        XCTAssertFalse(SchedulerConfigStore(workspace: ws).load().active)
        XCTAssertTrue(fake.calls.contains { $0 == ["bootout", "gui/501/\(LaunchAgentPlanner.schedulerLabel)"] })
    }

    func testStatusReflectsConfigLoadedSetAndPlan() throws {
        let ws = try seed(connected: ["a1"], schedule: monSchedule())
        let fake = FakeLaunchctl()
        _ = try makeScheduler(ws, fake).activate()

        fake.loaded = [LaunchAgentPlanner.schedulerLabel]
        let status = makeScheduler(ws, fake).status()
        XCTAssertTrue(status.active)
        XCTAssertTrue(status.agentInstalled)
        XCTAssertTrue(status.agentLoaded)
        XCTAssertEqual(status.accounts.count, 1)
        XCTAssertEqual(status.accounts[0].accountID, "a1")
        XCTAssertTrue(status.accounts[0].scheduled)
        XCTAssertFalse(status.accounts[0].entries.isEmpty)
        // No daemon has heartbeated in this test → not running.
        XCTAssertNil(status.daemon)
        XCTAssertFalse(status.isRunning())

        _ = try makeScheduler(ws, fake).deactivate()
        let deactivated = makeScheduler(ws, fake).status()
        XCTAssertFalse(deactivated.active)
        XCTAssertFalse(deactivated.accounts[0].scheduled)
    }

    // MARK: - stale daemon restart

    func testRestartDaemonIfOutdatedKicksStaleDaemon() throws {
        let ws = try seed(connected: ["a1"], schedule: monSchedule())
        let fake = FakeLaunchctl()
        let (scheduler, program) = try installedScheduler(ws, fake)

        // Live, idle daemon started an hour ago; binary rebuilt (and settled)
        // 60s ago → the daemon is provably running stale code.
        let now = Date()
        SchedulerStatusStore(workspace: ws).save(
            daemonStatus(startedAt: now.addingTimeInterval(-3600), updatedAt: now.addingTimeInterval(-10)))
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: program.path)

        XCTAssertTrue(scheduler.restartDaemonIfOutdated(now: now))
        // Exactly one launchctl call, and it's the in-place kickstart — never
        // a bootout/bootstrap (those would re-register and re-notify).
        XCTAssertEqual(fake.calls, [["kickstart", "-k", "gui/501/\(LaunchAgentPlanner.schedulerLabel)"]])
    }

    func testRestartDaemonIfOutdatedHoldsWithoutProofOfStaleness() throws {
        let ws = try seed(connected: ["a1"], schedule: monSchedule())
        let fake = FakeLaunchctl()
        let (scheduler, program) = try installedScheduler(ws, fake)
        let now = Date()
        let store = SchedulerStatusStore(workspace: ws)

        // No heartbeat at all → nothing to restart.
        XCTAssertFalse(scheduler.restartDaemonIfOutdated(now: now))

        // Daemon newer than the binary (the normal case) → no kick.
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-3600)], ofItemAtPath: program.path)
        store.save(daemonStatus(startedAt: now.addingTimeInterval(-60), updatedAt: now.addingTimeInterval(-10)))
        XCTAssertFalse(scheduler.restartDaemonIfOutdated(now: now))

        // Stale heartbeat (daemon dead or unloaded) → launchd owns that case.
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: program.path)
        store.save(daemonStatus(startedAt: now.addingTimeInterval(-7200), updatedAt: now.addingTimeInterval(-3600)))
        XCTAssertFalse(scheduler.restartDaemonIfOutdated(now: now))

        // Ping child in flight → never kill a daemon mid-turn.
        store.save(daemonStatus(startedAt: now.addingTimeInterval(-3600), updatedAt: now.addingTimeInterval(-10), pinging: "a1"))
        XCTAssertFalse(scheduler.restartDaemonIfOutdated(now: now))

        // Binary too fresh — a build may still be writing it.
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-5)], ofItemAtPath: program.path)
        store.save(daemonStatus(startedAt: now.addingTimeInterval(-3600), updatedAt: now.addingTimeInterval(-10)))
        XCTAssertFalse(scheduler.restartDaemonIfOutdated(now: now))

        XCTAssertTrue(fake.calls.isEmpty, "unexpected launchctl calls: \(fake.calls)")
    }

    /// Repeat activation stays registration-silent even when it heals a stale
    /// daemon: the plist is untouched and the only launchd mutation is the
    /// in-place kickstart.
    func testRepeatActivationKicksStaleDaemonWithoutReregistering() throws {
        let ws = try seed(connected: ["a1"], schedule: monSchedule())
        let fake = FakeLaunchctl()
        let (_, program) = try installedScheduler(ws, fake)

        let now = Date()
        SchedulerStatusStore(workspace: ws).save(
            daemonStatus(startedAt: now.addingTimeInterval(-3600), updatedAt: now.addingTimeInterval(-10)))
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: program.path)

        let report = try makeScheduler(ws, fake, program: program.path).activate()
        XCTAssertFalse(report.agentUpdated)
        XCTAssertFalse(fake.calls.contains { $0.first == "bootstrap" || $0.first == "bootout" },
                       "stale-daemon healing must not re-register: \(fake.calls)")
        XCTAssertTrue(fake.calls.contains(["kickstart", "-k", "gui/501/\(LaunchAgentPlanner.schedulerLabel)"]))
    }
}
