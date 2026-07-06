import Foundation

/// The journey-4 orchestration both surfaces drive through one Core operation
/// (UI/CLI parity): make sure the single resident scheduler agent is installed,
/// switch its queue on/off (the app's "Scheduler active" toggle), and report
/// status.
///
/// The launchd surface is deliberately minimal — one `KeepAlive` agent
/// (`com.agent-manager.scheduler`) installed once. **The toggle never churns
/// launchd**: it writes the active flag in `scheduler.json` and the resident
/// `SchedulerDaemon` picks it up on its next tick. That's the fix for
/// macOS 13+'s "background items added" notification, which fires on every
/// LaunchAgent (re)registration and used to appear once per account on every
/// apply. The agent's plist is rewritten/re-bootstrapped only when its rendered
/// content actually changed (an `am` path or environment change — rare).
///
/// Everything is injectable (workspace, LaunchAgents dir, `launchctl` runner,
/// the `am` program path, base environment) so the whole
/// activate/deactivate/uninstall flow is unit-testable without touching the
/// real launchd.
public struct Scheduler {
    let workspace: Workspace
    let launchAgentsDir: URL
    let launchd: LaunchdController
    let program: String
    let baseEnvironment: [String: String]
    let fileManager: FileManager

    public init(
        workspace: Workspace,
        launchAgentsDir: URL? = nil,
        launchd: LaunchdController = LaunchdController(),
        program: String? = nil,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default)
    {
        self.workspace = workspace
        self.launchAgentsDir = launchAgentsDir ?? Workspace.launchAgentsDir(environment: baseEnvironment, fileManager: fileManager)
        self.launchd = launchd
        self.program = program ?? Scheduler.resolveAmProgram(environment: baseEnvironment, fileManager: fileManager)
        self.baseEnvironment = baseEnvironment
        self.fileManager = fileManager
    }

    var store: AccountStore { AccountStore(workspace: workspace, fileManager: fileManager) }
    var scheduleStore: ScheduleStore { ScheduleStore(workspace: workspace, fileManager: fileManager) }
    var configStore: SchedulerConfigStore { SchedulerConfigStore(workspace: workspace, fileManager: fileManager) }

    /// Accounts eligible for scheduling: **connected** only (a queue entry that
    /// can't ping is just a daily failure), in canonical priority order. The
    /// order *is* the stagger phase order, and it matches what the app + CLI
    /// display.
    public func schedulableAccounts() throws -> [Account] {
        try store.load()
            .filter { $0.status == .connected }
            .inPriorityOrder()
    }

    public func schedule() throws -> WorkSchedule {
        try scheduleStore.load()
    }

    // MARK: - plan (display)

    /// One weekday's plan for the scheduled accounts (pings + usage rotation),
    /// for the `am plan` printout and the coverage screen.
    public struct DayPlan: Sendable {
        public var weekday: Int
        public var blocks: [Block]
        public var plan: MultiDayPlan
    }

    public func weeklyPlan() throws -> [DayPlan] {
        let accounts = try schedulableAccounts()
        let schedule = try scheduleStore.load()
        let ids = accounts.map(\.id)
        let parallelism = schedule.resolvedParallelism(accountCount: ids.count)
        return (0..<7).map { wd in
            let blocks = schedule.blocks(forWeekday: wd)
            let plan = ScheduleEngine.planDay(forAccountIDs: ids, workBlocks: blocks, window: schedule.windowMinutes, parallelism: parallelism, minSlice: schedule.resolvedMinSliceMinutes)
            return DayPlan(weekday: wd, blocks: blocks, plan: plan)
        }
    }

    // MARK: - activate

    public struct ActivationReport: Sendable {
        public struct AccountPlan: Sendable {
            public var accountID: String
            public var pingsPerWeek: Int
        }
        public var dryRun: Bool
        public var accountIDs: [String]
        public var accounts: [AccountPlan]
        public var totalPingsPerWeek: Int
        /// The agent plist was written this activation (first install, or the
        /// `am` path / baked environment changed). This is the only case where
        /// the user sees a macOS "background items" notification.
        public var agentUpdated: Bool
        /// The scheduler agent is loaded in launchd after this activation.
        public var agentLoaded: Bool
        public var loadOutput: String
        /// Set when there are no connected accounts to schedule (the scheduler
        /// stays inactive).
        public var noAccounts: Bool
    }

