import AgentManagerCore
import AppKit
import CoreGraphics
import Foundation
import Observation
import SwiftUI

/// App-wide state and the bridge to `AgentManagerCore`. Blocking Core calls
/// (ping/verify/reconcile drive a PTY for seconds) run off the main actor and
/// post results back, so the UI never freezes.
@MainActor
@Observable
final class AppModel {
    enum Route: String, CaseIterable, Identifiable {
        case agents, planner, monitoring, preferences
        var id: String { rawValue }

        var title: String {
            switch self {
            case .agents: "Agents"
            case .planner: "Planner"
            case .monitoring: "Monitoring"
            case .preferences: "Preferences"
            }
        }

        var systemImage: String {
            switch self {
            case .agents: "person.2.fill"
            case .planner: "calendar"
            case .monitoring: "waveform.path.ecg"
            case .preferences: "gearshape.fill"
            }
        }
    }

    /// How the menu-bar surfaces accounts. Chosen in **Preferences**.
    enum MenuBarMode: String, CaseIterable, Identifiable, Sendable {
        /// One status item summarising every agent's session usage at a glance.
        case merged
        /// One status item per agent — brand glyph above its session %.
        case individual
        /// No menu-bar presence at all.
        case hidden

        var id: String { rawValue }

        var title: String {
            switch self {
            case .merged: "Merged"
            case .individual: "Individual"
            case .hidden: "Hidden"
            }
        }

        var subtitle: String {
            switch self {
            case .merged: "One item showing every agent's session usage."
            case .individual: "A separate item per agent — icon above its session %."
            case .hidden: "Keep the menu bar clear; manage agents from this window."
            }
        }

        var systemImage: String {
            switch self {
            case .merged: "rectangle.3.group.fill"
            case .individual: "square.split.2x2.fill"
            case .hidden: "eye.slash.fill"
            }
        }
    }

    private static let menuBarModeDefaultsKey = "menuBarMode"

    var route: Route = .agents

    /// Which agent's row is expanded on the Agents screen — a single-open accordion,
    /// so opening one (or revealing one from elsewhere) collapses the rest.
    var expandedAgentID: String?
    /// The agent the Agents screen should scroll to; paired with `revealTick` so a
    /// repeat reveal of the *same* id still re-fires the scroll.
    var pendingRevealAgentID: String?
    var revealTick = 0

    /// Jump to the Agents screen, expand `id` (collapsing the others), and scroll to
    /// it — used by the sidebar recommendation card.
    func revealAgent(_ id: String) {
        route = .agents
        expandedAgentID = id
        pendingRevealAgentID = id
        revealTick &+= 1
    }

    /// Persisted menu-bar display mode (UserDefaults). Defaults to `.merged`.
    var menuBarMode: MenuBarMode = .merged {
        didSet {
            guard menuBarMode != oldValue else { return }
            UserDefaults.standard.set(menuBarMode.rawValue, forKey: Self.menuBarModeDefaultsKey)
        }
    }

    /// Persisted clock style for reset times (preferences.json, shared with the
    /// `am` CLI so both render times the same way). Defaults to 12-hour.
    var clockStyle: ClockStyle = .twelveHour {
        didSet {
            guard clockStyle != oldValue else { return }
            var prefs = preferencesStore.load()
            prefs.clockStyle = clockStyle
            preferencesStore.save(prefs)
        }
    }

    /// Persisted app appearance (preferences.json). Defaults to following macOS.
    var theme: AppTheme = .system {
        didSet {
            guard theme != oldValue else { return }
            var prefs = preferencesStore.load()
            prefs.theme = theme
            preferencesStore.save(prefs)
            applyTheme()
        }
    }

    /// Pin (or unpin) the whole app's appearance to `theme`. App-wide rather
    /// than per-window so every surface — main window, its sheets, alerts, the
    /// menu-bar popover — follows one switch. The menu-bar *status items* are
    /// the deliberate exception: `StatusBarController` pins them back to the
    /// system appearance so their glyphs stay legible on the real menu bar.
    func applyTheme() {
        NSApplication.shared.appearance = theme.nsAppearance
    }

