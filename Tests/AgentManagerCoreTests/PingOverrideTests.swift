import XCTest
@testable import AgentManagerCore

/// Per-account ping-method overrides: storage (back-compat, forgiving decode),
/// resolution (override vs. inherit, the command-scope rule, sanitization),
/// pruning, per-account cloud-routine audit, and `AccountPinger` dispatch. The
/// daemon's side lives with the other cloud-routine scenarios in
/// `SchedulerDaemonTests`.
final class PingOverrideTests: XCTestCase {
    private let fileManager = FileManager.default
    private var dir: URL!

    override func setUpWithError() throws {
        dir = fileManager.temporaryDirectory
            .appendingPathComponent("am-override-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fileManager.removeItem(at: dir) }

    private let evalCommand = CustomPingCommand(executable: "/bin/echo", arguments: ["eval"])
    private let providerCommand = CustomPingCommand(executable: "/bin/echo", arguments: ["all"])

    // MARK: - Storage

    func testOldFileHasNoOverridesAndReencodesWithoutTheKey() throws {
        let old = #"{"claudePingMethod":"headless","clockStyle":"twelveHour","codexPingMethod":"terminal","theme":"system"}"#
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data(old.utf8))
        XCTAssertTrue(decoded.accountPingOverrides.isEmpty)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(String(decoding: try encoder.encode(decoded), as: UTF8.self), old)

        // Through the store too: a load + save of an untouched file is a no-op
        // on its bytes (the store pretty-prints with sorted keys).
        let url = dir.appendingPathComponent("preferences.json")
        let store = PreferencesStore(fileURL: url)
        store.save(decoded)
        let first = try Data(contentsOf: url)
        store.save(store.load())
        XCTAssertEqual(try Data(contentsOf: url), first)
        XCTAssertFalse(String(decoding: first, as: UTF8.self).contains("accountPingOverrides"))

        // Clearing the last override drops the key again.
        var prefs = decoded
        prefs.setPingOverride(AccountPingOverride(method: .sdk), forAccount: "a1")
        prefs.setPingOverride(nil, forAccount: "a1")
        XCTAssertEqual(String(decoding: try encoder.encode(prefs), as: UTF8.self), old)
    }

    func testOverridesRoundTrip() throws {
        var prefs = Preferences(claudePingMethod: .headless)
        prefs.setPingOverride(AccountPingOverride(method: .custom, customCommand: evalCommand), forAccount: "eval")
        prefs.setPingOverride(AccountPingOverride(method: .routine), forAccount: "night")
        let round = try JSONDecoder().decode(Preferences.self, from: try JSONEncoder().encode(prefs))
        XCTAssertEqual(round, prefs)
        XCTAssertEqual(round.pingOverride(forAccount: "eval"), AccountPingOverride(method: .custom, customCommand: evalCommand))
        XCTAssertEqual(round.pingOverride(forAccount: "night")?.method, .routine)
        XCTAssertNil(round.pingOverride(forAccount: "other"))
    }

    func testOneUndecodableOverrideIsDroppedAndItsSiblingsSurvive() throws {
        let json = """
            {"claudePingMethod":"headless","codexPingMethod":"sdk","accountPingOverrides":{
              "good":{"method":"custom","customCommand":{"executable":"/bin/echo","arguments":["x"]}},
              "future":{"method":"teleport"},
              "badcmd":{"method":"custom","customCommand":{"arguments":[1]}},
              "nomethod":{},
              "bad/slug":{"method":"sdk"},
              "plain":{"method":"terminal"}
            }}
            """
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.codexPingMethod, .sdk) // the rest of the file holds
        XCTAssertEqual(Set(decoded.accountPingOverrides.keys), ["good", "plain"])
        XCTAssertEqual(decoded.pingOverride(forAccount: "good")?.customCommand,
                       CustomPingCommand(executable: "/bin/echo", arguments: ["x"]))
        // A dropped entry inherits again.
        XCTAssertEqual(decoded.pingMethod(forAccount: "future", provider: .claude), .headless)
        XCTAssertEqual(decoded.pingMethod(forAccount: "badcmd", provider: .claude), .headless)

        // A whole map of the wrong shape costs only the map.
        let wrongShape = #"{"claudePingMethod":"sdk","accountPingOverrides":[1,2]}"#
        let tolerant = try JSONDecoder().decode(Preferences.self, from: Data(wrongShape.utf8))
        XCTAssertEqual(tolerant.claudePingMethod, .sdk)
        XCTAssertTrue(tolerant.accountPingOverrides.isEmpty)
    }

