import XCTest
@testable import AgentManagerCore

final class SDKPingTests: XCTestCase {
    private let fileManager = FileManager.default
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("am-sdk-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: temporaryDirectory)
    }

    func testCommandShapeAndCodexManagedCWDEnvironment() {
        let scripts = (
            claude: temporaryDirectory.appendingPathComponent("ping.mjs"),
            codex: temporaryDirectory.appendingPathComponent("codex_ping.py"))
        let home = temporaryDirectory.appendingPathComponent("home", isDirectory: true)

        let claude = SDKPingRunner.command(
            provider: .claude,
            providerBinary: "/bin/claude",
            scripts: scripts,
            environment: ["AGENT_MANAGER_NODE_BIN": "/custom/node"],
            workingDirectory: home)
        XCTAssertEqual(claude.executable, "/custom/node")
        XCTAssertEqual(claude.arguments, [scripts.claude.path, ClaudePingRunner.pingPrompt, "/bin/claude"])

        let codex = SDKPingRunner.command(
            provider: .codex,
            providerBinary: "/bin/codex",
            scripts: scripts,
            environment: ["AGENT_MANAGER_PYTHON_BIN": "/custom/python3"],
            workingDirectory: home)
        XCTAssertEqual(codex.executable, "/custom/python3")
        XCTAssertEqual(codex.arguments, [scripts.codex.path, CodexPingRunner.pingPrompt, "/bin/codex"])
        XCTAssertEqual(codex.environment["AGENT_MANAGER_CODEX_SDK_CWD"], home.path)
    }

    func testSetupCommandsMatchProviderDependencyResolution() {
        let workspace = Workspace(root: URL(fileURLWithPath: "/tmp/Agent Manager's workspace"))
        XCTAssertEqual(
            SDKPingRunner.setupCommand(provider: .claude, workspace: workspace),
            "cd '/tmp/Agent Manager'\\''s workspace/sdk-ping' && npm install @anthropic-ai/claude-agent-sdk")
        XCTAssertEqual(
            SDKPingRunner.setupCommand(provider: .codex, workspace: workspace),
            "python3 -m pip install openai-codex")
    }

    func testScriptMaterializationIsContentAwareAndIdempotent() throws {
        let directory = temporaryDirectory.appendingPathComponent("sdk-ping", isDirectory: true)
        let first = try SDKPingScripts.materialize(in: directory)
        XCTAssertEqual(try String(contentsOf: first.claude, encoding: .utf8), SDKPingScripts.claude)
        XCTAssertEqual(try String(contentsOf: first.codex, encoding: .utf8), SDKPingScripts.codex)

        let sentinel = Date(timeIntervalSince1970: 1_000)
        try fileManager.setAttributes([.modificationDate: sentinel], ofItemAtPath: first.claude.path)
        _ = try SDKPingScripts.materialize(in: directory)
        let attributes = try fileManager.attributesOfItem(atPath: first.claude.path)
        XCTAssertEqual((attributes[.modificationDate] as? Date)?.timeIntervalSince1970, 1_000)

        try "old".write(to: first.codex, atomically: true, encoding: .utf8)
        _ = try SDKPingScripts.materialize(in: directory)
        XCTAssertEqual(try String(contentsOf: first.codex, encoding: .utf8), SDKPingScripts.codex)
    }

    func testMissingDependencyHasActionableSetupCommand() throws {
        let workspace = Workspace(root: temporaryDirectory.appendingPathComponent("workspace", isDirectory: true))
        let home = workspace.managedHome(forAccountID: "work")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        let providerBinary = try executableStub(name: "claude", body: "exit 0")
        let node = try executableStub(
            name: "node",
            body: "echo 'Error [ERR_MODULE_NOT_FOUND]: Cannot find package' >&2\nexit 1")
        let result = SDKPingRunner.run(
            provider: .claude,
            binary: providerBinary.path,
            environment: [
                "HOME": temporaryDirectory.path,
                "PATH": "/usr/bin:/bin",
                "AGENT_MANAGER_NODE_BIN": node.path,
            ],
            workingDirectory: home,
            workspace: workspace,
            timeout: 2)

        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.detail.contains("npm install @anthropic-ai/claude-agent-sdk"))
        XCTAssertTrue(fileManager.fileExists(atPath: workspace.sdkPingDir.appendingPathComponent("ping.mjs").path))
    }

    func testEndToEndRunsInjectedNodeAndPythonStubs() throws {
        let workspace = Workspace(root: temporaryDirectory.appendingPathComponent("workspace", isDirectory: true))
        let home = workspace.managedHome(forAccountID: "work")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        let providerBinary = try executableStub(name: "provider", body: "exit 0")
        let node = try executableStub(
            name: "node-ok",
            body: #"echo '{"ok":true,"usage":{"input_tokens":10,"cache_creation_input_tokens":13691,"output_tokens":4}}'"#)
        let python = try executableStub(
            name: "python-ok",
            body: #"echo '{"ok":true,"usage":{"last":{"input_tokens":11,"cached_input_tokens":9000,"output_tokens":5}}}'"#)

        let claude = SDKPingRunner.run(
            provider: .claude,
            binary: providerBinary.path,
            environment: ["AGENT_MANAGER_NODE_BIN": node.path, "PATH": "/usr/bin:/bin"],
            workingDirectory: home,
            workspace: workspace,
            timeout: 2)
        XCTAssertTrue(claude.ok)
        XCTAssertEqual(claude.detail, "sdk turn completed (in=10 cache=13691 out=4)")

        let codex = SDKPingRunner.run(
            provider: .codex,
            binary: providerBinary.path,
            environment: ["AGENT_MANAGER_PYTHON_BIN": python.path, "PATH": "/usr/bin:/bin"],
            workingDirectory: home,
            workspace: workspace,
            timeout: 2)
        XCTAssertTrue(codex.ok)
        XCTAssertEqual(codex.detail, "sdk turn completed (in=11 cache=9000 out=5)")
    }

    func testActivityRecordWithoutMethodStillDecodes() throws {
        let data = #"{"time":"2026-07-16T08:00:00Z","accountID":"work","ok":true,"anchored":false,"detail":"old"}"#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertNil(try decoder.decode(ActivityRecord.self, from: data).pingMethod)
    }

    private func executableStub(name: String, body: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
