import XCTest
@testable import AgentManagerCore

/// The cloud anchor routine, end to end minus the network: the state store, the
/// planner's convergence rules, the wire decoders (fed the real captured JSON
/// shapes), and the engine run against a recording fake API.
final class CloudFallbackTests: XCTestCase {
    var tmp: URL!
    let fm = FileManager.default

    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("am-cloud-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: tmp) }

    func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    func makeWorkspace() -> Workspace {
        Workspace(root: tmp.appendingPathComponent("ws", isDirectory: true))
    }

    // MARK: - Stores

    func testStateStoreRoundTripsWithWholeSecondDates() throws {
        let ws = makeWorkspace()
        let store = CloudFallbackStateStore(workspace: ws)
        XCTAssertEqual(store.load(), CloudFallbackState()) // missing → empty

        var state = CloudFallbackState()
        state.accounts["a1"] = AccountCloudFallbackState(
            triggerID: "trig_1", environmentID: "env_1",
            armedFor: date(2026, 7, 6, 5, 5), disabled: false)
        store.save(state)
        XCTAssertEqual(store.load(), state)
    }

    func testStateStoreDecodesMissingKeysToDefaults() throws {
        // An old (or hand-edited) file without `disabled` must still decode —
        // the additive-field pattern the account store established.
        let ws = makeWorkspace()
        let json = """
        {"version": 1, "accounts": {"a1": {"triggerID": "trig_1"}}}
        """
        try fm.createDirectory(at: ws.root, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: ws.cloudFallbackStateFile)
        let state = CloudFallbackStateStore(workspace: ws).load()
        XCTAssertEqual(state.accounts["a1"]?.triggerID, "trig_1")
        XCTAssertEqual(state.accounts["a1"]?.disabled, false)
        XCTAssertNil(state.accounts["a1"]?.armedFor)
    }

    func testCodexCanNeverHoldTheRoutineMethod() throws {
        // Only Claude has routines; a hand-edited file that says otherwise must
        // not reach the daemon as "never ping this account".
        let ws = makeWorkspace()
        try fm.createDirectory(at: ws.root, withIntermediateDirectories: true)
        try Data(#"{"claudePingMethod":"routine","codexPingMethod":"routine"}"#.utf8)
            .write(to: ws.preferencesFile)
        let prefs = PreferencesStore(workspace: ws).load()
        XCTAssertEqual(prefs.claudePingMethod, .routine)
        XCTAssertEqual(prefs.codexPingMethod, .terminal)
    }

    // MARK: - Planner

    func testPlannerArmsAtTheExactPlannedFire() {
        // The routine *is* the anchor, so it arms at the planned minute itself.
        let fire = date(2026, 7, 6, 5, 0)
        let action = CloudFallbackPlanner.plan(
            state: AccountCloudFallbackState(), nextFireAt: fire, now: date(2026, 7, 6, 4, 0))
        XCTAssertEqual(action, .arm(fire))
    }

    func testPlannerIsIdempotentWhenConverged() {
        let fire = date(2026, 7, 6, 5, 0)
        let state = AccountCloudFallbackState(triggerID: "t", armedFor: fire)
        let action = CloudFallbackPlanner.plan(
            state: state, nextFireAt: fire, now: date(2026, 7, 6, 4, 0))
        XCTAssertEqual(action, .none)
    }

    func testPlannerArmsOnWholeMinutes() {
        // `run_once_at` schedules by the minute, and a target derived from a
        // reset carries that reset's fractional seconds. Round *up*, so the fire
        // can never land back inside the window it was deferred past.
        let deferred = date(2026, 7, 6, 10, 32).addingTimeInterval(0.848)
        XCTAssertEqual(
            CloudFallbackPlanner.plan(
                state: AccountCloudFallbackState(), nextFireAt: deferred, now: date(2026, 7, 6, 9, 0)),
            .arm(date(2026, 7, 6, 10, 33)))
    }

    func testPlannerDoesNotRearmForJitterWithinOneAnchorBucket() {
        // The re-arm churn bug, with the real values: the same live window read
        // as `10:29:59.576` and then `10:30:00.848`, which — plus the refire
        // margin — moved the target across a whole-minute boundary and re-armed
        // a routine that would have anchored identically either way. Both land
        // in the 10:30 anchor bucket, so there is nothing to do.
        let armed = date(2026, 7, 6, 10, 32)
        for jitter in [-0.424, 0.848, 60.0, 420.0] {
            let desired = armed.addingTimeInterval(jitter)
            XCTAssertEqual(
                CloudFallbackPlanner.plan(
                    state: AccountCloudFallbackState(triggerID: "t", armedFor: armed),
                    nextFireAt: desired, now: date(2026, 7, 6, 9, 0)),
                .none,
                "jitter of \(jitter)s stayed inside the bucket and must not re-arm")
        }
        // Crossing into the next bucket really does change the anchor.
        XCTAssertEqual(
            CloudFallbackPlanner.plan(
                state: AccountCloudFallbackState(triggerID: "t", armedFor: armed),
                nextFireAt: date(2026, 7, 6, 10, 41), now: date(2026, 7, 6, 9, 0)),
            .arm(date(2026, 7, 6, 10, 41)))
    }

    func testPlannerHoldsAPassedOneShotThroughTheDispatchGap() {
        // The cancellation bug. claude.ai dispatches a one-shot tens of seconds
        // late, and `run_once_at` is the server's only handle on that pending
        // run — so moving it during the gap deletes the run. Five seconds after
        // the armed minute, with the next fire already five hours out, the
        // planner must still refuse to move.
        let fire = date(2026, 7, 6, 5, 0)
        let next = date(2026, 7, 6, 10, 0)
        let state = AccountCloudFallbackState(triggerID: "t", armedFor: fire)
        XCTAssertEqual(
            CloudFallbackPlanner.plan(
                state: state, nextFireAt: next, now: fire.addingTimeInterval(5)),
            .none)

        // Resolved by the daemon → the run is accounted for, so follow the queue.
        XCTAssertEqual(
            CloudFallbackPlanner.plan(
                state: state, nextFireAt: next, resolvedFire: fire,
                now: fire.addingTimeInterval(5)),
            .arm(next))

        // Never resolved at all: the settle deadline releases the hold anyway,
        // so a stuck reconciler cannot freeze the routine forever.
        XCTAssertEqual(
            CloudFallbackPlanner.plan(
                state: state, nextFireAt: next,
                now: fire.addingTimeInterval(CloudFallbackPlanner.dispatchSettle + 1)),
            .arm(next))
    }

    func testPlannerStillDisablesDuringTheDispatchGap() {
        // The hold protects a pending run from being *moved*, not from being
        // switched off: turning the method (or the scheduler) off is the user
        // asking for exactly that.
        let fire = date(2026, 7, 6, 5, 0)
        XCTAssertEqual(
            CloudFallbackPlanner.plan(
                state: AccountCloudFallbackState(triggerID: "t", armedFor: fire),
                nextFireAt: nil, now: fire.addingTimeInterval(5)),
            .disable)
    }

    func testPlannerFollowsRepaintsInBothDirections() {
        let state = AccountCloudFallbackState(triggerID: "t", armedFor: date(2026, 7, 6, 10, 0))
        // Pulled earlier.
        XCTAssertEqual(
            CloudFallbackPlanner.plan(
                state: state, nextFireAt: date(2026, 7, 6, 7, 0), now: date(2026, 7, 6, 6, 0)),
            .arm(date(2026, 7, 6, 7, 0)))
        // Pushed later — the armed moment is still in the future, so no run was
        // stranded by moving it.
        XCTAssertEqual(
            CloudFallbackPlanner.plan(
                state: state, nextFireAt: date(2026, 7, 6, 13, 0), now: date(2026, 7, 6, 6, 0)),
            .arm(date(2026, 7, 6, 13, 0)))
    }

    func testPlannerDisablesWhenThereIsNothingToAnchor() {
        let armed = AccountCloudFallbackState(triggerID: "t", armedFor: date(2026, 7, 6, 5, 0))
        XCTAssertEqual(
            CloudFallbackPlanner.plan(state: armed, nextFireAt: nil, now: date(2026, 7, 6, 4, 0)),
            .disable)
        // Nothing live → nothing to do (steady state while the method is off).
        XCTAssertEqual(
            CloudFallbackPlanner.plan(
                state: AccountCloudFallbackState(), nextFireAt: nil, now: date(2026, 7, 6, 4, 0)),
            .none)
        let disabled = AccountCloudFallbackState(triggerID: "t", disabled: true)
        XCTAssertEqual(
            CloudFallbackPlanner.plan(state: disabled, nextFireAt: nil, now: date(2026, 7, 6, 4, 0)),
            .none)
    }

    func testPlannerReenablesDisabledRoutine() {
        let fire = date(2026, 7, 6, 5, 0)
        let state = AccountCloudFallbackState(triggerID: "t", disabled: true)
        let action = CloudFallbackPlanner.plan(
            state: state, nextFireAt: fire, now: date(2026, 7, 6, 4, 0))
        XCTAssertEqual(action, .arm(fire))
    }

    func testPlannerBacksOffAfterError() {
        let fire = date(2026, 7, 6, 5, 0)
        var state = AccountCloudFallbackState()
        state.lastError = "boom"
        state.lastErrorAt = date(2026, 7, 6, 4, 0)
        XCTAssertEqual(
            CloudFallbackPlanner.plan(state: state, nextFireAt: fire, now: date(2026, 7, 6, 4, 2)),
            .none)
        XCTAssertEqual(
            CloudFallbackPlanner.plan(state: state, nextFireAt: fire, now: date(2026, 7, 6, 4, 6)),
            .arm(fire))
    }

    // MARK: - Wire decoders (shapes captured live 2026-07-04)

    func testDecodesTriggerCreateResponse() throws {
        let json = """
        {"trigger":{"api_token_hint":"","created_at":"2026-07-04T10:31:09.083495Z","created_via":"http_api",
        "cron_expression":"","enabled":true,"ended_reason":"","id":"trig_01UjeJ1JTen4dWAzqVLPP9Zm",
        "name":"AgentManager Routine","next_run_at":"2026-07-05T07:00:00Z","persist_session":false,
        "run_once_at":"2026-07-05T07:00:00Z","updated_at":"2026-07-04T10:31:09.083495Z"}}
        """
        let trigger = try TriggerClient.decodeTriggerForTesting(Data(json.utf8))
        XCTAssertEqual(trigger.id, "trig_01UjeJ1JTen4dWAzqVLPP9Zm")
        XCTAssertTrue(trigger.enabled)
        XCTAssertEqual(trigger.runOnceAt, date(2026, 7, 5, 7, 0))
        XCTAssertEqual(trigger.nextRunAt, date(2026, 7, 5, 7, 0))
        XCTAssertNil(trigger.endedReason) // empty string reads as "still live"
    }

    func testDecodesLastFiredAtFromARearmResponse() throws {
        // Captured from the re-arm that cancelled a pending run: the response
        // came back five seconds after `run_once_at` had passed, still
        // `enabled: true` with an empty `ended_reason`, and `last_fired_at`
        // pointing at the *previous* night. That one field is the whole
        // difference between "it ran" and "we just deleted it".
        let json = """
        {"trigger":{"id":"trig_013QWDNZ4CPvmusg2qEEeN2s","name":"AgentManager Routine",
        "cron_expression":"","enabled":true,"ended_reason":"",
        "last_fired_at":"2026-07-25T02:00:44.137244Z","next_run_at":"2026-07-26T10:01:00Z",
        "persist_session":false,"run_once_at":"2026-07-26T10:01:00Z",
        "updated_at":"2026-07-26T05:00:06.001581Z"}}
        """
        let trigger = try TriggerClient.decodeTriggerForTesting(Data(json.utf8))
        XCTAssertEqual(
            trigger.lastFiredAt?.timeIntervalSince1970 ?? 0,
            date(2026, 7, 25, 2, 0, 44).timeIntervalSince1970 + 0.137244,
            accuracy: 0.001)
        XCTAssertEqual(trigger.runOnceAt, date(2026, 7, 26, 10, 1))
        XCTAssertTrue(trigger.enabled)
        XCTAssertNil(trigger.endedReason)
        // The armed fire was 2026-07-26T05:00:00Z; the last run predates it, so
        // this response proves the one-shot had not run when we moved it.
        XCTAssertLessThan(trigger.lastFiredAt!, date(2026, 7, 26, 5, 0))
    }

    func testDecodesTriggerListAndFiredOneShot() throws {
        let json = """
        {"data":[{"id":"trig_a","enabled":false,"ended_reason":"run_once_fired",
        "run_once_at":"2026-07-04T05:00:00Z","next_run_at":""}],"has_more":false}
        """
        let list = try TriggerClient.decodeTriggerListForTesting(Data(json.utf8))
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].endedReason, "run_once_fired")
        XCTAssertFalse(list[0].enabled)
    }