    /// Bridges the menu-bar's "Open Agent Manager" button back to SwiftUI's
    /// `openWindow`, captured by `RootView` once the window scene is alive.
    var presentMainWindow: (() -> Void)?

    /// AppKit controller that owns the live `NSStatusItem`(s). Created lazily once
    /// the app is up so the menu bar reflects `menuBarMode` + per-account usage.
    private var statusBar: StatusBarController?
    var accounts: [Account] = []
    var statusMessage: String = ""
    /// Accounts with an action in flight (drives row spinners + button disabling).
    var busyAccountIDs: Set<String> = []
    /// Latest usage reading per account id; loaded from cache on launch and
    /// refreshed per-account on its own cadence.
    var usageReadings: [String: UsageReading] = [:]
    var usageErrors: [String: String] = [:]
    /// On-disk last-known usage, so the menu bar shows numbers without an eager
    /// network fetch on every launch.
    private let usageCache: UsageCache
    /// Persisted per-account "blocked until" gate honoring 429 / `Retry-After`,
    /// surviving relaunches so we never re-hammer a throttled endpoint.
    private let usageGate: UsageRateLimitGate
    /// On-disk display preferences shared with the `am` CLI.
    private let preferencesStore: PreferencesStore
    /// Records every HTTP exchange (request + response, token-redacted) so the
    /// Monitoring → Logs tab can show exactly what went over the wire.
    let networkLog: NetworkLog
    /// Accounts with a usage fetch in flight (dedupes timer + manual refresh).
    private var usageFetchInFlight: Set<String> = []
    /// Per-account cooldown before we'll ask the Claude CLI to refresh the token
    /// again, so an expired/revoked token can't make us spawn `claude` in a loop.
    private var claudeRefreshCooldownUntil: [String: Date] = [:]
    /// Background poller that services per-account refresh cadences.
    private var usageTimerTask: Task<Void, Never>?
    /// Background timer that re-runs the shared-config auto-reconcile on a daily
    /// cadence, so long-running app sessions pick up new depth-1 entries in a
    /// tracked source home without needing a restart (see `startReconcileTimer`).
    private var reconcileTimerTask: Task<Void, Never>?
    /// How often the daily auto-reconcile fires. Reconcile is local + idempotent,
    /// so "roughly daily" is plenty — precision across system sleep is irrelevant.
    static let reconcileInterval: TimeInterval = 24 * 60 * 60
    /// True while the session is locked (set by screen lock/unlock notifications).
    /// Combined with display-sleep, drives `isAway`, which pauses the usage poll so
    /// the app isn't hitting the Claude/Codex APIs around the clock while you're
    /// away — which both looks like batch automation and is when stray `/status`
    /// refreshes would anchor windows.
    private var screenLocked = false
    /// Lock/unlock + wake observers, retained so we can detach them in `deinit`.
    private var presenceObservers: [NSObjectProtocol] = []