    func testInvalidAccountIDIsNeverStored() {
        var prefs = Preferences()
        prefs.setPingOverride(AccountPingOverride(method: .sdk), forAccount: "../evil")
        XCTAssertTrue(prefs.accountPingOverrides.isEmpty)
        let built = Preferences(accountPingOverrides: ["ok": .init(method: .sdk), "no way": .init(method: .sdk)])
        XCTAssertEqual(Array(built.accountPingOverrides.keys), ["ok"])
    }

    // MARK: - Resolution

    func testOverrideWinsAndOthersInherit() {
        var prefs = Preferences(claudePingMethod: .headless, codexPingMethod: .terminal)
        prefs.setPingOverride(AccountPingOverride(method: .custom), forAccount: "eval")
        XCTAssertEqual(prefs.pingMethod(forAccount: "eval", provider: .claude), .custom)
        XCTAssertEqual(prefs.pingMethod(forAccount: "work", provider: .claude), .headless)
        XCTAssertEqual(prefs.pingMethod(forAccount: "cx", provider: .codex), .terminal)

        // Inheritors follow later default changes.
        prefs.claudePingMethod = .sdk
        XCTAssertEqual(prefs.pingMethod(forAccount: "work", provider: .claude), .sdk)
        XCTAssertEqual(prefs.pingMethod(forAccount: "eval", provider: .claude), .custom)
    }

    func testCommandComesFromTheScopeThatChoseTheMethod() {
        var prefs = Preferences(claudePingMethod: .custom, claudeCustomCommand: providerCommand)
        prefs.setPingOverride(AccountPingOverride(method: .custom, customCommand: evalCommand), forAccount: "eval")
        // An overridden account with no command of its own does NOT borrow the
        // provider's — it has none.
        prefs.setPingOverride(AccountPingOverride(method: .custom), forAccount: "bare")

        XCTAssertEqual(prefs.customCommand(forAccount: "eval", provider: .claude), evalCommand)
        XCTAssertEqual(prefs.customCommand(forAccount: "work", provider: .claude), providerCommand)
        XCTAssertNil(prefs.customCommand(forAccount: "bare", provider: .claude))

        // Scoped accessors used by the Preferences field.
        XCTAssertEqual(prefs.customCommand(in: .provider(.claude)), providerCommand)
        XCTAssertEqual(prefs.customCommand(in: .account(id: "eval", provider: .claude)), evalCommand)
        XCTAssertNil(prefs.customCommand(in: .account(id: "work", provider: .claude)))

        prefs.setCustomCommand(providerCommand, in: .account(id: "bare", provider: .claude))
        XCTAssertEqual(prefs.customCommand(forAccount: "bare", provider: .claude), providerCommand)
        // No override → nothing to attach a command to; the provider's is untouched.
        prefs.setCustomCommand(evalCommand, in: .account(id: "work", provider: .claude))
        XCTAssertNil(prefs.pingOverride(forAccount: "work"))
        XCTAssertEqual(prefs.customCommand(for: .claude), providerCommand)
    }

    func testRoutineOverrideOnCodexIsSanitizedToTerminal() {
        var prefs = Preferences(codexPingMethod: .headless)
        prefs.setPingOverride(AccountPingOverride(method: .routine), forAccount: "cx")
        XCTAssertEqual(prefs.pingMethod(forAccount: "cx", provider: .codex), .terminal)
        XCTAssertEqual(prefs.pingMethod(forAccount: "cx", provider: .codex), PingMethod.routine.sanitized(for: .codex))
        let codex = Account(id: "cx", label: "cx", provider: .codex, home: "/tmp/cx", status: .connected)
        XCTAssertTrue(prefs.cloudRoutineAccounts([codex]).isEmpty)
    }

    func testCloudRoutineAccountsResolvePerAccount() {
        let accounts = [
            Account(id: "a", label: "a", provider: .claude, home: "/tmp/a", status: .connected),
            Account(id: "b", label: "b", provider: .claude, home: "/tmp/b", status: .connected),
            Account(id: "cx", label: "cx", provider: .codex, home: "/tmp/cx", status: .connected),
        ]
        var prefs = Preferences(claudePingMethod: .routine)
        prefs.setPingOverride(AccountPingOverride(method: .custom), forAccount: "b")
        XCTAssertEqual(prefs.cloudRoutineAccounts(accounts), ["a"])

        prefs.claudePingMethod = .headless
        prefs.setPingOverride(AccountPingOverride(method: .routine), forAccount: "b")
        XCTAssertEqual(prefs.cloudRoutineAccounts(accounts), ["b"])
    }

