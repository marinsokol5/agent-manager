import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The resident scheduler: one long-lived launchd agent
/// (`com.agent-manager.scheduler`, KeepAlive) that fires every scheduled ping
/// in-process, replacing the old one-launchd-job-per-account design.
///
/// Why a resident daemon instead of N calendar jobs:
/// - **No launchd churn.** macOS 13+ posts a "background items added"
///   notification every time a LaunchAgent is (re)registered — with per-account
///   jobs that meant N notifications on every Schedule click. The agent that
///   hosts this daemon is registered once and never touched again; the app's
///   "Scheduler active" toggle only writes `scheduler.json`, which the daemon
///   notices on its next tick.
/// - **The daemon knows its own intent.** Staleness ("did we sleep through this
///   fire?") is a direct comparison against the queue entry's planned time — no
///   more reconstructing the scheduled minute from installed plists.
/// - **Sequential pings.** Entries that land on the same minute drain one at a
///   time in account-priority order instead of racing N PTYs.
///
/// ## The loop
///
/// `runForever` ticks at most every `pollInterval` seconds (chunked sleeps make
/// system sleep/wake and clock changes self-healing: `ContinuousClock` keeps
/// counting through machine sleep, so a wake lands in a tick within one chunk).
/// Each `tick`:
///
/// 1. Reloads `schedule.json` / `accounts.json` / `scheduler.json` when their
///    on-disk stamps changed (that's how the app's toggle and calendar edits
///    "poke" us — no IPC).
/// 2. Rebuilds the queue from scratch — pure `PingQueuePlanner` math, ≤ 7 days —
///    excluding everything at/before each account's `lastHandled` watermark, so
///    the rebuild is idempotent and a restart can't double-fire.
/// 3. Drains due entries: within `grace` → spawn one `am ping … --scheduled-for`
///    child and wait (sequential); past `grace` → drop it and log a `ping.skip`
///    (grouped per account, so a weekend of sleep logs one line per account, not
///    one per missed slot).
/// 4. Writes the `scheduler-status.json` heartbeat for the app/CLI.
/// 5. Notices when the `am` binary it runs from was replaced on disk (a
///    rebuild) and exits — launchd's KeepAlive relaunches it on the new code,
///    so an upgrade never leaves a stale daemon running old logic.
///
/// Pings run as **child `am` processes**, not in-process: the child takes the
/// exact same code path as a manual `am ping` (logging, power management, PTY),
/// its crash can't take the daemon down, and its `caffeinate -w <pid>` assertion
/// stays bound to a process that exits when the turn ends.
public actor SchedulerDaemon {
    /// One scheduled ping the daemon wants run: `accountID` was planned for
    /// `scheduledFor` (the child re-checks staleness against it, then anchors).
    public struct PingRequest: Sendable, Equatable {
        public var accountID: String
        public var scheduledFor: Date
        public init(accountID: String, scheduledFor: Date) {
            self.accountID = accountID
            self.scheduledFor = scheduledFor
        }
    }

    /// Runs one scheduled ping to completion and reports what happened (the
    /// child's exit code, mapped — see `PingOutcome`). Injected so tests can
    /// record requests instead of spawning processes.
    public typealias PingRunner = @Sendable (PingRequest) async -> PingOutcome

    private let workspace: Workspace
    private let fileManager: FileManager
    private let calendar: Calendar
    private let pollInterval: TimeInterval
    private let grace: TimeInterval
    private let now: @Sendable () -> Date
    private let pingRunner: PingRunner
    private let wakeBridge: @Sendable (TimeInterval) -> Void
    private let cloudSyncer: CloudFallbackSyncer
    private let statusStore: SchedulerStatusStore
    private let audit: AuditLog
    private let activity: ActivityLog
    /// Our own executable, watched for updates (nil = don't watch — tests, and
    /// hand-run daemons that nothing would relaunch). See `Self.binarySettle`.
    private let executablePath: String?
    private let launchBinaryStamp: FileStamp?

    // Cached config, reloaded only when the on-disk stamps change.
    private var stamps: [FileStamp?] = []
    private var active = false
    private var schedule = WorkSchedule()
    private var accountIDs: [String] = []
    /// Every known account's provider (connected or not) — the cloud-fallback
    /// sync must also reach routines of accounts that just *disconnected*.
    private var providersByID: [String: Provider] = [:]
    /// The experimental cloud-fallback opt-in (`cloud-fallback.json`).
    private var cloudFallbackEnabled = false
    /// Fire times observed anchoring *this daemon run* (local ping succeeded,
    /// or the cloud routine covered the fire). In-memory on purpose: after a
    /// restart the planner just waits out the armed moment instead — at most
    /// one redundant cloud turn, never a coverage gap.
    private var lastAnchoredFire: [String: Date] = [:]

    // Progress watermarks, persisted in the status file across restarts.
    private var lastHandled: [String: Date] = [:]
    private var horizonFloor: Date
    private let startedAt: Date
    private let pid = ProcessInfo.processInfo.processIdentifier

    /// A fire this close ahead gets a wake-bridge assertion (see `tick`).
    /// Must comfortably exceed the wake helper's 45 s lead so the first tick
    /// after an RTC wake always lands inside the window.
    static let bridgeWindow: TimeInterval = 90
    /// The bridge holds past the fire moment by this much, covering the gap
    /// until the spawned ping child takes its own PID-bound assertion.
    static let bridgeTail: TimeInterval = 60
    /// The latest fire a bridge has been spawned for (not persisted — a
    /// restart double-spawning a short overlapping assertion is harmless).
    private var bridgeCoveredUntil: Date = .distantPast

    /// A rebuilt binary must be this many seconds old before we exit for it —
    /// `make build` assembles and then codesigns the bundle, so an mtime still
    /// warm from the copy may not be the finished artifact yet.
    static let binarySettle: TimeInterval = 30
    /// Set by `tick` when the on-disk binary no longer matches the one we were
    /// launched from; `runForever` then returns so the process exits and the
    /// KeepAlive agent relaunches it on the new code.
    private(set) var wantsRestart = false

    public init(
        workspace: Workspace,
        fileManager: FileManager = .default,
        calendar: Calendar = .current,
        pollInterval: TimeInterval = 20,
        grace: TimeInterval = StalePingPolicy.defaultGrace,
        now: @escaping @Sendable () -> Date = { Date() },
        pingRunner: PingRunner? = nil,
        wakeBridge: (@Sendable (TimeInterval) -> Void)? = nil,
        cloudSyncer: CloudFallbackSyncer? = nil,
        executablePath: String? = nil)
    {
        self.workspace = workspace
        self.fileManager = fileManager
        self.calendar = calendar
        self.pollInterval = pollInterval
        self.grace = grace
        self.now = now
        self.executablePath = executablePath
        self.launchBinaryStamp = executablePath.flatMap {
            SchedulerDaemon.stamp(URL(fileURLWithPath: $0), fileManager: fileManager)
        }
        self.pingRunner = pingRunner ?? SchedulerDaemon.spawningPingRunner(
            program: Scheduler.resolveAmProgram(environment: ProcessInfo.processInfo.environment, fileManager: fileManager),
            workspace: workspace,
            fileManager: fileManager)
        self.wakeBridge = wakeBridge ?? SchedulerDaemon.spawningWakeBridge
        self.cloudSyncer = cloudSyncer ?? CloudFallbackEngine.live(workspace: workspace).syncer()
        self.statusStore = SchedulerStatusStore(workspace: workspace, fileManager: fileManager)
        self.audit = AuditLog(workspace: workspace, fileManager: fileManager)
        self.activity = ActivityLog(workspace: workspace, fileManager: fileManager)

        // Resume where a previous incarnation left off; a fresh start scopes the
        // schedule to "now − grace" so we never dredge up last week's entries.
        // Seeding `active` from the prior status matters: a restart of an
        // already-active daemon must NOT read as an off→on flip (which resets
        // the horizon), or entries missed while we were dead would be swallowed
        // silently instead of surfacing as logged stale skips.
        let startNow = now()
        self.startedAt = startNow
        if let prior = SchedulerStatusStore(workspace: workspace, fileManager: fileManager).load() {
            self.lastHandled = prior.lastHandled
            self.horizonFloor = prior.horizonFloor
            self.active = prior.active
        } else {
            self.horizonFloor = startNow.addingTimeInterval(-grace)
        }
    }

    /// The daemon entry point (`am scheduler run`). Returns only when the
    /// binary it was launched from has been replaced on disk (a rebuild): the
    /// process then exits and the KeepAlive agent relaunches it on the new
    /// code, so users never have to restart the daemon by hand after an
    /// upgrade. The relaunch is double-fire safe by construction — watermarks
    /// persist in the status file, and `lastAnchoredFire` degrades to at most
    /// one redundant cloud turn (see its doc).
    public func runForever() async {
        audit.append(accountID: nil, action: "scheduler.start", ok: true, detail: "pid \(pid)")
        while true {
            let interval = await tick()
            if wantsRestart { return }
            try? await Task.sleep(for: .seconds(interval), tolerance: .seconds(max(1, min(5, interval / 4))))
        }
    }

    /// One scheduling pass; returns how long to sleep before the next. Exposed
    /// (internally) so tests can drive the daemon with a fake clock, tick by tick.
    func tick() async -> TimeInterval {
        reloadIfChanged()

        // One read per tick: which cloud routines are armed (for the
        // covered-fire check below). The engine is the file's only writer.
        let cloudStates = cloudFallbackEnabled
            ? CloudFallbackStateStore(workspace: workspace, fileManager: fileManager).load()
            : CloudFallbackState()

        var queue = rebuildQueue()
        var dropped: [QueueEntry] = []
        while let head = queue.first, head.fireAt <= now() {
            queue.removeFirst()
            lastHandled[head.accountID] = head.fireAt
            if now().timeIntervalSince(head.fireAt) > grace {
                dropped.append(head)
            } else if cloudFallbackEnabled,
                      providersByID[head.accountID]?.supportsCloudAnchorRoutines == true,
                      CloudFallbackPlanner.isCovered(
                          fireAt: head.fireAt,
                          state: cloudStates.accounts[head.accountID] ?? AccountCloudFallbackState(),
                          now: now())
            {
                // We slept past this fire's cloud backstop: Anthropic already
                // ran the one-shot and anchored the window (that's the whole
                // point of the fallback) — a local ping now would just burn a
                // redundant turn.
                logCloudCoveredSkip(head)
                lastAnchoredFire[head.accountID] = head.fireAt
            } else {
                writeStatus(upcoming: queue, current: head.accountID)
                let outcome = await pingRunner(PingRequest(accountID: head.accountID, scheduledFor: head.fireAt))
                if outcome == .anchored {
                    lastAnchoredFire[head.accountID] = head.fireAt
                }
            }
        }
        if !dropped.isEmpty { logStaleDrops(dropped) }

        // Recompute after the drain so the published queue reflects the new
        // watermarks (the drained entries' next occurrences are a week out).
        let upcoming = rebuildQueue()
        bridgeImminentFire(in: upcoming)
        writeStatus(upcoming: upcoming, current: nil)
        await syncCloudFallback(upcoming: upcoming)
        checkForUpdatedBinary(nextFireAt: upcoming.first?.fireAt)

        guard let next = upcoming.first else { return pollInterval }
        return min(pollInterval, max(next.fireAt.timeIntervalSince(now()), 1))
    }

    /// Notice a rebuilt `am` on disk and ask `runForever` to exit for a
    /// launchd relaunch. Checked at the end of the tick, so never mid-ping.
    /// Holds off while the new file is younger than `binarySettle` (a build
    /// may still be writing/codesigning it — and a *missing* file is the same
    /// situation, mid-reassembly of the .app bundle) and while a fire is
    /// imminent (inside `bridgeWindow`), so a restart can never race an RTC
    /// wake or a due entry.
    private func checkForUpdatedBinary(nextFireAt: Date?) {
        guard !wantsRestart, let executablePath else { return }
        guard let current = stamp(URL(fileURLWithPath: executablePath)), current != launchBinaryStamp else { return }
        guard now().timeIntervalSince1970 - current.mtime >= SchedulerDaemon.binarySettle else { return }
        if let nextFireAt, nextFireAt.timeIntervalSince(now()) <= SchedulerDaemon.bridgeWindow { return }
        wantsRestart = true
        audit.append(
            accountID: nil, action: "scheduler.restart", ok: true,
            detail: "am binary updated on disk — exiting so launchd relaunches the new build (pid \(pid))")
    }

    /// Reconcile each Claude account's cloud anchor routine with the plan:
    /// keep a one-shot armed at `next fire + lead` while the feature and the
    /// scheduler are on; drive it to disabled otherwise (a nil `nextFireAt` is
    /// the disable signal — that also covers accounts that just disconnected).
    /// Steady state is a no-op (the engine's planner returns `.none`), so this
    /// only talks to the API when something actually changed.
    private func syncCloudFallback(upcoming: [QueueEntry]) async {
        for (id, provider) in providersByID.sorted(by: { $0.key < $1.key })
            where provider.supportsCloudAnchorRoutines
        {
            let nextFire: Date? = (cloudFallbackEnabled && active && accountIDs.contains(id))
                ? upcoming.first(where: { $0.accountID == id })?.fireAt
                : nil
            await cloudSyncer(CloudFallbackSyncRequest(
                accountID: id,
                nextFireAt: nextFire,
                lastAnchoredFireAt: lastAnchoredFire[id],
                now: now()))
        }
    }

    /// Log a fire the cloud routine already anchored — mirrors the stale-drop
    /// logging, but `anchored: true`: the window *is* anchored, just from
    /// Anthropic's side.
    private func logCloudCoveredSkip(_ entry: QueueEntry) {
        let detail = "skipped: cloud routine covered this fire (anchored from claude.ai)"
        audit.append(accountID: entry.accountID, action: "ping.skip", ok: true, detail: detail)
        activity.append(ActivityRecord(
            time: now(), accountID: entry.accountID, ok: true, anchored: true, detail: detail))
    }

    /// Keep an RTC-woken Mac awake long enough to actually fire.
    ///
    /// The wake helper wakes the machine ~45 s before a fire, but that is a
    /// *dark* wake with a leash of roughly half a minute — without an
    /// assertion the Mac can re-sleep in the gap between waking and the entry
    /// coming due. So whenever the next fire is inside `bridgeWindow`, hold a
    /// timed idle assertion (`caffeinate -i -t`) from now until just past the
    /// fire; the spawned ping child then takes over with its own PID-bound
    /// assertion. Once per fire (`bridgeCoveredUntil`), and a ~2-minute timed
    /// assertion twice a day is negligible on a Mac that was awake anyway.
    private func bridgeImminentFire(in queue: [QueueEntry]) {
        guard let next = queue.first else { return }
        let lead = next.fireAt.timeIntervalSince(now())
        guard lead > 0, lead <= SchedulerDaemon.bridgeWindow, next.fireAt > bridgeCoveredUntil else { return }
        bridgeCoveredUntil = next.fireAt
        wakeBridge(lead + SchedulerDaemon.bridgeTail)
    }

    // MARK: - config reload

    private struct FileStamp: Equatable {
        var mtime: TimeInterval
        var size: Int
    }

    private static func stamp(_ url: URL, fileManager: FileManager) -> FileStamp? {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path) else { return nil }
        return FileStamp(
            mtime: (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
            size: (attrs[.size] as? Int) ?? 0)
    }

    private func stamp(_ url: URL) -> FileStamp? {
        SchedulerDaemon.stamp(url, fileManager: fileManager)
    }

    /// Re-read the four inputs when any changed on disk (or on first tick). An
    /// off→on flip resets `horizonFloor` to "now − grace": time spent inactive
    /// must not resurface as a flood of stale drops.
    private func reloadIfChanged() {
        let fresh = [
            workspace.scheduleFile,
            workspace.accountsFile,
            workspace.schedulerConfigFile,
            workspace.cloudFallbackConfigFile,
        ].map(stamp)
        guard fresh != stamps else { return }
        stamps = fresh

        let wasActive = active
        active = SchedulerConfigStore(workspace: workspace, fileManager: fileManager).load().active
        if active && !wasActive {
            horizonFloor = now().addingTimeInterval(-grace)
        }
        // Unreadable inputs fail safe: no accounts → nothing fires, but the
        // heartbeat keeps reporting so the UI can show something is wrong.
        schedule = (try? ScheduleStore(workspace: workspace, fileManager: fileManager).load()) ?? WorkSchedule()
        let accounts = (try? AccountStore(workspace: workspace, fileManager: fileManager).load()) ?? []
        accountIDs = accounts.filter { $0.status == .connected }.inPriorityOrder().map(\.id)
        providersByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.provider) })
        cloudFallbackEnabled = CloudFallbackConfigStore(workspace: workspace, fileManager: fileManager).load().enabled
    }

    // MARK: - queue

    private func rebuildQueue() -> [QueueEntry] {
        guard active, !accountIDs.isEmpty else { return [] }
        return PingQueuePlanner.queue(
            accountIDs: accountIDs,
            schedule: schedule,
            after: horizonFloor,
            notBefore: lastHandled,
            calendar: calendar)
    }

    // MARK: - stale drops

    /// Log entries we slept through, one line per account (matching the old
    /// launchd behavior of a single coalesced late fire per account), so a long
    /// sleep explains itself in Activity without flooding it.
    private func logStaleDrops(_ dropped: [QueueEntry]) {
        let at = now()
        for (id, entries) in Dictionary(grouping: dropped, by: \.accountID).sorted(by: { $0.key < $1.key }) {
            let latest = entries.map(\.fireAt).max() ?? at
            let lateMin = Int((at.timeIntervalSince(latest) / 60).rounded())
            let detail = entries.count == 1
                ? "skipped: stale ping (due \(lateMin)m ago)"
                : "skipped: \(entries.count) stale pings (slept through; latest due \(lateMin)m ago)"
            audit.append(accountID: id, action: "ping.skip", ok: true, detail: detail)
            activity.append(ActivityRecord(time: at, accountID: id, ok: true, anchored: false, detail: detail))
        }
    }

    // MARK: - status heartbeat

    private func writeStatus(upcoming: [QueueEntry], current: String?) {
        statusStore.save(SchedulerDaemonStatus(
            pid: pid,
            startedAt: startedAt,
            updatedAt: now(),
            active: active,
            upcoming: Array(upcoming.prefix(50)),
            lastHandled: lastHandled,
            horizonFloor: horizonFloor,
            currentAccountID: current))
    }

    // MARK: - the real ping runner

    /// Spawn `am ping <id> --manage-sleep --scheduled-for <epoch>` — the
    /// workspace root travels as `AGENT_MANAGER_ROOT` in the child's env, set
    /// explicitly (not just inherited) so a hand-run daemon serving a custom
    /// root still points its pings at that root — and wait for it, appending
    /// its output to the same per-account log files launchd used to write. A
    /// hard `timeout` (well past the ping's own internal one) guards the
    /// sequential queue against a wedged PTY: SIGTERM, then SIGKILL if the
    /// child ignores it.
    public static func spawningPingRunner(
        program: String,
        workspace: Workspace,
        fileManager: FileManager = .default,
        timeout: TimeInterval = 600)
        -> PingRunner
    {
        let root = workspace.root.path
        let logsDir = workspace.logsDir
        // FileManager isn't Sendable by declaration but is documented
        // thread-safe for the path operations we do; the closure only ever runs
        // one ping at a time (the daemon drains sequentially).
        nonisolated(unsafe) let fileManager = fileManager
        return { request in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: program)
            process.arguments = [
                "ping", request.accountID,
                "--manage-sleep",
                "--scheduled-for", String(Int(request.scheduledFor.timeIntervalSince1970)),
            ]
            process.environment = ProcessInfo.processInfo.environment
                .merging(["AGENT_MANAGER_ROOT": root]) { _, ours in ours }
            let out = appendHandle(logsDir.appendingPathComponent("\(request.accountID).out.log"), fileManager: fileManager)
            let err = appendHandle(logsDir.appendingPathComponent("\(request.accountID).err.log"), fileManager: fileManager)
            process.standardOutput = out ?? FileHandle.nullDevice
            process.standardError = err ?? FileHandle.nullDevice
            defer {
                try? out?.close()
                try? err?.close()
            }

            do { try process.run() } catch { return .failed }
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(500))
            }
            var timedOut = false
            if process.isRunning {
                timedOut = true
                process.terminate()
                try? await Task.sleep(for: .seconds(5))
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            if !process.isRunning { process.waitUntilExit() }
            // A wedged child we had to kill may or may not have dispatched its
            // turn first — report `.timedOut`, which the cloud fallback treats
            // as "not anchored" (the safe reading).
            return timedOut ? .timedOut : PingOutcome.fromExitCode(process.terminationStatus)
        }
    }

    /// The real wake bridge: a timed idle assertion via `caffeinate -i -t`.
    /// Fire-and-forget — `-t` self-expires, and the termination handler keeps
    /// the `Process` alive until the child exits so it gets reaped (no
    /// zombies from a long-lived daemon spawning two of these a day).
    static let spawningWakeBridge: @Sendable (TimeInterval) -> Void = { seconds in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-i", "-t", String(Int(seconds.rounded(.up)))]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in }
        try? process.run()
    }

    private static func appendHandle(_ url: URL, fileManager: FileManager) -> FileHandle? {
        let dir = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? handle.seekToEnd()
        return handle
    }

    // MARK: - single instance

    /// Take the workspace's scheduler flock. launchd already guarantees one
    /// instance of the label, but nothing stops a hand-run `am scheduler run`
    /// next to it — the flock does. The descriptor is deliberately left open for
    /// the life of the process (the kernel drops the lock on exit, crash
    /// included).
    public static func acquireSingletonLock(at url: URL, fileManager: FileManager = .default) -> Bool {
        let dir = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return false }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        return true
    }
}
