import XCTest
@testable import AgentManagerCore

final class AccountRunnerTests: XCTestCase {
    var tmp: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("am-run-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: tmp)
    }

    func workspace() -> Workspace { Workspace(root: tmp) }

    /// A real, executable no-op file the resolver can find on disk.
    func makeStub(_ name: String) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @discardableResult
    func insertAccount(_ id: String, status: AccountStatus, ws: Workspace) throws -> Account {
        let home = ws.managedHome(forAccountID: id)
        let account = Account(id: id, label: id.capitalized, provider: .claude, home: home.path, status: status)
        try AccountStore(workspace: ws).insert(account)
        return account
    }

    func testPlanResolvesBinaryEnvAndPassthrough() throws {
        let ws = workspace()
        let account = try insertAccount("work", status: .connected, ws: ws)
        let stub = try makeStub("claude-stub")
        // Override the resolved binary at the stub; the account's home drives the
        // injected isolation env var.
        let base = ["HOME": tmp.path, "PATH": "/usr/bin:/bin", "AGENT_MANAGER_CLAUDE_BIN": stub.path]

        let plan = try AccountRunner(workspace: ws).plan(
            "work", passthrough: ["--model", "opus", "-p", "fix the build"], baseEnvironment: base)

        XCTAssertEqual(plan.executablePath, stub.path)
        XCTAssertEqual(plan.arguments, ["--model", "opus", "-p", "fix the build"])
        XCTAssertEqual(plan.environment["CLAUDE_CONFIG_DIR"], account.home, "account's managed home is isolated in")
        XCTAssertEqual(plan.provider, .claude)
        XCTAssertEqual(plan.accountID, "work")
    }

    func testPlanRejectsUnknownAccount() throws {
        XCTAssertThrowsError(try AccountRunner(workspace: workspace()).plan("ghost")) { error in
            XCTAssertEqual(error as? AccountRunner.RunError, .notFound("ghost"))
        }
    }

    func testPlanRejectsDisconnectedAccount() throws {
        let ws = workspace()
        try insertAccount("pending", status: .connecting, ws: ws)
        XCTAssertThrowsError(try AccountRunner(workspace: ws).plan("pending")) { error in
            XCTAssertEqual(error as? AccountRunner.RunError, .notConnected(.connecting))
        }
    }

    func testPlanFailsWhenBinaryMissing() throws {
        let ws = workspace()
        try insertAccount("work", status: .connected, ws: ws)
        let missing = tmp.appendingPathComponent("nope").path
        let base = ["HOME": tmp.path, "PATH": "", "AGENT_MANAGER_CLAUDE_BIN": missing]
        XCTAssertThrowsError(try AccountRunner(workspace: ws).plan("work", baseEnvironment: base)) { error in
            XCTAssertEqual(error as? AccountRunner.RunError, .binaryNotFound(missing))
        }
    }
}
