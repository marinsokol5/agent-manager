import Foundation

/// One sync request from the scheduler daemon: "this account's next planned
/// fire is at `nextFireAt`" — `nil` meaning there is nothing to anchor, which
/// is the disable signal (the ping method isn't `routine`, the scheduler is
/// off, or the account dropped out of the plan).
public struct CloudFallbackSyncRequest: Sendable, Equatable {
    public var accountID: String
    public var nextFireAt: Date?
    /// The latest fire whose cloud run the daemon has accounted for. Passed
    /// through to `CloudFallbackPlanner.plan`, where it gates the hold that
    /// keeps a just-passed one-shot from being cancelled mid-dispatch.
    public var resolvedFire: Date?
    public var now: Date

    public init(
        accountID: String,
        nextFireAt: Date?,
        resolvedFire: Date? = nil,
        now: Date)
    {
        self.accountID = accountID
        self.nextFireAt = nextFireAt
        self.resolvedFire = resolvedFire
        self.now = now
    }
}

/// Reconciles one account's cloud anchor routine after a daemon tick. Injected
/// into `SchedulerDaemon` so tests can record requests instead of hitting the
/// routines API.
public typealias CloudFallbackSyncer = @Sendable (CloudFallbackSyncRequest) async -> Void

/// Executes `CloudFallbackPlanner` decisions against the claude.ai routines
/// API: keeps the account's one-shot "AgentManager Routine" as the *single*
/// routine we ever put in the customer's list — re-arming its `run_once_at`
/// forward as the plan advances, disabling it when the `routine` ping method
/// (or the scheduler) turns off, and, when no routine is pinned locally,
/// re-adopting an existing one by name before ever creating (see
/// `adoptOrCreateRoutine`).
/// Owns `cloud-fallback-state.json` — the daemon only reads it.
///
/// Deliberate omissions, both load-bearing:
/// - **No delegated token refresh.** `ClaudeTokenRefresher` runs `/status`,
///   and a token-refresh `/status` *anchors a 5h window* — exactly the
///   side effect this feature schedules around. In practice the token is fresh
///   when arming matters: the re-arm runs moments after a ping child drove the
///   real CLI (which refreshes its own token). An expired token just reads as
///   401 → error + backoff → retry next tick.
/// - **No Keychain prompting.** The daemon must never pop the macOS allow
///   dialog; an ungranted service defers (error + backoff) until a user-driven
///   flow (usage Refresh) establishes the grant.
public struct CloudFallbackEngine: Sendable {
    /// The routines-API surface the engine needs, as injectable closures
    /// (`(auth, accountID)` at the tail of each) so engine tests exercise the
    /// full sync flow without a network. `live(log:)` binds `TriggerClient`.
    public struct API: Sendable {
        public var listEnvironments: @Sendable (TriggerClient.Auth, String) async throws -> [CloudEnvironment]
        public var createEnvironment: @Sendable (TriggerClient.Auth, String) async throws -> CloudEnvironment
        public var listRoutines: @Sendable (TriggerClient.Auth, String) async throws -> [CloudTrigger]
        public var createRoutine: @Sendable (AnchorRoutineSpec, TriggerClient.Auth, String) async throws -> CloudTrigger
        public var updateRoutine: @Sendable (String, TriggerPatch, TriggerClient.Auth, String) async throws -> CloudTrigger
        /// Read one routine back — the `last_fired_at` probe behind
        /// `CloudRunConfirmer`. Read-only, and the only call this engine makes
        /// that isn't reconciling state.
        public var getRoutine: @Sendable (String, TriggerClient.Auth, String) async throws -> CloudTrigger

        public init(
            listEnvironments: @escaping @Sendable (TriggerClient.Auth, String) async throws -> [CloudEnvironment],
            createEnvironment: @escaping @Sendable (TriggerClient.Auth, String) async throws -> CloudEnvironment,
            listRoutines: @escaping @Sendable (TriggerClient.Auth, String) async throws -> [CloudTrigger],
            createRoutine: @escaping @Sendable (AnchorRoutineSpec, TriggerClient.Auth, String) async throws -> CloudTrigger,
            updateRoutine: @escaping @Sendable (String, TriggerPatch, TriggerClient.Auth, String) async throws -> CloudTrigger,
            getRoutine: @escaping @Sendable (String, TriggerClient.Auth, String) async throws -> CloudTrigger)
        {
            self.listEnvironments = listEnvironments
            self.createEnvironment = createEnvironment
            self.listRoutines = listRoutines
            self.createRoutine = createRoutine
            self.updateRoutine = updateRoutine
            self.getRoutine = getRoutine
        }

