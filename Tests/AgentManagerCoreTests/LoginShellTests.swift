import XCTest
@testable import AgentManagerCore

/// The `custom` method's login-shell form: shell resolution, the constant
/// prologue, storage, and end-to-end runs through real shells whose profiles
/// try to undo the managed home, the API-key removal, and the binary's PATH
/// position.
final class LoginShellTests: XCTestCase {
    private let fileManager = FileManager.default
    private var dir: URL!

    override func setUpWithError() throws {
        dir = fileManager.temporaryDirectory
            .appendingPathComponent("am-loginshell-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: dir)
    }

    private func lookup(_ shell: String, home: String? = nil) -> LoginShell.Lookup {
        let record = LoginShell.UserRecord(shell: shell, homeDirectory: home ?? dir.path)
        return { record }
    }

    // MARK: - Resolution

    func testFamilyByBasename() {
        for name in ["zsh", "bash", "sh", "dash", "ksh"] {
            XCTAssertEqual(LoginShell.family(forShellNamed: name), .posix, name)
        }
        XCTAssertEqual(LoginShell.family(forShellNamed: "fish"), .fish)
        for name in ["tcsh", "csh", "nu", "xonsh", "elvish", "pwsh", "", "zsh5"] {
            XCTAssertNil(LoginShell.family(forShellNamed: name), name)
        }
    }

    func testResolveSupportedShell() throws {
        let shell = try LoginShell.resolve(lookup: lookup("/bin/zsh")).get()
        XCTAssertEqual(shell, LoginShell(path: "/bin/zsh", family: .posix, homeDirectory: dir.path))
        XCTAssertEqual(shell.name, "zsh")
        // A fish anywhere (it's never in /bin) resolves by basename.
        let fish = try executable("bin/fish")
        XCTAssertEqual(try LoginShell.resolve(lookup: lookup(fish.path)).get().family, .fish)
    }

    func testResolveProblems() throws {
        XCTAssertEqual(LoginShell.resolve(lookup: { nil }), .failure(.unknown))
        XCTAssertEqual(LoginShell.resolve(lookup: lookup("")), .failure(.unknown))
        XCTAssertEqual(LoginShell.resolve(lookup: lookup("  ")), .failure(.unknown))
        XCTAssertEqual(LoginShell.resolve(lookup: lookup("zsh")), .failure(.notAbsolute("zsh")))
        let missing = dir.appendingPathComponent("nope/zsh").path
        XCTAssertEqual(LoginShell.resolve(lookup: lookup(missing)), .failure(.notExecutable(missing)))
        let plain = dir.appendingPathComponent("bash")
        try "x".write(to: plain, atomically: true, encoding: .utf8)
        XCTAssertEqual(LoginShell.resolve(lookup: lookup(plain.path)), .failure(.notExecutable(plain.path)))
        XCTAssertEqual(LoginShell.resolve(lookup: lookup(dir.path)), .failure(.notExecutable(dir.path)))
        let tcsh = try executable("bin/tcsh")
        XCTAssertEqual(LoginShell.resolve(lookup: lookup(tcsh.path)), .failure(.unsupported("tcsh")))
        let nu = try executable("bin/nu")
        XCTAssertEqual(LoginShell.resolve(lookup: lookup(nu.path)), .failure(.unsupported("nu")))
        let noHome = dir.appendingPathComponent("gone").path
        XCTAssertEqual(LoginShell.resolve(lookup: lookup("/bin/zsh", home: noHome)), .failure(.noHomeDirectory(noHome)))
        XCTAssertEqual(LoginShell.resolve(lookup: lookup("/bin/zsh", home: "")), .failure(.noHomeDirectory("")))
        XCTAssertTrue("\(LoginShell.Problem.unsupported("tcsh"))".contains("script"),
                      "the unsupported message must point at the argv/script alternative")
    }

    // MARK: - Arguments and prologue

    func testPosixArgumentsPerProvider() {
        let zsh = LoginShell(path: "/bin/zsh", family: .posix, homeDirectory: "/Users/x")
        XCTAssertEqual(
            zsh.arguments(running: "cd ~/evals && npm run eval", provider: .claude,
                          reassertsConfigHome: true, prependsProviderBinDir: true),
            ["-l", "-c",
             #"export CLAUDE_CONFIG_DIR="$AGENT_MANAGER_CONFIG_HOME"; unset ANTHROPIC_API_KEY; export PATH="$AGENT_MANAGER_PROVIDER_BIN_DIR:$PATH"; cd ~/evals && npm run eval"#])
        XCTAssertEqual(
            zsh.arguments(running: "x", provider: .codex,
                          reassertsConfigHome: true, prependsProviderBinDir: true)[2],
            #"export CODEX_HOME="$AGENT_MANAGER_CONFIG_HOME"; unset OPENAI_API_KEY; export PATH="$AGENT_MANAGER_PROVIDER_BIN_DIR:$PATH"; x"#)
        // No binary resolved: no PATH clause (it would prepend an empty entry).
        XCTAssertEqual(
            zsh.arguments(running: "x", provider: .claude,
                          reassertsConfigHome: true, prependsProviderBinDir: false)[2],
            #"export CLAUDE_CONFIG_DIR="$AGENT_MANAGER_CONFIG_HOME"; unset ANTHROPIC_API_KEY; x"#)
        // No managed home in the environment: never export it empty.
        XCTAssertEqual(
            zsh.arguments(running: "x", provider: .claude,
                          reassertsConfigHome: false, prependsProviderBinDir: false)[2],
            "unset ANTHROPIC_API_KEY; x")
    }

    func testFishArgumentsPerProvider() {
        let fish = LoginShell(path: "/opt/homebrew/bin/fish", family: .fish, homeDirectory: "/Users/x")
        XCTAssertEqual(
            fish.arguments(running: "cd ~/evals; and npm run eval", provider: .claude,
                           reassertsConfigHome: true, prependsProviderBinDir: true),
            ["-l", "-c",
             "set -gx CLAUDE_CONFIG_DIR $AGENT_MANAGER_CONFIG_HOME; set -e -g ANTHROPIC_API_KEY; set -q ANTHROPIC_API_KEY; and set -gx ANTHROPIC_API_KEY; set -gx PATH $AGENT_MANAGER_PROVIDER_BIN_DIR $PATH; cd ~/evals; and npm run eval"])
        XCTAssertEqual(
            fish.arguments(running: "x", provider: .codex,
                           reassertsConfigHome: true, prependsProviderBinDir: false)[2],
            "set -gx CODEX_HOME $AGENT_MANAGER_CONFIG_HOME; set -e -g OPENAI_API_KEY; set -q OPENAI_API_KEY; and set -gx OPENAI_API_KEY; x")
    }

    /// Hard rule 5's intent: the prologue carries env-var names and `$VAR`
    /// references only, so whatever the managed home or binary path contains,
    /// none of it can appear in — or break out of — the string a shell parses.
    func testNoValueEverEntersTheShellString() throws {
        let hostileHome = dir.appendingPathComponent("home \"$(touch pwned)\"; '", isDirectory: true)
        try fileManager.createDirectory(at: hostileHome, withIntermediateDirectories: true)
        let claude = try executable("bin `id`; $HOME/claude")
        let env = CustomPingRunner.environment(
            base: ["PATH": "/usr/bin:/bin", "CLAUDE_CONFIG_DIR": hostileHome.path],
            accountID: "a", provider: .claude, providerBinary: claude.path, shimDirectory: nil)
        let shim = try XCTUnwrap(ProviderShim.create(binary: claude.path, name: "claude", parent: hostileHome))
        let prepared = CustomPingRunner.loginShellEnvironment(env, provider: .claude, shimDirectory: shim.path)
        XCTAssertEqual(prepared.env[LoginShell.configHomeEnvKey], hostileHome.path)
        XCTAssertEqual(prepared.env[LoginShell.providerBinDirEnvKey], shim.path)
        XCTAssertTrue(prepared.reassertsConfigHome)
        XCTAssertTrue(prepared.prependsProviderBinDir)

        for family in [LoginShell.Family.posix, .fish] {
            for provider in Provider.allCases {
                let prologue = LoginShell.prologue(
                    family: family, provider: provider,
                    reassertsConfigHome: true, prependsProviderBinDir: true)
                XCTAssertFalse(prologue.contains(hostileHome.path))
                XCTAssertFalse(prologue.contains("/"), "no path of any kind in: \(prologue)")
                // Only identifiers, `$NAME` references, and fixed punctuation.
                let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_ -;=\"$:")
                XCTAssertTrue(prologue.allSatisfy { allowed.contains($0) }, prologue)
            }
        }
    }

    // MARK: - Storage

    func testArgvFormEncodesByteIdenticallyToBefore() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Exactly what the old synthesized `{executable, arguments}` struct wrote.
        let legacy = #"{"claudeCustomCommand":{"arguments":["a b"],"executable":"/bin/echo"},"codexCustomCommand":{"arguments":[],"executable":"/bin/true"}}"#
        let prefs = try JSONDecoder().decode(Preferences.self, from: Data(legacy.utf8))
        XCTAssertEqual(prefs.claudeCustomCommand, .argv(executable: "/bin/echo", arguments: ["a b"]))
        XCTAssertEqual(prefs.codexCustomCommand, CustomPingCommand(executable: "/bin/true"))

        // Byte-for-byte against the pre-login-shell type's synthesized encoding.
        for (exe, args) in [("/bin/echo", ["a b"]), ("/bin/true", []), ("/x/it's", ["", "-lc", "a && b"])] {
            XCTAssertEqual(
                try encoder.encode(CustomPingCommand(executable: exe, arguments: args)),
                try encoder.encode(LegacyCommand(executable: exe, arguments: args)))
        }

        // The whole preferences file round-trips to the same bytes.
        let once = try encoder.encode(prefs)
        let twice = try encoder.encode(try JSONDecoder().decode(Preferences.self, from: once))
        XCTAssertEqual(once, twice)
    }

    func testLoginShellFormRoundTrips() throws {
        let line = #"cd ~/evals && FOO="a b" npm run eval -- --since '1 day' | tee /tmp/x"#
        let command = CustomPingCommand.loginShell(line)
        let compact = JSONEncoder()
        compact.outputFormatting = [.sortedKeys]
        let data = try compact.encode(command)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json.keys.sorted(), ["loginShell"])
        XCTAssertEqual(json["loginShell"] as? String, line, "stored exactly as typed")
        XCTAssertEqual(try JSONDecoder().decode(CustomPingCommand.self, from: data), command)
        XCTAssertEqual(command.commandLine, line)
        XCTAssertTrue(command.isLoginShell)
        XCTAssertNil(command.executable)

        // Works the same for a per-account override.
        var prefs = Preferences()
        prefs.setPingOverride(AccountPingOverride(method: .custom, customCommand: command), forAccount: "eval")
        prefs.setCustomCommand(command, for: .codex)
        let round = try JSONDecoder().decode(Preferences.self, from: try compact.encode(prefs))
        XCTAssertEqual(round.customCommand(forAccount: "eval", provider: .claude), command)
        XCTAssertEqual(round.customCommand(for: .codex), command)
    }

    func testMalformedLoginShellEntriesDecodeForgivingly() throws {
        let json = #"""
        {"claudePingMethod":"custom",
         "claudeCustomCommand":{"loginShell":42},
         "codexCustomCommand":{"loginShell":"   "},
         "accountPingOverrides":{
           "a":{"method":"custom","customCommand":{"loginShell":null}},
           "b":{"method":"custom","customCommand":{"loginShell":"make eval","executable":"/bin/echo"}}}}
        """#
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.claudePingMethod, .custom)
        XCTAssertNil(decoded.claudeCustomCommand)
        XCTAssertNil(decoded.codexCustomCommand)
        // A malformed command inside an override drops that override (as for
        // any undecodable override), and its siblings survive.
        XCTAssertNil(decoded.pingOverride(forAccount: "a"))
        // An explicit `loginShell` key wins over a stray `executable`.
        XCTAssertEqual(decoded.pingOverride(forAccount: "b")?.customCommand, .loginShell("make eval"))
    }

    func testValidateLoginShellForm() throws {
        XCTAssertNoThrow(try CustomPingCommand.loginShell("make eval").validate(loginShell: lookup("/bin/zsh")))
        XCTAssertThrowsError(try CustomPingCommand.loginShell("  \n").validate(loginShell: lookup("/bin/zsh"))) {
            XCTAssertEqual($0 as? CustomPingCommand.ParseError, .emptyShellLine)
        }
        let tcsh = try executable("bin/tcsh")
        XCTAssertThrowsError(try CustomPingCommand.loginShell("make").validate(loginShell: lookup(tcsh.path))) {
            XCTAssertEqual($0 as? LoginShell.Problem, .unsupported("tcsh"))
        }
    }

    // MARK: - Runner, end to end through real shells

    /// Shared probe: the user's line runs this script, which reports exactly
    /// what the eval would see after the profile ran.
    private func probe() throws -> URL {
        try executable("probe.sh", """
            echo "home=$CLAUDE_CONFIG_DIR"
            echo "key=[${ANTHROPIC_API_KEY-unset}]"
            echo "path0=$(echo "$PATH" | cut -d: -f1)"
            echo "which=$(command -v claude)"
            echo "ran=$(claude)"
            echo "shim=$AGENT_MANAGER_PROVIDER_BIN_DIR"
            echo "profile=${PROFILE_RAN:-no}"
            echo "cwd=$(pwd -P)"
            echo "account=$AGENT_MANAGER_ACCOUNT_ID"
            """)
    }

    private func physical(_ url: URL) throws -> String {
        try XCTUnwrap(realpath(url.path, nil).map { p in
            defer { free(p) }
            return String(cString: p)
        })
    }

    /// A profile that does everything a typical developer profile does to
    /// break the guarantees: wrong account home, an API key, and a PATH that
    /// puts something else's `claude` first.
    private let hostileExports = """
        export PROFILE_RAN=yes
        export CLAUDE_CONFIG_DIR=/wrong/account
        export ANTHROPIC_API_KEY=sk-from-profile
        export PATH="$SHADOW_BIN:$PATH"
        """

    private func assertGuarantees(
        _ result: ClaudePingRunner.Result, shellName: String,
        managedHome: String, userHome: URL,
        file: StaticString = #filePath, line: UInt = #line) throws
    {
        let t = result.transcript
        XCTAssertTrue(result.ok, result.detail, file: file, line: line)
        XCTAssertTrue(result.detail.hasPrefix("custom command (\(shellName) login shell) exited 0 after "),
                      result.detail, file: file, line: line)
        XCTAssertTrue(t.hasPrefix("custom command (\(shellName) login shell): /"), t, file: file, line: line)
        XCTAssertFalse(t.prefix(while: { $0 != "\n" }).contains("probe"), "header never names the line", file: file, line: line)
        XCTAssertTrue(t.contains("profile=yes"), "the profile must have loaded: \(t)", file: file, line: line)
        XCTAssertTrue(t.contains("home=\(managedHome)\n"), t, file: file, line: line)
        XCTAssertFalse(t.contains("sk-"), "no API key may survive the profile: \(t)", file: file, line: line)
        // The provider binary is re-asserted through the run's one-symlink
        // shim directory, which is first on PATH and gone once the run ends.
        let shim = try XCTUnwrap(value("shim", in: t), t, file: file, line: line)
        XCTAssertTrue(shim.contains(ProviderShim.directoryPrefix), t, file: file, line: line)
        XCTAssertEqual(value("path0", in: t), shim, t, file: file, line: line)
        XCTAssertEqual(value("which", in: t), shim + "/claude", t, file: file, line: line)
        XCTAssertEqual(value("ran", in: t), "real", "bare claude is the resolved binary: \(t)", file: file, line: line)
        XCTAssertFalse(fileManager.fileExists(atPath: shim), "shim removed after the run", file: file, line: line)
        XCTAssertTrue(t.contains("cwd=\(try physical(userHome))\n"), t, file: file, line: line)
        XCTAssertTrue(t.contains("account=work\n"), t, file: file, line: line)
    }

    private struct Fixture {
        var userHome: URL
        var binDir: URL
        var claude: URL
        var shadow: URL
        var base: [String: String]
        var managedHome: String
    }

    private func fixture() throws -> Fixture {
        let userHome = dir.appendingPathComponent("user home", isDirectory: true)
        try fileManager.createDirectory(at: userHome, withIntermediateDirectories: true)
        let claude = try executable("provider bin/claude", "echo real")
        let shadow = dir.appendingPathComponent("shadow", isDirectory: true)
        _ = try executable("shadow/claude", "echo shadow")
        let managedHome = dir.appendingPathComponent("managed home").path
        let base = [
            "HOME": userHome.path,
            "PATH": "/usr/bin:/bin",
            "CLAUDE_CONFIG_DIR": managedHome,
            "SHADOW_BIN": shadow.path,
        ]
        return Fixture(
            userHome: userHome, binDir: claude.deletingLastPathComponent(), claude: claude,
            shadow: shadow, base: base, managedHome: managedHome)
    }

    func testRunnerThroughRealZshSurvivesHostileProfile() throws {
        let f = try fixture()
        let zdot = dir.appendingPathComponent("zdot", isDirectory: true)
        try fileManager.createDirectory(at: zdot, withIntermediateDirectories: true)
        // .zprofile is what a login, non-interactive zsh reads (with .zshenv
        // and .zlogin); .zshrc is deliberately not.
        try hostileExports.write(to: zdot.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
        try "export PROFILE_RAN=zshrc-should-not-load\n"
            .write(to: zdot.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        var base = f.base
        base["ZDOTDIR"] = zdot.path
        let probe = try probe()

        let result = CustomPingRunner.run(
            command: .loginShell("'\(probe.path)' && true"),
            accountID: "work", provider: .claude, binary: f.claude.path, environment: base,
            loginShell: lookup("/bin/zsh", home: f.userHome.path))
        try assertGuarantees(result, shellName: "zsh", managedHome: f.managedHome, userHome: f.userHome)
    }

    func testRunnerThroughRealBashSurvivesHostileProfile() throws {
        let f = try fixture()
        try hostileExports.write(
            to: f.userHome.appendingPathComponent(".bash_profile"), atomically: true, encoding: .utf8)
        let probe = try probe()

        let result = CustomPingRunner.run(
            command: .loginShell("'\(probe.path)' | cat"),
            accountID: "work", provider: .claude, binary: f.claude.path, environment: f.base,
            loginShell: lookup("/bin/bash", home: f.userHome.path))
        try assertGuarantees(result, shellName: "bash", managedHome: f.managedHome, userHome: f.userHome)
    }

    func testRunnerThroughRealFishSurvivesHostileProfile() throws {
        guard let fish = ["/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/usr/bin/fish"]
            .first(where: { fileManager.isExecutableFile(atPath: $0) })
        else { throw XCTSkip("no fish binary installed") }
        let f = try fixture()
        // XDG_CONFIG_HOME keeps fish's config *and* its universal-variable
        // store (fish_variables) inside the temp dir — the user's own fish
        // state is never read or written by this test.
        let xdg = dir.appendingPathComponent("xdg", isDirectory: true)
        let fishDir = xdg.appendingPathComponent("fish", isDirectory: true)
        try fileManager.createDirectory(at: fishDir, withIntermediateDirectories: true)
        try """
            set -gx PROFILE_RAN yes
            set -gx CLAUDE_CONFIG_DIR /wrong/account
            # A universal export survives `set -e -g`; the prologue must still
            # keep it from the child without erasing the user's stored value.
            set -Ux ANTHROPIC_API_KEY sk-universal
            set -gx ANTHROPIC_API_KEY sk-from-profile
            set -gx PATH $SHADOW_BIN $PATH
            """.write(to: fishDir.appendingPathComponent("config.fish"), atomically: true, encoding: .utf8)
        var base = f.base
        base["XDG_CONFIG_HOME"] = xdg.path
        let probe = try probe()

        let result = CustomPingRunner.run(
            command: .loginShell("'\(probe.path)'; and true"),
            accountID: "work", provider: .claude, binary: f.claude.path, environment: base,
            loginShell: lookup(fish, home: f.userHome.path))
        try assertGuarantees(result, shellName: "fish", managedHome: f.managedHome, userHome: f.userHome)
        // The universal is shadowed (empty), not erased.
        XCTAssertTrue(result.transcript.contains("key=[]") || result.transcript.contains("key=[unset]"), result.transcript)
        let stored = try String(contentsOf: fishDir.appendingPathComponent("fish_variables"), encoding: .utf8)
        XCTAssertTrue(stored.contains("ANTHROPIC_API_KEY:") && stored.contains("universal"), stored)
    }

    func testRunnerTimeoutKillsTheTreeInLoginShellMode() throws {
        let pidFile = dir.appendingPathComponent("grandchild.pid")
        let zdot = dir.appendingPathComponent("zdot", isDirectory: true)
        try fileManager.createDirectory(at: zdot, withIntermediateDirectories: true)
        let shimFile = dir.appendingPathComponent("shim.path")
        let claude = try executable("bin/claude")
        let result = CustomPingRunner.run(
            command: .loginShell("echo \"$AGENT_MANAGER_PROVIDER_BIN_DIR\" > '\(shimFile.path)'; /bin/sleep 300 & echo $! > '\(pidFile.path)'; wait"),
            accountID: "work", provider: .claude, binary: claude.path,
            environment: ["PATH": "/usr/bin:/bin", "HOME": dir.path, "ZDOTDIR": zdot.path],
            timeout: 1, loginShell: lookup("/bin/zsh"))

        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.mayHaveRunTurns)
        XCTAssertTrue(result.needsAnchorVerification)
        XCTAssertTrue(result.detail.hasPrefix("custom command (zsh login shell) timed out"), result.detail)

        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        let deadline = Date().addingTimeInterval(3)
        while kill(pid, 0) == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertNotEqual(kill(pid, 0), 0, "the backgrounded sleep must die with the shell's group")
        let shim = try String(contentsOf: shimFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(shim.contains(ProviderShim.directoryPrefix), shim)
        XCTAssertFalse(fileManager.fileExists(atPath: shim), "a timed-out run still removes its shim")
    }

    func testUnsupportedOrMissingShellFailsAsNeverLaunched() throws {
        let marker = dir.appendingPathComponent("ran")
        let tcsh = try executable("bin/tcsh", "touch '\(marker.path)'")
        let unsupported = CustomPingRunner.run(
            command: .loginShell("echo hi"), accountID: "a", provider: .claude, binary: "claude",
            environment: [:], loginShell: lookup(tcsh.path))
        XCTAssertFalse(unsupported.ok)
        XCTAssertFalse(unsupported.needsAnchorVerification)
        XCTAssertTrue(unsupported.detail.hasPrefix("custom command unusable: "), unsupported.detail)
        XCTAssertTrue(unsupported.detail.contains("tcsh"), unsupported.detail)
        XCTAssertFalse(fileManager.fileExists(atPath: marker.path), "an unsupported shell is never launched")

        let missing = CustomPingRunner.run(
            command: .loginShell("echo hi"), accountID: "a", provider: .claude, binary: "claude",
            environment: [:], loginShell: { nil })
        XCTAssertFalse(missing.ok)
        XCTAssertFalse(missing.needsAnchorVerification)
        XCTAssertTrue(missing.detail.contains("login shell"), missing.detail)
    }

    func testAccountPingerDispatchesLoginShellForm() throws {
        let workspace = Workspace(root: dir.appendingPathComponent("workspace", isDirectory: true))
        let home = workspace.managedHome(forAccountID: "work")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try AccountStore(workspace: workspace).insert(Account(
            id: "work", label: "Work", provider: .claude, home: home.path, status: .connected))
        let zdot = dir.appendingPathComponent("zdot", isDirectory: true)
        try fileManager.createDirectory(at: zdot, withIntermediateDirectories: true)
        try "export ANTHROPIC_API_KEY=sk-profile\nexport CLAUDE_CONFIG_DIR=/wrong\n"
            .write(to: zdot.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
        PreferencesStore(workspace: workspace).save(Preferences(
            claudePingMethod: .custom,
            claudeCustomCommand: .loginShell(#"test -z "$ANTHROPIC_API_KEY" && test "$CLAUDE_CONFIG_DIR" = "$EXPECTED_HOME""#)))
        var pinger = AccountPinger(workspace: workspace, baseEnvironment: [
            "HOME": dir.path, "PATH": "/usr/bin:/bin", "ZDOTDIR": zdot.path,
            "ANTHROPIC_API_KEY": "must-not-reach-child", "EXPECTED_HOME": home.path,
        ])
        pinger.loginShellLookup = lookup("/bin/zsh")

        let result = try pinger.runTurn("work")
        XCTAssertEqual(result.pingMethod, .custom)
        XCTAssertTrue(result.detail.hasPrefix("custom command (zsh login shell) exited 0"), result.detail)
    }

    // MARK: - The provider re-assert never shadows the profile's toolchain

    /// The reason the toggle exists is the profile's toolchain (nvm, mise,
    /// pyenv). The provider binary's real directory — `/opt/homebrew/bin` in
    /// life — also holds node; re-asserting *that directory* after the profile
    /// would hand the eval Homebrew's node. Only the binary may be re-asserted.
    private func toolchainFixture() throws -> (base: [String: String], claude: URL, nvm: URL, home: URL) {
        let home = dir.appendingPathComponent("user home", isDirectory: true)
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        let claude = try executable("brew bin/claude", "echo provider-claude")
        _ = try executable("brew bin/node", "echo brew-node")
        let nvm = try executable("nvm bin/node", "echo nvm-node").deletingLastPathComponent()
        let base = [
            "HOME": home.path,
            // The provider dir is on the inherited PATH, as when
            // ExecutableResolver found the CLI there.
            "PATH": "\(claude.deletingLastPathComponent().path):/usr/bin:/bin",
            "CLAUDE_CONFIG_DIR": dir.appendingPathComponent("managed").path,
            "NVM_BIN": nvm.path,
        ]
        return (base, claude, nvm, home)
    }

    private let toolchainLine = #"echo "node=$(node)"; echo "claude=$(claude)"; echo "shim=$AGENT_MANAGER_PROVIDER_BIN_DIR""#

    private func assertToolchainWins(_ result: ClaudePingRunner.Result, file: StaticString = #filePath, line: UInt = #line) {
        let t = result.transcript
        XCTAssertTrue(result.ok, result.detail, file: file, line: line)
        XCTAssertEqual(value("node", in: t), "nvm-node", "the profile's node must win: \(t)", file: file, line: line)
        XCTAssertEqual(value("claude", in: t), "provider-claude", t, file: file, line: line)
        let shim = value("shim", in: t) ?? ""
        XCTAssertTrue(shim.contains(ProviderShim.directoryPrefix), t, file: file, line: line)
        XCTAssertFalse(fileManager.fileExists(atPath: shim), "shim removed after the run", file: file, line: line)
    }

    func testZshProfileToolchainWinsOverProviderNeighbours() throws {
        let f = try toolchainFixture()
        let zdot = dir.appendingPathComponent("zdot", isDirectory: true)
        try fileManager.createDirectory(at: zdot, withIntermediateDirectories: true)
        try #"export PATH="$NVM_BIN:$PATH""#
            .write(to: zdot.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
        var base = f.base
        base["ZDOTDIR"] = zdot.path
        let result = CustomPingRunner.run(
            command: .loginShell(toolchainLine), accountID: "work", provider: .claude,
            binary: f.claude.path, environment: base,
            loginShell: lookup("/bin/zsh", home: f.home.path))
        assertToolchainWins(result)
    }

    func testFishProfileToolchainWinsOverProviderNeighbours() throws {
        guard let fish = ["/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/usr/bin/fish"]
            .first(where: { fileManager.isExecutableFile(atPath: $0) })
        else { throw XCTSkip("no fish binary installed") }
        let f = try toolchainFixture()
        let fishDir = dir.appendingPathComponent("xdg/fish", isDirectory: true)
        try fileManager.createDirectory(at: fishDir, withIntermediateDirectories: true)
        try "set -gx PATH $NVM_BIN $PATH\n"
            .write(to: fishDir.appendingPathComponent("config.fish"), atomically: true, encoding: .utf8)
        var base = f.base
        base["XDG_CONFIG_HOME"] = fishDir.deletingLastPathComponent().path
        let result = CustomPingRunner.run(
            command: .loginShell(toolchainLine), accountID: "work", provider: .claude,
            binary: f.claude.path, environment: base,
            loginShell: lookup(fish, home: f.home.path))
        assertToolchainWins(result)
    }

    /// A shim that can't be built isn't fatal: no PATH clause is emitted (so
    /// nothing is prepended at all), and the override var still names the
    /// binary. Exercised through the pure halves the runner composes.
    func testNoShimMeansNoPathReassert() {
        let env = CustomPingRunner.environment(
            base: ["PATH": "/usr/bin:/bin", "CLAUDE_CONFIG_DIR": "/m"],
            accountID: "a", provider: .claude, providerBinary: "/opt/x/claude", shimDirectory: nil)
        let prepared = CustomPingRunner.loginShellEnvironment(env, provider: .claude, shimDirectory: nil)
        XCTAssertFalse(prepared.prependsProviderBinDir)
        XCTAssertNil(prepared.env[LoginShell.providerBinDirEnvKey])
        XCTAssertEqual(prepared.env["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(prepared.env["AGENT_MANAGER_CLAUDE_BIN"], "/opt/x/claude")
    }

    // MARK: - argv → line conversion

    func testLoginShellLineDeclinesBackslashesInFishOnly() {
        let plain = CustomPingCommand(executable: "/x/eval", arguments: ["a b", "it's"])
        XCTAssertEqual(plain.loginShellLine(for: .posix), plain.commandLine)
        XCTAssertEqual(plain.loginShellLine(for: .fish), plain.commandLine)
        // `'a\\b'` is two backslashes in sh but one in fish; a trailing `\`
        // would leave fish's quote open. POSIX renders faithfully; fish declines.
        for word in [#"a\b"#, #"c:\"#, #"x\'y"#] {
            let command = CustomPingCommand(executable: "/x/eval", arguments: [word])
            XCTAssertEqual(command.loginShellLine(for: .posix), command.commandLine, word)
            XCTAssertNil(command.loginShellLine(for: .fish), word)
        }
        XCTAssertNil(CustomPingCommand(executable: #"/x/we\ird"#).loginShellLine(for: .fish))
        XCTAssertEqual(CustomPingCommand.loginShell(#"echo a\b"#).loginShellLine(for: .fish), #"echo a\b"#)
    }

    // MARK: - Helpers

    /// The value of the transcript's first `key=value` line.
    private func value(_ key: String, in transcript: String) -> String? {
        transcript.split(separator: "\n").first { $0.hasPrefix(key + "=") }
            .map { String($0.dropFirst(key.count + 1)) }
    }

    /// The argv command exactly as it was declared before the login-shell
    /// form: a struct with synthesized `Codable`.
    private struct LegacyCommand: Encodable {
        var executable: String
        var arguments: [String]
    }

    @discardableResult
    private func executable(_ name: String, _ body: String = "exit 0") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
