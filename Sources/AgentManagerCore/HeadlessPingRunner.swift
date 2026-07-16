import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The structured-output ping path: `claude -p` or `codex exec` under the
/// account's isolated managed home. This proves that a programmatic turn ran;
/// it deliberately makes no claim that the provider's rolling window moved.
public enum HeadlessPingRunner {
    struct Command: Sendable, Equatable {
        let executable: String
        let arguments: [String]
        let workingDirectory: URL
    }

    struct TokenUsage: Sendable, Equatable {
        let input: Int
        let cached: Int
        let output: Int
    }

    struct ParsedTurn: Sendable, Equatable {
        let isError: Bool
        let usage: TokenUsage
    }

    /// Pure command construction kept separate from process I/O so every flag
    /// that defines the low-cost, read-only turn can be regression-tested.
    static func command(provider: Provider, binary: String, workingDirectory: URL) -> Command {
        switch provider {
        case .claude:
            return Command(
                executable: binary,
                arguments: [
                    "-p", ClaudePingRunner.pingPrompt,
                    "--model", "haiku",
                    "--max-turns", "1",
                    "--output-format", "json",
                ] + Provider.claude.sandboxOptOutArguments,
                workingDirectory: workingDirectory)
        case .codex:
            return Command(
                executable: binary,
                arguments: [
                    "exec", CodexPingRunner.pingPrompt,
                    "-m", "gpt-5.4-mini",
                    "-c", "model_reasoning_effort=\"low\"",
                    "--skip-git-repo-check",
                    "-s", "read-only",
                    "--ephemeral",
                    "--ignore-user-config",
                    "--json",
                    "-C", workingDirectory.path,
                ],
                workingDirectory: workingDirectory)
        }
    }

    /// Parse Claude's single result object. A clean process is insufficient:
    /// `is_error == false` and the token-bearing usage object are the evidence
    /// that the requested turn reached a result.
    static func parseClaude(_ stdout: String) -> ParsedTurn? {
        guard let data = stdout.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let isError = object["is_error"] as? Bool,
              let usage = object["usage"] as? [String: Any],
              let input = integer(usage["input_tokens"]),
              let cached = integer(usage["cache_creation_input_tokens"]),
              let output = integer(usage["output_tokens"])
        else { return nil }
        return ParsedTurn(
            isError: isError,
            usage: TokenUsage(input: input, cached: cached, output: output))
    }

    /// Parse the last completed Codex turn from JSONL. Earlier events (including
    /// thread startup and item completion) are not execution evidence by
    /// themselves, so malformed lines are skipped and no fallback is inferred.
    static func parseCodex(_ stdout: String) -> ParsedTurn? {
        for line in stdout.split(whereSeparator: \.isNewline).reversed() {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "turn.completed",
                  let usage = object["usage"] as? [String: Any],
                  let input = integer(usage["input_tokens"]),
                  let cached = integer(usage["cached_input_tokens"]),
                  let output = integer(usage["output_tokens"])
            else { continue }
            return ParsedTurn(
                isError: false,
                usage: TokenUsage(input: input, cached: cached, output: output))
        }
        return nil
    }