        public static func live(log: NetworkLog?) -> API {
            API(
                listEnvironments: { auth, id in
                    try await TriggerClient.listEnvironments(auth: auth, accountID: id, log: log)
                },
                createEnvironment: { auth, id in
                    try await TriggerClient.createCloudEnvironment(
                        name: "Agent Manager",
                        description: "Created by Agent Manager for its cloud anchor routine (no repo, no tools).",
                        auth: auth, accountID: id, log: log)
                },
                listRoutines: { auth, id in
                    try await TriggerClient.listTriggers(auth: auth, accountID: id, log: log)
                },
                createRoutine: { spec, auth, id in
                    try await TriggerClient.createAnchorRoutine(spec, auth: auth, accountID: id, log: log)
                },
                updateRoutine: { triggerID, patch, auth, id in
                    try await TriggerClient.updateTrigger(id: triggerID, patch: patch, auth: auth, accountID: id, log: log)
                },
                getRoutine: { triggerID, auth, id in
                    try await TriggerClient.getTrigger(id: triggerID, auth: auth, accountID: id, log: log)
                })
        }
    }

    /// Named so the customer recognizes it on claude.ai/code/routines.
    public static let routineName = "AgentManager Routine"
    /// Generation of the instructions below. **Bump this whenever
    /// `routinePrompt` or `routineModel` changes**: re-arming a routine only
    /// moves `run_once_at`, so this integer — stored per account in
    /// `cloud-fallback-state.json` — is the only thing that makes a live routine
    /// catch up with a shipped wording change. It costs nothing when unchanged,
    /// and rides along on the next arm when it differs, so no extra request.
    ///
    /// Revision 2 retired the backstop wording. Routines created before it still
    /// told the customer they run "only when your Mac slept through a scheduled
    /// local ping", which stopped being true when the routine became a ping
    /// method in its own right.
    public static let routineRevision = 2
    /// Cheapest anchor: any billed turn anchors the shared window; Haiku
    /// minimizes what the turn costs.
    public static let routineModel = "claude-haiku-4-5-20251001"
    /// Do-nothing instructions: one greeting back, no tools, no thinking.
    public static let routinePrompt = """
        Good morning! Reply with one short good-morning sentence and do nothing \
        else — no tools, no thinking, no questions. This routine is Agent \
        Manager's cloud anchor ping: it runs at one scheduled moment, whether or \
        not your Mac is awake, and its one turn keeps this account's 5-hour \
        usage window anchored to your workday.
        """

    let workspace: Workspace
    let api: API
    /// Produces per-account API auth (Keychain token + org UUID), or throws a
    /// `TriggerAPIError` explaining why it can't right now.
    let authProvider: @Sendable (Account) throws -> TriggerClient.Auth

    public init(
        workspace: Workspace,
        api: API,
        authProvider: @escaping @Sendable (Account) throws -> TriggerClient.Auth)
    {
        self.workspace = workspace
        self.api = api
        self.authProvider = authProvider
    }

    /// The production engine: `TriggerClient` over the shared `NetworkLog`
    /// (every exchange lands token-redacted in Monitoring → Logs), auth from
    /// the login Keychain + the managed home's `.claude.json`.
    public static func live(workspace: Workspace) -> CloudFallbackEngine {
        CloudFallbackEngine(
            workspace: workspace,
            api: .live(log: NetworkLog(workspace: workspace)),
            authProvider: { account in try keychainAuth(for: account) })
    }

    /// Background (never-prompting) auth read. See the type doc for why there
    /// is no refresh fallback here.
    static func keychainAuth(for account: Account) throws -> TriggerClient.Auth {
        guard let service = account.keychainService else {
            throw TriggerAPIError.keychainAccessDeferred
        }
        guard let blob = ClaudeCredentials.read(keychainService: service, allowInteraction: false) else {
            throw TriggerAPIError.keychainAccessDeferred
        }
        let identity = ManagedHome(url: account.homeURL, provider: account.provider).identityFileURL
        guard let org = IdentityVerifier.readOrganizationUuid(at: identity) else {
            throw TriggerAPIError.missingOrganization
        }
        return TriggerClient.Auth(accessToken: blob.accessToken, organizationUUID: org)
    }

    /// A `CloudFallbackSyncer` bound to this engine (what the daemon holds).
    public func syncer() -> CloudFallbackSyncer {
        { request in await sync(request) }
    }

    /// A `CloudRunConfirmer` bound to this engine (what the daemon holds).
    public func confirmer() -> CloudRunConfirmer {
        { accountID in await confirmRun(accountID) }
    }