    func testDecodesEnvironments() throws {
        let json = """
        {"environments":[{"kind":"anthropic_cloud","environment_id":"env_01D6DXmvjmxTHdJavJcewoms",
        "name":"Default","created_at":"2026-07-04T07:04:42.015642Z","state":"active","config":null,
        "bridge_info":null}],"has_more":false,"first_id":"env_01D6DXmvjmxTHdJavJcewoms","last_id":"env_01D6DXmvjmxTHdJavJcewoms"}
        """
        let envs = try TriggerClient.decodeEnvironmentsForTesting(Data(json.utf8))
        XCTAssertEqual(envs.count, 1)
        XCTAssertEqual(envs[0].id, "env_01D6DXmvjmxTHdJavJcewoms")
        XCTAssertTrue(envs[0].isActiveCloud)
    }

    func testRFC3339FormatsWholeSecondsUTC() {
        XCTAssertEqual(TriggerClient.rfc3339(date(2026, 7, 5, 5, 0)), "2026-07-05T05:00:00Z")
    }

    // MARK: - Engine (fake API, injected auth)

    final class FakeAPI: @unchecked Sendable {
        private let lock = NSLock()
        private var callLog: [String] = []
        var environments: [CloudEnvironment] = []
        var triggers: [CloudTrigger] = []
        var updateErrors: [String: TriggerAPIError] = [:]
        private(set) var createdSpecs: [AnchorRoutineSpec] = []
        private(set) var patches: [(id: String, patch: TriggerPatch)] = []