    /// Switch the resident scheduler on (the toggle's ON side). Writes the
    /// active flag and ensures the (single) agent is installed + loaded.
    /// Idempotent — and, crucially, a repeat activation with an unchanged agent
    /// plist makes **zero** launchd mutations, so flipping the toggle never
    /// re-triggers macOS's background-items notification after the first
    /// install.
    @discardableResult
    public func activate(dryRun: Bool = false) throws -> ActivationReport {
        let accounts = try schedulableAccounts()
        let schedule = try scheduleStore.load()
        let ids = accounts.map(\.id)
        let plans = ids.map { id in
            ActivationReport.AccountPlan(
                accountID: id,
                pingsPerWeek: LaunchAgentPlanner.entries(forAccountID: id, accountIDs: ids, schedule: schedule).count)
        }
        let total = plans.reduce(0) { $0 + $1.pingsPerWeek }

        var agentUpdated = false
        var agentLoaded = false
        var loadOutput = ""

        if !dryRun {
            try configStore.save(SchedulerConfig(active: !ids.isEmpty))
            // With nothing to schedule, don't install the agent just to idle —
            // but if it's already installed, keep it healthy (it simply idles
            // inactive, ready for the next activation).
            let ensured = try ensureAgent(installIfMissing: !ids.isEmpty)
            agentUpdated = ensured.updated
            agentLoaded = ensured.loaded
            loadOutput = ensured.output
            // A changed plist was just re-bootstrapped (fresh daemon); an
            // unchanged one may still host a daemon older than its binary.
            if !ensured.updated { restartDaemonIfOutdated() }
        }

        AuditLog(workspace: workspace, fileManager: fileManager).append(
            accountID: nil, action: "scheduler.activate", ok: true,
            detail: "\(ids.count) account(s), \(total) pings/week\(agentUpdated ? ", agent (re)installed" : "")\(dryRun ? " (dry-run)" : "")")

        return ActivationReport(
            dryRun: dryRun,
            accountIDs: ids,
            accounts: plans,
            totalPingsPerWeek: total,
            agentUpdated: agentUpdated,
            agentLoaded: agentLoaded,
            loadOutput: loadOutput,
            noAccounts: ids.isEmpty)
    }

    // MARK: - deactivate

    public struct DeactivationReport: Sendable {
        /// Whether this call actually flipped the active flag off (false = it
        /// was already inactive).
        public var wasActive: Bool
    }

    /// Switch the resident scheduler off (the toggle's OFF side). The painted
    /// calendar in `schedule.json` is untouched (toggling back on restores it),
    /// and the agent itself stays installed + loaded, idling — unloading it
    /// would just re-trigger the background-items notification on the next
    /// activation. `uninstall()` is the full-removal path.
    @discardableResult
    public func deactivate() throws -> DeactivationReport {
        let wasActive = configStore.load().active
        try configStore.save(SchedulerConfig(active: false))
        AuditLog(workspace: workspace, fileManager: fileManager).append(
            accountID: nil, action: "scheduler.deactivate", ok: true, detail: "scheduler off")
        return DeactivationReport(wasActive: wasActive)
    }

    // MARK: - uninstall

    public struct UninstallReport: Sendable {
        /// Every launchd label removed.
        public var removed: [String]
    }