    // MARK: - Sync

    public func sync(_ request: CloudFallbackSyncRequest) async {
        let store = CloudFallbackStateStore(workspace: workspace)
        var state = store.load()
        let account = state.accounts[request.accountID] ?? AccountCloudFallbackState()

        let action = CloudFallbackPlanner.plan(
            state: account,
            nextFireAt: request.nextFireAt,
            resolvedFire: request.resolvedFire,
            now: request.now)
        guard action != .none else { return }

        let updated = await execute(action, accountID: request.accountID, current: account, now: request.now)
        state.accounts[request.accountID] = updated
        store.save(state)
    }

    private func execute(
        _ action: CloudFallbackPlanner.Action,
        accountID: String,
        current: AccountCloudFallbackState,
        now: Date) async -> AccountCloudFallbackState
    {
        let audit = AuditLog(workspace: workspace)
        var state = current
        do {
            guard let account = try AccountStore(workspace: workspace).find(accountID),
                  account.provider.supportsCloudAnchorRoutines
            else {
                // The account vanished from the inventory; nothing more we can
                // do — a still-armed routine is a one-shot and self-disables.
                state.armedFor = nil
                return state
            }
            let auth = try authProvider(account)

            switch action {
            case .none:
                break

            case .disable:
                guard let triggerID = state.triggerID else { break }
                do {
                    _ = try await api.updateRoutine(triggerID, TriggerPatch(enabled: false), auth, accountID)
                    state.disabled = true
                    state.armedFor = nil
                    audit.append(accountID: accountID, action: "routine.disable", ok: true,
                                 detail: "nothing to anchor — \(triggerID) disabled")
                } catch TriggerAPIError.notFound {
                    // Deleted on the web — even better than disabled.
                    state.triggerID = nil
                    state.armedFor = nil
                    state.disabled = false
                    audit.append(accountID: accountID, action: "routine.disable", ok: true,
                                 detail: "routine already deleted on claude.ai")
                }

            case let .arm(runAt):
                if let triggerID = state.triggerID {
                    do {
                        // Carry the instructions along whenever the live routine
                        // is a revision behind. Free — this PATCH was happening
                        // anyway — and it needs `environmentID`, since
                        // `job_config` is replaced wholesale (see `RoutineJob`);
                        // without one cached, the rewrite waits for a sync that
                        // has resolved it.
                        let staleInstructions = state.routineRevision != Self.routineRevision
                        let job = staleInstructions ? state.environmentID.map(Self.job(environmentID:)) : nil
                        _ = try await api.updateRoutine(
                            triggerID, TriggerPatch(runOnceAt: runAt, enabled: true, job: job), auth, accountID)
                        state.armedFor = runAt
                        state.disabled = false
                        if job != nil { state.routineRevision = Self.routineRevision }
                        audit.append(accountID: accountID, action: "routine.arm", ok: true,
                                     detail: "armed for \(TriggerClient.rfc3339(runAt)) — \(triggerID)"
                                         + (job != nil ? " (instructions updated to revision \(Self.routineRevision))" : ""))
                    } catch TriggerAPIError.notFound {
                        // The user deleted it on claude.ai. A sibling may
                        // still exist (another install's routine) — adopt it
                        // before resorting to a create.
                        state.triggerID = nil
                        try await adoptOrCreateRoutine(
                            runAt: runAt, state: &state, auth: auth, accountID: accountID, audit: audit)
                    }
                } else {
                    try await adoptOrCreateRoutine(
                        runAt: runAt, state: &state, auth: auth, accountID: accountID, audit: audit)
                }
            }

            state.lastError = nil
            state.lastErrorAt = nil
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            state.lastError = detail
            state.lastErrorAt = now
            let name = switch action {
            case .disable: "routine.disable"
            default: "routine.arm"
            }
            audit.append(accountID: accountID, action: name, ok: false, detail: detail)
        }
        return state
    }