        var calls: [String] { lock.lock(); defer { lock.unlock() }; return callLog }
        private func record(_ s: String) { lock.lock(); callLog.append(s); lock.unlock() }
        private func recordCreate(_ spec: AnchorRoutineSpec) {
            lock.lock(); callLog.append("create"); createdSpecs.append(spec); lock.unlock()
        }
        private func recordPatch(_ id: String, _ patch: TriggerPatch) {
            lock.lock(); callLog.append("update"); patches.append((id, patch)); lock.unlock()
        }

        func api() -> CloudFallbackEngine.API {
            CloudFallbackEngine.API(
                listEnvironments: { [self] _, _ in
                    record("listEnv")
                    return environments
                },
                createEnvironment: { [self] _, _ in
                    record("createEnv")
                    return CloudEnvironment(id: "env_new", kind: "anthropic_cloud", name: "Agent Manager", state: "active")
                },
                listRoutines: { [self] _, _ in
                    record("list")
                    return triggers
                },
                createRoutine: { [self] spec, _, _ in
                    recordCreate(spec)
                    return CloudTrigger(id: "trig_new", enabled: true, runOnceAt: spec.runOnceAt)
                },
                updateRoutine: { [self] id, patch, _, _ in
                    if let error = updateErrors[id] {
                        record("updateFail")
                        throw error
                    }
                    recordPatch(id, patch)
                    return CloudTrigger(id: id, enabled: patch.enabled ?? true, runOnceAt: patch.runOnceAt)
                },
                getRoutine: { [self] id, _, _ in
                    record("get")
                    guard let found = triggers.first(where: { $0.id == id }) else {
                        throw TriggerAPIError.notFound
                    }
                    return found
                })
        }
    }

