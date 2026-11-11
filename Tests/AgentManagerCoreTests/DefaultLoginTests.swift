import XCTest
@testable import AgentManagerCore

/// Accounts whose home is the provider's *default* login
/// (`AccountLoginSource.providerDefault`): full accounts that run the official
/// CLI with the isolation variable removed. Every test runs against a temp
/// workspace and a fake home directory (its own `.claude.json` / `.codex`),
/// with the Keychain reader and the CLI binary (`AGENT_MANAGER_CLAUDE_BIN`)
/// injected — nothing touches the real Keychain or the real `~/.claude`.
final class DefaultLoginTests: XCTestCase {
    var tmp: URL!
    var fakeHome: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("am-default-login-\(UUID().uuidString)", isDirectory: true)
        fakeHome = tmp.appendingPathComponent("home", isDirectory: true)
        try fm.createDirectory(at: fakeHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: tmp)
    }

    func workspace() -> Workspace { Workspace(root: tmp.appendingPathComponent("ws", isDirectory: true)) }

    /// A probe over the fake home whose Claude Keychain read returns `status`
    /// and records which services were asked for.
    final class KeychainSpy: @unchecked Sendable {
        var status: ClaudeCredentials.Status?
        var services: [String] = []
        init(_ status: ClaudeCredentials.Status?) { self.status = status }
    }

    func probe(_ spy: KeychainSpy) -> DefaultLoginProbe {
        DefaultLoginProbe(homeDirectory: fakeHome) { service, _ in
            spy.services.append(service)
            return spy.status
        }
    }

    static let liveToken = ClaudeCredentials.Status.valid(.init(accessToken: "t", expiresAt: nil))

    /// The default Claude identity file: `~/.claude.json`, beside `~/.claude`.
    func writeDefaultClaudeIdentity(email: String) throws {
        let json = #"{"oauthAccount":{"emailAddress":"\#(email)","organizationUuid":"org-1"}}"#
        try json.write(to: fakeHome.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
    }

    /// The default Codex login: `~/.codex/auth.json` with an id_token carrying `email`.
    func writeDefaultCodexAuth(email: String) throws {
        let codex = fakeHome.appendingPathComponent(".codex", isDirectory: true)
        try fm.createDirectory(at: codex, withIntermediateDirectories: true)
        let payload = Data(#"{"email":"\#(email)"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        let auth = #"{"tokens":{"access_token":"at","id_token":"h.\#(payload).s"}}"#
        try auth.write(to: codex.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
    }

    /// Every path under the fake home with its modification date — taken
    /// before and after an operation to prove the default home was only read.
    func snapshotDefaultHome() throws -> [String: Date] {
        var out: [String: Date] = [:]
        let e = fm.enumerator(at: fakeHome, includingPropertiesForKeys: [.contentModificationDateKey])
        while let url = e?.nextObject() as? URL {
            out[url.path] = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        return out
    }

    func managedAccount(
        _ id: String, provider: Provider = .claude, email: String? = nil, ws: Workspace,
        excluded: Bool = false) -> Account
    {
        let home = ws.managedHome(forAccountID: id)
        return Account(
            id: id, label: id, provider: provider, home: home.path,
            sourceHome: provider.defaultSourceHome(homeDirectory: fakeHome).path,
            status: .connected, identityEmail: email,
            keychainService: provider == .claude ? "Claude Code-credentials-abc12345" : nil,
            excludedFromScheduling: excluded,
            // Whole seconds: the store persists ISO-8601, so equality survives a round trip.
            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    // MARK: Model + persistence

    /// An `accounts.json` written before `loginSource` existed decodes as
    /// managed and re-encodes to the *same bytes* — the key only appears once
    /// the user picks the default login for an account.
    func testOldInventoryDecodesManagedAndReencodesByteIdentical() throws {
        let old = """
        {
          "accounts" : [
            {
              "color" : "#7C7CFF",
              "createdAt" : "2026-01-02T03:04:05Z",
              "excludedFromScheduling" : false,
              "home" : "\\/tmp\\/homes\\/work",
              "id" : "work",
              "identityEmail" : "work@example.com",
              "keychainService" : "Claude Code-credentials-abc12345",
              "label" : "Work",
              "lastVerifiedAt" : "2026-01-03T03:04:05Z",
              "pinned" : true,
              "provider" : "claude",
              "rank" : 0,
              "sourceHome" : "\\/Users\\/me\\/.claude",
              "status" : "connected",
              "usageRefreshSeconds" : 300
            },
            {
              "color" : "#259c8e",
              "createdAt" : "2026-01-02T03:04:05Z",
              "excludedFromScheduling" : true,
              "home" : "\\/tmp\\/homes\\/cx",
              "id" : "cx",
              "label" : "Codex",
              "pinned" : false,
              "provider" : "codex",
              "status" : "disconnected"
            }
          ],
          "version" : 1
        }
        """
        let ws = workspace()
        try fm.createDirectory(at: ws.root, withIntermediateDirectories: true)
        try Data(old.utf8).write(to: ws.accountsFile)

        let store = AccountStore(workspace: ws)
        let accounts = try store.load()
        XCTAssertEqual(accounts.map(\.loginSource), [.managed, .managed])
        XCTAssertFalse(accounts.contains(where: \.tracksDefaultLogin))

        try store.save(accounts)
        XCTAssertEqual(String(decoding: try Data(contentsOf: ws.accountsFile), as: UTF8.self), old)

        // Opting in writes the key; switching back removes it again.
        var work = accounts[0]
        work.loginSource = .providerDefault
        try store.upsert(work)
        let written = String(decoding: try Data(contentsOf: ws.accountsFile), as: UTF8.self)
        XCTAssertTrue(written.contains(#""loginSource" : "providerDefault""#), written)
        XCTAssertEqual(try store.find("work")?.loginSource, .providerDefault)
        work.loginSource = .managed
        try store.upsert(work)
        XCTAssertEqual(String(decoding: try Data(contentsOf: ws.accountsFile), as: UTF8.self), old)
    }

    /// A value from a newer build must not fail the whole inventory.
    func testUnknownLoginSourceDecodesAsManaged() throws {
        let json = ##"{"id":"a","label":"a","color":"#000000","provider":"claude","home":"/tmp/a","status":"connected","createdAt":"2026-01-02T03:04:05Z","loginSource":"somethingNew"}"##
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(Account.self, from: Data(json.utf8)).loginSource, .managed)
    }

    // MARK: Credential locations

    func testCredentialLocationsResolvePerLoginSource() {
        let ws = workspace()
        var claude = managedAccount("cl", ws: ws)
        XCTAssertEqual(claude.effectiveKeychainService, "Claude Code-credentials-abc12345")
        XCTAssertEqual(claude.configHomeURL(homeDirectory: fakeHome), claude.homeURL)
        XCTAssertEqual(claude.identityFileURL(homeDirectory: fakeHome).path, claude.homeURL.appendingPathComponent(".claude.json").path)

        claude.loginSource = .providerDefault
        XCTAssertEqual(claude.effectiveKeychainService, "Claude Code-credentials", "unsuffixed default item")
        XCTAssertEqual(claude.keychainService, "Claude Code-credentials-abc12345", "stored item kept for switching back")
        XCTAssertEqual(claude.identityFileURL(homeDirectory: fakeHome).path,
                       fakeHome.appendingPathComponent(".claude.json").path, "~/.claude.json, beside ~/.claude")
        XCTAssertEqual(claude.home, ws.managedHome(forAccountID: "cl").path, "home stays a managed path")

        var codex = managedAccount("cx", provider: .codex, ws: ws)
        XCTAssertEqual(codex.configHomeURL(homeDirectory: fakeHome), codex.homeURL)
        codex.loginSource = .providerDefault
        XCTAssertNil(codex.effectiveKeychainService)
        XCTAssertEqual(codex.configHomeURL(homeDirectory: fakeHome).path,
                       fakeHome.appendingPathComponent(".codex").path)
        XCTAssertEqual(codex.identityFileURL(homeDirectory: fakeHome).path,
                       fakeHome.appendingPathComponent(".codex/auth.json").path)
    }

    // MARK: Scheduling and cloud routines

    /// Nothing special-cases the default login any more: it is in the
    /// cloud-routine set whenever its resolved method is `routine`.
    func testCloudRoutineSetIncludesDefaultLoginAccount() {
        let ws = workspace()
        var desk = managedAccount("desk", ws: ws)
        desk.loginSource = .providerDefault
        let other = managedAccount("other", ws: ws)
        var prefs = Preferences(claudePingMethod: .routine)
        XCTAssertEqual(prefs.cloudRoutineAccounts([desk, other]), ["desk", "other"])
        prefs.setPingOverride(AccountPingOverride(method: .headless), forAccount: "desk")
        XCTAssertEqual(prefs.cloudRoutineAccounts([desk, other]), ["other"], "its own override applies as usual")
    }

    // MARK: The child environment (isolation variable removed)

    /// The heart of it: a default-login account's child has **no**
    /// `CLAUDE_CONFIG_DIR` / `CODEX_HOME` — not even one inherited from the
    /// caller — because Claude Code picks a suffixed Keychain item whenever the
    /// variable is set at all. A managed account still gets its own path.
    func testChildEnvironmentRemovesIsolationVarOnlyForDefaultLogin() {
        let ws = workspace()
        for provider in Provider.allCases {
            let key = provider.configHomeEnvKey
            let base = ["HOME": fakeHome.path, "PATH": "/usr/bin:/bin", key: "/inherited/elsewhere", "LANG": "C"]
            var account = managedAccount("acct-\(provider.rawValue)", provider: provider, ws: ws)

            let managed = ChildEnvironment.make(for: account, base: base)
            XCTAssertEqual(managed[key], account.home, "\(provider): managed home injected over the inherited value")

            account.loginSource = .providerDefault
            let def = ChildEnvironment.make(for: account, base: base)
            XCTAssertNil(def[key], "\(provider): isolation variable must be absent, not set to the default home")
            // Everything else is the same enriched environment.
            XCTAssertEqual(def["LANG"], "C")
            XCTAssertEqual(def["PATH"], managed["PATH"])
            XCTAssertEqual(def["TERM"], managed["TERM"])
        }
    }

    /// The delegated `/status` refresh answers Claude's trust dialog, and the
    /// CLI records that in the config it runs under — so *where* it runs is
    /// pinned: never the caller's cwd (`/` for the app and the daemon, which
    /// would trust every folder), and for a default-login account never with
    /// the isolation variable set.
    func testTokenRefreshLaunchSpecPinsEnvironmentAndWorkingDirectory() {
        let ws = workspace()
        let key = Provider.claude.configHomeEnvKey
        let base = ["HOME": fakeHome.path, "PATH": "/usr/bin:/bin", key: "/inherited/elsewhere"]
        var account = managedAccount("main", ws: ws)

        let managed = ClaudeTokenRefresher.launchSpec(for: account, workspace: ws, base: base)
        XCTAssertEqual(managed.environment[key], account.home)
        XCTAssertEqual(managed.workingDirectory, account.homeURL)

        account.loginSource = .providerDefault
        let def = ClaudeTokenRefresher.launchSpec(for: account, workspace: ws, base: base)
        XCTAssertNil(def.environment[key])
        XCTAssertEqual(def.workingDirectory, ws.root)
        XCTAssertNotEqual(def.workingDirectory.path, "/")
    }

    /// `am run <id>` for a default-login account is a plain `claude`: the
    /// stub binary, the passthrough args, and no `CLAUDE_CONFIG_DIR`.
    func testRunPlanForDefaultLoginIsAPlainCLI() throws {
        let ws = workspace()
        try writeDefaultClaudeIdentity(email: "me@example.com")
        try DefaultLoginAccounts(workspace: ws, probe: probe(KeychainSpy(Self.liveToken)))
            .add(id: "claude-ms55", label: "Main", provider: .claude)
        let stub = try makeStub("claude", body: "exit 0")
        let before = try snapshotDefaultHome()

        let plan = try AccountRunner(workspace: ws).plan(
            "claude-ms55", passthrough: ["--resume", "abc"],
            baseEnvironment: [
                "HOME": fakeHome.path, "PATH": "/usr/bin:/bin",
                "AGENT_MANAGER_CLAUDE_BIN": stub.path, "CLAUDE_CONFIG_DIR": "/from/my/shell",
            ])
        XCTAssertEqual(plan.executablePath, stub.path)
        XCTAssertEqual(plan.arguments, ["--resume", "abc"])
        XCTAssertNil(plan.environment["CLAUDE_CONFIG_DIR"])
        XCTAssertEqual(plan.environment["HOME"], fakeHome.path)
        XCTAssertEqual(try snapshotDefaultHome(), before)
        XCTAssertFalse(fm.fileExists(atPath: ws.managedHome(forAccountID: "claude-ms55").path))
    }

    /// An executable shell script under the temp dir (never the fake home).
    func makeStub(_ name: String, body: String) throws -> URL {
        let dir = tmp.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// A Test ping (any built-in method; headless here) runs the CLI with the
    /// isolation variable absent, in the workspace root (the managed home
    /// doesn't exist), and our code writes nothing into the default home.
    func testPingOfDefaultLoginRunsTheCLIWithoutIsolationInTheWorkspaceRoot() throws {
        let ws = workspace()
        try writeDefaultClaudeIdentity(email: "me@example.com")
        let account = try DefaultLoginAccounts(workspace: ws, probe: probe(KeychainSpy(Self.liveToken)))
            .add(id: "desk", label: "Desk", provider: .claude)
        let record = tmp.appendingPathComponent("record.txt")
        let stub = try makeStub("claude", body: """
            echo "config=${CLAUDE_CONFIG_DIR-<unset>}" > '\(record.path)'
            echo "cwd=$(pwd -P)" >> '\(record.path)'
            echo '{"is_error":false,"usage":{"input_tokens":1,"cache_creation_input_tokens":0,"output_tokens":1}}'
            """)
        let before = try snapshotDefaultHome()

        let pinger = AccountPinger(workspace: ws, baseEnvironment: [
            "HOME": fakeHome.path, "PATH": "/usr/bin:/bin",
            "AGENT_MANAGER_CLAUDE_BIN": stub.path, "CLAUDE_CONFIG_DIR": "/inherited",
            "ANTHROPIC_API_KEY": "must-not-reach-child",
        ])
        let result = try pinger.runTurn("desk", methodOverride: .headless)
        XCTAssertTrue(result.ok, result.detail)

        let recorded = try String(contentsOf: record, encoding: .utf8)
        XCTAssertTrue(recorded.contains("config=<unset>"), recorded)
        // `pwd -P` reports /private/var/…; compare the unambiguous tail.
        XCTAssertTrue(recorded.contains("/\(tmp.lastPathComponent)/ws\n"), recorded)
        XCTAssertEqual(AccountPinger.workingDirectory(for: account, workspace: ws), ws.root)
        XCTAssertFalse(fm.fileExists(atPath: account.home), "no managed home is created for it")
        XCTAssertEqual(try snapshotDefaultHome(), before, "nothing of ours lands in the default home")
    }

    /// "Log in" in Terminal: the variable is removed for the one command (any
    /// shell — `env -u`), never set to `~/.claude`; a managed account keeps
    /// its `cd` + preset path. Only constants and the validated slug path.
    func testTerminalLoginCommandUnsetsTheVariableForDefaultLogin() {
        let ws = workspace()
        var claude = managedAccount("main", ws: ws)
        XCTAssertEqual(TerminalLauncher.loginCommand(for: claude),
                       "cd \(claude.homeShellQuoted) && CLAUDE_CONFIG_DIR=\(claude.homeShellQuoted) claude /login")
        claude.loginSource = .providerDefault
        XCTAssertEqual(TerminalLauncher.loginCommand(for: claude), "/usr/bin/env -u CLAUDE_CONFIG_DIR claude /login")

        var codex = managedAccount("cx", provider: .codex, ws: ws)
        codex.loginSource = .providerDefault
        XCTAssertEqual(TerminalLauncher.loginCommand(for: codex), "/usr/bin/env -u CODEX_HOME codex login")
    }

    // MARK: Custom ping, login-shell form

    /// The prologue for a default-login run *unsets* the isolation variable
    /// after the profile ran — a constant clause, no value interpolated (hard
    /// rule 5), and it doesn't read `$AGENT_MANAGER_CONFIG_HOME` at all.
    func testLoginShellPrologueUnsetsIsolationVarForDefaultLogin() {
        let zsh = LoginShell(path: "/bin/zsh", family: .posix, homeDirectory: "/Users/x")
        XCTAssertEqual(
            zsh.arguments(running: "x", provider: .claude, configHome: .unset, prependsProviderBinDir: true)[2],
            #"unset CLAUDE_CONFIG_DIR; unset ANTHROPIC_API_KEY; export PATH="$AGENT_MANAGER_PROVIDER_BIN_DIR:$PATH"; x"#)
        XCTAssertEqual(
            zsh.arguments(running: "x", provider: .codex, configHome: .unset, prependsProviderBinDir: false)[2],
            "unset CODEX_HOME; unset OPENAI_API_KEY; x")
        let fish = LoginShell(path: "/opt/homebrew/bin/fish", family: .fish, homeDirectory: "/Users/x")
        XCTAssertEqual(
            fish.arguments(running: "x", provider: .claude, configHome: .unset, prependsProviderBinDir: true)[2],
            "set -e -g CLAUDE_CONFIG_DIR; set -e -g ANTHROPIC_API_KEY; set -q ANTHROPIC_API_KEY; and set -gx ANTHROPIC_API_KEY; set -gx PATH $AGENT_MANAGER_PROVIDER_BIN_DIR $PATH; x")
        XCTAssertEqual(
            fish.arguments(running: "x", provider: .codex, configHome: .unset, prependsProviderBinDir: false)[2],
            "set -e -g CODEX_HOME; set -e -g OPENAI_API_KEY; set -q OPENAI_API_KEY; and set -gx OPENAI_API_KEY; x")

        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_ -;=\"$:")
        for family in [LoginShell.Family.posix, .fish] {
            for provider in Provider.allCases {
                let prologue = LoginShell.prologue(
                    family: family, provider: provider, configHome: .unset, prependsProviderBinDir: true)
                XCTAssertFalse(prologue.contains(LoginShell.configHomeEnvKey), prologue)
                XCTAssertFalse(prologue.contains("/"), prologue)
                XCTAssertTrue(prologue.allSatisfy { allowed.contains($0) }, prologue)
            }
        }
    }

    /// The carriers the runner exports for a default-login run: no isolation
    /// variable (even if the caller passed one), `AGENT_MANAGER_CONFIG_HOME` =
    /// the default home, and the `unset` clause.
    func testCustomLoginShellEnvironmentForDefaultLogin() {
        let configHome = fakeHome.appendingPathComponent(".claude").path
        let prepared = CustomPingRunner.loginShellEnvironment(
            ["PATH": "/usr/bin:/bin", "CLAUDE_CONFIG_DIR": "/stray"], provider: .claude,
            login: .providerDefault(configHome: configHome), shimDirectory: nil)
        XCTAssertEqual(prepared.configHome, .unset)
        XCTAssertNil(prepared.env["CLAUDE_CONFIG_DIR"])
        XCTAssertEqual(prepared.env[LoginShell.configHomeEnvKey], configHome)
    }

    /// End to end through a real zsh: a profile that exports
    /// `CLAUDE_CONFIG_DIR` (and an API key) must not win — the line sees the
    /// variable unset, the key gone, and `AGENT_MANAGER_CONFIG_HOME` naming
    /// the default home (resolved from the child's `HOME`).
    func testCustomLoginShellPingOfDefaultLoginUnsetsAProfileExportInZsh() throws {
        let ws = workspace()
        try writeDefaultClaudeIdentity(email: "me@example.com")
        try DefaultLoginAccounts(workspace: ws, probe: probe(KeychainSpy(Self.liveToken)))
            .add(id: "desk", label: "Desk", provider: .claude)
        let zdot = tmp.appendingPathComponent("zdot", isDirectory: true)
        try fm.createDirectory(at: zdot, withIntermediateDirectories: true)
        try "export CLAUDE_CONFIG_DIR=/wrong/account\nexport ANTHROPIC_API_KEY=sk-profile\n"
            .write(to: zdot.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
        PreferencesStore(workspace: ws).save(Preferences(
            claudePingMethod: .custom,
            claudeCustomCommand: .loginShell(
                #"test -z "${CLAUDE_CONFIG_DIR+x}" && test -z "$ANTHROPIC_API_KEY" && test "$AGENT_MANAGER_CONFIG_HOME" = "$EXPECTED_HOME""#)))
        var pinger = AccountPinger(workspace: ws, baseEnvironment: [
            "HOME": fakeHome.path, "PATH": "/usr/bin:/bin", "ZDOTDIR": zdot.path,
            "CLAUDE_CONFIG_DIR": "/inherited", "ANTHROPIC_API_KEY": "must-not-reach-child",
            "EXPECTED_HOME": fakeHome.appendingPathComponent(".claude").path,
        ])
        let homePath = fakeHome.path
        pinger.loginShellLookup = { LoginShell.UserRecord(shell: "/bin/zsh", homeDirectory: homePath) }

        let result = try pinger.runTurn("desk")
        XCTAssertEqual(result.pingMethod, .custom)
        XCTAssertTrue(result.detail.hasPrefix("custom command (zsh login shell) exited 0"), result.detail + result.transcript)
    }

    /// The same through a real fish (skipped when none is installed): the
    /// prologue's `set -e -g` removes the profile's global export.
    func testCustomLoginShellPingOfDefaultLoginUnsetsAProfileExportInFish() throws {
        guard let fish = ["/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/usr/bin/fish"]
            .first(where: { fm.isExecutableFile(atPath: $0) })
        else { throw XCTSkip("no fish binary installed") }
        let ws = workspace()
        try writeDefaultClaudeIdentity(email: "me@example.com")
        try DefaultLoginAccounts(workspace: ws, probe: probe(KeychainSpy(Self.liveToken)))
            .add(id: "desk", label: "Desk", provider: .claude)
        // XDG_CONFIG_HOME keeps fish's config and universal store in the temp dir.
        let fishDir = tmp.appendingPathComponent("xdg/fish", isDirectory: true)
        try fm.createDirectory(at: fishDir, withIntermediateDirectories: true)
        try "set -gx CLAUDE_CONFIG_DIR /wrong/account\n"
            .write(to: fishDir.appendingPathComponent("config.fish"), atomically: true, encoding: .utf8)
        PreferencesStore(workspace: ws).save(Preferences(
            claudePingMethod: .custom,
            claudeCustomCommand: .loginShell(
                #"not set -q CLAUDE_CONFIG_DIR; and test "$AGENT_MANAGER_CONFIG_HOME" = "$EXPECTED_HOME""#)))
        var pinger = AccountPinger(workspace: ws, baseEnvironment: [
            "HOME": fakeHome.path, "PATH": "/usr/bin:/bin",
            "XDG_CONFIG_HOME": fishDir.deletingLastPathComponent().path,
            "EXPECTED_HOME": fakeHome.appendingPathComponent(".claude").path,
        ])
        let homePath = fakeHome.path
        pinger.loginShellLookup = { LoginShell.UserRecord(shell: fish, homeDirectory: homePath) }

        let result = try pinger.runTurn("desk")
        XCTAssertTrue(result.detail.hasPrefix("custom command (fish login shell) exited 0"), result.detail + result.transcript)
    }

    // MARK: One per provider

    func testStoreAllowsOneDefaultLoginAccountPerProvider() throws {
        let ws = workspace()
        let store = AccountStore(workspace: ws)
        var a = managedAccount("a", ws: ws); a.loginSource = .providerDefault
        var b = managedAccount("b", ws: ws); b.loginSource = .providerDefault
        var cx = managedAccount("cx", provider: .codex, ws: ws); cx.loginSource = .providerDefault
        try store.insert(a)
        XCTAssertThrowsError(try store.insert(b)) { error in
            XCTAssertEqual(error as? AccountStoreError, .defaultLoginTaken(provider: .claude, accountID: "a"))
        }
        try store.insert(cx) // a different provider is fine

        // Converting an existing account goes through `upsert`: same guard.
        b.loginSource = .managed
        try store.insert(b)
        b.loginSource = .providerDefault
        XCTAssertThrowsError(try store.upsert(b))
        XCTAssertEqual(try store.find("b")?.loginSource, .managed)
        // Re-saving the owner itself is not a conflict.
        a.label = "renamed"
        try store.upsert(a)
        XCTAssertEqual(AccountStore.defaultLoginOwner(provider: .claude, in: try store.load())?.id, "a")
        XCTAssertNil(AccountStore.defaultLoginOwner(provider: .claude, in: try store.load(), excludingID: "a"))
    }

    // MARK: Add

    func testAddVerifiesDefaultLoginWithoutTouchingAnyHome() throws {
        let ws = workspace()
        try writeDefaultClaudeIdentity(email: "me@example.com")
        let spy = KeychainSpy(Self.liveToken)
        let before = try snapshotDefaultHome()

        let account = try DefaultLoginAccounts(workspace: ws, probe: probe(spy))
            .add(id: "desk", label: "Desk", provider: .claude)

        XCTAssertEqual(spy.services, ["Claude Code-credentials"])
        XCTAssertEqual(account.loginSource, .providerDefault)
        XCTAssertEqual(account.status, .connected)
        XCTAssertEqual(account.identityEmail, "me@example.com")
        XCTAssertEqual(account.home, ws.managedHome(forAccountID: "desk").path)
        XCTAssertNotNil(account.keychainService, "a managed item name is ready for a later switch back")
        XCTAssertFalse(fm.fileExists(atPath: account.home), "no managed home is provisioned")
        XCTAssertEqual(try snapshotDefaultHome(), before, "the default home is only read")
        XCTAssertEqual(try AccountStore(workspace: ws).find("desk")?.loginSource, .providerDefault)

        // A second one for the same provider is refused before any read.
        XCTAssertThrowsError(try DefaultLoginAccounts(workspace: ws, probe: probe(spy))
            .add(id: "desk2", label: "Desk 2", provider: .claude))
        { error in
            XCTAssertEqual(error as? AccountStoreError, .defaultLoginTaken(provider: .claude, accountID: "desk"))
        }
        XCTAssertEqual(spy.services.count, 1, "the refusal happened before a second Keychain read")
    }

    func testAddRefusesSignedOutOrMissingDefaultLogin() throws {
        let ws = workspace()
        try writeDefaultClaudeIdentity(email: "me@example.com")
        let flows = DefaultLoginAccounts(workspace: ws, probe: probe(KeychainSpy(.signedOut(reason: "time_limit"))))
        XCTAssertThrowsError(try flows.add(id: "desk", label: "Desk", provider: .claude)) { error in
            guard case let .unavailable(provider, detail) = error as? DefaultLoginError else {
                return XCTFail("expected unavailable, got \(error)")
            }
            XCTAssertEqual(provider, .claude)
            XCTAssertTrue(detail.contains("signed out"), detail)
            XCTAssertTrue("\(error)".contains("Claude desktop app"), "\(error)")
        }
        XCTAssertEqual(try AccountStore(workspace: ws).load(), [])

        // Codex with no ~/.codex/auth.json at all.
        XCTAssertThrowsError(try flows.add(id: "cx", label: "Codex", provider: .codex))
    }

    func testAddAccountFlowRoutesDefaultLoginThroughTheVerifyOnlyPath() throws {
        let ws = workspace()
        try writeDefaultCodexAuth(email: "me@example.com")
        var events: [String] = []
        let account = try AddAccountFlow(workspace: ws).run(
            .init(id: "cx", label: "Codex", provider: .codex, loginSource: .providerDefault),
            probe: probe(KeychainSpy(nil)),
            onEvent: { if case let .verified(connected, _) = $0 { events.append("verified:\(connected)") } })
        XCTAssertEqual(events, ["verified:true"])
        XCTAssertEqual(account.identityEmail, "me@example.com")
        XCTAssertEqual(account.status, .connected)
        XCTAssertFalse(fm.fileExists(atPath: account.home), "no managed home, no guided login")
    }

    // MARK: Convert

    func testConvertRefusesADifferentPersonAndChangesNothing() throws {
        let ws = workspace()
        try writeDefaultClaudeIdentity(email: "someone-else@example.com")
        let original = managedAccount("main", email: "me@example.com", ws: ws)
        try AccountStore(workspace: ws).insert(original)

        let flows = DefaultLoginAccounts(workspace: ws, probe: probe(KeychainSpy(Self.liveToken)))
        XCTAssertThrowsError(try flows.useDefaultLogin("main")) { error in
            XCTAssertEqual(error as? DefaultLoginError, .identityMismatch(
                provider: .claude, accountEmail: "me@example.com", defaultEmail: "someone-else@example.com"))
            let text = "\(error)"
            XCTAssertTrue(text.contains("me@example.com") && text.contains("someone-else@example.com"), text)
        }
        XCTAssertEqual(try AccountStore(workspace: ws).find("main"), original)
    }

    func testIdentityRule() throws {
        XCTAssertNoThrow(try DefaultLoginAccounts.checkIdentity(provider: .claude, accountEmail: nil, defaultEmail: "x@y"))
        XCTAssertNoThrow(try DefaultLoginAccounts.checkIdentity(provider: .claude, accountEmail: "Me@Example.com", defaultEmail: "me@example.com"))
        XCTAssertThrowsError(try DefaultLoginAccounts.checkIdentity(provider: .claude, accountEmail: "me@x", defaultEmail: nil),
                             "an unreadable default identity can't be shown to be the same person")
    }

    /// The owner's own case: a managed account whose login ended, switched to
    /// the default login and back. Its managed home, stored Keychain item, and
    /// scheduling opt-out survive the round trip.
    func testConvertToDefaultAndBackKeepsTheManagedHome() throws {
        let ws = workspace()
        try writeDefaultClaudeIdentity(email: "me@example.com")
        var original = managedAccount("main", email: "me@example.com", ws: ws, excluded: true)
        original.status = .connected
        try fm.createDirectory(at: original.homeURL, withIntermediateDirectories: true)
        let marker = original.homeURL.appendingPathComponent(".claude.json")
        try #"{"oauthAccount":{"emailAddress":"me@example.com"}}"#.write(to: marker, atomically: true, encoding: .utf8)
        try AccountStore(workspace: ws).insert(original)
        let before = try snapshotDefaultHome()

        let managedResult = IdentityVerifier.Result(
            connected: false, oauthAccountPresent: false, keychainItemPresent: false,
            identityEmail: nil, detail: "managed: not logged in")
        let flows = DefaultLoginAccounts(
            workspace: ws, probe: probe(KeychainSpy(Self.liveToken)), verifyManaged: { _, _ in managedResult })

        let converted = try flows.useDefaultLogin("main")
        XCTAssertTrue(converted.tracksDefaultLogin)
        XCTAssertEqual(converted.status, .connected)
        XCTAssertEqual(converted.keychainService, original.keychainService)
        XCTAssertTrue(converted.excludedFromScheduling)
        XCTAssertTrue(fm.fileExists(atPath: marker.path), "managed home left on disk")
        XCTAssertEqual(try snapshotDefaultHome(), before)

        let back = try flows.useManagedLogin("main")
        XCTAssertEqual(back.loginSource, .managed)
        XCTAssertEqual(back.status, .disconnected, "whatever the managed home really is")
        XCTAssertEqual(back.identityEmail, "me@example.com")
        XCTAssertTrue(fm.fileExists(atPath: marker.path))
        XCTAssertEqual(try snapshotDefaultHome(), before)
    }

    /// The managed home's identity file outlives its login: when the managed
    /// Keychain item is blanked, switching back must not read `connected` (and
    /// so must not rejoin the schedule).
    func testSwitchBackToAnEndedManagedLoginIsExpiredNotConnected() throws {
        let ws = workspace()
        try writeDefaultClaudeIdentity(email: "me@example.com")
        var original = managedAccount("main", email: "me@example.com", ws: ws)
        original.status = .connected
        try AccountStore(workspace: ws).insert(original)

        let spy = KeychainSpy(Self.liveToken)
        let stillHasIdentity = IdentityVerifier.Result(
            connected: true, oauthAccountPresent: true, keychainItemPresent: true,
            identityEmail: "me@example.com", detail: "managed: oauthAccount present")
        let flows = DefaultLoginAccounts(
            workspace: ws, probe: probe(spy), verifyManaged: { _, _ in stillHasIdentity })
        try flows.useDefaultLogin("main")

        spy.status = .signedOut(reason: "time_limit")
        let back = try flows.useManagedLogin("main")
        XCTAssertEqual(back.status, .expired, "not connected, so not schedulable")
        XCTAssertEqual(spy.services.last, original.keychainService, "asked the managed item, not the default one")

        // A live managed credential stays connected.
        spy.status = Self.liveToken
        try flows.useDefaultLogin("main")
        XCTAssertEqual(try flows.useManagedLogin("main").status, .connected)
    }

    /// An account created on the default login has no managed home; switching
    /// it to managed lays one down (in the workspace — never in the default
    /// home) and leaves it for the user to log in.
    func testSwitchToManagedProvisionsAMissingHome() throws {
        let ws = workspace()
        try writeDefaultCodexAuth(email: "me@example.com")
        let flows = DefaultLoginAccounts(
            workspace: ws, probe: probe(KeychainSpy(nil)),
            verifyManaged: { IdentityVerifier.verify(provider: $0, home: $1, keychainBaseline: nil) })
        let added = try flows.add(id: "cx", label: "Codex", provider: .codex)
        XCTAssertFalse(fm.fileExists(atPath: added.home))
        let before = try snapshotDefaultHome()

        let back = try flows.useManagedLogin("cx")
        XCTAssertTrue(fm.fileExists(atPath: back.home))
        XCTAssertEqual(back.status, .disconnected, "the fresh managed home has no auth.json of its own")
        XCTAssertEqual(try snapshotDefaultHome(), before, "links point into ~/.codex, nothing is written there")
    }

    func testReverifyExpiresWhenTheDefaultLoginChangedPerson() throws {
        let ws = workspace()
        try writeDefaultClaudeIdentity(email: "me@example.com")
        let flows = DefaultLoginAccounts(workspace: ws, probe: probe(KeychainSpy(Self.liveToken)))
        try flows.add(id: "desk", label: "Desk", provider: .claude)

        try writeDefaultClaudeIdentity(email: "partner@example.com")
        let detail = try flows.reverify("desk")
        XCTAssertTrue(detail.contains("partner@example.com"), detail)
        let account = try XCTUnwrap(AccountStore(workspace: ws).find("desk"))
        XCTAssertEqual(account.status, .expired)
        XCTAssertEqual(account.identityEmail, "me@example.com", "never adopts a different person")
    }

    // MARK: Messages

    /// Behavior is identical to a managed account; only the two messages that
    /// would send the user to the wrong place are reworded — and they name
    /// both routes, since both now sign in the login this account uses.
    func testDefaultLoginErrorVariantsNameBothLoginRoutes() {
        let ws = workspace()
        var account = managedAccount("main", ws: ws)
        guard case .loginEnded = UsageFetchError.loginEnded(accountID: "main", reason: nil).adapted(for: account) else {
            return XCTFail("managed accounts keep the managed message")
        }
        account.loginSource = .providerDefault

        let ended = UsageFetchError.loginEnded(accountID: "main", reason: "time_limit").adapted(for: account)
        guard case .defaultLoginSignedOut = ended else { return XCTFail("\(ended)") }
        let endedText = ended.errorDescription ?? ""
        XCTAssertTrue(endedText.contains("time limit"), endedText)
        XCTAssertTrue(endedText.contains("Claude desktop app"), endedText)
        XCTAssertTrue(endedText.contains("am run main") && endedText.contains("/login"), endedText)
        XCTAssertFalse(endedText.contains("separate login"), endedText)
        XCTAssertTrue(ended.requiresLogin)

        // Window gating and the generic 401 are exactly the managed ones.
        guard case .refreshDeferred = UsageFetchError.refreshDeferred.adapted(for: account) else {
            return XCTFail("an expired default token defers like a managed one")
        }
        guard case .unauthorized = UsageFetchError.unauthorized.adapted(for: account) else {
            return XCTFail("a 401 reads as for a managed account")
        }
        guard case .rateLimited = UsageFetchError.rateLimited(retryAfter: nil).adapted(for: account) else {
            return XCTFail("unrelated errors pass through")
        }
    }

    /// An aged or revoked default Codex token: we never refresh a Codex token
    /// ourselves, so the server's `token_expired` verdict is reported as for a
    /// managed account — a login problem — worded for the default login: both
    /// `codex login` and `am run <id> login` sign in `~/.codex`.
    func testDefaultCodexTokenExpiredReportsBothLoginRoutes() {
        let ws = workspace()
        var codex = managedAccount("cx", provider: .codex, ws: ws)
        codex.loginSource = .providerDefault
        let lastRefresh = Date(timeIntervalSince1970: 1_000_000)
        let rejected = CodexUsageFetcher.classifyRejectionForTesting(
            statusCode: 401, errorCodeHeader: "token_expired", body: Data(),
            accountID: "cx", lastRefresh: lastRefresh).adapted(for: codex)
        guard case .defaultLoginTokenRevoked(accountID: "cx", lastRefresh: lastRefresh) = rejected else {
            return XCTFail("\(rejected)")
        }
        XCTAssertTrue(rejected.requiresLogin)
        let text = UsageFetchError.defaultLoginTokenRevokedMessage(
            accountID: "cx", lastRefresh: lastRefresh, now: lastRefresh.addingTimeInterval(3 * 86400))
        XCTAssertTrue(text.contains("codex login"), text)
        XCTAssertTrue(text.contains("am run cx login"), text)
        XCTAssertTrue(text.contains("~/.codex"), text)
        XCTAssertTrue(text.contains("3d ago"), text)
    }
}