    // MARK: - Journey 4 (schedule) state
    /// The painted weekly work-hour selection (mirrors `schedule.json`).
    var schedule = WorkSchedule()
    /// Memo for `plan(forWeekday:)`: the compiled continuous weekly plan for
    /// the given inputs. Compiling the week is the expensive step (it can run
    /// the whole-day search); projecting a weekday out of it is cheap, and the
    /// coverage view asks for one day per render. `@ObservationIgnored` because
    /// it is written from `plan(forWeekday:)` during view-body evaluation — an
    /// observed write there would invalidate the very body computing it.
    @ObservationIgnored
    var weeklyPlanMemo: (ids: [String], schedule: WorkSchedule, weekly: [AccountDayPlan])?
    /// The resident scheduler's full picture: active flag, launchd state, the
    /// daemon's heartbeat/queue, and the per-account plan (nil = not read yet).
    var schedulerStatus: Scheduler.StatusReport?
    /// What the sidebar's "Scheduler active" switch shows. Flipped optimistically
    /// by `setSchedulerActive` (so the control doesn't snap back while the Core
    /// call is in flight), then reconciled with ground truth — the flag in
    /// `scheduler.json` — every `refreshMonitoring()`.
    var schedulerActive = false
    /// SMAppService state of the bundled scheduler agent (the no-sudo path that
    /// groups it under the app's own Login Items row); from the last
    /// `refreshMonitoring()`. `.unavailable` when running as a bare executable
    /// (the classic `~/Library/LaunchAgents` bootstrap is used instead).
    var schedulerRegistration: SchedulerAppService.Registration?
    /// Alive only while the scheduler agent sits in `requiresApproval`: the same
    /// short re-poll loop the wake helper uses, so the UI notices the System
    /// Settings approval by itself (SMAppService posts no notification on Allow).
    var schedulerApprovalPoll: Task<Void, Never>?
    /// The scheduler-registration self-heal is attempted at most once per app
    /// run (same restraint as `wakeHealAttempted`): if re-registering doesn't
    /// take, looping on it would just churn BTM.
    var schedulerHealAttempted = false
    /// The "Wake Mac for pings" opt-in switch (mirrors `wake.json`), flipped
    /// optimistically by `setWakeEnabled` and reconciled on refresh.
    var wakeEnabled = false
    /// The root wake helper's ground truth (installed? serving this workspace?
    /// which wakes are armed in the RTC table?), from the last
    /// `refreshMonitoring()`. nil = not read yet.
    var wakeStatus: WakeHelperSetup.Status?
    /// SMAppService state of the bundled wake helper (the no-sudo path); from
    /// the last `refreshMonitoring()`. `.unavailable` when running as a bare
    /// executable instead of the assembled .app.
    var wakeRegistration: WakeHelperAppService.Registration?
    /// Alive only while the wake helper sits in `requiresApproval`: a short
    /// re-poll loop so the UI notices the System Settings approval by itself
    /// (SMAppService posts no notification when the user clicks Allow).
    /// Managed by `refreshMonitoring()`.
    var wakeApprovalPoll: Task<Void, Never>?
    /// Whether the wake helper *process* is actually alive (launchd ground
    /// truth) — the registration can read `.enabled` while every spawn fails.
    /// From the last `refreshMonitoring()`; drives the automatic re-register.
    var wakeProcessState: WakeHelperSetup.ProcessState?
    /// The self-heal is attempted at most once per app run: if re-registering
    /// doesn't fix the spawn failure, retrying in a loop won't either.
    var wakeHealAttempted = false
    /// The experimental "Cloud fallback" opt-in switch (mirrors
    /// `cloud-fallback.json`), flipped optimistically by
    /// `setCloudFallbackEnabled` and reconciled on refresh.
    var cloudFallbackEnabled = false
    /// Per-account cloud routine state (`cloud-fallback-state.json`, written by
    /// the daemon's engine) for the Monitoring row and the Preferences caption.
    /// nil = not read yet.
    var cloudFallbackState: CloudFallbackState?
    /// Recent ping outcomes for the Activity log (newest first).
    var recentActivity: [ActivityRecord] = []
    /// Unified, newest-first feed for Monitoring → Logs: pings, controlled runs,
    /// and HTTP exchanges merged from the activity / audit / network logs.
    var monitoringLogs: [MonitoringLogEntry] = []
    /// When `refreshMonitoring()` last completed. Drives the "Updated Xs ago"
    /// freshness label so a user never mistakes a stale feed for a live one —
    /// launchd keeps firing pings while this screen sits open.
    var monitoringRefreshedAt: Date?
    /// A monitoring refresh is in flight (drives the Refresh button spinner).
    var monitoringRefreshing = false
    /// An activate/deactivate is in flight (disables the Scheduler toggle and
    /// drives its spinner).
    var scheduleBusy = false

    let workspace: Workspace
    private var store: AccountStore { AccountStore(workspace: workspace) }

