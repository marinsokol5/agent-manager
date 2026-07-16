import AgentManagerCore
import Foundation

/// Journey 4 — the App's bridge into the Core scheduling operations. The painted
/// `schedule` drives a live in-memory plan (so the grid + coverage update as you
/// paint); persistence and launchd work go through the same `ScheduleStore` /
/// `Scheduler` the CLI uses, so neither surface owns state.
extension AppModel {
    var scheduleStore: ScheduleStore { ScheduleStore(workspace: workspace) }

    /// Connected, non-excluded accounts in scheduling (stagger) order.
    /// `accounts` is already in canonical priority order, so filtering preserves
    /// it — the same eligibility rule and order `Scheduler.schedulableAccounts`
    /// stages token windows in.
    var scheduledAccounts: [Account] {
        accounts.filter { $0.status == .connected && !$0.excludedFromScheduling }
    }

    /// The live multi-account plan for one weekday, computed from in-memory
    /// state — a projection of the same continuous weekly geometry the daemon
    /// fires, so the coverage screen can never show a ping that won't happen
    /// (planning a weekday in isolation would, whenever painted work hugs
    /// midnight). The compiled week is memoised; painting invalidates it by
    /// changing `schedule`.
    func plan(forWeekday d: Int) -> MultiDayPlan {
        let ids = scheduledAccounts.map(\.id)
        let weekly: [AccountDayPlan]
        if let memo = weeklyPlanMemo, memo.ids == ids, memo.schedule == schedule {
            weekly = memo.weekly
        } else {
            weekly = LaunchAgentPlanner.weeklyPings(accountIDs: ids, schedule: schedule)
            weeklyPlanMemo = (ids, schedule, weekly)
        }
        return LaunchAgentPlanner.displayPlan(forWeekday: d, weekly: weekly, schedule: schedule)
    }

    // MARK: - paint (edit `schedule`)

    func reloadSchedule() {
        schedule = (try? scheduleStore.load()) ?? WorkSchedule()
    }

    /// How long the calendar must sit untouched before an edit lands in
    /// `schedule.json`. The daemon re-arms each account's cloud routine within
    /// a tick of the file changing, so writing mid-editing-burst turns every
    /// repaint into a routines-API PATCH; batching until the user has clearly
    /// stopped keeps that churn to one write per editing session.
    static let scheduleSaveDebounceInterval: TimeInterval = 30

