import XCTest
@testable import AgentManagerCore

/// The experimental cloud fallback, end to end minus the network: the two
/// stores, the planner's dead-man state machine, the wire decoders (fed the
/// real captured JSON shapes), and the engine run against a recording fake API.
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

    func testConfigStoreRoundTripsAndFailsSafe() throws {
        let ws = makeWorkspace()
        let store = CloudFallbackConfigStore(workspace: ws)
        XCTAssertFalse(store.load().enabled) // missing file → disabled

        try store.save(CloudFallbackConfig(enabled: true))
        XCTAssertTrue(store.load().enabled)

        try Data("not json".utf8).write(to: ws.cloudFallbackConfigFile)
        XCTAssertFalse(store.load().enabled) // corrupt → disabled, never throws
    }

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

    // MARK: - Planner

    func testPlannerArmsFirstTime() {
        let fire = date(2026, 7, 6, 5, 0)
        let action = CloudFallbackPlanner.plan(
            state: AccountCloudFallbackState(),
            nextFireAt: fire, lastAnchoredFireAt: nil, now: date(2026, 7, 6, 4, 0))
        XCTAssertEqual(action, .arm(fire.addingTimeInterval(300)))
    }

    func testPlannerIsIdempotentWhenConverged() {
        let fire = date(2026, 7, 6, 5, 0)
        let state = AccountCloudFallbackState(triggerID: "t", armedFor: fire.addingTimeInterval(300))
        let action = CloudFallbackPlanner.plan(
            state: state, nextFireAt: fire, lastAnchoredFireAt: nil, now: date(2026, 7, 6, 4, 0))
        XCTAssertEqual(action, .none)
    }

    func testPlannerAdvancesAfterAnchoredLocalPing() {
        // 05:00 fired and anchored; the queue moved on to 10:00 — the pending
        // 05:05 backstop must be re-armed forward (cancelled) right away.
        let fired = date(2026, 7, 6, 5, 0)
        let next = date(2026, 7, 6, 10, 0)
        let state = AccountCloudFallbackState(triggerID: "t", armedFor: fired.addingTimeInterval(300))
        let action = CloudFallbackPlanner.plan(
            state: state, nextFireAt: next, lastAnchoredFireAt: fired, now: date(2026, 7, 6, 5, 1))
        XCTAssertEqual(action, .arm(next.addingTimeInterval(300)))
    }

    func testPlannerHoldsBackstopWhileLocalOutcomeUnresolved() {
        // 05:00's local ping did NOT anchor (failed, or a restart lost the
        // outcome). Until 05:05 passes, the backstop must not move forward.
        let fired = date(2026, 7, 6, 5, 0)
        let next = date(2026, 7, 6, 10, 0)
        let state = AccountCloudFallbackState(triggerID: "t", armedFor: fired.addingTimeInterval(300))
        let held = CloudFallbackPlanner.plan(
            state: state, nextFireAt: next, lastAnchoredFireAt: nil, now: date(2026, 7, 6, 5, 1))
        XCTAssertEqual(held, .none)

        // Once the armed moment passed, the cloud ran it — advance.
        let advanced = CloudFallbackPlanner.plan(
            state: state, nextFireAt: next, lastAnchoredFireAt: nil, now: date(2026, 7, 6, 5, 6))
        XCTAssertEqual(advanced, .arm(next.addingTimeInterval(300)))
    }

    func testPlannerMovesEarlierOnRepaint() {
        let state = AccountCloudFallbackState(triggerID: "t", armedFor: date(2026, 7, 6, 10, 5))
        let action = CloudFallbackPlanner.plan(
            state: state, nextFireAt: date(2026, 7, 6, 7, 0),
            lastAnchoredFireAt: nil, now: date(2026, 7, 6, 6, 0))
        XCTAssertEqual(action, .arm(date(2026, 7, 6, 7, 5)))
    }

    func testPlannerFollowsRepaintThatMovedTheFireLater() {
        // Armed 05:05 backing a 05:00 fire that a repaint just pushed to
        // 08:00. The covered fire is still in the future yet no longer
        // planned, so it can never resolve — the backstop follows the plan
        // instead of guaranteeing a pointless cloud run at 05:05.
        let state = AccountCloudFallbackState(triggerID: "t", armedFor: date(2026, 7, 6, 5, 5))
        let action = CloudFallbackPlanner.plan(
            state: state, nextFireAt: date(2026, 7, 6, 8, 0),
            lastAnchoredFireAt: nil, now: date(2026, 7, 6, 4, 0))
        XCTAssertEqual(action, .arm(date(2026, 7, 6, 8, 5)))

        // Same shape, but the covered fire's moment already passed with no
        // anchor observed — that's the failed-ping dead-man case: hold.
        let held = CloudFallbackPlanner.plan(
            state: state, nextFireAt: date(2026, 7, 6, 8, 0),
            lastAnchoredFireAt: nil, now: date(2026, 7, 6, 5, 1))
        XCTAssertEqual(held, .none)
    }

    func testPlannerDisablesWhenNothingToBackUp() {
        let armed = AccountCloudFallbackState(triggerID: "t", armedFor: date(2026, 7, 6, 5, 5))
        XCTAssertEqual(
            CloudFallbackPlanner.plan(state: armed, nextFireAt: nil, lastAnchoredFireAt: nil, now: date(2026, 7, 6, 4, 0)),
            .disable)
        // Nothing live → nothing to do (steady state while the feature is off).
        XCTAssertEqual(
            CloudFallbackPlanner.plan(state: AccountCloudFallbackState(), nextFireAt: nil, lastAnchoredFireAt: nil, now: date(2026, 7, 6, 4, 0)),
            .none)
        let disabled = AccountCloudFallbackState(triggerID: "t", disabled: true)
        XCTAssertEqual(
            CloudFallbackPlanner.plan(state: disabled, nextFireAt: nil, lastAnchoredFireAt: nil, now: date(2026, 7, 6, 4, 0)),
            .none)
    }

    func testPlannerReenablesDisabledRoutine() {
        let fire = date(2026, 7, 6, 5, 0)
        let state = AccountCloudFallbackState(triggerID: "t", disabled: true)
        let action = CloudFallbackPlanner.plan(
            state: state, nextFireAt: fire, lastAnchoredFireAt: nil, now: date(2026, 7, 6, 4, 0))
        XCTAssertEqual(action, .arm(fire.addingTimeInterval(300)))
    }

    func testPlannerBacksOffAfterError() {
        let fire = date(2026, 7, 6, 5, 0)
        var state = AccountCloudFallbackState()
        state.lastError = "boom"
        state.lastErrorAt = date(2026, 7, 6, 4, 0)
        XCTAssertEqual(
            CloudFallbackPlanner.plan(state: state, nextFireAt: fire, lastAnchoredFireAt: nil, now: date(2026, 7, 6, 4, 2)),
            .none)
        XCTAssertEqual(
            CloudFallbackPlanner.plan(state: state, nextFireAt: fire, lastAnchoredFireAt: nil, now: date(2026, 7, 6, 4, 6)),
            .arm(fire.addingTimeInterval(300)))
    }

    func testIsCovered() {
        let fire = date(2026, 7, 6, 5, 0)
        let armed = AccountCloudFallbackState(triggerID: "t", armedFor: fire.addingTimeInterval(300))

        // The backstop moment passed → the cloud ran it.
        XCTAssertTrue(CloudFallbackPlanner.isCovered(fireAt: fire, state: armed, now: date(2026, 7, 6, 5, 6)))
        // Not yet — the local ping should still run.
        XCTAssertFalse(CloudFallbackPlanner.isCovered(fireAt: fire, state: armed, now: date(2026, 7, 6, 5, 1)))
        // Armed for a *different* fire.
        XCTAssertFalse(CloudFallbackPlanner.isCovered(fireAt: date(2026, 7, 6, 10, 0), state: armed, now: date(2026, 7, 6, 10, 1)))

        // A sync error means we can't trust `armedFor` — never skip on it.
        var errored = armed
        errored.lastError = "boom"
        XCTAssertFalse(CloudFallbackPlanner.isCovered(fireAt: fire, state: errored, now: date(2026, 7, 6, 5, 6)))

        var disabled = armed
        disabled.disabled = true
        XCTAssertFalse(CloudFallbackPlanner.isCovered(fireAt: fire, state: disabled, now: date(2026, 7, 6, 5, 6)))
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
            accountID: "a1", nextFireAt: fire, lastAnchoredFireAt: nil, now: date(2026, 7, 6, 4, 0)))

        // Nothing pinned locally → list first (adopt-or-create), find nothing
        // of ours, then discover/create the environment and create.
        XCTAssertEqual(api.calls, ["list", "listEnv", "createEnv", "create"])
        XCTAssertEqual(api.createdSpecs.first?.name, "AgentManager Routine")
        XCTAssertEqual(api.createdSpecs.first?.model, CloudFallbackEngine.routineModel)
        let state = CloudFallbackStateStore(workspace: ws).load().accounts["a1"]
        XCTAssertEqual(state?.triggerID, "trig_new")
        XCTAssertEqual(state?.environmentID, "env_new")
        XCTAssertEqual(state?.armedFor, fire.addingTimeInterval(300))
        XCTAssertNil(state?.lastError)
    }

    func testEngineUsesExistingEnvironmentAndRearmsViaUpdate() async throws {
        let ws = makeWorkspace()
        let api = FakeAPI()
        api.environments = [CloudEnvironment(id: "env_default", kind: "anthropic_cloud", name: "Default", state: "active")]
        let engine = try makeEngine(ws, api: api)

        // Existing routine armed for 05:05; 05:00 anchored locally → advance to 10:05.
        var seed = CloudFallbackState()
        seed.accounts["a1"] = AccountCloudFallbackState(
            triggerID: "trig_1", environmentID: "env_default", armedFor: date(2026, 7, 6, 5, 5))
        CloudFallbackStateStore(workspace: ws).save(seed)

        await engine.sync(CloudFallbackSyncRequest(
            accountID: "a1", nextFireAt: date(2026, 7, 6, 10, 0),
            lastAnchoredFireAt: date(2026, 7, 6, 5, 0), now: date(2026, 7, 6, 5, 1)))

        XCTAssertEqual(api.calls, ["update"]) // cached env, no create
        XCTAssertEqual(api.patches.first?.id, "trig_1")
        XCTAssertEqual(api.patches.first?.patch.runOnceAt, date(2026, 7, 6, 10, 5))
        XCTAssertEqual(api.patches.first?.patch.enabled, true)
        XCTAssertEqual(CloudFallbackStateStore(workspace: ws).load().accounts["a1"]?.armedFor, date(2026, 7, 6, 10, 5))
    }

    func testEngineRecreatesWhenRoutineDeletedOnWeb() async throws {
        let ws = makeWorkspace()
        let api = FakeAPI()
        api.updateErrors["trig_gone"] = .notFound
        let engine = try makeEngine(ws, api: api)

        var seed = CloudFallbackState()
        seed.accounts["a1"] = AccountCloudFallbackState(
            triggerID: "trig_gone", environmentID: "env_default", armedFor: date(2026, 7, 6, 5, 5))
        CloudFallbackStateStore(workspace: ws).save(seed)

        await engine.sync(CloudFallbackSyncRequest(
            accountID: "a1", nextFireAt: date(2026, 7, 6, 10, 0),
            lastAnchoredFireAt: date(2026, 7, 6, 5, 0), now: date(2026, 7, 6, 5, 1)))

        // 404 → look for an adoptable sibling first; none → create.
        XCTAssertEqual(api.calls, ["updateFail", "list", "create"])
        let state = CloudFallbackStateStore(workspace: ws).load().accounts["a1"]
        XCTAssertEqual(state?.triggerID, "trig_new")
        XCTAssertEqual(state?.armedFor, date(2026, 7, 6, 10, 5))
        XCTAssertNil(state?.lastError)
    }

    func testEngineAdoptsExistingRoutineInsteadOfCreating() async throws {
        // A wiped state file (uninstall/reinstall, dev-variant workspace) must
        // not grow the customer's routine list: the engine re-adopts the
        // existing "AgentManager Routine" by name and re-arms it in place.
        let ws = makeWorkspace()
        let api = FakeAPI()
        api.triggers = [
            CloudTrigger(id: "trig_user", name: "My own routine", enabled: true),
            CloudTrigger(id: "trig_old", name: "AgentManager Routine", enabled: false,
                         runOnceAt: date(2026, 7, 5, 19, 35)),
        ]
        let engine = try makeEngine(ws, api: api)
        let fire = date(2026, 7, 6, 5, 0)

        await engine.sync(CloudFallbackSyncRequest(
            accountID: "a1", nextFireAt: fire, lastAnchoredFireAt: nil, now: date(2026, 7, 6, 4, 0)))

        XCTAssertEqual(api.calls, ["list", "update"]) // no create, no env discovery
        XCTAssertEqual(api.patches.first?.id, "trig_old")
        XCTAssertEqual(api.patches.first?.patch.runOnceAt, fire.addingTimeInterval(300))
        XCTAssertEqual(api.patches.first?.patch.enabled, true)
        let state = CloudFallbackStateStore(workspace: ws).load().accounts["a1"]
        XCTAssertEqual(state?.triggerID, "trig_old")
        XCTAssertEqual(state?.armedFor, fire.addingTimeInterval(300))
        XCTAssertNil(state?.lastError)
    }

    func testEngineAdoptPrefersEnabledRoutineAndPausesDuplicates() async throws {
        // Multiple leftovers from older installs: adopt the live one (it is
        // the only copy that could fire) and pause the other enabled strays —
        // the strongest cleanup the API allows (DELETE is web-only).
        let ws = makeWorkspace()
        let api = FakeAPI()
        api.triggers = [
            CloudTrigger(id: "trig_paused", name: "AgentManager Routine", enabled: false),
            CloudTrigger(id: "trig_live", name: "AgentManager Routine", enabled: true),
            CloudTrigger(id: "trig_stray", name: "AgentManager Routine", enabled: true),
        ]
        let engine = try makeEngine(ws, api: api)
        let fire = date(2026, 7, 6, 5, 0)

        await engine.sync(CloudFallbackSyncRequest(
            accountID: "a1", nextFireAt: fire, lastAnchoredFireAt: nil, now: date(2026, 7, 6, 4, 0)))

        XCTAssertEqual(api.calls, ["list", "update", "update"])
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
            triggerID: "trig_gone", environmentID: "env_default", armedFor: date(2026, 7, 6, 5, 5))
        CloudFallbackStateStore(workspace: ws).save(seed)

        await engine.sync(CloudFallbackSyncRequest(
            accountID: "a1", nextFireAt: date(2026, 7, 6, 10, 0),
            lastAnchoredFireAt: date(2026, 7, 6, 5, 0), now: date(2026, 7, 6, 5, 1)))

        XCTAssertEqual(api.calls, ["updateFail", "list", "update"])
        XCTAssertEqual(api.patches.first?.id, "trig_sibling")
        let state = CloudFallbackStateStore(workspace: ws).load().accounts["a1"]
        XCTAssertEqual(state?.triggerID, "trig_sibling")
        XCTAssertEqual(state?.armedFor, date(2026, 7, 6, 10, 5))
        XCTAssertNil(state?.lastError)
    }

    func testEngineDisablesWhenNothingToBackUp() async throws {
        let ws = makeWorkspace()
        let api = FakeAPI()
        let engine = try makeEngine(ws, api: api)

        var seed = CloudFallbackState()
        seed.accounts["a1"] = AccountCloudFallbackState(
            triggerID: "trig_1", environmentID: "env_default", armedFor: date(2026, 7, 6, 5, 5))
        CloudFallbackStateStore(workspace: ws).save(seed)

        await engine.sync(CloudFallbackSyncRequest(
            accountID: "a1", nextFireAt: nil, lastAnchoredFireAt: nil, now: date(2026, 7, 6, 4, 0)))

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
            accountID: "a1", nextFireAt: date(2026, 7, 6, 5, 0), lastAnchoredFireAt: nil, now: now))

        XCTAssertTrue(api.calls.isEmpty)
        let state = CloudFallbackStateStore(workspace: ws).load().accounts["a1"]
        XCTAssertNotNil(state?.lastError)
        XCTAssertEqual(state?.lastErrorAt, now)

        // Within the backoff window the planner holds — no second attempt.
        await engine.sync(CloudFallbackSyncRequest(
            accountID: "a1", nextFireAt: date(2026, 7, 6, 5, 0), lastAnchoredFireAt: nil,
            now: now.addingTimeInterval(60)))
        XCTAssertTrue(api.calls.isEmpty)
    }
}