    init(workspace: Workspace = .standard()) {
        self.workspace = workspace
        self.usageCache = UsageCache(workspace: workspace)
        self.usageGate = UsageRateLimitGate(workspace: workspace)
        self.networkLog = NetworkLog(workspace: workspace)
        self.preferencesStore = PreferencesStore(workspace: workspace)
        if let raw = UserDefaults.standard.string(forKey: Self.menuBarModeDefaultsKey),
           let mode = MenuBarMode(rawValue: raw) {
            menuBarMode = mode
        }
        let prefs = preferencesStore.load()
        clockStyle = prefs.clockStyle
        theme = prefs.theme
        applyTheme() // didSet doesn't fire during init — apply the loaded theme explicitly
        reload()
        reconcileAll()
        loadCachedUsage()
        fetchMissingUsage()
        startUsageTimer()
        startReconcileTimer()
        setupPresenceObservers()
        reloadSchedule()
        refreshMonitoring()
    }

    var pinnedAccounts: [Account] { accounts.filter { $0.pinned } }

    /// The accounts the menu bar surfaces, in priority order. Usage only makes
    /// sense for connected agents; if any are pinned we honor that as a filter,
    /// otherwise every connected agent shows (so it works out of the box).
    var menuBarAccounts: [Account] {
        let connected = accounts.filter { $0.status == .connected }
        let pinned = connected.filter { $0.pinned }
        return pinned.isEmpty ? connected : pinned
    }

    /// The agent to run *right now* — see `AgentRecommender` in Core for the rule
    /// (soonest-to-expire, 10-min tolerance, most-tokens tiebreak). Shared with the
    /// CLI. `nil` when nothing is connected / has a usable reading.
    var recommendedAgent: Account? {
        guard let id = AgentRecommender.recommendedAgentID(accounts: accounts, readings: usageReadings)
        else { return nil }
        return accounts.first { $0.id == id }
    }

    /// Stand the menu bar up once the app is alive. Idempotent — safe to call
    /// from `RootView.onAppear`, which can fire more than once.
    func startMenuBar() {
        guard statusBar == nil else { return }
        statusBar = StatusBarController(model: self)
    }

    func reload() {
        do {
            var loaded = try store.load().inPriorityOrder()
            // Make ranks explicit and contiguous (0..<n) so the priority order is
            // stable and identical across the app, CLI, and scheduler. Persist only
            // when it actually changed (e.g. a freshly-added, unranked account).
            if loaded.enumerated().contains(where: { $0.element.rank != $0.offset }) {
                for i in loaded.indices { loaded[i].rank = i }
                try? store.save(loaded)
            }
            accounts = loaded
        } catch {
            statusMessage = "load failed: \(error)"
        }
    }