    /// The list-before-create step that keeps the customer's routine list at
    /// one "AgentManager Routine" per account. The stored `triggerID` normally
    /// pins the routine, but that ID lives only in `cloud-fallback-state.json`
    /// — losable to an uninstall/reinstall, a dev-variant build with its own
    /// workspace, or a re-added account slug — while the routines *list* is
    /// permanent from our side (the API exposes DELETE only to web sessions).
    /// So whenever no routine is pinned, re-adopt an existing one by name and
    /// patch it into shape; create only when the account has zero of ours.
    /// Duplicates left behind by older installs are paused (best-effort — the
    /// strongest cleanup the API allows), so at most one copy can ever fire;
    /// removing them from the list entirely is a one-time manual delete on
    /// claude.ai.
    private func adoptOrCreateRoutine(
        runAt: Date,
        state: inout AccountCloudFallbackState,
        auth: TriggerClient.Auth,
        accountID: String,
        audit: AuditLog) async throws
    {
        let ours = try await api.listRoutines(auth, accountID).filter { $0.name == Self.routineName }
        if let adopted = ours.first(where: \.enabled) ?? ours.first {
            // Adoption is exactly the case where the routine's instructions are
            // an unknown quantity — another install's, or a revision of ours old
            // enough to still describe the retired backstop behavior — so bring
            // them up to date in the very PATCH that arms it.
            let environmentID = try await resolveEnvironment(&state, auth: auth, accountID: accountID)
            _ = try await api.updateRoutine(
                adopted.id,
                TriggerPatch(runOnceAt: runAt, enabled: true, job: Self.job(environmentID: environmentID)),
                auth, accountID)
            state.triggerID = adopted.id
            state.armedFor = runAt
            state.disabled = false
            state.routineRevision = Self.routineRevision
            audit.append(accountID: accountID, action: "routine.adopt", ok: true,
                         detail: "adopted existing — armed for \(TriggerClient.rfc3339(runAt)) — \(adopted.id)")
            for extra in ours where extra.id != adopted.id && extra.enabled {
                guard (try? await api.updateRoutine(
                    extra.id, TriggerPatch(enabled: false), auth, accountID)) != nil else { continue }
                audit.append(accountID: accountID, action: "routine.disable", ok: true,
                             detail: "paused duplicate \(extra.id)")
            }
        } else {
            let environmentID = try await resolveEnvironment(&state, auth: auth, accountID: accountID)
            let created = try await createRoutine(runAt: runAt, environmentID: environmentID,
                                                  auth: auth, accountID: accountID)
            state.triggerID = created.id
            state.armedFor = runAt
            state.disabled = false
            state.routineRevision = Self.routineRevision
            audit.append(accountID: accountID, action: "routine.create", ok: true,
                         detail: "armed for \(TriggerClient.rfc3339(runAt)) — \(created.id)")
        }
    }

    /// The instruction payload every create, adopt, and catch-up arm writes —
    /// one definition, so a live routine and a freshly created one can never
    /// disagree about what the turn does.
    static func job(environmentID: String) -> RoutineJob {
        RoutineJob(environmentID: environmentID, model: routineModel, prompt: routinePrompt)
    }

    private func createRoutine(
        runAt: Date, environmentID: String, auth: TriggerClient.Auth, accountID: String)
        async throws -> CloudTrigger
    {
        try await api.createRoutine(
            AnchorRoutineSpec(
                name: Self.routineName,
                runOnceAt: runAt,
                job: Self.job(environmentID: environmentID)),
            auth, accountID)
    }

    // MARK: - Confirmation

    /// Read one account's pinned routine back, for `CloudRunConfirmer`.
    ///
    /// Fail-soft in the same way as everything else here, and for the same
    /// reason: `nil` means "could not tell", which the daemon must never read as
    /// "it didn't run". No routine pinned is also `nil` — there is nothing whose
    /// run could be pending.
    func confirmRun(_ accountID: String) async -> CloudTrigger? {
        let state = CloudFallbackStateStore(workspace: workspace).load()
        guard let triggerID = state.accounts[accountID]?.triggerID,
              let account = try? AccountStore(workspace: workspace).find(accountID),
              account.provider.supportsCloudAnchorRoutines,
              let auth = try? authProvider(account)
        else { return nil }
        return try? await api.getRoutine(triggerID, auth, accountID)
    }

    /// The org's environment id, cached in state after the first discovery
    /// (it never changes for an org). Prefers an existing active cloud
    /// environment; creates one only for orgs that never opened claude.ai/code.
    private func resolveEnvironment(
        _ state: inout AccountCloudFallbackState,
        auth: TriggerClient.Auth,
        accountID: String) async throws -> String
    {
        if let cached = state.environmentID { return cached }
        if let existing = try await api.listEnvironments(auth, accountID).first(where: \.isActiveCloud) {
            state.environmentID = existing.id
            return existing.id
        }
        let created = try await api.createEnvironment(auth, accountID)
        AuditLog(workspace: workspace).append(
            accountID: accountID, action: "routine.create", ok: true,
            detail: "created cloud environment \(created.id)")
        state.environmentID = created.id
        return created.id
    }
}