    func makeEngine(_ ws: Workspace, api: FakeAPI) throws -> CloudFallbackEngine {
        try AccountStore(workspace: ws).insert(Account(
            id: "a1", label: "a1", provider: .claude,
            home: ws.managedHome(forAccountID: "a1").path, status: .connected))
        return CloudFallbackEngine(
            workspace: ws,
            api: api.api(),
            authProvider: { _ in TriggerClient.Auth(accessToken: "tok", organizationUUID: "org") })
    }

    func testEngineFirstArmDiscoversEnvironmentAndCreatesRoutine() async throws {
        let ws = makeWorkspace()
        let api = FakeAPI() // no environments → the engine must create one
        let engine = try makeEngine(ws, api: api)
        let fire = date(2026, 7, 6, 5, 0)

        await engine.sync(CloudFallbackSyncRequest(
            accountID: "a1", nextFireAt: fire, now: date(2026, 7, 6, 4, 0)))

        // Nothing pinned locally → list first (adopt-or-create), find nothing
        // of ours, then discover/create the environment and create.
        XCTAssertEqual(api.calls, ["list", "listEnv", "createEnv", "create"])
        XCTAssertEqual(api.createdSpecs.first?.name, "AgentManager Routine")
        XCTAssertEqual(api.createdSpecs.first?.job.model, CloudFallbackEngine.routineModel)
        XCTAssertEqual(api.createdSpecs.first?.job.prompt, CloudFallbackEngine.routinePrompt)
        let state = CloudFallbackStateStore(workspace: ws).load().accounts["a1"]
        XCTAssertEqual(state?.triggerID, "trig_new")
        XCTAssertEqual(state?.environmentID, "env_new")
        XCTAssertEqual(state?.armedFor, fire)
        // Stamped, so a later arm doesn't gratuitously rewrite the instructions.
        XCTAssertEqual(state?.routineRevision, CloudFallbackEngine.routineRevision)
        XCTAssertNil(state?.lastError)
    }

