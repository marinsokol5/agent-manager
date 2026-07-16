import XCTest
@testable import AgentManagerCore

final class AccountPingerTests: XCTestCase {
    private let fileManager = FileManager.default
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("am-pinger-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: temporaryDirectory)
    }

    func testPreferenceDispatchReloadsAndOneOffOverrideWins() throws {
        let workspace = Workspace(root: temporaryDirectory.appendingPathComponent("workspace", isDirectory: true))
        let home = workspace.managedHome(forAccountID: "work")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try AccountStore(workspace: workspace).insert(Account(
            id: "work", label: "Work", provider: .claude, home: home.path, status: .connected))
        let claude = try executableStub(
            name: "claude",
            body: """
            test -z "$ANTHROPIC_API_KEY" || exit 19
            test "$CLAUDE_CONFIG_DIR" = "$EXPECTED_HOME" || exit 20
            echo '{"is_error":false,"usage":{"input_tokens":10,"cache_creation_input_tokens":20,"output_tokens":3}}'
            """)
        let environment = [
            "HOME": temporaryDirectory.path,
            "PATH": "/usr/bin:/bin",
            "AGENT_MANAGER_CLAUDE_BIN": claude.path,
            "ANTHROPIC_API_KEY": "must-not-reach-child",
            "EXPECTED_HOME": home.path,
        ]
        let pinger = AccountPinger(workspace: workspace, baseEnvironment: environment)

        PreferencesStore(workspace: workspace).save(Preferences(claudePingMethod: .headless))
        let configured = try pinger.runTurn("work", timeout: 2)
        XCTAssertTrue(configured.ok)
        XCTAssertEqual(configured.pingMethod, .headless)

        // The override is selected before dispatch and logged even when this
        // deliberately tiny timeout makes the PTY implementation fail.
        let overridden = try pinger.runTurn("work", timeout: 0, methodOverride: .terminal)
        XCTAssertEqual(overridden.pingMethod, .terminal)

        let starts = AuditLog(workspace: workspace).readRecent(limit: 10)
            .filter { $0.action == "ping.start" }
        XCTAssertEqual(starts.map(\.detail), ["terminal", "headless"])
    }

    func testRecordedActivityCarriesSelectedMethod() throws {
        let workspace = Workspace(root: temporaryDirectory.appendingPathComponent("workspace", isDirectory: true))
        let result = ClaudePingRunner.Result(
            ok: true,
            detail: "headless turn completed",
            transcript: "summary",
            pingMethod: .headless)
        AccountPinger(workspace: workspace).recordOutcome("work", result: result, anchored: false)

        XCTAssertEqual(ActivityLog(workspace: workspace).readRecent(limit: 1).first?.pingMethod, .headless)
    }

    private func executableStub(name: String, body: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