    /// Persist the in-memory schedule, debounced: (re)starts a quiet-period
    /// timer, and the write happens only once `scheduleSaveDebounceInterval`
    /// passes with no further edits. Every schedule mutation funnels through
    /// here. The pending write is flushed early when something is about to
    /// *read* `schedule.json` (`setSchedulerActive`) and on app quit.
    func saveSchedule() {
        scheduleSaveDebounce?.cancel()
        scheduleSaveDebounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(AppModel.scheduleSaveDebounceInterval))
            guard !Task.isCancelled else { return }
            self?.scheduleSaveDebounce = nil
            self?.persistScheduleNow()
        }
    }

    /// Write `schedule.json` now, cancelling any pending debounced save.
    /// Harmless when nothing is pending (the store's write is idempotent).
    func persistScheduleNow() {
        scheduleSaveDebounce?.cancel()
        scheduleSaveDebounce = nil
        try? scheduleStore.save(schedule)
    }

    /// Set one cell on/off without persisting (called rapidly during a drag);
    /// the view persists once on gesture end via `saveSchedule()`.
    func setHour(weekday d: Int, hour h: Int, on: Bool) {
        let has = schedule.hours(forWeekday: d).contains(h)
        if has != on { schedule.toggle(weekday: d, hour: h) }
    }

    /// Replace one weekday's selected hours wholesale, without persisting. The
    /// grid's range-paint reapplies the whole column on every pointer move
    /// (Google-Calendar style), so dragging back toward the anchor shrinks the
    /// selection; the view saves once on gesture end via `saveSchedule()`.
    func setColumnHours(weekday d: Int, hours: [Int]) {
        schedule.set(weekday: d, hours: hours)
    }

    /// Clear a single day and persist (the per-day ⌫ on the grid header).
    func clearDay(_ d: Int) {
        schedule.set(weekday: d, hours: [])
        saveSchedule()
    }

    func toggleHour(weekday d: Int, hour h: Int) {
        schedule.toggle(weekday: d, hour: h)
        saveSchedule()
    }

    /// Overwrite Tue–Fri with Monday's exact selection (a clean replace, not a
    /// merge). Reassigns the whole `schedule` so the @Observable mutation is
    /// unambiguous and every painted-grid snapshot redraws immediately.
    func copyMondayToWeekdays() {
        var next = schedule
        let mon = next.hours(forWeekday: 0)
        for d in 1..<5 { next.set(weekday: d, hours: mon) }
        schedule = next
        saveSchedule()
    }

    func clearAllHours() {
        schedule.clearAll()
        saveSchedule()
    }

    func setWindow(minutes: Int) {
        schedule.windowMinutes = max(30, minutes)
        saveSchedule()
    }

    /// How many connected accounts should run concurrently (parallel lanes), and
    /// the live resolved value (defaults to "all of them").
    var parallelAccountCap: Int { max(scheduledAccounts.count, 1) }
    var resolvedParallelism: Int { schedule.resolvedParallelism(accountCount: scheduledAccounts.count) }

    /// Set the desired parallelism. Picking the max (or more) stores `nil` so the
    /// preference stays "all accounts" as the user connects more later.
    func setParallelism(_ n: Int) {
        let cap = parallelAccountCap
        schedule.parallelism = (n >= cap) ? nil : max(n, 1)
        saveSchedule()
    }

    /// The engine's budget-slice floor as shown in the coverage stepper, and
    /// its bounds: 15 minutes up to one full window (beyond which nothing
    /// could ever satisfy it).
    var minSliceMinutes: Int { schedule.resolvedMinSliceMinutes }
    var minSliceRange: ClosedRange<Int> {
        minSliceFloorMinutes...max(schedule.windowMinutes, minSliceFloorMinutes)
    }

    /// Set the floor. The default stores `nil` — old `schedule.json` files stay
    /// byte-identical until the user actually reaches for the knob (mirrors how
    /// `setParallelism` stores the max as `nil`).
    func setMinSlice(minutes: Int) {
        let clamped = min(max(minutes, minSliceRange.lowerBound), minSliceRange.upperBound)
        schedule.minSliceMinutes = (clamped == defaultMinSliceMinutes) ? nil : clamped
        saveSchedule()
    }

    // MARK: - the Scheduler toggle / monitor (Core operations, off-main)

    /// The sidebar's "Scheduler active" switch. On = activate the resident
    /// scheduler on the painted plan (installs the single agent on first use —
    /// the only time macOS shows its one "background items" notification);
    /// off = deactivate (the painted calendar and the idling agent both stay).
    /// While active, calendar repaints and account changes flow to the daemon
    /// on their own — there is no apply step.
    ///
    /// The switch flips optimistically; the trailing `refreshMonitoring()`
    /// reconciles it with what `scheduler.json` actually says (e.g. snaps back
    /// off if activation found no connected accounts or failed).
    func setSchedulerActive(_ on: Bool) {
        guard !scheduleBusy, on != schedulerActive else { return }
        // Activation replans off `schedule.json` — a debounced paint still in
        // memory must land first or the daemon starts on the stale calendar.
        persistScheduleNow()
        scheduleBusy = true
        schedulerActive = on
        statusMessage = on ? "starting scheduler…" : "stopping scheduler…"
        let ws = workspace
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> (message: String, openSettings: Bool) in
                do {
                    if on {
                        let report = try Scheduler(workspace: ws).activate()
                        if report.noAccounts { return ("no connected accounts to schedule", false) }
                        var msg = "scheduler active — \(report.accounts.count) account(s) · \(report.totalPingsPerWeek) pings/week"
                        if report.agentUpdated { msg += " · background agent installed" }
                        // Bundled app: the agent registers via SMAppService and
                        // won't run until the one-time Login Items approval, which
                        // we deep-link open (mirrors the wake helper). Named with
                        // the variant's display name so it matches the Settings row.
                        if SchedulerAppService.registration() == .requiresApproval {
                            return ("scheduler set — allow \u{201C}\(AppVariant.displayName)\u{201D} in System Settings → Login Items (one time)", true)
                        }
                        if !report.agentLoaded { msg += " · agent failed to load" }
                        return (msg, false)
                    } else {
                        let report = try Scheduler(workspace: ws).deactivate()
                        return (report.wasActive ? "scheduler off — calendar kept" : "scheduler already off", false)
                    }
                } catch {
                    return ("scheduler \(on ? "activation" : "deactivation") failed: \(error)", false)
                }
            }.value
            scheduleBusy = false
            statusMessage = outcome.message
            if outcome.openSettings { SchedulerAppService.openSystemSettings() }
            refreshMonitoring()
        }
    }

    /// The "Wake Mac for pings" switch. Writes `wake.json` (which the running
    /// helper obeys within a minute) and, on first enable, gets a helper in
    /// place: running from the assembled .app it registers the **bundled**
    /// daemon via SMAppService — macOS then asks for a one-time approval in
    /// System Settings → Login Items, which we deep-link open. A pre-existing
    /// classic install (`sudo am wake install`) owns the same launchd label and
    /// is left alone; a bare-binary run without either falls back to pointing
    /// at the sudo command (the app never shells out for privileges).
    /// Toggling off only disables — the approved registration is kept so
    /// re-enabling never re-asks.
    func setWakeEnabled(_ on: Bool) {
        guard on != wakeEnabled else { return }
        wakeEnabled = on
        let ws = workspace
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> (message: String, openSettings: Bool) in
                do {
                    try WakeConfigStore(workspace: ws).save(WakeConfig(enabled: on))
                } catch {
                    return ("wake toggle failed: \(error)", false)
                }
                guard on else { return ("wake off — scheduled wakes clear within a minute", false) }

                let classic = WakeHelperSetup(workspace: ws).status()
                if classic.binaryInstalled && classic.plistInstalled {
                    return ("wake on — the Mac will wake for pings (AC-only when the lid is closed)", false)
                }
                switch WakeHelperAppService.registration() {
                case .enabled:
                    return ("wake on — the Mac will wake for pings (AC-only when the lid is closed)", false)
                case .unavailable:
                    return ("wake on — helper missing, run once: sudo am wake install", false)
                case .notRegistered, .notFound, .requiresApproval:
                    // May throw while approval is pending — the re-read decides.
                    try? WakeHelperAppService.register()
                    if WakeHelperAppService.registration() == .enabled {
                        return ("wake on — helper registered and running", false)
                    }
                    return ("wake on — allow \u{201C}Agent Manager\u{201D} in System Settings → Login Items (one time)", true)
                }
            }.value
            statusMessage = outcome.message
            if outcome.openSettings { WakeHelperAppService.openSystemSettings() }
            refreshMonitoring()
        }
    }

    /// The experimental Claude cloud-routine switch. Only writes
    /// `cloud-fallback.json` — the resident daemon does everything else on its
    /// next tick: arming one claude.ai routine per Claude account (on), or
    /// disabling them (off). No launchd, no prompt, nothing to install; the
    /// worst an abandoned routine can do is fire once (it's always a one-shot).
    func setCloudFallbackEnabled(_ on: Bool) {
        guard on != cloudFallbackEnabled else { return }
        cloudFallbackEnabled = on
        let ws = workspace
        Task {
            let message = await Task.detached(priority: .userInitiated) { () -> String in
                do {
                    // Load-modify-save so we never clobber the `cloudPrimary` bit.
                    var config = CloudFallbackConfigStore(workspace: ws).load()
                    config.enabled = on
                    try CloudFallbackConfigStore(workspace: ws).save(config)
                } catch {
                    return "cloud fallback toggle failed: \(error)"
                }
                AuditLog(workspace: ws).append(
                    accountID: nil, action: on ? "cloud.enable" : "cloud.disable",
                    ok: true, detail: "via app toggle")
                return on
                    ? "Claude cloud routine on — routines arm on the daemon's next tick"
                    : "Claude cloud routine off — routines are disabled on the daemon's next tick"
            }.value
            statusMessage = message
            refreshMonitoring()
        }
    }

    /// The Fallback / Routines only mode selector. Routines only promotes the
    /// routine from backstop to the *sole* anchor for scheduled Claude slots. Only
    /// writes `cloud-fallback.json` (load-modify-save, preserving `enabled`);
    /// the daemon arms at the exact planned fire and stops spawning local
    /// Claude pings on its next tick. No-op unless fallback is on.
    func setCloudPrimaryEnabled(_ on: Bool) {
        guard on != cloudPrimaryEnabled else { return }
        cloudPrimaryEnabled = on
        let ws = workspace
        Task {
            let message = await Task.detached(priority: .userInitiated) { () -> String in
                do {
                    var config = CloudFallbackConfigStore(workspace: ws).load()
                    config.cloudPrimary = on
                    try CloudFallbackConfigStore(workspace: ws).save(config)
                } catch {
                    return "cloud-primary toggle failed: \(error)"
                }
                AuditLog(workspace: ws).append(
                    accountID: nil, action: on ? "cloud.primary.enable" : "cloud.primary.disable",
                    ok: true, detail: "via app toggle")
                return on
                    ? "Routines only — cloud handles scheduled Claude slots; Test ping still uses the local method"
                    : "Fallback mode — cloud routine covers missed local Claude pings"
            }.value
            statusMessage = message
            refreshMonitoring()
        }
    }

    /// While the wake helper awaits its one-time System Settings approval,
    /// re-check every few seconds so the UI flips to "armed" on its own —
    /// SMAppService posts no notification when the user clicks Allow. The task
    /// exists only in the `requiresApproval` state (each refresh re-decides),
    /// so this costs nothing in steady state.
    private func scheduleWakeApprovalPollIfNeeded() {
        wakeApprovalPoll?.cancel()
        wakeApprovalPoll = nil
        guard wakeEnabled, wakeRegistration == .requiresApproval else { return }
        wakeApprovalPoll = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.refreshMonitoring()
        }
    }

    /// The scheduler-agent twin of `scheduleWakeApprovalPollIfNeeded`: while the
    /// SMAppService scheduler sits in `requiresApproval`, re-check every few
    /// seconds so the sidebar flips to active on its own once the user clicks
    /// Allow (SMAppService posts no notification). Exists only in that state.
    private func scheduleSchedulerApprovalPollIfNeeded() {
        schedulerApprovalPoll?.cancel()
        schedulerApprovalPoll = nil
        guard schedulerActive, schedulerRegistration == .requiresApproval else { return }
        schedulerApprovalPoll = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.refreshMonitoring()
        }
    }

    /// Reload the scheduler status, recent ping log, and the unified Logs feed
    /// (all touch the filesystem / `launchctl`, so they run off-main).
    func refreshMonitoring() {
        let ws = workspace
        monitoringRefreshing = true
        Task {
            let result = await Task.detached(priority: .utility) {
                () -> (status: Scheduler.StatusReport, wake: WakeHelperSetup.Status,
                       registration: WakeHelperAppService.Registration,
                       schedReg: SchedulerAppService.Registration,
                       wakeProcess: WakeHelperSetup.ProcessState,
                       cloudEnabled: Bool, cloudPrimary: Bool, cloudState: CloudFallbackState,
                       recent: [ActivityRecord], logs: [MonitoringLogEntry]) in
                let scheduler = Scheduler(workspace: ws)
                // Heal a daemon running a binary older than the one launchd
                // would relaunch (e.g. an upgrade installed while it was
                // running, before the daemon's own self-restart existed).
                // No-op unless genuinely stale; the restarted daemon's fresh
                // heartbeat shows up on the next refresh.
                scheduler.restartDaemonIfOutdated()
                let wakeSetup = WakeHelperSetup(workspace: ws)
                let wake = wakeSetup.status()
                let wakeProcess = wakeSetup.processState()
                let registration = WakeHelperAppService.registration()
                let schedReg = SchedulerAppService.registration()
                let cloudConfig = CloudFallbackConfigStore(workspace: ws).load()
                let cloudState = CloudFallbackStateStore(workspace: ws).load()
                // Monitoring shows everything from the last 48 hours (the UI says
                // so); the limit is only a guard against a pathological file.
                let cutoff = Date().addingTimeInterval(-48 * 3600)
                let activity = ActivityLog(workspace: ws).readRecent(limit: 2000, since: cutoff)
                let audit = AuditLog(workspace: ws).readRecent(limit: 2000, since: cutoff)
                let network = NetworkLog(workspace: ws).readRecent(limit: 2000, since: cutoff)
                let logs = MonitoringLogEntry.merge(activity: activity, audit: audit, network: network)
                return (scheduler.status(), wake, registration, schedReg, wakeProcess, cloudConfig.enabled, cloudConfig.cloudPrimary, cloudState, activity, logs)
            }.value
            let wasAwaitingWakeApproval = self.wakeRegistration == .requiresApproval
            let wasAwaitingSchedApproval = self.schedulerRegistration == .requiresApproval
            self.schedulerStatus = result.status
            self.schedulerActive = result.status.active
            self.schedulerRegistration = result.schedReg
            self.wakeStatus = result.wake
            self.wakeEnabled = result.wake.enabled
            self.wakeRegistration = result.registration
            self.wakeProcessState = result.wakeProcess
            self.cloudFallbackEnabled = result.cloudEnabled
            self.cloudPrimaryEnabled = result.cloudPrimary
            self.cloudFallbackState = result.cloudState
            if wasAwaitingWakeApproval && result.registration == .enabled {
                self.statusMessage = "wake helper approved — active"
            }
            if wasAwaitingSchedApproval && result.schedReg == .enabled {
                self.statusMessage = "scheduler approved — active"
            }
            self.scheduleWakeApprovalPollIfNeeded()
            self.scheduleSchedulerApprovalPollIfNeeded()
            self.healWakeHelperIfSpawnFailed()
            self.healSchedulerRegistrationIfTornDown()
            self.recentActivity = result.recent
            self.monitoringLogs = result.logs
            self.monitoringRefreshedAt = Date()
            self.monitoringRefreshing = false
        }
    }

    /// Self-heal a torn-down scheduler-agent registration. The failure mode: a
    /// cask/brew upgrade *deletes* the app bundle before laying down the new
    /// one, and macOS tears the SMAppService/BTM registration down with it —
    /// afterwards `scheduler.json` still says active (and a leftover KeepAlive
    /// job may even keep the daemon running for now), but the registration
    /// reads `.notRegistered`, so nothing relaunches the daemon after the next
    /// logout/reboot. Nothing on the happy path ever re-registers (the toggle
    /// only writes `scheduler.json`; `ensureAgentViaAppService` runs only from
    /// `activate`), so heal it here on the monitoring refresh, next to
    /// `restartDaemonIfOutdated`. `.notFound` gets the same repair — launchd
    /// lost track of the service and Apple's fix is registering again from the
    /// current bundle. Registering from a genuinely unregistered state is a
    /// real state change, so it never re-notifies an already-approved agent;
    /// if macOS wants a fresh approval, the `requiresApproval` flow (card +
    /// poll) takes over. One attempt per app run.
    private func healSchedulerRegistrationIfTornDown() {
        guard schedulerActive,
              let previous = schedulerRegistration,
              previous == .notRegistered || previous == .notFound,
              !schedulerHealAttempted
        else { return }
        schedulerHealAttempted = true
        let ws = workspace
        Task {
            let message = await Task.detached(priority: .userInitiated) { () -> String in
                try? SchedulerAppService.register()
                let message: String
                switch SchedulerAppService.registration() {
                case .enabled:
                    message = "scheduler agent registration was lost — re-registered"
                case .requiresApproval:
                    message = "scheduler re-registered — allow \u{201C}\(AppVariant.displayName)\u{201D} in System Settings → Login Items"
                default:
                    message = "scheduler re-registration didn't take — flip \u{201C}Scheduler active\u{201D} off and on"
                }
                AuditLog(workspace: ws).append(
                    accountID: nil, action: "scheduler.reregister", ok: true,
                    detail: "registration read \(String(describing: previous)) while active — \(message)")
                return message
            }.value
            statusMessage = message
            refreshMonitoring() // re-reads state; the once-per-run flag stops a loop
        }
    }

    /// Self-heal a bundled wake helper that launchd can't start. The failure
    /// mode: the Background-items approval binds to the bundle's signature, so
    /// a re-signed rebuild can leave the registration reading `.enabled` while
    /// every spawn fails (`job state = spawn failed`, exit 78, forever) — and
    /// nothing surfaces it. Re-registering from the current bundle refreshes
    /// what BTM has recorded; if macOS wants a fresh approval, the existing
    /// `requiresApproval` flow (card state + poll) takes over from there.
    /// Bundled installs only — a classic install heals via `sudo am wake
    /// install`, which the card already points at. One attempt per app run.
    private func healWakeHelperIfSpawnFailed() {
        guard case .spawnFailed(let detail) = wakeProcessState,
              wakeEnabled,
              wakeRegistration == .enabled,
              !(wakeStatus.map { $0.binaryInstalled && $0.plistInstalled } ?? false), // not a classic install
              !wakeHealAttempted
        else { return }
        wakeHealAttempted = true
        let ws = workspace
        Task {
            let message = await Task.detached(priority: .userInitiated) { () -> String in
                try? WakeHelperAppService.unregister()
                try? WakeHelperAppService.register()
                let message: String
                switch WakeHelperAppService.registration() {
                case .enabled:
                    message = "wake helper wasn't starting — re-registered"
                case .requiresApproval:
                    message = "wake helper re-registered — allow \u{201C}Agent Manager\u{201D} in System Settings → Login Items"
                default:
                    message = "wake helper re-registration didn't take — flip \u{201C}Wake Mac for pings\u{201D} off and on"
                }
                AuditLog(workspace: ws).append(
                    accountID: nil, action: "wake.reregister", ok: true,
                    detail: "spawn failed (\(detail)) — \(message)")
                return message
            }.value
            statusMessage = message
            refreshMonitoring() // re-reads state; the once-per-run flag stops a loop
        }
    }
}