    /// Zero-footprint removal: deactivate, then boot out + delete the scheduler
    /// agent. The next activation reinstalls from scratch (with the one-time
    /// notification that entails).
    @discardableResult
    public func uninstall() throws -> UninstallReport {
        try configStore.save(SchedulerConfig(active: false))
        var removed: [String] = []
        if SchedulerAppService.isAvailable {
            // Web/API DELETE isn't a thing here — unregister removes the launchd
            // job and the app-row entry outright.
            if SchedulerAppService.registration() != .notRegistered {
                try? SchedulerAppService.unregister()
                removed.append(LaunchAgentPlanner.schedulerLabel)
            }
        } else {
            let url = launchAgentsDir.appendingPathComponent(LaunchAgentPlanner.schedulerFilename)
            if fileManager.fileExists(atPath: url.path) || launchd.loadedLabels().contains(LaunchAgentPlanner.schedulerLabel) {
                launchd.bootout(label: LaunchAgentPlanner.schedulerLabel)
                try? fileManager.removeItem(at: url)
                removed.append(LaunchAgentPlanner.schedulerLabel)
            }
        }
        AuditLog(workspace: workspace, fileManager: fileManager).append(
            accountID: nil, action: "scheduler.uninstall", ok: true, detail: "removed \(removed.count) job(s)")
        return UninstallReport(removed: removed)
    }

    // MARK: - status (Activity badges)

    public struct StatusReport: Sendable {
        public struct AccountJobStatus: Sendable {
            public var accountID: String
            public var pingsPerWeek: Int
            /// The account's weekly triggers from the live plan (for "next fire"
            /// display) — the same inputs the daemon resolves its queue from.
            public var entries: [CalEntry]
            /// Scheduler active and part of the plan (i.e. the daemon will
            /// fire it).
            public var scheduled: Bool
        }
        public var active: Bool
        /// The scheduler agent's plist exists on disk.
        public var agentInstalled: Bool
        /// The scheduler agent is loaded in launchd right now.
        public var agentLoaded: Bool
        /// The daemon's own last heartbeat/queue snapshot (nil = never reported).
        public var daemon: SchedulerDaemonStatus?
        public var accounts: [AccountJobStatus]

        /// The agent is loaded and its daemon heartbeat is recent (regardless
        /// of whether the queue is active).
        public func isRunning(asOf now: Date = Date()) -> Bool {
            agentLoaded && (daemon?.isFresh(asOf: now) ?? false)
        }
    }

    /// One coherent picture of the scheduling machinery for the UI/CLI: intent
    /// (active), launchd truth (installed/loaded), the daemon's own heartbeat,
    /// and the per-account plan.
    public func status() -> StatusReport {
        let active = configStore.load().active
        let installed: Bool
        let loaded: Bool
        if SchedulerAppService.isAvailable {
            // Registered in any form counts as "installed"; only an approved
            // registration is "loaded" (launchd owns it). The daemon heartbeat
            // below is still the real "is it running" signal.
            let reg = SchedulerAppService.registration()
            installed = reg == .enabled || reg == .requiresApproval || reg == .notFound
            loaded = reg == .enabled
        } else {
            let url = launchAgentsDir.appendingPathComponent(LaunchAgentPlanner.schedulerFilename)
            installed = fileManager.fileExists(atPath: url.path)
            loaded = launchd.loadedLabels().contains(LaunchAgentPlanner.schedulerLabel)
        }
        let daemon = SchedulerStatusStore(workspace: workspace, fileManager: fileManager).load()

        let accounts = (try? schedulableAccounts()) ?? []
        let schedule = (try? scheduleStore.load()) ?? WorkSchedule()
        let ids = accounts.map(\.id)
        let perAccount = ids.map { id -> StatusReport.AccountJobStatus in
            let entries = LaunchAgentPlanner.entries(forAccountID: id, accountIDs: ids, schedule: schedule)
            return .init(accountID: id, pingsPerWeek: entries.count, entries: entries, scheduled: active && !entries.isEmpty)
        }
        return StatusReport(active: active, agentInstalled: installed, agentLoaded: loaded, daemon: daemon, accounts: perAccount)
    }

    // MARK: - stale daemon restart

