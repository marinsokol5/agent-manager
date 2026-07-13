import Foundation

/// One sync request from the scheduler daemon: "this account's next local fire
/// is at `nextFireAt` (nil = nothing to back up — disable); the most recent
/// local fire whose old backstop is resolved was `lastAnchoredFireAt`. The
/// property keeps its original name for source compatibility, but resolution
/// now also includes a slot already covered by a verified-open window.
public struct CloudFallbackSyncRequest: Sendable, Equatable {
    public var accountID: String
    public var nextFireAt: Date?
    public var lastAnchoredFireAt: Date?
    public var now: Date

    public init(accountID: String, nextFireAt: Date?, lastAnchoredFireAt: Date?, now: Date) {
        self.accountID = accountID
        self.nextFireAt = nextFireAt
        self.lastAnchoredFireAt = lastAnchoredFireAt
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
/// forward after anchored local pings, disabling it when the feature (or the
/// scheduler) turns off, and, when no routine is pinned locally, re-adopting
/// an existing one by name before ever creating (see `adoptOrCreateRoutine`).
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

        public init(
            listEnvironments: @escaping @Sendable (TriggerClient.Auth, String) async throws -> [CloudEnvironment],
            createEnvironment: @escaping @Sendable (TriggerClient.Auth, String) async throws -> CloudEnvironment,
            listRoutines: @escaping @Sendable (TriggerClient.Auth, String) async throws -> [CloudTrigger],
            createRoutine: @escaping @Sendable (AnchorRoutineSpec, TriggerClient.Auth, String) async throws -> CloudTrigger,
            updateRoutine: @escaping @Sendable (String, TriggerPatch, TriggerClient.Auth, String) async throws -> CloudTrigger)
        {
            self.listEnvironments = listEnvironments
            self.createEnvironment = createEnvironment
            self.listRoutines = listRoutines
            self.createRoutine = createRoutine
            self.updateRoutine = updateRoutine
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
                })
        }
    }

    /// Named so the customer recognizes it on claude.ai/code/routines.
    public static let routineName = "AgentManager Routine"
    /// Cheapest anchor: any billed turn anchors the shared window; Haiku
    /// minimizes what the turn costs.
    public static let routineModel = "claude-haiku-4-5-20251001"
    /// Do-nothing instructions: one greeting back, no tools, no thinking.
    public static let routinePrompt = """
        Good morning! Reply with one short good-morning sentence and do nothing \
        else — no tools, no thinking, no questions. This routine is Agent \
        Manager's cloud anchor ping: it runs only when your Mac slept through a \
        scheduled local ping, and its one turn keeps this account's 5-hour \
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

    // MARK: - Sync

    public func sync(_ request: CloudFallbackSyncRequest) async {
        let store = CloudFallbackStateStore(workspace: workspace)
        var state = store.load()
        let account = state.accounts[request.accountID] ?? AccountCloudFallbackState()

        let action = CloudFallbackPlanner.plan(
            state: account,
            nextFireAt: request.nextFireAt,
            lastAnchoredFireAt: request.lastAnchoredFireAt,
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
                                 detail: "cloud fallback off — \(triggerID) disabled")
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
                        _ = try await api.updateRoutine(
                            triggerID, TriggerPatch(runOnceAt: runAt, enabled: true), auth, accountID)
                        state.armedFor = runAt
                        state.disabled = false
                        audit.append(accountID: accountID, action: "routine.arm", ok: true,
                                     detail: "armed for \(TriggerClient.rfc3339(runAt)) — \(triggerID)")
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
            _ = try await api.updateRoutine(
                adopted.id, TriggerPatch(runOnceAt: runAt, enabled: true), auth, accountID)
            state.triggerID = adopted.id
            state.armedFor = runAt
            state.disabled = false
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
            audit.append(accountID: accountID, action: "routine.create", ok: true,
                         detail: "armed for \(TriggerClient.rfc3339(runAt)) — \(created.id)")
        }
    }

    private func createRoutine(
        runAt: Date, environmentID: String, auth: TriggerClient.Auth, accountID: String)
        async throws -> CloudTrigger
    {
        try await api.createRoutine(
            AnchorRoutineSpec(
                name: Self.routineName,
                runOnceAt: runAt,
                environmentID: environmentID,
                model: Self.routineModel,
                prompt: Self.routinePrompt),
            auth, accountID)
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