    /// Move an agent up (-1) or down (+1) in the priority order and persist the
    /// new contiguous ranks. The order drives token-window assignment and every
    /// list (app + CLI), so reordering here re-prioritizes scheduling too.
    func moveAccount(_ account: Account, by delta: Int) {
        guard let i = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        let j = i + delta
        guard accounts.indices.contains(j) else { return }
        var ordered = accounts
        ordered.swapAt(i, j)
        for idx in ordered.indices { ordered[idx].rank = idx }
        do {
            try store.save(ordered)
            // Animate the swap so the row visibly slides to its new rank
            // instead of snapping — the ForEach keys on `account.id`, so
            // SwiftUI interpolates the reorder when the change is animated.
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                accounts = ordered
            }
        } catch {
            statusMessage = "reorder failed: \(error)"
        }
    }

    // MARK: - Add (independent of login)

    /// Create the agent now (managed home + symlink farm), persisted logged-out.
    /// Returns an error string for synchronous validation failures (so the sheet
    /// can stay open), or `nil` on success. The filesystem work runs off-main.
    @discardableResult
    func addAccount(label: String, id: String, color: String, provider: Provider, source: URL?) -> String? {
        do { try AccountID.validate(id) } catch { return "\(error)" }
        if accounts.contains(where: { $0.id == id }) { return "an account with id '\(id)' already exists" }

        let ws = workspace
        let options = AccountProvisioner.Options(id: id, label: label, color: color, provider: provider, sourceHome: source)
        statusMessage = "adding \(label)…"
        Task {
            let error = await offMain { () -> String in
                do { _ = try AccountProvisioner(workspace: ws).create(options); return "" }
                catch { return "\(error)" }
            }
            statusMessage = error.isEmpty ? "added \(label) — log in when ready" : error
            reload()
        }
        return nil
    }

    /// Open Terminal to log this account in, and optimistically mark it
    /// connecting. The user verifies afterwards.
    func loginInTerminal(_ account: Account) {
        guard TerminalLauncher.login(account: account) else {
            statusMessage = "could not open Terminal"
            return
        }
        statusMessage = "opened Terminal — finish login there, then Verify"
        if var current = accounts.first(where: { $0.id == account.id }), current.status != .connected {
            current.status = .connecting
            try? store.upsert(current)
            reload()
        }
    }

    // MARK: - Row actions

    func ping(_ account: Account) {
        guard account.status == .connected, !busyAccountIDs.contains(account.id) else { return }
        let ws = workspace, id = account.id, label = account.label
        busyAccountIDs.insert(id)
        statusMessage = "pinging \(label)…"
        Task {
            let detail = await offMain {
                do { return try AccountPinger(workspace: ws).ping(id).detail }
                catch { return "\(error)" }
            }
            busyAccountIDs.remove(id)
            statusMessage = "\(label): \(detail)"
            reload()
        }
    }

    func verify(_ account: Account) {
        guard !busyAccountIDs.contains(account.id) else { return }
        let ws = workspace, id = account.id, label = account.label
        busyAccountIDs.insert(id)
        statusMessage = "verifying \(label)…"
        Task {
            let detail = await offMain { Self.verifyAndPersist(ws: ws, id: id) }
            busyAccountIDs.remove(id)
            statusMessage = "\(label): \(detail)"
            reload()
            // First time an account comes online with no usage yet, fetch once —
            // user-initiated, so it may anchor this account's first window. They
            // just connected it, so they're clearly present and this is the right
            // moment to pay that cost; `usageReadings == nil` keeps re-verifies of
            // an already-known account from re-anchoring.
            if let acct = accounts.first(where: { $0.id == id }),
               acct.status == .connected, usageReadings[id] == nil {
                refreshUsage(for: acct)
            }
        }
    }

    /// Auto-share: re-create any missing/broken shared-config symlinks for every
    /// account in the background. Runs at launch, so a new depth-1 entry in a
    /// tracked source home gets wired into each agent's home with no manual step;
    /// any *newly* linked names are recorded to the audit log. Best-effort — a
    /// failure for one account never blocks the others or the UI. (Replaces the old
    /// per-account "Reconcile config links" button.)
    func reconcileAll() {
        let ws = workspace
        let ids = accounts.map(\.id)
        guard !ids.isEmpty else { return }
        Task {
            await offMain {
                for id in ids { _ = Self.reconcile(ws: ws, id: id) }
            }
        }
    }

    func remove(_ account: Account, purge: Bool) {
        try? store.remove(account.id)
        if purge { try? FileManager.default.removeItem(at: account.homeURL) }
        AuditLog(workspace: workspace).append(
            accountID: account.id, action: "account.remove", ok: true,
            detail: purge ? "purged managed home" : "kept managed home")
        statusMessage = "removed \(account.label)"
        reload()
    }

    func updateAccount(_ account: Account, label: String, color: String, pinned: Bool, usageRefreshSeconds: Int?) {
        guard var current = accounts.first(where: { $0.id == account.id }) else { return }
        current.label = label.isEmpty ? current.label : label
        current.color = color
        current.pinned = pinned
        current.usageRefreshSeconds = usageRefreshSeconds
        try? store.upsert(current)
        statusMessage = "updated \(current.label)"
        reload()
    }

    func togglePinned(_ account: Account) {
        guard var current = accounts.first(where: { $0.id == account.id }) else { return }
        current.pinned.toggle()
        try? store.upsert(current)
        reload()
    }

    /// Populate the menu bar from the on-disk cache so numbers show instantly,
    /// with no network call.
    private func loadCachedUsage() {
        usageReadings = usageCache.load()
    }

    /// Launch-time fetch: only accounts we have *no* cached reading for. Cached
    /// accounts wait for their own cadence (serviced by the refresh timer).
    private func fetchMissingUsage() {
        for account in accounts where account.status == .connected && usageReadings[account.id] == nil {
            fetchUsage(for: account, userInitiated: false)
        }
    }

    /// Per-account cadence: refresh a connected account once its reading is older
    /// than that account's interval (default 1 min). Missing readings are also
    /// (re)fetched here as a backstop.
    private func refreshDueUsage() {
        let now = Date()
        for account in accounts where account.status == .connected && account.usageAutoRefreshEnabled {
            if let existing = usageReadings[account.id],
               now.timeIntervalSince(existing.fetchedAt) < account.usageRefreshInterval { continue }
            fetchUsage(for: account, userInitiated: false)
        }
    }

    /// `force` (the "Refresh usage" button) fetches every connected account now
    /// and bypasses the rate-limit gate; otherwise this just services what's due.
    func refreshUsage(force: Bool = false) {
        guard force else { refreshDueUsage(); return }
        for account in accounts where account.status == .connected {
            fetchUsage(for: account, userInitiated: true)
        }
    }

    /// Refresh just this account's usage now (the per-row refresh button),
    /// bypassing the rate-limit gate. No-op unless the account is connected.
    func refreshUsage(for account: Account) {
        guard account.status == .connected else { return }
        fetchUsage(for: account, userInitiated: true)
    }

    /// Whether a usage fetch is currently in flight for this account (drives the
    /// per-row refresh spinner).
    func isRefreshingUsage(_ account: Account) -> Bool {
        usageFetchInFlight.contains(account.id)
    }

    private func startUsageTimer() {
        usageTimerTask?.cancel()
        usageTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return } // model gone → stop polling
                // Pause polling while away (display asleep or screen locked): no
                // point hitting the APIs 24/7, and it keeps stray background token
                // refreshes from anchoring windows while you're not working.
                if self.isAway { continue }
                self.refreshDueUsage()
            }
        }
    }

    /// Re-run the shared-config auto-reconcile (`reconcileAll`) on a daily cadence,
    /// so a menu-bar app that stays up for days still picks up new depth-1 entries
    /// in a tracked source home. Mirrors `startUsageTimer`; unlike the usage poll,
    /// reconcile is a cheap, local, idempotent filesystem op (no network/token/
    /// anchor side effects), so it runs unconditionally — no `isAway` gate. The
    /// launch pass in `init` covers t=0; this handles every ~24h after.
    private func startReconcileTimer() {
        reconcileTimerTask?.cancel()
        reconcileTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.reconcileInterval))
                guard let self else { return }
                self.reconcileAll()
            }
        }
    }

    /// True when you're away from the machine — the display is asleep or the
    /// session is locked. We pause the usage poll then (see `startUsageTimer`).
    private var isAway: Bool {
        if screenLocked { return true }
        return CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    /// Observe screen lock/unlock and display wake so `isAway` is current and we
    /// poll again promptly when you come back (lock state isn't otherwise pushed
    /// to us). Display *sleep* needs no notification — `isAway` reads it live.
    private func setupPresenceObservers() {
        let dnc = DistributedNotificationCenter.default()
        presenceObservers.append(dnc.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenLocked = true }
        })
        presenceObservers.append(dnc.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.screenLocked = false
                self.refreshDueUsage() // catch up the moment you're back
            }
        })
        presenceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshDueUsage() }
        })
        // App activation: the moment the user comes back — typically from
        // System Settings after approving the wake helper — freshen the
        // monitoring snapshot so approval/heartbeat state updates itself.
        // Throttled: activations are frequent, and a snapshot <5 s old is fine.
        presenceObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let at = self.monitoringRefreshedAt, Date().timeIntervalSince(at) < 5 { return }
                self.refreshMonitoring()
            }
        })
    }

    private func fetchUsage(for account: Account, userInitiated: Bool) {
        let id = account.id
        guard !usageFetchInFlight.contains(id) else { return }
        usageFetchInFlight.insert(id)
        Task {
            defer { usageFetchInFlight.remove(id) }
            do {
                let reading = try await loadUsage(for: account, userInitiated: userInitiated)
                usageReadings[id] = reading
                usageErrors.removeValue(forKey: id)
                usageCache.save(usageReadings)
            } catch UsageFetchError.keychainAccessDeferred {
                // Background read can't prompt; keep cached usage. Only nudge the
                // user when we have nothing to show yet.
                if usageReadings[id] == nil {
                    usageErrors[id] = UsageFetchError.keychainAccessDeferred.localizedDescription
                }
            } catch {
                let msg = error.localizedDescription
                fputs("[usage] \(id): \(msg)\n", stderr)
                usageErrors[id] = msg
            }
        }
    }

    private func loadUsage(for account: Account, userInitiated: Bool) async throws -> UsageReading {
        switch account.provider {
        case .codex:
            return try await CodexUsageFetcher.fetch(
                account: account, gate: usageGate, userInitiated: userInitiated, log: networkLog)
        case .claude:
            guard let service = account.keychainService else { throw UsageFetchError.keychainReadFailed }
            // Read the credential ONCE. Background reads are no-UI (never prompt);
            // only a user-initiated refresh may pop the dialog.
            guard var credentials = ClaudeCredentials.read(keychainService: service, allowInteraction: userInitiated) else {
                // Couldn't read silently — keep cached usage unless the user asked.
                throw userInitiated ? UsageFetchError.tokenDecodeFailed : UsageFetchError.keychainAccessDeferred
            }
            // Proactively refresh an expired token so we don't fire a doomed 401 —
            // but a background refresh is gated (see `refreshClaudeToken`): when no
            // window is live it returns nil rather than anchor one. If we can't get
            // a fresh token without anchoring, keep cached usage instead of polling.
            if ClaudeCredentials.needsRefresh(credentials) {
                guard let refreshed = await refreshClaudeToken(account, userInitiated: userInitiated) else {
                    throw userInitiated ? UsageFetchError.unauthorized : UsageFetchError.keychainAccessDeferred
                }
                credentials = refreshed
            }
            let token = credentials.accessToken
            do {
                return try await ClaudeUsageFetcher.fetch(
                    account: account, accessToken: token, gate: usageGate, userInitiated: userInitiated, log: networkLog)
            } catch UsageFetchError.unauthorized {
                // Token may have just lapsed — one delegated refresh + retry. The
                // refresh is window-gated, so on a background poll with no live
                // window it's skipped and we keep cached usage rather than anchor.
                guard let refreshed = await refreshClaudeToken(account, userInitiated: userInitiated),
                      !ClaudeCredentials.needsRefresh(refreshed) else {
                    throw userInitiated ? UsageFetchError.unauthorized : UsageFetchError.keychainAccessDeferred
                }
                return try await ClaudeUsageFetcher.fetch(
                    account: account, accessToken: refreshed.accessToken, gate: usageGate,
                    userInitiated: userInitiated, log: networkLog)
            }
        }
    }

    /// Ask the Claude CLI to refresh this account's token (delegated refresh via
    /// `/status`, no usage turn), gated by a per-account cooldown so a broken
    /// token can't make us spawn `claude` repeatedly. Returns the re-read
    /// credential (one Keychain read), or `nil` if skipped/unreadable. The
    /// blocking PTY work runs off-main.
    private func refreshClaudeToken(_ account: Account, userInitiated: Bool) async -> ClaudeCredentials.Blob? {
        let id = account.id, now = Date()
        if !userInitiated, let until = claudeRefreshCooldownUntil[id], now < until { return nil }
        // Never let a *background* `/status` refresh anchor a fresh window — only
        // run it while one is already live, per the shared window-gate policy
        // (see `ClaudeTokenRefresher.mayRefresh` for the full why + incident).
        guard ClaudeTokenRefresher.mayRefresh(
            userInitiated: userInitiated, lastReading: usageReadings[id], now: now)
        else { return nil }

        statusMessage = "\(account.label): refreshing token via Claude Code…"
        let result = await offMain { () -> ClaudeTokenRefresher.Result in
            let home = ManagedHome(url: account.homeURL, provider: account.provider)
            let env = ChildEnvironment.make(for: home)
            let binary = ChildEnvironment.binary(for: account.provider, environment: env)
            return ClaudeTokenRefresher.run(binary: binary, environment: env)
        }

        // One read to pick up the new token and judge freshness; back off 5 min on
        // success, 30 s otherwise. Background reads stay no-UI.
        let blob = account.keychainService.flatMap {
            ClaudeCredentials.read(keychainService: $0, allowInteraction: userInitiated)
        }
        let fresh = !ClaudeCredentials.needsRefresh(blob)
        claudeRefreshCooldownUntil[id] = now.addingTimeInterval(fresh ? 300 : 30)
        AuditLog(workspace: workspace).append(
            accountID: id, action: "token.refresh", ok: fresh, detail: result.detail)
        return blob
    }

    func revealHome(_ account: Account) {
        NSWorkspace.shared.activateFileViewerSelecting([account.homeURL])
    }

    /// Suggest a unique slug id from a label (for the add sheet).
    func suggestedID(for label: String) -> String {
        var base = label.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { $0.append($1) }
        while base.contains("--") { base = base.replacingOccurrences(of: "--", with: "-") }
        base = base.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        if base.isEmpty { base = "account" }
        guard accounts.contains(where: { $0.id == base }) else { return base }
        var n = 2
        while accounts.contains(where: { $0.id == "\(base)-\(n)" }) { n += 1 }
        return "\(base)-\(n)"
    }

    // MARK: - Off-main helpers (Sendable in/out only)

    private nonisolated func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated, operation: work).value
    }

    private nonisolated static func verifyAndPersist(ws: Workspace, id: String) -> String {
        let store = AccountStore(workspace: ws)
        guard var acct = (try? store.find(id)) ?? nil else { return "not found" }
        let home = ManagedHome(url: acct.homeURL, provider: acct.provider)
        let result = IdentityVerifier.verify(provider: acct.provider, home: home, keychainBaseline: nil)
        AuditLog(workspace: ws).append(accountID: id, action: "verify", ok: result.connected, detail: result.detail)
        // Connected → connected; otherwise a previously-connected account is
        // expired, anything else is plainly disconnected (e.g. login not finished).
        acct.status = result.connected ? .connected : (acct.status == .connected ? .expired : .disconnected)
        if result.connected {
            acct.identityEmail = result.identityEmail
            acct.lastVerifiedAt = Date()
        }
        try? store.upsert(acct)
        return result.detail
    }

    private nonisolated static func reconcile(ws: Workspace, id: String) -> String {
        guard let account = (try? AccountStore(workspace: ws).find(id)) ?? nil else { return "not found" }
        // Share from the folder this account actually tracks (its `sourceHome`,
        // default `~/.claude` / `~/.codex`), not always the provider default.
        let source = URL(fileURLWithPath: account.effectiveSourceHome(), isDirectory: true)
        guard FileManager.default.fileExists(atPath: source.path) else { return "source home absent; skipped" }
        let farm = SymlinkFarm(provider: account.provider, sourceHome: source, managedHome: account.homeURL)
        guard let report = try? farm.apply() else { return "reconcile failed" }
        // Record which depth-1 entries were *newly* shared on this pass — i.e. a
        // fresh file/folder appeared in the tracked source home since last time
        // (already-shared entries come back `alreadyPresent`, so this is the diff).
        let newlyLinked = report.items.filter { $0.result == .linked }.map(\.name).sorted()
        let detail = newlyLinked.isEmpty ? report.summary : "\(report.summary) new=[\(newlyLinked.joined(separator: ", "))]"
        AuditLog(workspace: ws).append(
            accountID: id, action: "symlink.reconcile", ok: report.failures.isEmpty, detail: detail)
        return detail
    }
}