    /// Bounce a running daemon that predates the `am` binary launchd would
    /// relaunch it from. The daemon has caught rebuilds itself since the
    /// self-restart shipped (see `SchedulerDaemon.runForever`), but a daemon
    /// *built before that* keeps running old code forever — this is how any
    /// surface heals it without churning the launchd registration (kickstart
    /// never re-registers, so no "background items" notification).
    ///
    /// Deliberately conservative — it only kicks when *all* of these hold:
    /// - the heartbeat is fresh (there is a live daemon to restart) and no
    ///   ping child is in flight (`currentAccountID == nil`);
    /// - the installed plist names a program whose on-disk mtime is newer than
    ///   the daemon's `startedAt` (comparing against the plist's program, not
    ///   our own `program`, so an app running from a different bundle copy can
    ///   never kick-loop a daemon whose binary hasn't actually changed);
    /// - the new binary has settled (`SchedulerDaemon.binarySettle`), so we
    ///   never relaunch into a half-written build artifact.
    @discardableResult
    public func restartDaemonIfOutdated(now: Date = Date()) -> Bool {
        guard let daemon = SchedulerStatusStore(workspace: workspace, fileManager: fileManager).load(),
              daemon.isFresh(asOf: now),
              daemon.currentAccountID == nil,
              let program = installedAgentProgram(),
              let attrs = try? fileManager.attributesOfItem(atPath: program),
              let binaryMtime = attrs[.modificationDate] as? Date,
              daemon.startedAt < binaryMtime,
              now.timeIntervalSince(binaryMtime) >= SchedulerDaemon.binarySettle
        else { return false }
        let result = launchd.kickstart(label: LaunchAgentPlanner.schedulerLabel)
        AuditLog(workspace: workspace, fileManager: fileManager).append(
            accountID: nil, action: "scheduler.kickstart", ok: result.ok,
            detail: "daemon (pid \(daemon.pid)) predates the am binary on disk — restarted via launchctl kickstart")
        return result.ok
    }

