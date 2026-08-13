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
            runtime: "/custom/node",
            scripts: scripts,
            environment: [:],
            workingDirectory: home)
        XCTAssertEqual(claude.executable, "/custom/node")
        XCTAssertEqual(claude.arguments, [scripts.claude.path, ClaudePingRunner.pingPrompt, "/bin/claude"])

        let codex = SDKPingRunner.command(
            provider: .codex,
            providerBinary: "/bin/codex",
            runtime: "/custom/python3",
            scripts: scripts,
            environment: [:],
            workingDirectory: home)
        XCTAssertEqual(codex.executable, "/custom/python3")
        XCTAssertEqual(codex.arguments, [scripts.codex.path, CodexPingRunner.pingPrompt, "/bin/codex"])
        XCTAssertEqual(codex.environment["AGENT_MANAGER_CODEX_SDK_CWD"], home.path)
    }

    func testSetupCommandsMatchProviderDependencyResolution() {
        let workspace = Workspace(root: URL(fileURLWithPath: "/tmp/Agent Manager's workspace"))
        XCTAssertEqual(
            SDKPingRunner.setupCommand(provider: .claude, workspace: workspace),
            "mkdir -p '/tmp/Agent Manager'\\''s workspace/sdk-ping' "
                + "&& cd '/tmp/Agent Manager'\\''s workspace/sdk-ping' "
                + "&& npm install @anthropic-ai/claude-agent-sdk")
        // The Codex line installs into the very interpreter `runtime` picks —
        // never a bare `python3`, whose identity is the thing we can't rely on.
        XCTAssertEqual(
            SDKPingRunner.setupCommand(provider: .codex, workspace: workspace),
            "python3 -m venv '/tmp/Agent Manager'\\''s workspace/sdk-ping/.venv' "
                + "&& '/tmp/Agent Manager'\\''s workspace/sdk-ping/.venv/bin/python3' "
                + "-m pip install openai-codex")
    }

    /// The workspace venv is the whole point: it must beat whatever `python3`
    /// the enriched PATH resolves, and it must win on existence alone — a venv
    /// that lacks the module reports *that*, rather than quietly anchoring on
    /// some other interpreter the user never installed into.
    func testCodexRuntimePrefersWorkspaceVenvOverPathPython() throws {
        let workspace = Workspace(root: temporaryDirectory.appendingPathComponent("workspace", isDirectory: true))
        let pathDirectory = try directory(named: "bin")
        _ = try executableStub(name: "python3", in: pathDirectory, body: "exit 0")
        let environment = ["PATH": pathDirectory.path, "HOME": temporaryDirectory.path]

        XCTAssertEqual(
            SDKPingRunner.runtime(
                provider: .codex, workspace: workspace, environment: environment, probe: { _, _ in true }),
            pathDirectory.appendingPathComponent("python3").path)

        try fileManager.createDirectory(
            at: workspace.sdkPingVenvPython.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try executableStub(
            name: "python3", in: workspace.sdkPingVenvPython.deletingLastPathComponent(), body: "exit 1")
        XCTAssertEqual(
            SDKPingRunner.runtime(
                provider: .codex, workspace: workspace, environment: environment, probe: { _, _ in false }),
            workspace.sdkPingVenvPython.path)
    }

    /// Without a venv, the PATH order alone is not the answer — the first
    /// `python3` that can actually see the module is. Stubs stand in for real
    /// interpreters, so this exercises the real probe, not an injected one.
    func testCodexRuntimeProbesPathInterpretersForTheModule() throws {
        let workspace = Workspace(root: temporaryDirectory.appendingPathComponent("workspace", isDirectory: true))
        let bare = try directory(named: "bare-bin")
        let installed = try directory(named: "installed-bin")
        _ = try executableStub(name: "python3", in: bare, body: "exit 1")
        let expected = try executableStub(name: "python3", in: installed, body: "exit 0")
        let environment = ["PATH": "\(bare.path):\(installed.path)", "HOME": temporaryDirectory.path]

        XCTAssertEqual(
            SDKPingRunner.runtime(provider: .codex, workspace: workspace, environment: environment),
            expected.path)

        // No interpreter has it: fall back to the first, so the failure names a
        // real path instead of an unresolved `python3`.
        let noneInstalled = ["PATH": bare.path, "HOME": temporaryDirectory.path]
        XCTAssertEqual(
            SDKPingRunner.runtime(provider: .codex, workspace: workspace, environment: noneInstalled),
            bare.appendingPathComponent("python3").path)
    }

    func testExplicitRuntimeOverridesWinOverVenvAndProbe() throws {
        let workspace = Workspace(root: temporaryDirectory.appendingPathComponent("workspace", isDirectory: true))
        try fileManager.createDirectory(
            at: workspace.sdkPingVenvPython.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try executableStub(
            name: "python3", in: workspace.sdkPingVenvPython.deletingLastPathComponent(), body: "exit 0")

        XCTAssertEqual(
            SDKPingRunner.runtime(
                provider: .codex,
                workspace: workspace,
                environment: ["AGENT_MANAGER_PYTHON_BIN": "/custom/python3"],
                probe: { _, _ in true }),
            "/custom/python3")
        // Node needs no such search: it resolves `node_modules` from the script.
        XCTAssertEqual(
            SDKPingRunner.runtime(provider: .claude, workspace: workspace, environment: [:]),
            "node")
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
        XCTAssertTrue(result.detail.contains("\(node.path) cannot resolve @anthropic-ai/claude-agent-sdk"))
        XCTAssertTrue(fileManager.fileExists(atPath: workspace.sdkPingDir.appendingPathComponent("ping.mjs").path))
    }

    /// The failure a user acts on: "pip install it" is advice they have already
    /// followed, so the line has to say which interpreter came up short and
    /// point the install at the one that will actually be run.
    func testCodexMissingDependencyNamesTheInterpreterItTried() throws {
        let workspace = Workspace(root: temporaryDirectory.appendingPathComponent("workspace", isDirectory: true))
        let home = workspace.managedHome(forAccountID: "work")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        let providerBinary = try executableStub(name: "codex", body: "exit 0")
        let python = try executableStub(
            name: "python-missing",
            body: #"echo '{"ok":false,"error":"openai-codex is not installed for /opt/homebrew/bin/python3"}'"#
                + "\nexit 1")

        let result = SDKPingRunner.run(
            provider: .codex,
            binary: providerBinary.path,
            environment: [
                "HOME": temporaryDirectory.path,
                "PATH": "/usr/bin:/bin",
                "AGENT_MANAGER_PYTHON_BIN": python.path,
            ],
            workingDirectory: home,
            workspace: workspace,
            timeout: 2)

        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.detail.contains("\(python.path) cannot import openai_codex"))
        XCTAssertTrue(result.detail.contains(workspace.sdkPingVenv.path))
        XCTAssertTrue(result.detail.contains("-m pip install openai-codex"))
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
        try executableStub(name: name, in: temporaryDirectory, body: body)
    }

    private func executableStub(name: String, in directory: URL, body: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func directory(named name: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