    // MARK: - Scope-keyed method

    func testAccountOverrideKeepsItsCommandAcrossMethodChanges() {
        var prefs = Preferences(claudePingMethod: .headless)
        let scope = PingMethodScope.account(id: "eval", provider: .claude)
        XCTAssertNil(prefs.pingMethod(in: scope)) // inherits

        prefs.setPingMethod(.custom, in: scope)
        prefs.setCustomCommand(evalCommand, in: scope)
        prefs.setPingMethod(.sdk, in: scope)
        XCTAssertEqual(prefs.pingMethod(in: scope), .sdk)
        XCTAssertEqual(prefs.pingOverride(forAccount: "eval")?.customCommand, evalCommand)
        prefs.setPingMethod(.custom, in: scope)
        XCTAssertEqual(prefs.customCommand(forAccount: "eval", provider: .claude), evalCommand)

        // nil goes back to inheriting, command and all.
        prefs.setPingMethod(nil, in: scope)
        XCTAssertNil(prefs.pingMethod(in: scope))
        XCTAssertNil(prefs.pingOverride(forAccount: "eval"))
    }

    func testScopeKeyedMethodSanitizesForTheProvider() {
        var prefs = Preferences()
        prefs.setPingMethod(.routine, in: .provider(.codex))
        XCTAssertEqual(prefs.pingMethod(in: .provider(.codex)), .terminal)
        prefs.setPingMethod(nil, in: .provider(.claude)) // a provider always has one
        XCTAssertEqual(prefs.pingMethod(in: .provider(.claude)), Preferences.default.claudePingMethod)
        let codexAccount = PingMethodScope.account(id: "cx", provider: .codex)
        prefs.setPingMethod(.routine, in: codexAccount)
        XCTAssertEqual(prefs.pingMethod(in: codexAccount), .terminal)
    }

    // MARK: - Pruning

    func testRemovingAnAccountPrunesItsOverride() {
        let workspace = Workspace(root: dir.appendingPathComponent("ws", isDirectory: true))
        let store = PreferencesStore(workspace: workspace)
        var prefs = Preferences(claudePingMethod: .headless)
        prefs.setPingOverride(AccountPingOverride(method: .custom, customCommand: evalCommand), forAccount: "eval")
        prefs.setPingOverride(AccountPingOverride(method: .sdk), forAccount: "keep")
        store.save(prefs)

        let returned = store.removeAccount("eval")
        let reloaded = store.load()
        XCTAssertEqual(returned, reloaded)
        XCTAssertNil(reloaded.pingOverride(forAccount: "eval"))
        // A re-added slug inherits the provider default, not the stale method/command.
        XCTAssertEqual(reloaded.pingMethod(forAccount: "eval", provider: .claude), .headless)
        XCTAssertNil(reloaded.customCommand(forAccount: "eval", provider: .claude))
        XCTAssertEqual(reloaded.pingOverride(forAccount: "keep")?.method, .sdk)
    }