    /// The program the installed agent plist actually points launchd at —
    /// the ground truth of what a relaunch would exec. `nil` when no agent is
    /// installed (nothing to restart) or the plist is unreadable.
    func installedAgentProgram() -> String? {
        if SchedulerAppService.isAvailable {
            // The sealed plist's BundleProgram resolves to the bundle's own `am`
            // (== `program`); its on-disk mtime is the restart signal.
            return fileManager.isExecutableFile(atPath: program) ? program : nil
        }
        let url = launchAgentsDir.appendingPathComponent(LaunchAgentPlanner.schedulerFilename)
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String]
        else { return nil }
        return arguments.first
    }

    // MARK: - helpers

    struct EnsureResult {
        var updated: Bool
        var loaded: Bool
        var output: String
    }

    /// Make the scheduler agent match what we'd render today, touching launchd
    /// as little as possible:
    /// - plist content changed (or first install) → write + bootstrap;
    /// - unchanged and loaded → **do nothing** (the no-notification invariant);
    /// - unchanged but not loaded (e.g. user ran `launchctl bootout` by hand) →
    ///   bootstrap the existing file.
    func ensureAgent(installIfMissing: Bool) throws -> EnsureResult {
        if SchedulerAppService.isAvailable {
            return ensureAgentViaAppService(installIfMissing: installIfMissing)
        }
        let url = launchAgentsDir.appendingPathComponent(LaunchAgentPlanner.schedulerFilename)
        let onDisk = try? String(contentsOf: url, encoding: .utf8)
        if onDisk == nil && !installIfMissing {
            return EnsureResult(updated: false, loaded: false, output: "")
        }

        try fileManager.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: workspace.logsDir, withIntermediateDirectories: true)

        let rendered = LaunchAgentPlanner.renderSchedulerAgentPlist(
            program: program,
            root: workspace.root.path,
            logDir: workspace.logsDir.path,
            environment: schedulerEnvironment())
        if onDisk != rendered {
            try rendered.write(to: url, atomically: true, encoding: .utf8)
            let result = launchd.bootstrap(plistPath: url.path, label: LaunchAgentPlanner.schedulerLabel)
            return EnsureResult(updated: true, loaded: result.ok, output: result.output)
        }
        if launchd.loadedLabels().contains(LaunchAgentPlanner.schedulerLabel) {
            return EnsureResult(updated: false, loaded: true, output: "")
        }
        let result = launchd.bootstrap(plistPath: url.path, label: LaunchAgentPlanner.schedulerLabel)
        return EnsureResult(updated: false, loaded: result.ok, output: result.output)
    }

    /// The bundled-app counterpart to `ensureAgent`: register the sealed agent
    /// plist via SMAppService instead of writing/bootstrapping one in
    /// `~/Library/LaunchAgents`. Preserves the no-churn invariant — an already
    /// `.enabled` registration is left untouched (no re-`register()`, so no
    /// repeat background-items notification). `updated` marks the first
    /// registration (the one time macOS notifies). A `register()` throw while the
    /// approval is pending is expected, not fatal — we re-read the status after.
    func ensureAgentViaAppService(installIfMissing: Bool) -> EnsureResult {
        migrateAwayFromClassicAgent()
        let before = SchedulerAppService.registration()
        // Nothing to schedule and not yet registered → don't register just to idle.
        if before == .notRegistered && !installIfMissing {
            return EnsureResult(updated: false, loaded: false, output: "")
        }
        // Already approved and owned by launchd → zero mutation, zero notification.
        if before == .enabled {
            return EnsureResult(updated: false, loaded: true, output: "")
        }
        try? SchedulerAppService.register()
        let after = SchedulerAppService.registration()
        return EnsureResult(
            updated: before == .notRegistered,
            loaded: after == .enabled,
            output: after == .requiresApproval ? "awaiting approval in System Settings → Login Items" : "")
    }

    /// Clean handoff for users upgrading from the classic-bootstrap scheduler to
    /// the SMAppService one: an old `~/Library/LaunchAgents/…scheduler.plist`
    /// (same launchd label) would otherwise keep running and fight the
    /// SMAppService registration. Boot it out and delete it the first time we go
    /// through the app-service path; after that the file is gone and this is a
    /// cheap no-op. Only touches the classic *file* — never the SMAppService
    /// registration (which has no such file), so it can't disturb an already
    /// enabled agent.
    func migrateAwayFromClassicAgent() {
        let url = launchAgentsDir.appendingPathComponent(LaunchAgentPlanner.schedulerFilename)
        guard fileManager.fileExists(atPath: url.path) else { return }
        launchd.bootout(label: LaunchAgentPlanner.schedulerLabel)
        try? fileManager.removeItem(at: url)
        AuditLog(workspace: workspace, fileManager: fileManager).append(
            accountID: nil, action: "scheduler.migrate", ok: true,
            detail: "removed classic LaunchAgent; scheduler now managed via SMAppService")
    }

    /// The env baked into the scheduler agent's plist: a usable `PATH` (launchd's
    /// is nearly empty) + the same `SHELL`/`HOME`, plus any provider binary
    /// overrides (dev/test) — the daemon hands its environment straight down to
    /// the `am ping` children, which re-derive each account's config-home env
    /// from the account record at fire time. Deliberately account-independent so
    /// account changes never change the plist bytes.
    func schedulerEnvironment() -> [String: String] {
        let enriched = ChildEnvironment.enriched(base: baseEnvironment)
        var env: [String: String] = [:]
        if let path = enriched["PATH"] { env["PATH"] = path }
        if let shell = baseEnvironment["SHELL"] { env["SHELL"] = shell }
        if let home = baseEnvironment["HOME"] { env["HOME"] = home }
        for provider in Provider.allCases {
            if let bin = baseEnvironment[provider.binaryOverrideEnvKey] {
                env[provider.binaryOverrideEnvKey] = bin
            }
        }
        return env
    }

    /// Resolve the absolute path to the `am` binary that launchd should run for
    /// the scheduler daemon: explicit env override → a sibling named `am` next to
    /// the current executable (covers `am` itself and the App bundled next to it)
    /// → PATH search → bare `am`.
    static func resolveAmProgram(environment: [String: String], fileManager: FileManager) -> String {
        if let override = environment["AGENT_MANAGER_AM_BIN"]?.trimmingCharacters(in: .whitespaces), !override.isEmpty {
            return override
        }
        if let exe = Bundle.main.executablePath {
            if (exe as NSString).lastPathComponent == "am", fileManager.isExecutableFile(atPath: exe) {
                return exe
            }
            let sibling = (exe as NSString).deletingLastPathComponent + "/am"
            if fileManager.isExecutableFile(atPath: sibling) { return sibling }
        }
        if let resolved = ExecutableResolver.resolve("am", environment: environment, fileManager: fileManager) {
            return resolved
        }
        return "am"
    }
}