    func testEngineUsesExistingEnvironmentAndRearmsViaUpdate() async throws {
        let ws = makeWorkspace()
        let api = FakeAPI()
        api.environments = [CloudEnvironment(id: "env_default", kind: "anthropic_cloud", name: "Default", state: "active")]
        let engine = try makeEngine(ws, api: api)

        // Existing routine armed for 05:00, whose fire the daemon has already
        // resolved → follow the queue to 10:00. (`resolvedFire` is what lifts the
        // dispatch hold; without it the 05:00 arm would still be untouchable.)
        var seed = CloudFallbackState()
        seed.accounts["a1"] = AccountCloudFallbackState(
            triggerID: "trig_1", environmentID: "env_default",
            armedFor: date(2026, 7, 6, 5, 0),
            routineRevision: CloudFallbackEngine.routineRevision)
        CloudFallbackStateStore(workspace: ws).save(seed)

        await engine.sync(CloudFallbackSyncRequest(
            accountID: "a1", nextFireAt: date(2026, 7, 6, 10, 0),
            resolvedFire: date(2026, 7, 6, 5, 0), now: date(2026, 7, 6, 5, 1)))

        XCTAssertEqual(api.calls, ["update"]) // cached env, no create
        XCTAssertNil(api.patches.first?.patch.job) // instructions already current
        XCTAssertEqual(api.patches.first?.id, "trig_1")
        XCTAssertEqual(api.patches.first?.patch.runOnceAt, date(2026, 7, 6, 10, 0))
        XCTAssertEqual(api.patches.first?.patch.enabled, true)
        XCTAssertEqual(CloudFallbackStateStore(workspace: ws).load().accounts["a1"]?.armedFor, date(2026, 7, 6, 10, 0))
    }

