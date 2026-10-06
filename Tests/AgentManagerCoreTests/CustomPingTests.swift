import XCTest
@testable import AgentManagerCore

/// The `custom` ping method: the argv-only command model, its storage, the
/// runner's environment/cwd/exit/timeout contract, and its dispatch.
final class CustomPingTests: XCTestCase {
    private let fileManager = FileManager.default
    private var dir: URL!

    override func setUpWithError() throws {
        dir = fileManager.temporaryDirectory
            .appendingPathComponent("am-custom-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: dir)
    }

    // MARK: - Command parsing

    func testTokenizerQuotingRules() throws {
        XCTAssertEqual(try CustomPingCommand.tokenize("  a  b\tc\n"), ["a", "b", "c"])
        XCTAssertEqual(try CustomPingCommand.tokenize(#"'a b' "c d""#), ["a b", "c d"])
        // Single quotes are fully literal; backslashes too.
        XCTAssertEqual(try CustomPingCommand.tokenize(#"'x\"y\\z'"#), [#"x\"y\\z"#])
        // Double quotes honor only \" and \\.
        XCTAssertEqual(try CustomPingCommand.tokenize(#""a\"b\\c\n""#), [#"a"b\c\n"#])
        // Backslash outside quotes escapes the next character, including space.
        XCTAssertEqual(try CustomPingCommand.tokenize(#"a\ b \'q"#), ["a b", "'q"])
        // Adjacent runs concatenate; an explicit empty word survives.
        XCTAssertEqual(try CustomPingCommand.tokenize(#"pre'mid'"post" ''"#), ["premidpost", ""])
        XCTAssertEqual(try CustomPingCommand.tokenize("   "), [])
    }

    func testParseErrors() throws {
        let exe = try script("ok.sh", "exit 0")
        XCTAssertThrowsError(try CustomPingCommand.parse("   ")) {
            XCTAssertEqual($0 as? CustomPingCommand.ParseError, .empty)
        }
        XCTAssertThrowsError(try CustomPingCommand.parse("\(exe.path) 'open")) {
            XCTAssertEqual($0 as? CustomPingCommand.ParseError, .unterminatedQuote("'"))
        }
        XCTAssertThrowsError(try CustomPingCommand.parse("\(exe.path) \"open")) {
            XCTAssertEqual($0 as? CustomPingCommand.ParseError, .unterminatedQuote("\""))
        }
        XCTAssertThrowsError(try CustomPingCommand.parse("\(exe.path) trailing\\")) {
            XCTAssertEqual($0 as? CustomPingCommand.ParseError, .danglingBackslash)
        }
        // No PATH lookup: a bare name is rejected rather than searched for.
        XCTAssertThrowsError(try CustomPingCommand.parse("claude -p hi")) {
            XCTAssertEqual($0 as? CustomPingCommand.ParseError, .relativePath("claude"))
        }
        XCTAssertThrowsError(try CustomPingCommand.parse(dir.appendingPathComponent("nope").path)) {
            XCTAssertEqual($0 as? CustomPingCommand.ParseError, .notFound(self.dir.appendingPathComponent("nope").path))
        }
        let plain = dir.appendingPathComponent("plain.txt")
        try "x".write(to: plain, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try CustomPingCommand.parse(plain.path)) {
            XCTAssertEqual($0 as? CustomPingCommand.ParseError, .notExecutable(plain.path))
        }
        // A directory is "executable" to `isExecutableFile`, never to us.
        XCTAssertThrowsError(try CustomPingCommand.parse(dir.path)) {
            XCTAssertEqual($0 as? CustomPingCommand.ParseError, .notExecutable(self.dir.path))
        }
    }

    func testTildeExpandsOnlyInTheExecutable() throws {
        let exe = try script("eval.sh", "exit 0")
        let parsed = try CustomPingCommand.parse("~/eval.sh ~/data", homeDirectory: dir.path)
        XCTAssertEqual(parsed.executable, exe.path)
        XCTAssertEqual(parsed.arguments, ["~/data"])
    }

    func testRenderRoundTrips() throws {
        let exe = try script("my eval.sh", "exit 0")
        let original = CustomPingCommand(
            executable: exe.path,
            arguments: ["-lc", "echo 'hi' && ls \"$HOME\"", "", "plain", "it's", #"back\slash"#])
        let line = original.commandLine
        XCTAssertTrue(line.hasPrefix("'"), "a path with a space must be quoted: \(line)")
        XCTAssertTrue(line.contains(" plain "), "inert words stay bare: \(line)")
        XCTAssertEqual(try CustomPingCommand.parse(line), original)
    }

    // MARK: - Preferences storage

    func testPreferencesBackCompatAndOmission() throws {
        let old = #"{"clockStyle":"twelveHour","theme":"system","claudePingMethod":"headless","codexPingMethod":"terminal"}"#
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data(old.utf8))
        XCTAssertNil(decoded.claudeCustomCommand)
        XCTAssertNil(decoded.codexCustomCommand)

        // nil commands are omitted, so a file the user never touched in this
        // respect re-encodes with exactly the keys it had.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let reencoded = String(decoding: try encoder.encode(decoded), as: UTF8.self)
        XCTAssertFalse(reencoded.contains("CustomCommand"))
        XCTAssertEqual(reencoded, #"{"claudePingMethod":"headless","clockStyle":"twelveHour","codexPingMethod":"terminal","theme":"system"}"#)

        var prefs = decoded
        prefs.codexPingMethod = .custom
        prefs.setCustomCommand(CustomPingCommand(executable: "/bin/echo", arguments: ["a b"]), for: .codex)
        let round = try JSONDecoder().decode(Preferences.self, from: try encoder.encode(prefs))
        XCTAssertEqual(round.codexPingMethod, .custom)
        XCTAssertEqual(round.customCommand(for: .codex), CustomPingCommand(executable: "/bin/echo", arguments: ["a b"]))
        XCTAssertNil(round.customCommand(for: .claude))
    }

    func testMalformedCommandDecodesAsUnsetWithoutLosingTheRest() throws {
        let json = #"{"claudePingMethod":"custom","claudeCustomCommand":{"arguments":[1]},"codexCustomCommand":{"executable":"/bin/echo"}}"#
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.claudePingMethod, .custom)
        XCTAssertNil(decoded.claudeCustomCommand)
        // Missing `arguments` is a bare executable, not a failure.
        XCTAssertEqual(decoded.codexCustomCommand, CustomPingCommand(executable: "/bin/echo"))
    }

    // MARK: - PingMethod

    func testCustomIsALocalDriverForBothProvidersInOrder() {
        XCTAssertEqual(PingMethod.custom.rawValue, "custom")
        XCTAssertEqual(PingMethod.custom.localDriver, .custom)
        XCTAssertEqual(PingMethod.custom.sanitized(for: .codex), .custom)
        XCTAssertFalse(PingMethod.custom.usesCloudRoutine)
        XCTAssertEqual(PingMethod.available(for: .claude), [.headless, .terminal, .sdk, .custom, .routine])
        XCTAssertEqual(PingMethod.available(for: .codex), [.headless, .terminal, .sdk, .custom])
    }

    // MARK: - Timeout budget

    /// The custom command, its kill grace, and the postflight usage read must
    /// all finish before the daemon's hard kill of the whole ping child — and
    /// stay well inside the stale grace other same-minute accounts wait under.
    func testTimeoutFitsInsideDaemonHardKill() {
        XCTAssertLessThanOrEqual(
            CustomPingRunner.timeout + CustomPingRunner.terminationGrace + CustomPingRunner.postflightAllowance,
            SchedulerDaemon.pingChildTimeout)
        XCTAssertLessThanOrEqual(CustomPingRunner.timeout, StalePingPolicy.defaultGrace / 1.5)
    }

    // MARK: - Runner

    func testRunnerEnvironmentCwdAndExitStatus() throws {
        let fakeBinDir = dir.appendingPathComponent("bin", isDirectory: true)
        try fileManager.createDirectory(at: fakeBinDir, withIntermediateDirectories: true)
        let claude = try script("bin/claude", "echo fake-claude")
        let exe = try script("eval.sh", """
            echo "home=$CLAUDE_CONFIG_DIR"
            echo "account=$AGENT_MANAGER_ACCOUNT_ID provider=$AGENT_MANAGER_PROVIDER"
            echo "bin=$AGENT_MANAGER_CLAUDE_BIN"
            echo "which=$(command -v claude)"
            echo "key=${ANTHROPIC_API_KEY:-unset}"
            echo "cwd=$(pwd -P)"
            echo "args=$1|$2"
            echo oops >&2
            exit 3
            """)
        let base = ["PATH": "/usr/bin:/bin", "HOME": dir.path, "CLAUDE_CONFIG_DIR": "/managed/home"]
        let result = CustomPingRunner.run(
            command: CustomPingCommand(executable: exe.path, arguments: ["a b", "c"]),
            accountID: "work", provider: .claude, binary: claude.path, environment: base)

        XCTAssertTrue(result.ok, "an exit status is the command's verdict, not the ping's")
        XCTAssertFalse(result.mayHaveRunTurns)
        XCTAssertTrue(result.detail.hasPrefix("custom command exited 3 after "), result.detail)
        let t = result.transcript
        XCTAssertTrue(t.contains("home=/managed/home"), t)
        XCTAssertTrue(t.contains("account=work provider=claude"), t)
        XCTAssertTrue(t.contains("bin=\(claude.path)"), t)
        XCTAssertTrue(t.contains("which=\(claude.path)"), t)
        XCTAssertTrue(t.contains("key=unset"), t)
        // `pwd -P` reports /private/var; Foundation's resolver keeps /var.
        let physical = try XCTUnwrap(realpath(dir.path, nil).map { p in
            defer { free(p) }
            return String(cString: p)
        })
        XCTAssertTrue(t.contains("cwd=\(physical)\n"), t)
        XCTAssertTrue(t.contains("args=a b|c"), t)
        XCTAssertTrue(t.contains("oops"), "stderr shares the transcript: \(t)")
    }

    func testEnvironmentPutsProviderBinaryDirFirstOnce() {
        let env = CustomPingRunner.environment(
            base: ["PATH": "/usr/bin:/opt/x:/bin"],
            accountID: "a", provider: .codex, providerBinary: "/opt/x/codex")
        XCTAssertEqual(env["PATH"], "/opt/x:/usr/bin:/bin")
        XCTAssertEqual(env["AGENT_MANAGER_CODEX_BIN"], "/opt/x/codex")
        XCTAssertEqual(env["AGENT_MANAGER_PROVIDER"], "codex")
        XCTAssertEqual(env["AGENT_MANAGER_ACCOUNT_ID"], "a")
    }

    func testTimeoutKillsTheWholeProcessGroup() throws {
        let pidFile = dir.appendingPathComponent("grandchild.pid")
        let exe = try script("hang.sh", """
            /bin/sleep 300 &
            echo $! > "\(pidFile.path)"
            wait
            """)
        let result = CustomPingRunner.run(
            command: CustomPingCommand(executable: exe.path),
            accountID: "work", provider: .claude, binary: "/nonexistent/claude",
            environment: ["PATH": "/usr/bin:/bin"], timeout: 1)

        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.mayHaveRunTurns, "a launched command may have billed turns: verify it")
        XCTAssertTrue(result.needsAnchorVerification)
        XCTAssertTrue(result.detail.contains("timed out"), result.detail)

        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        // The grandchild is reaped by launchd/init asynchronously; give it a beat.
        let deadline = Date().addingTimeInterval(3)
        while kill(pid, 0) == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertNotEqual(kill(pid, 0), 0, "the backgrounded sleep must die with its group")
    }

    func testNeverLaunchedFailsWithoutVerification() throws {
        let missing = CustomPingRunner.run(
            command: nil, accountID: "a", provider: .claude, binary: "claude", environment: [:])
        XCTAssertFalse(missing.ok)
        XCTAssertFalse(missing.needsAnchorVerification)
        XCTAssertTrue(missing.detail.contains("no custom command set"), missing.detail)

        let plain = dir.appendingPathComponent("not-exec.sh")
        try "#!/bin/sh\nexit 0\n".write(to: plain, atomically: true, encoding: .utf8)
        let notExec = CustomPingRunner.run(
            command: CustomPingCommand(executable: plain.path),
            accountID: "a", provider: .claude, binary: "claude", environment: [:])
        XCTAssertFalse(notExec.ok)
        XCTAssertFalse(notExec.needsAnchorVerification)
        XCTAssertTrue(notExec.detail.contains("not an executable file"), notExec.detail)
    }

    func testDurationFormatting() {
        XCTAssertEqual(CustomPingRunner.duration(42.4), "42s")
        XCTAssertEqual(CustomPingRunner.duration(302), "5m02s")
    }

    // MARK: - Dispatch

    func testAccountPingerDispatchesCustomWithManagedEnvironment() throws {
        let workspace = Workspace(root: dir.appendingPathComponent("workspace", isDirectory: true))
        let home = workspace.managedHome(forAccountID: "work")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try AccountStore(workspace: workspace).insert(Account(
            id: "work", label: "Work", provider: .claude, home: home.path, status: .connected))
        let claude = try script("claude", "exit 0")
        let exe = try script("eval.sh", """
            test -z "$ANTHROPIC_API_KEY" || exit 19
            test "$CLAUDE_CONFIG_DIR" = "$EXPECTED_HOME" || exit 20
            test "$AGENT_MANAGER_ACCOUNT_ID" = work || exit 21
            exit 0
            """)
        PreferencesStore(workspace: workspace).save(Preferences(
            claudePingMethod: .custom,
            claudeCustomCommand: CustomPingCommand(executable: exe.path)))
        let pinger = AccountPinger(workspace: workspace, baseEnvironment: [
            "HOME": dir.path,
            "PATH": "/usr/bin:/bin",
            "AGENT_MANAGER_CLAUDE_BIN": claude.path,
            "ANTHROPIC_API_KEY": "must-not-reach-child",
            "EXPECTED_HOME": home.path,
        ])

        // The 0 s generic timeout would kill any turn; custom ignores it.
        let result = try pinger.runTurn("work", timeout: 0)
        XCTAssertEqual(result.pingMethod, .custom)
        XCTAssertEqual(result.detail.prefix("custom command exited 0".count), "custom command exited 0")
        XCTAssertTrue(result.ok)

        // A one-off override to custom also reads the saved command.
        PreferencesStore(workspace: workspace).save(Preferences(
            claudePingMethod: .headless,
            claudeCustomCommand: CustomPingCommand(executable: exe.path)))
        XCTAssertEqual(try pinger.runTurn("work", methodOverride: .custom).detail.prefix(23), "custom command exited 0")

        let starts = AuditLog(workspace: workspace).readRecent(limit: 10).filter { $0.action == "ping.start" }
        XCTAssertEqual(starts.map(\.detail), ["custom", "custom"])
    }

    /// The real dispatch path for a timed-out command: `runTurn` rebuilds the
    /// runner's `Result`, and dropping `mayHaveRunTurns` there would silently
    /// write every killed eval off as failed instead of verifying it.
    func testAccountPingerTimedOutCustomStillNeedsVerification() throws {
        let workspace = Workspace(root: dir.appendingPathComponent("workspace", isDirectory: true))
        let home = workspace.managedHome(forAccountID: "work")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try AccountStore(workspace: workspace).insert(Account(
            id: "work", label: "Work", provider: .claude, home: home.path, status: .connected))
        let exe = try script("hang.sh", "exec /bin/sleep 300")
        PreferencesStore(workspace: workspace).save(Preferences(
            claudePingMethod: .custom,
            claudeCustomCommand: CustomPingCommand(executable: exe.path)))
        var pinger = AccountPinger(workspace: workspace, baseEnvironment: [
            "HOME": dir.path, "PATH": "/usr/bin:/bin",
        ])
        pinger.customTimeout = 1

        let result = try pinger.runTurn("work")
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.mayHaveRunTurns, result.detail)
        XCTAssertTrue(result.needsAnchorVerification)
        XCTAssertEqual(result.pingMethod, .custom)
        XCTAssertTrue(result.detail.contains("timed out"), result.detail)
    }

    // MARK: - Transcript tail

    func testPipeCaptureKeepsOnlyTheTail() throws {
        let limit = 1024
        let capture = AsyncPipeCapture(tailLimit: limit)
        // Past 2× the limit, so the reader's lazy trim fires too, and the
        // newest bytes are distinguishable from everything before them. 4 KB
        // fits the pipe buffer, so it can be written before the reader starts;
        // `closeParentWriterAndStart` then closes our end, giving the reader EOF.
        let head = Data(repeating: UInt8(ascii: "a"), count: 3 * limit)
        let tail = Data(repeating: UInt8(ascii: "z"), count: limit - 4) + Data("END\n".utf8)
        try capture.pipe.fileHandleForWriting.write(contentsOf: head + tail)
        capture.closeParentWriterAndStart()

        let text = capture.finish()
        let marker = "[… earlier output truncated — last \(limit) bytes kept …]\n"
        XCTAssertTrue(text.hasPrefix(marker), String(text.prefix(120)))
        XCTAssertEqual(String(text.dropFirst(marker.count)), String(decoding: tail, as: UTF8.self))
    }

    func testOutcomeLabelPrefersAnchored() {
        XCTAssertEqual(ActivityRecord(accountID: "a", ok: false, anchored: true, detail: "").outcomeLabel, "anchored")
        XCTAssertEqual(ActivityRecord(accountID: "a", ok: true, anchored: true, detail: "").outcomeLabel, "anchored")
        XCTAssertEqual(ActivityRecord(accountID: "a", ok: true, anchored: false, detail: "").outcomeLabel, "ran · no anchor")
        XCTAssertEqual(ActivityRecord(accountID: "a", ok: false, anchored: false, detail: "").outcomeLabel, "failed")
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
