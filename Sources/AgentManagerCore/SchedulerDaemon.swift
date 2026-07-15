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
///    the rebuild is idempotent and a restart can't double-fire. The nominal
///    queue is then bent around each account's best-known *real* window expiry
///    (`RuntimeAnchorPolicy`, fed by usage readings + observed anchor events):
///    an entry that would fire into a still-open window — a phantom that
///    anchors nothing — runs just past the real expiry instead, or resolves as
///    a covered skip when the open window already spans its whole slice.
/// 3. Drains due entries: within `grace` (of the *effective* time) → spawn one
///    `am ping … --scheduled-for` child and wait (sequential); past `grace` →
///    drop it and log a `ping.skip` (grouped per account, so a weekend of
///    sleep logs one line per account, not one per missed slot).
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
    /// One scheduled ping the daemon wants run at its effective
    /// `scheduledFor` time (the child re-checks staleness against it, then
    /// anchors). The nominal identity remains on `QueueEntry` for watermarks.
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
    /// Read the account's current usage after a passed cloud one-shot. The
    /// production closure is noninteractive and forbids delegated token
    /// refresh; tests inject a deterministic reading or nil.
    public typealias CloudUsageReader = @Sendable (String) async -> UsageReading?

    private let workspace: Workspace
    private let fileManager: FileManager
    private let calendar: Calendar
    private let pollInterval: TimeInterval
    private let grace: TimeInterval
    private let now: @Sendable () -> Date
    private let pingRunner: PingRunner
    private let wakeBridge: @Sendable (TimeInterval) -> Void
    private let cloudSyncer: CloudFallbackSyncer
    private let cloudUsageReader: CloudUsageReader
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
    /// Minute-geometry compilation is cached with the stamped config. Ticks
    /// only resolve these weekly fields to concrete dates and watermarks.
    private var weeklyEntries: [String: [CalEntry]] = [:]
    /// Every known account's provider (connected or not) — the cloud-fallback
    /// sync must also reach routines of accounts that just *disconnected*.
    private var providersByID: [String: Provider] = [:]
    /// The experimental cloud-fallback opt-in (`cloud-fallback.json`).
    private var cloudFallbackEnabled = false
    /// Cloud-primary mode (`cloudPrimary` in `cloud-fallback.json`, only ever
    /// true when `cloudFallbackEnabled` is too): the claude.ai routine is the
    /// *sole* anchor for Claude accounts — armed at the exact planned fire
    /// (`cloudLead == 0`), and local Claude pings are never spawned. Codex is
    /// unaffected. Reloaded with the other config stamps.
    private var cloudPrimaryEnabled = false
    /// Effective local-fire times whose cloud backstops are resolved: a
    /// verified local anchor, a passed one-shot, or an entry already covered
    /// by a known-open window. Persisted because losing this between the local
    /// decision and the routines API re-arm would let an obsolete one-shot run.
    private var lastResolvedFire: [String: Date] = [:]
    /// Best-known real expiry of each account's rolling window — the evidence
    /// `RuntimeAnchorPolicy` bends the queue around, so a fixed-time entry
    /// never fires into a still-open window (a phantom that anchors nothing).
    /// Merged from usage readings (`foldUsageEvidence`) and observed anchor
    /// events; persisted in the status file so a restart keeps deferring.
    private var windowStates: [String: AccountWindowState] = [:]
    /// Stamp of `usage.json` at the last fold, so the tick only re-decodes the
    /// cache when it actually changed on disk.
    private var usageStamp: FileStamp?
    /// Deferrals already audited (planned slot → last logged effective time),
    /// so a shifted entry logs `ping.defer` once — and again only if new
    /// evidence moves it by more than the margin — never every tick.
    private struct DeferralKey: Hashable {
        var accountID: String
        var plannedAt: Date
    }
    private var loggedDeferrals: [DeferralKey: Date] = [:]

    // Progress watermarks, persisted in the status file across restarts.
    private var lastHandled: [String: Date] = [:]
    /// The child attempt durably checkpointed in status but not yet resolved
    /// into `lastHandled`. Keeping these states separate is essential for an
    /// exit-4 deferral: the nominal slot must remain pending until the child
    /// outcome is known.
    private var inFlight: SchedulerInFlight?
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
        cloudUsageReader: CloudUsageReader? = nil,
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
        self.cloudUsageReader = cloudUsageReader ?? SchedulerDaemon.liveCloudUsageReader(
            workspace: workspace, fileManager: fileManager)
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
            self.windowStates = prior.windowStates ?? [:]
            self.lastResolvedFire = prior.lastResolvedFire ?? [:]
            if let abandoned = prior.inFlight {
                let recovered = SchedulerDaemon.recoverAbandonedInFlight(
                    abandoned,
                    lastHandled: self.lastHandled,
                    windowStates: self.windowStates,
                    readings: UsageCache(
                        workspace: workspace, fileManager: fileManager).load())
                self.lastHandled = recovered.lastHandled
                self.windowStates = recovered.windowStates
            }
        } else {
            self.horizonFloor = startNow.addingTimeInterval(-grace)
        }
    }

    /// The daemon entry point (`am scheduler run`). Returns only when the
    /// binary it was launched from has been replaced on disk (a rebuild): the
    /// process then exits and the KeepAlive agent relaunches it on the new
    /// code, so users never have to restart the daemon by hand after an
    /// upgrade. The relaunch is double-fire safe by construction — watermarks
    /// persist in the status file, including runtime window/backstop state.
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
        foldUsageEvidence()

        // One read per tick: which cloud routines are armed (for the
        // covered-fire check below). The engine is the file's only writer.
        let cloudStates = cloudFallbackEnabled
            ? CloudFallbackStateStore(workspace: workspace, fileManager: fileManager).load()
            : CloudFallbackState()

        // Take the dark-wake bridge before any cloud usage probe can spend up
        // to its network timeout. The wake helper gives us only ~45 seconds of
        // lead; waiting until the end of the tick could let the Mac re-sleep
        // during that read and miss an otherwise imminent local fire.
        bridgeImminentFire(in: adjustedQueue().entries)

        var dropped: [QueueEntry] = []
        while true {
            // A cloud one-shot can pass while its local entry is intentionally
            // deferred. Reconcile it independently of local due-ness; checking
            // only inside the due loop is the original cloud +5m phantom.
            if await reconcilePassedCloudFire(cloudStates) { continue }

            let adjusted = adjustedQueue()
            if !adjusted.covered.isEmpty {
                resolveCovered(adjusted.covered)
                let checkpoint = adjustedQueue()
                writeStatus(upcoming: checkpoint.entries, current: nil)
                continue
            }
            guard let head = adjusted.entries.first, head.fireAt <= now() else { break }

            // Grace/staleness is measured against the *effective* time — a
            // fire deferred past a known expiry is exactly on time there.
            if now().timeIntervalSince(head.fireAt) > grace {
                markHandled(head)
                dropped.append(head)
                let checkpoint = adjustedQueue()
                writeStatus(upcoming: checkpoint.entries, current: nil)
            } else if cloudPrimaryEnabled
                && providersByID[head.accountID]?.supportsCloudAnchorRoutines == true
            {
                // Cloud-primary: this account is anchored solely by its
                // claude.ai routine, never a local ping.
                // `reconcilePassedCloudFire` already resolved (and logged) any
                // fire the routine covered, so reaching a *due* entry here means
                // the routine isn't confirmed for this fire — not yet armed, or
                // its arm is erroring. We consume the slot without pinging: this
                // one window goes unanchored by design rather than fall back to
                // the flaky local turn the mode exists to avoid; the post-drain
                // sync re-arms the routine forward for the next fire.
                markHandled(head)
                logCloudPrimarySkip(head)
                let checkpoint = adjustedQueue()
                writeStatus(upcoming: checkpoint.entries, current: nil)
            } else {
                let fireStarted = now()
                // Checkpoint the attempt separately from `lastHandled` before
                // spawning. A child that proves the window is open must be
                // able to leave this nominal slot pending; persisting the
                // watermark here was a crash window that could swallow it.
                inFlight = SchedulerInFlight(
                    accountID: head.accountID,
                    nominalFireAt: head.nominalFireAt,
                    effectiveFireAt: head.fireAt,
                    startedAt: fireStarted,
                    windowSeconds: windowSeconds)
                writeStatus(
                    upcoming: Array(adjusted.entries.dropFirst()),
                    current: head.accountID)
                let outcome = await pingRunner(PingRequest(accountID: head.accountID, scheduledFor: head.fireAt))
                switch outcome {
                case .anchored:
                    markHandled(head)
                    noteAnchorEvidence(head.accountID, since: fireStarted)
                    markCloudFireResolved(head.accountID, fireAt: head.fireAt)
                case .anchorUnknown:
                    // A turn may have anchored: schedule conservatively around
                    // it without reporting an anchor. If fresh exact evidence
                    // instead proves a window materially predates this turn,
                    // it was a phantom the preflight couldn't see: leave the
                    // nominal slot pending so it re-fires at the real expiry.
                    noteAnchorEvidence(head.accountID, since: fireStarted)
                    if windowWasAlreadyOpen(head.accountID, at: fireStarted) {
                        resolveRedundantBackstopIfProven(for: head)
                    } else {
                        markHandled(head)
                    }
                case .timedOut:
                    // The child may have dispatched before wedging. Hold later
                    // local fires conservatively, but never cancel its backstop.
                    markHandled(head)
                    noteAnchorEvidence(head.accountID, since: fireStarted)
                case .deferredOpenWindow:
                    // The child proved the window is still open (and saved the
                    // reading it proved it with). `lastHandled` was deliberately
                    // never advanced, so the rebuild re-emits this entry — now
                    // deferred by that evidence — instead of writing it off.
                    noteDeferredOutcomeEvidence(head.accountID)
                    resolveRedundantBackstopIfProven(for: head)
                case .failed, .skippedStale:
                    markHandled(head)
                }
                inFlight = nil

                // Persist the resolved attempt immediately, before the next
                // cloud probe or queue operation can suspend. If the status
                // write itself fails, the older in-flight checkpoint remains
                // and restart recovery still makes a conservative decision.
                let checkpoint = adjustedQueue()
                writeStatus(upcoming: checkpoint.entries, current: nil)
            }
            // Always rebuild after handling one entry. A child can add exact
            // usage evidence or defer its nominal slot, changing both order
            // and effective times; draining the old array could swallow the
            // deferred entry behind a later watermark.
        }
        if !dropped.isEmpty { logStaleDrops(dropped) }

        // Recompute after the drain so the published queue reflects the new
        // watermarks (the drained entries' next occurrences are a week out)
        // and the fresh window evidence.
        let upcoming = adjustedQueue()
        bridgeImminentFire(in: upcoming.entries)
        writeStatus(upcoming: upcoming.entries, current: nil)
        await syncCloudFallback(upcoming: upcoming.entries)
        checkForUpdatedBinary(nextFireAt: upcoming.entries.first?.fireAt)

        guard let next = upcoming.entries.first else { return pollInterval }
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
                lastAnchoredFireAt: lastResolvedFire[id],
                now: now(),
                leadSeconds: cloudLead))
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

    /// Cloud-primary mode consumed a Claude slot without a local ping because
    /// its routine wasn't confirmed for this fire (not yet armed, or its arm is
    /// erroring). `anchored: false` — nothing anchored from our side this time;
    /// once the routine arms, `reconcilePassedCloudFire` covers later fires.
    private func logCloudPrimarySkip(_ entry: QueueEntry) {
        let detail = "skipped: cloud-primary — no local ping; routine anchors this account"
        audit.append(accountID: entry.accountID, action: "ping.skip", ok: true, detail: detail)
        activity.append(ActivityRecord(
            time: now(), accountID: entry.accountID, ok: true, anchored: false, detail: detail))
    }

    /// The one-shot ran, but runtime evidence proves another window was still
    /// open at that instant. Keep the local slot pending and record the cloud
    /// turn truthfully instead of converting it into five more hours of fake
    /// expiry.
    private func logCloudPhantom(accountID: String) {
        let detail = "cloud routine fired inside an already-open window; no new window anchored"
        audit.append(accountID: accountID, action: "ping.skip", ok: true, detail: detail)
        activity.append(ActivityRecord(
            time: now(), accountID: accountID, ok: true, anchored: false, detail: detail))
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
        weeklyEntries = active
            ? LaunchAgentPlanner.entriesByAccount(
                accountIDs: accountIDs, schedule: schedule)
            : [:]
        providersByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.provider) })
        let knownAccountIDs = Set(providersByID.keys)
        windowStates = windowStates.filter { knownAccountIDs.contains($0.key) }
        lastResolvedFire = lastResolvedFire.filter { knownAccountIDs.contains($0.key) }
        let cloudConfig = CloudFallbackConfigStore(workspace: workspace, fileManager: fileManager).load()
        cloudFallbackEnabled = cloudConfig.enabled
        cloudPrimaryEnabled = cloudConfig.enabled && cloudConfig.cloudPrimary
    }

    /// The routine arm lead for this daemon's mode: `0` in cloud-primary (arm
    /// the routine at the exact planned fire, the account's only anchor), the
    /// planner's `lead` otherwise (armed as a backstop after the local ping).
    /// Threaded to `syncCloudFallback` and to every place the daemon reasons
    /// about a routine's covered fire (`armedFor - lead`) so the two stay
    /// consistent.
    private var cloudLead: TimeInterval {
        cloudPrimaryEnabled ? 0 : CloudFallbackPlanner.lead
    }

    // MARK: - queue

    private func rebuildQueue() -> [QueueEntry] {
        guard active, !accountIDs.isEmpty else { return [] }
        return PingQueuePlanner.queue(
            accountIDs: accountIDs,
            weeklyEntries: weeklyEntries,
            after: horizonFloor,
            notBefore: lastHandled,
            calendar: calendar)
    }

    // MARK: - runtime anchor deferral

    /// The rolling-window length the evidence describes, in seconds.
    private var windowSeconds: TimeInterval { TimeInterval(schedule.windowMinutes * 60) }

    /// Resolve an abandoned child checkpoint from a prior daemon process.
    /// Exact evidence that the window began before the attempt means the child
    /// could only have deferred/burned a phantom, so its slot remains pending.
    /// Otherwise advance the slot: the child may still have dispatched before
    /// the daemon died, and preserving the long-standing no-double-fire rule is
    /// safer than repeating an unobservable turn.
    private static func recoverAbandonedInFlight(
        _ abandoned: SchedulerInFlight,
        lastHandled: [String: Date],
        windowStates: [String: AccountWindowState],
        readings: [String: UsageReading])
        -> (lastHandled: [String: Date], windowStates: [String: AccountWindowState])
    {
        var handled = lastHandled
        var states = windowStates
        if let reading = readings[abandoned.accountID],
           let resets = reading.primaryResetsAt
        {
            let candidate = AccountWindowState(
                expiresAt: resets, evidence: .usage, observedAt: reading.fetchedAt)
            states[abandoned.accountID] = RuntimeAnchorPolicy.merged(
                states[abandoned.accountID], candidate)
        }

        if let state = states[abandoned.accountID],
           exactWindowPredates(
               state, eventAt: abandoned.startedAt, window: abandoned.windowSeconds)
        {
            return (handled, states)
        }

        if handled[abandoned.accountID].map({ $0 < abandoned.nominalFireAt }) ?? true {
            handled[abandoned.accountID] = abandoned.nominalFireAt
        }
        return (handled, states)
    }

    /// The next physical nominal slot for this account, including the cyclic
    /// last-entry→next-week-first-entry seam. `PingQueuePlanner` materializes
    /// one occurrence of every weekly trigger, so adding seven calendar days
    /// to the first entry gives the missing successor without DST drift.
    static func cyclicSuccessor(
        after entry: QueueEntry,
        in queue: [QueueEntry],
        calendar: Calendar)
        -> Date?
    {
        let sameAccount = queue
            .filter { $0.accountID == entry.accountID }
            .map(\.nominalFireAt)
            .sorted()
        if let later = sameAccount.first(where: { $0 > entry.nominalFireAt }) {
            return later
        }
        guard let first = sameAccount.first else { return nil }
        return calendar.date(byAdding: .day, value: 7, to: first)
    }

    private func adjustNominalQueue(_ nominal: [QueueEntry]) -> RuntimeAnchorPolicy.AdjustedQueue {
        let schedule = self.schedule
        let calendar = self.calendar
        return RuntimeAnchorPolicy.adjust(
            nominal,
            windowStates: windowStates,
            window: windowSeconds,
            now: now(),
            nextNominalFire: { entry in
                SchedulerDaemon.cyclicSuccessor(
                    after: entry, in: nominal, calendar: calendar)
            },
            hasPaintedWork: { from, to in
                SchedulerDaemon.paintedWorkOverlaps(
                    schedule: schedule,
                    calendar: calendar,
                    from: from,
                    to: to,
                    minimumDuration: TimeInterval(schedule.resolvedMinSliceMinutes * 60))
            })
    }

    /// The nominal queue bent around known-open windows (see
    /// `RuntimeAnchorPolicy`), with newly shifted entries audited once.
    private func adjustedQueue() -> RuntimeAnchorPolicy.AdjustedQueue {
        let adjusted = adjustNominalQueue(rebuildQueue())
        logNewDeferrals(adjusted.entries)
        return adjusted
    }

    /// Reconcile one passed cloud one-shot even when the corresponding local
    /// entry is not due because runtime state shifted it later. `armedFor -
    /// lead` is the effective local fire that the one-shot backed; match that
    /// against either today's effective queue or the entry's nominal identity.
    /// Returning after one mutation forces the caller to rebuild before it
    /// considers another account.
    private func reconcilePassedCloudFire(_ cloudStates: CloudFallbackState) async -> Bool {
        guard cloudFallbackEnabled else { return false }

        let nominal = rebuildQueue()
        let adjusted = adjustNominalQueue(nominal)

        for id in accountIDs where providersByID[id]?.supportsCloudAnchorRoutines == true {
            let state = cloudStates.accounts[id] ?? AccountCloudFallbackState()
            guard let armedFor = state.armedFor,
                  state.triggerID != nil,
                  !state.disabled,
                  state.lastError == nil,
                  now() >= armedFor
            else { continue }

            let coveredFire = armedFor.addingTimeInterval(-cloudLead)
            if let resolved = lastResolvedFire[id], resolved >= coveredFire { continue }

            let sameInstant: (Date, Date) -> Bool = {
                abs($0.timeIntervalSince($1)) < 1
            }
            let entry = adjusted.entries.first {
                $0.accountID == id && sameInstant($0.fireAt, coveredFire)
            } ?? nominal.first {
                $0.accountID == id && sameInstant($0.nominalFireAt, coveredFire)
            }

            // `resets_at` is the only exact cloud-anchor timestamp available.
            // Probe once after the one-shot passes; the production reader never
            // refreshes credentials, because `/status` itself can anchor.
            if let reading = await cloudUsageReader(id),
               let resets = reading.primaryResetsAt,
               resets <= now().addingTimeInterval(
                   windowSeconds + RuntimeAnchorPolicy.margin)
            {
                let candidate = AccountWindowState(
                    expiresAt: resets, evidence: .usage, observedAt: reading.fetchedAt)
                windowStates[id] = RuntimeAnchorPolicy.merged(windowStates[id], candidate)
            }

            if windowWasAlreadyOpen(id, at: armedFor) {
                // The one-shot itself was a phantom. Resolve that obsolete
                // backstop so the engine can move it forward. If its local
                // entry is still pending, leave that entry for the real expiry.
                logCloudPhantom(accountID: id)
                markCloudFireResolved(id, fireAt: coveredFire)
                let checkpoint = adjustedQueue()
                writeStatus(upcoming: checkpoint.entries, current: nil)
                return true
            }

            // The slot may already be watermarked because its local child
            // failed or returned anchor-unknown. The unresolved backstop still
            // ran and can be the event that truly anchored the account, so
            // account for it even without a pending queue entry.
            if let entry { markHandled(entry) }
            logCloudCoveredSkip(QueueEntry(fireAt: coveredFire, accountID: id))
            noteCloudAnchorEvidence(id, armedFor: armedFor)
            markCloudFireResolved(id, fireAt: coveredFire)
            let checkpoint = adjustedQueue()
            writeStatus(upcoming: checkpoint.entries, current: nil)
            return true
        }
        return false
    }

    /// Did the best-known window begin before this cloud event? If so, a turn
    /// at `eventAt` cannot move its reset. For exact usage evidence the implied
    /// anchor is `expiresAt - window`. Conservative evidence means only "may
    /// have anchored" and cannot prove the cloud turn was redundant.
    /// Physically impossible state is ignored.
    private func windowWasAlreadyOpen(_ accountID: String, at eventAt: Date) -> Bool {
        guard let state = windowStates[accountID] else { return false }
        return SchedulerDaemon.exactWindowPredates(
            state, eventAt: eventAt, window: windowSeconds)
    }

    /// Whether exact reset evidence proves this window began materially before
    /// `eventAt`. A one-minute attribution tolerance avoids calling the event a
    /// phantom merely because the provider rounded `resets_at` or its clock is
    /// a few seconds behind ours.
    private static func exactWindowPredates(
        _ state: AccountWindowState,
        eventAt: Date,
        window: TimeInterval,
        clockTolerance: TimeInterval = RuntimeAnchorPolicy.margin)
        -> Bool
    {
        guard state.evidence == .usage,
              state.expiresAt > eventAt,
              state.expiresAt <= eventAt.addingTimeInterval(window + clockTolerance)
        else { return false }
        // A reading obtained no later than the event is direct proof that its
        // window was already open; no timestamp derivation or clock tolerance
        // is needed for that case.
        if state.observedAt <= eventAt { return true }
        let impliedAnchor = state.expiresAt.addingTimeInterval(-window)
        return impliedAnchor < eventAt.addingTimeInterval(-clockTolerance)
    }

    private func markCloudFireResolved(_ accountID: String, fireAt: Date) {
        if let prior = lastResolvedFire[accountID], prior >= fireAt { return }
        lastResolvedFire[accountID] = fireAt
    }

    /// Consume one weekly slot in nominal plan time. Effective deferral can
    /// reorder entries, so never move an account's watermark backwards.
    private func markHandled(_ entry: QueueEntry) {
        if let prior = lastHandled[entry.accountID], prior >= entry.nominalFireAt { return }
        lastHandled[entry.accountID] = entry.nominalFireAt
    }

    /// A deferred/phantom local turn should also cancel its old +5m cloud
    /// backstop when exact reset evidence proves that backstop would land in
    /// the same already-open window. Otherwise leave it armed: it may still be
    /// the event that anchors after a reset occurring before the +5m mark.
    private func resolveRedundantBackstopIfProven(for entry: QueueEntry) {
        let backstopAt = entry.fireAt.addingTimeInterval(cloudLead)
        if windowWasAlreadyOpen(entry.accountID, at: backstopAt) {
            markCloudFireResolved(entry.accountID, fireAt: entry.fireAt)
        }
    }

    /// Fold the shared usage cache into the window evidence. The cache is the
    /// ground-truth channel: the app's refreshes, `am usage`, and the ping
    /// child's pre/postflight fetches all save readings there, and a reading's
    /// `resets_at` is the exact window expiry. Stamped so a quiet cache costs
    /// nothing per tick; `force` re-reads right after a ping child exits (it
    /// just wrote the reading that matters).
    private func foldUsageEvidence(force: Bool = false) {
        let fresh = stamp(workspace.usageCacheFile)
        guard force || fresh != usageStamp else { return }
        usageStamp = fresh
        let readings = UsageCache(workspace: workspace, fileManager: fileManager).load()
        for (id, reading) in readings {
            guard providersByID[id] != nil, let resets = reading.primaryResetsAt else { continue }
            // A response fetched after an anchor-unknown turn can still lag
            // and report the previous, already-expired reset. Do not let that
            // erase a live completion-time guard: it would put the next chained
            // fire back on the unsafe planned boundary. A live exact reset may
            // still tighten it immediately, and once the guard itself expires
            // an expired reading can replace it normally.
            if let current = windowStates[id],
               current.evidence == .conservative,
               current.expiresAt > reading.fetchedAt,
               resets <= reading.fetchedAt
            {
                continue
            }
            let candidate = AccountWindowState(
                expiresAt: resets, evidence: .usage, observedAt: reading.fetchedAt)
            windowStates[id] = RuntimeAnchorPolicy.merged(windowStates[id], candidate)
        }
    }

    /// Record what an anchored (or possibly-anchored) local ping implies about
    /// the real window: prefer the exact reading the child's postflight fetch
    /// saved; fall back to the conservative bound "the anchoring turn finished
    /// by now, so the window can't outlive now + window" when no reading from
    /// this fire exists (postflight failed, or its cache write lost a race).
    private func noteAnchorEvidence(_ accountID: String, since fireStarted: Date) {
        foldUsageEvidence(force: true)
        if let state = windowStates[accountID],
           state.evidence == .usage,
           state.observedAt >= fireStarted,
           state.expiresAt > fireStarted
        {
            return
        }
        noteConservativeAnchor(accountID, since: now())
    }

    private func noteConservativeAnchor(_ accountID: String, since observed: Date) {
        let candidate = AccountWindowState(
            expiresAt: observed.addingTimeInterval(windowSeconds),
            evidence: .conservative,
            observedAt: observed)
        // This path is chosen only after a possibly-anchoring event whose
        // fresh usage evidence did not prove a live window. Override even a
        // same-instant usage snapshot: it may be the lagging response that
        // made the child return `anchorUnknown`, and keeping its past reset
        // would immediately reintroduce the phantom risk.
        windowStates[accountID] = candidate
    }

    /// Record a passed cloud one-shot. Its scheduled `armedFor` boundary is
    /// known even when the Mac notices it hours later, so falling back to
    /// detection-time + window would gratuitously push the next anchor hours
    /// late. Exact usage still wins when available; otherwise use
    /// `armedFor + window` and let the standard one-minute fire margin absorb
    /// routine dispatch/clock jitter.
    private func noteCloudAnchorEvidence(_ accountID: String, armedFor: Date) {
        foldUsageEvidence(force: true)
        if let state = windowStates[accountID],
           state.evidence == .usage
        {
            let describesCloudBoundary = state.expiresAt > armedFor
                && state.expiresAt <= armedFor.addingTimeInterval(
                    windowSeconds + RuntimeAnchorPolicy.margin)
            let describesCurrentWindow = RuntimeAnchorPolicy.isPlausibleLiveExpiry(
                state.expiresAt, at: now(), window: windowSeconds)
            // A later user/CLI anchor can supersede the one-shot before this
            // sleeping Mac notices it. Exact current state still wins even
            // when its reset cannot be attributed to `armedFor`.
            if describesCloudBoundary || describesCurrentWindow { return }
        }
        windowStates[accountID] = AccountWindowState(
            expiresAt: armedFor.addingTimeInterval(windowSeconds),
            evidence: .conservative,
            observedAt: now())
    }

    /// After a child bailed with "window still open": adopt the reading it
    /// saved. If none is usable (its cache write failed), hold the entry back
    /// one margin anyway — otherwise the next tick would respawn the child
    /// immediately, looping a spawn every poll interval until grace ran out.
    private func noteDeferredOutcomeEvidence(_ accountID: String) {
        foldUsageEvidence(force: true)
        if let state = windowStates[accountID],
           RuntimeAnchorPolicy.isPlausibleLiveExpiry(
               state.expiresAt, at: now(), window: windowSeconds)
        {
            return
        }
        let candidate = AccountWindowState(
            // Unknown expiry: retry one safety margin from now. `expiresAt`
            // itself is the boundary, so use now — the policy adds the margin.
            expiresAt: now(),
            evidence: .conservative,
            observedAt: now())
        windowStates[accountID] = RuntimeAnchorPolicy.merged(windowStates[accountID], candidate)
    }

    /// Resolve entries whose open window leaves no planner-worthy remainder:
    /// consume the nominal slot and say why, mirroring stale-drop logging
    /// (`ok: true, anchored: false` — nothing anchored *from this entry*).
    private func resolveCovered(_ covered: [QueueEntry]) {
        for entry in covered {
            markHandled(entry)
            markCloudFireResolved(entry.accountID, fireAt: entry.fireAt)
            let detail = "skipped: open window leaves no usable budget slice for this slot"
            audit.append(accountID: entry.accountID, action: "ping.skip", ok: true, detail: detail)
            activity.append(ActivityRecord(
                time: now(), accountID: entry.accountID, ok: true, anchored: false, detail: detail))
        }
    }

    /// Audit each deferral once per planned slot (and again only when the
    /// evidence moves the effective time by more than the margin) — the
    /// forensic record of "the 10:00 fire will run at 10:07, on purpose".
    private func logNewDeferrals(_ entries: [QueueEntry]) {
        for entry in entries {
            guard let planned = entry.plannedAt else { continue }
            let key = DeferralKey(accountID: entry.accountID, plannedAt: planned)
            if let logged = loggedDeferrals[key],
               abs(logged.timeIntervalSince(entry.fireAt)) <= RuntimeAnchorPolicy.margin
            {
                continue
            }
            loggedDeferrals[key] = entry.fireAt
            let deferMin = Int((entry.fireAt.timeIntervalSince(planned) / 60).rounded())
            audit.append(
                accountID: entry.accountID, action: "ping.defer", ok: true,
                detail: "deferred: 5h window still open at the planned minute — refiring \(deferMin)m past plan, just after the real expiry")
        }
        let horizon = now().addingTimeInterval(-2 * 24 * 3600)
        loggedDeferrals = loggedDeferrals.filter { $0.key.plannedAt > horizon }
    }

    /// Does a continuous painted-work stretch of at least `minimumDuration`
    /// overlap `[from, to)`? Runtime deferral must honor the same minimum slice
    /// floor as the planner; anchoring five hours for a few leftover minutes
    /// would violate the cadence invariant. Walks calendar days and maps block
    /// minutes as wall time so DST transitions stay correct.
    static func paintedWorkOverlaps(
        schedule: WorkSchedule,
        calendar: Calendar,
        from: Date,
        to: Date,
        minimumDuration: TimeInterval = 0)
        -> Bool
    {
        guard from < to else { return false }
        var overlaps: [(start: Date, end: Date)] = []
        var dayStart = calendar.startOfDay(for: from)
        while dayStart < to {
            // Calendar weekday (1 = Sun...7 = Sat) → schedule index (0 = Mon...6 = Sun).
            let weekdayMon0 = (calendar.component(.weekday, from: dayStart) + 5) % 7
            for block in schedule.blocks(forWeekday: weekdayMon0) {
                guard let blockStart = wallTime(
                    minuteOfDay: block.start, on: dayStart, calendar: calendar),
                      let blockEnd = wallTime(
                          minuteOfDay: block.end, on: dayStart, calendar: calendar)
                else { continue }
                if blockStart < to && blockEnd > from {
                    overlaps.append((max(blockStart, from), min(blockEnd, to)))
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }
            dayStart = next
        }
        guard !overlaps.isEmpty else { return false }
        let required = max(minimumDuration, 0)
        if required == 0 { return true }

        let sorted = overlaps.sorted { $0.start < $1.start }
        var runStart = sorted[0].start
        var runEnd = sorted[0].end
        for overlap in sorted.dropFirst() {
            if overlap.start <= runEnd {
                runEnd = max(runEnd, overlap.end)
            } else {
                if runEnd.timeIntervalSince(runStart) >= required { return true }
                runStart = overlap.start
                runEnd = overlap.end
            }
        }
        return runEnd.timeIntervalSince(runStart) >= required
    }

    /// Map a painted wall-clock minute onto one calendar day. Adding elapsed
    /// minutes to midnight is wrong on DST transitions (03:00 becomes 04:00 on
    /// spring-forward day, and 03:00 becomes the repeated 02:00 in autumn).
    /// Match clock components instead, using the first repeated occurrence and
    /// Calendar's next-valid-time policy for a nonexistent hour.
    private static func wallTime(
        minuteOfDay: Int,
        on dayStart: Date,
        calendar: Calendar)
        -> Date?
    {
        if minuteOfDay == 24 * 60 {
            return calendar.date(byAdding: .day, value: 1, to: dayStart)
        }
        guard (0..<(24 * 60)).contains(minuteOfDay) else { return nil }
        var components = DateComponents()
        components.hour = minuteOfDay / 60
        components.minute = minuteOfDay % 60
        components.second = 0
        guard let result = calendar.nextDate(
            after: dayStart.addingTimeInterval(-1),
            matching: components,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward),
              let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart),
              result < nextDay
        else { return nil }
        return result
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
            currentAccountID: current,
            inFlight: inFlight,
            windowStates: windowStates,
            lastResolvedFire: lastResolvedFire))
    }

    // MARK: - the real ping runner

    /// Read exact usage after a cloud one-shot without ever invoking the
    /// delegated `/status` refresh. Passing `cachedReading: nil` is deliberate:
    /// `UsageService` then fails with `refreshDeferred` when credentials are
    /// expired instead of risking a refresh that anchors by itself. Successful
    /// readings join the shared cache for the app and the next daemon tick.
    public static func liveCloudUsageReader(
        workspace: Workspace,
        fileManager: FileManager = .default)
        -> CloudUsageReader
    {
        nonisolated(unsafe) let fileManager = fileManager
        return { accountID in
            guard let account = try? AccountStore(
                workspace: workspace, fileManager: fileManager).find(accountID),
                  account.status == .connected
            else { return nil }
            guard let reading = try? await UsageService.fetch(
                account: account,
                gate: UsageRateLimitGate(workspace: workspace, fileManager: fileManager),
                allowInteraction: false,
                cachedReading: nil,
                log: NetworkLog(workspace: workspace))
            else { return nil }

            let cache = UsageCache(workspace: workspace, fileManager: fileManager)
            var readings = cache.load()
            readings[accountID] = reading
            cache.save(readings)
            return reading
        }
    }

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