    func testEngineRecreatesWhenRoutineDeletedOnWeb() async throws {
        let ws = makeWorkspace()
        let api = FakeAPI()
        api.updateErrors["trig_gone"] = .notFound
        let engine = try makeEngine(ws, api: api)

        var seed = CloudFallbackState()
        seed.accounts["a1"] = AccountCloudFallbackState(
            triggerID: "trig_gone", environmentID: "env_default",
            armedFor: date(2026, 7, 6, 5, 0),
            routineRevision: CloudFallbackEngine.routineRevision)
        CloudFallbackStateStore(workspace: ws).save(seed)

        await engine.sync(CloudFallbackSyncRequest(
            accountID: "a1", nextFireAt: date(2026, 7, 6, 10, 0),
            resolvedFire: date(2026, 7, 6, 5, 0), now: date(2026, 7, 6, 5, 1)))

        // 404 → look for an adoptable sibling first; none → create.
        XCTAssertEqual(api.calls, ["updateFail", "list", "create"])
        let state = CloudFallbackStateStore(workspace: ws).load().accounts["a1"]
        XCTAssertEqual(state?.triggerID, "trig_new")
        XCTAssertEqual(state?.armedFor, date(2026, 7, 6, 10, 0))
        XCTAssertNil(state?.lastError)
    }

    func testEngineAdoptsExistingRoutineInsteadOfCreating() async throws {
        // A wiped state file (uninstall/reinstall, dev-variant workspace) must
        // not grow the customer's routine list: the engine re-adopts the
        // existing "AgentManager Routine" by name and re-arms it in place.
        let ws = makeWorkspace()
        let api = FakeAPI()
        api.environments = [CloudEnvironment(id: "env_default", kind: "anthropic_cloud", name: "Default", state: "active")]
        api.triggers = [
            CloudTrigger(id: "trig_user", name: "My own routine", enabled: true),
            CloudTrigger(id: "trig_old", name: "AgentManager Routine", enabled: false,
                         runOnceAt: date(2026, 7, 5, 19, 35)),
        ]
        let engine = try makeEngine(ws, api: api)
        let fire = date(2026, 7, 6, 5, 0)

        await engine.sync(CloudFallbackSyncRequest(
            accountID: "a1", nextFireAt: fire, now: date(2026, 7, 6, 4, 0)))

        // No create — but the environment *is* resolved, because an adopted
        // routine's instructions are an unknown quantity and get rewritten.
        XCTAssertEqual(api.calls, ["list", "listEnv", "update"])
        XCTAssertEqual(api.patches.first?.id, "trig_old")
        XCTAssertEqual(api.patches.first?.patch.runOnceAt, fire)
        XCTAssertEqual(api.patches.first?.patch.enabled, true)
        XCTAssertEqual(api.patches.first?.patch.job?.prompt, CloudFallbackEngine.routinePrompt)
        XCTAssertEqual(api.patches.first?.patch.job?.environmentID, "env_default")
        let state = CloudFallbackStateStore(workspace: ws).load().accounts["a1"]
        XCTAssertEqual(state?.triggerID, "trig_old")
        XCTAssertEqual(state?.armedFor, fire)
        XCTAssertEqual(state?.routineRevision, CloudFallbackEngine.routineRevision)
        XCTAssertNil(state?.lastError)
    }

    func testEngineAdoptPrefersEnabledRoutineAndPausesDuplicates() async throws {
        // Multiple leftovers from older installs: adopt the live one (it is
        // the only copy that could fire) and pause the other enabled strays —
        // the strongest cleanup the API allows (DELETE is web-only).
        let ws = makeWorkspace()
        let api = FakeAPI()
        api.environments = [CloudEnvironment(id: "env_default", kind: "anthropic_cloud", name: "Default", state: "active")]
        api.triggers = [
            CloudTrigger(id: "trig_paused", name: "AgentManager Routine", enabled: false),
            CloudTrigger(id: "trig_live", name: "AgentManager Routine", enabled: true),
            CloudTrigger(id: "trig_stray", name: "AgentManager Routine", enabled: true),
        ]
        let engine = try makeEngine(ws, api: api)
        let fire = date(2026, 7, 6, 5, 0)

        await engine.sync(CloudFallbackSyncRequest(
            accountID: "a1", nextFireAt: fire, now: date(2026, 7, 6, 4, 0)))

        XCTAssertEqual(api.calls, ["list", "listEnv", "update", "update"])
        XCTAssertEqual(api.patches[0].id, "trig_live")
        XCTAssertEqual(api.patches[0].patch.enabled, true)
        XCTAssertEqual(api.patches[1].id, "trig_stray")
        XCTAssertEqual(api.patches[1].patch.enabled, false)
        XCTAssertNil(api.patches[1].patch.runOnceAt)
        XCTAssertEqual(CloudFallbackStateStore(workspace: ws).load().accounts["a1"]?.triggerID, "trig_live")
    }