    func testRemovingAnAccountWithoutAnOverrideLeavesTheFileAlone() throws {
        let workspace = Workspace(root: dir.appendingPathComponent("ws", isDirectory: true))
        let store = PreferencesStore(workspace: workspace)
        store.save(Preferences(claudePingMethod: .sdk))
        // Compact bytes no `save` would produce: any rewrite would show.
        let compact = Data(#"{"claudePingMethod":"sdk","clockStyle":"twelveHour","codexPingMethod":"headless","theme":"system"}"#.utf8)
        try compact.write(to: workspace.preferencesFile)
        store.removeAccount("ordinary")
        XCTAssertEqual(try Data(contentsOf: workspace.preferencesFile), compact)
    }

    // MARK: - Audit

    func testCrossingIntoOrOutOfRoutineIsAuditedPerAccount() {
        let workspace = Workspace(root: dir.appendingPathComponent("ws", isDirectory: true))
        let store = PreferencesStore(workspace: workspace)
        let audit = AuditLog(workspace: workspace)
        let accounts = [
            Account(id: "a", label: "a", provider: .claude, home: "/tmp/a", status: .connected),
            Account(id: "b", label: "b", provider: .claude, home: "/tmp/b", status: .connected),
            Account(id: "cx", label: "cx", provider: .codex, home: "/tmp/cx", status: .connected),
        ]
        var seed = Preferences(claudePingMethod: .headless)
        seed.setPingOverride(AccountPingOverride(method: .custom), forAccount: "b")
        store.save(seed)

        func cloudEvents() -> [String] {
            // File order (readRecent is newest-first; timestamps can tie).
            audit.readRecent(limit: 50)
                .filter { $0.action.hasPrefix("cloud.") }
                .reversed()
                .map { "\($0.action) \($0.accountID ?? "-")" }
        }

        // Provider-level: only the inheriting Claude account crosses.
        var result = store.updatePingMethods(accounts: accounts, audit: audit, via: "Claude ping method") {
            $0.claudePingMethod = .routine
        }
        XCTAssertEqual(result.transition, CloudRoutineTransition(entered: ["a"], left: []))
        XCTAssertEqual(cloudEvents(), ["cloud.enable a"])

        // Account-level: b joins the routine through its own override.
        result = store.updatePingMethods(accounts: accounts, audit: audit, via: "b ping method override") {
            $0.setPingOverride(AccountPingOverride(method: .routine), forAccount: "b")
        }
        XCTAssertEqual(result.transition.entered, ["b"])
        XCTAssertEqual(cloudEvents(), ["cloud.enable a", "cloud.enable b"])

        // An edit that moves nothing in or out logs nothing.
        result = store.updatePingMethods(accounts: accounts, audit: audit, via: "Codex ping method") {
            $0.codexPingMethod = .sdk
        }
        XCTAssertTrue(result.transition.isEmpty)
        XCTAssertEqual(cloudEvents().count, 2)

        // Provider back to local: a leaves, b (overridden to routine) stays.
        result = store.updatePingMethods(accounts: accounts, audit: audit, via: "Claude ping method") {
            $0.claudePingMethod = .headless
        }
        XCTAssertEqual(result.transition, CloudRoutineTransition(entered: [], left: ["a"]))
        XCTAssertEqual(cloudEvents(), ["cloud.enable a", "cloud.enable b", "cloud.disable a"])
        XCTAssertEqual(store.load().cloudRoutineAccounts(accounts), ["b"])
    }

    // MARK: - Dispatch

    func testAccountPingerUsesTheAccountsResolvedMethodAndCommand() throws {
        let workspace = Workspace(root: dir.appendingPathComponent("workspace", isDirectory: true))
        for id in ["eval", "work"] {
            let home = workspace.managedHome(forAccountID: id)
            try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
            try AccountStore(workspace: workspace).insert(Account(
                id: id, label: id, provider: .claude, home: home.path, status: .connected))
        }
        let marker = dir.appendingPathComponent("ran")
        let claude = try script("claude", """
            echo '{"is_error":false,"usage":{"input_tokens":10,"cache_creation_input_tokens":20,"output_tokens":3}}'
            """)
        let evalScript = try script("eval.sh", "echo \"eval $AGENT_MANAGER_ACCOUNT_ID\" >> \(marker.path)")
        let allScript = try script("all.sh", "echo \"all $AGENT_MANAGER_ACCOUNT_ID\" >> \(marker.path)")

        // Provider default: headless. `eval` overrides to custom with its own
        // command; the provider-level command must never run for it.
        var prefs = Preferences(
            claudePingMethod: .headless,
            claudeCustomCommand: CustomPingCommand(executable: allScript.path))
        prefs.setPingOverride(
            AccountPingOverride(method: .custom, customCommand: CustomPingCommand(executable: evalScript.path)),
            forAccount: "eval")
        PreferencesStore(workspace: workspace).save(prefs)

        let pinger = AccountPinger(workspace: workspace, baseEnvironment: [
            "HOME": dir.path,
            "PATH": "/usr/bin:/bin",
            "AGENT_MANAGER_CLAUDE_BIN": claude.path,
        ])
        let evalResult = try pinger.runTurn("eval", timeout: 2)
        XCTAssertEqual(evalResult.pingMethod, .custom)
        XCTAssertTrue(evalResult.ok, evalResult.detail)

        let workResult = try pinger.runTurn("work", timeout: 5)
        XCTAssertEqual(workResult.pingMethod, .headless)

        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "eval eval\n")

        // A `routine` override still runs a local turn for a Test ping, via
        // `localDriver` — never nothing.
        prefs.setPingOverride(AccountPingOverride(method: .routine), forAccount: "work")
        PreferencesStore(workspace: workspace).save(prefs)
        XCTAssertEqual(try pinger.runTurn("work", timeout: 0).pingMethod, .terminal)
    }

    // MARK: - Helpers

    @discardableResult
    private func script(_ name: String, _ body: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
