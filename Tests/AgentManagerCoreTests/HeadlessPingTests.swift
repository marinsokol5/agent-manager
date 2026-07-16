import XCTest
@testable import AgentManagerCore

final class HeadlessPingTests: XCTestCase {
    func testClaudeCommandPinsStructuredHaikuTurnAndSandboxOverride() {
        let home = URL(fileURLWithPath: "/tmp/claude-home", isDirectory: true)
        let command = HeadlessPingRunner.command(
            provider: .claude, binary: "/bin/claude", workingDirectory: home)

        XCTAssertEqual(command.executable, "/bin/claude")
        XCTAssertEqual(command.workingDirectory, home)
        XCTAssertEqual(command.arguments, [
            "-p", ClaudePingRunner.pingPrompt,
            "--model", "haiku",
            "--max-turns", "1",
            "--output-format", "json",
        ] + Provider.claude.sandboxOptOutArguments)
    }

    func testCodexCommandPinsCheapReadOnlyEphemeralTurn() {
        let home = URL(fileURLWithPath: "/tmp/codex-home", isDirectory: true)
        let command = HeadlessPingRunner.command(
            provider: .codex, binary: "/bin/codex", workingDirectory: home)

        XCTAssertEqual(command.executable, "/bin/codex")
        XCTAssertEqual(command.workingDirectory, home)
        XCTAssertEqual(command.arguments, [
            "exec", CodexPingRunner.pingPrompt,
            "-m", "gpt-5.4-mini",
            "-c", "model_reasoning_effort=\"low\"",
            "--skip-git-repo-check",
            "-s", "read-only",
            "--ephemeral",
            "--ignore-user-config",
            "--json",
            "-C", home.path,
        ])
    }

    func testClaudeParserRequiresNonErrorUsageObject() {
        let success = #"{"is_error":false,"usage":{"input_tokens":10,"cache_creation_input_tokens":13691,"output_tokens":40}}"#
        XCTAssertEqual(
            HeadlessPingRunner.parseClaude(success),
            .init(isError: false, usage: .init(input: 10, cached: 13691, output: 40)))

        let providerError = #"{"is_error":true,"usage":{"input_tokens":1,"cache_creation_input_tokens":2,"output_tokens":3}}"#
        XCTAssertEqual(HeadlessPingRunner.parseClaude(providerError)?.isError, true)
        XCTAssertNil(HeadlessPingRunner.parseClaude("not json"))
        XCTAssertNil(HeadlessPingRunner.parseClaude(#"{"is_error":false}"#))
    }

    func testCodexParserUsesLastCompletedTurnAndRejectsEventOnlyOutput() {
        let output = """
        {"type":"thread.started","thread_id":"abc"}
        not-json
        {"type":"turn.completed","usage":{"input_tokens":11,"cached_input_tokens":9000,"output_tokens":5}}
        """
        XCTAssertEqual(
            HeadlessPingRunner.parseCodex(output),
            .init(isError: false, usage: .init(input: 11, cached: 9000, output: 5)))
        XCTAssertNil(HeadlessPingRunner.parseCodex(#"{"type":"thread.started"}"#))
        XCTAssertNil(HeadlessPingRunner.parseCodex("garbage"))
    }

    func testSharedProcessRunnerTerminatesOnDeadline() {
        let directory = FileManager.default.temporaryDirectory
        let output = PingProcessRunner.run(
            executable: "/usr/bin/tail",
            arguments: ["-f", "/dev/null"],
            environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: directory,
            timeout: 0.05)

        XCTAssertTrue(output.timedOut)
        XCTAssertNil(output.launchError)
    }
}