    func testEngineAdoptsSiblingAfterWebDelete() async throws {
        // The pinned routine 404s (deleted on claude.ai) but another install's
        // sibling exists — adopt it rather than creating a third.
        let ws = makeWorkspace()
        let api = FakeAPI()
        api.updateErrors["trig_gone"] = .notFound
        api.triggers = [CloudTrigger(id: "trig_sibling", name: "AgentManager Routine", enabled: false)]
        let engine = try makeEngine(ws, api: api)

        var seed = CloudFallbackState()
        seed.accounts["a1"] = AccountCloudFallbackState(
            triggerID: "trig_gone", environmentID: "env_default",
            armedFor: date(2026, 7, 6, 5, 0),
            routineRevision: CloudFallbackEngine.routineRevision)
        CloudFallbackStateStore(workspace: ws).save(seed)

        await engine.sync(CloudFallbackSyncRequest(
            accountID: "a1", nextFireAt: date(2026, 7, 6, 10, 0),
            resolvedFire: date(2026, 7, 6, 5, 0), now: date(2026, 7, 6, 5, 1)))

        XCTAssertEqual(api.calls, ["updateFail", "list", "update"])
        XCTAssertEqual(api.patches.first?.id, "trig_sibling")
        let state = CloudFallbackStateStore(workspace: ws).load().accounts["a1"]
        XCTAssertEqual(state?.triggerID, "trig_sibling")
        XCTAssertEqual(state?.armedFor, date(2026, 7, 6, 10, 0))
        XCTAssertNil(state?.lastError)
    }

    func testEngineDisablesWhenNothingToAnchor() async throws {
        let ws = makeWorkspace()
        let api = FakeAPI()
        let engine = try makeEngine(ws, api: api)

        var seed = CloudFallbackState()
        seed.accounts["a1"] = AccountCloudFallbackState(
            triggerID: "trig_1", environmentID: "env_default", armedFor: date(2026, 7, 6, 5, 0))
        CloudFallbackStateStore(workspace: ws).save(seed)

        await engine.sync(CloudFallbackSyncRequest(
            accountID: "a1", nextFireAt: nil, now: date(2026, 7, 6, 4, 0)))

        XCTAssertEqual(api.calls, ["update"])
        XCTAssertEqual(api.patches.first?.patch.enabled, false)
        XCTAssertNil(api.patches.first?.patch.runOnceAt)
        let state = CloudFallbackStateStore(workspace: ws).load().accounts["a1"]
        XCTAssertEqual(state?.disabled, true)
        XCTAssertNil(state?.armedFor)
        XCTAssertEqual(state?.triggerID, "trig_1") // kept for re-enable
    }

    func testEngineAuthFailureRecordsErrorAndBacksOff() async throws {
        let ws = makeWorkspace()
        let api = FakeAPI()
        try AccountStore(workspace: ws).insert(Account(
            id: "a1", label: "a1", provider: .claude,
            home: ws.managedHome(forAccountID: "a1").path, status: .connected))
        let engine = CloudFallbackEngine(
            workspace: ws,
            api: api.api(),
            authProvider: { _ in throw TriggerAPIError.keychainAccessDeferred })

        let now = date(2026, 7, 6, 4, 0)
        await engine.sync(CloudFallbackSyncRequest(
            accountID: "a1", nextFireAt: date(2026, 7, 6, 5, 0), now: now))

        XCTAssertTrue(api.calls.isEmpty)
        let state = CloudFallbackStateStore(workspace: ws).load().accounts["a1"]
        XCTAssertNotNil(state?.lastError)
        XCTAssertEqual(state?.lastErrorAt, now)

        // Within the backoff window the planner holds — no second attempt.
        await engine.sync(CloudFallbackSyncRequest(
            accountID: "a1", nextFireAt: date(2026, 7, 6, 5, 0),
            now: now.addingTimeInterval(60)))
        XCTAssertTrue(api.calls.isEmpty)
    }
}