    public static func run(
        provider: Provider,
        binary: String,
        environment: [String: String],
        workingDirectory: URL,
        timeout: TimeInterval = 90,
        fileManager: FileManager = .default)
        -> ClaudePingRunner.Result
    {
        let command = command(provider: provider, binary: binary, workingDirectory: workingDirectory)
        guard let executable = ExecutableResolver.resolve(
            command.executable, environment: environment, fileManager: fileManager)
        else {
            return .init(
                ok: false,
                detail: "\(provider.cliBinaryName) binary not found on PATH",
                transcript: "")
        }

        let output = PingProcessRunner.run(
            executable: executable,
            arguments: command.arguments,
            environment: environment,
            workingDirectory: command.workingDirectory,
            timeout: timeout)
        let transcript = output.transcript
        if let launchError = output.launchError {
            return .init(
                ok: false,
                detail: "failed to launch \(provider.cliBinaryName): \(launchError)",
                transcript: transcript)
        }
        if output.timedOut {
            return .init(ok: false, detail: "headless ping timed out", transcript: transcript)
        }

        let parsed = provider == .claude ? parseClaude(output.stdout) : parseCodex(output.stdout)
        guard output.exitStatus == 0, let parsed, !parsed.isError else {
            let detail: String
            if output.exitStatus != 0 {
                detail = "headless ping failed (exit \(output.exitStatus))"
            } else if parsed?.isError == true {
                detail = "headless ping failed: provider reported an error"
            } else {
                detail = "headless ping failed: no completed turn evidence"
            }
            return .init(ok: false, detail: detail, transcript: transcript)
        }

        return .init(
            ok: true,
            detail: "headless turn completed (in=\(parsed.usage.input) cache=\(parsed.usage.cached) out=\(parsed.usage.output))",
            transcript: transcript)
    }

    private static func integer(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: number.intValue
        case let string as String: Int(string)
        default: nil
        }
    }
}

/// Synchronous, timeout-safe `Process` capture shared by non-PTY ping methods.
/// Each pipe is drained concurrently so a verbose child cannot deadlock against
/// pipe back-pressure, while output stays in memory until the caller deliberately
/// saves the normal activity transcript.
enum PingProcessRunner {
    struct Output: Sendable, Equatable {
        let stdout: String
        let stderr: String
        let exitStatus: Int32
        let timedOut: Bool
        let launchError: String?

        var transcript: String {
            stdout + "\n----- stderr -----\n" + stderr
        }
    }

    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        timeout: TimeInterval)
        -> Output
    {
        let stdout = AsyncPipeCapture()
        let stderr = AsyncPipeCapture()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout.pipe
        process.standardError = stderr.pipe

        do {
            try process.run()
        } catch {
            return Output(
                stdout: "", stderr: "", exitStatus: -1, timedOut: false,
                launchError: error.localizedDescription)
        }
        // The child has inherited duplicate write descriptors. Close the parent
        // copies so the readers see EOF as soon as the child terminates.
        stdout.closeParentWriterAndStart()
        stderr.closeParentWriterAndStart()

        let deadline = Date().addingTimeInterval(max(timeout, 0))
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
            let grace = Date().addingTimeInterval(2)
            while process.isRunning, Date() < grace {
                Thread.sleep(forTimeInterval: 0.05)
            }
            #if canImport(Darwin)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            #endif
        }
        process.waitUntilExit()
        return Output(
            stdout: stdout.finish(),
            stderr: stderr.finish(),
            exitStatus: process.terminationStatus,
            timedOut: timedOut,
            launchError: nil)
    }
}

/// One concurrently drained pipe. Access is synchronized because Swift 6
/// correctly treats the dispatch reader as a separate concurrency domain.
private final class AsyncPipeCapture: @unchecked Sendable {
    let pipe = Pipe()
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var captured = Data()

    func closeParentWriterAndStart() {
        try? pipe.fileHandleForWriting.close()
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { group.leave() }
            while let data = try? pipe.fileHandleForReading.read(upToCount: 64 * 1024),
                  !data.isEmpty
            {
                lock.lock()
                captured.append(data)
                lock.unlock()
            }
        }
    }

    func finish() -> String {
        // SDK runtimes can leave a provider child holding the inherited pipe
        // after the runtime itself is terminated. Never let that descendant
        // turn transcript collection into an unbounded second wait.
        if group.wait(timeout: .now() + 1) == .timedOut {
            try? pipe.fileHandleForReading.close()
            _ = group.wait(timeout: .now() + 0.2)
        }
        lock.lock()
        let data = captured
        lock.unlock()
        return String(decoding: data, as: UTF8.self)
    }
}
