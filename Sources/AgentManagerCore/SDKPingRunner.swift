import Foundation

/// SDK delivery through small Node/Python helpers. Runtime dependencies remain
/// explicitly user-managed: this runner materializes versioned source only and
/// never invokes npm, pip, or any package registry.
public enum SDKPingRunner {
    struct Command: Sendable, Equatable {
        let executable: String
        let arguments: [String]
        let environment: [String: String]
        let workingDirectory: URL
    }

    struct ParsedSummary: Sendable, Equatable {
        let ok: Bool
        let usage: HeadlessPingRunner.TokenUsage?
        let error: String?
    }

    /// Pure command shape after scripts and the provider CLI have been resolved.
    static func command(
        provider: Provider,
        providerBinary: String,
        scripts: (claude: URL, codex: URL),
        environment: [String: String],
        workingDirectory: URL)
        -> Command
    {
        var childEnvironment = environment
        switch provider {
        case .claude:
            let runtime = nonEmpty(environment["AGENT_MANAGER_NODE_BIN"]) ?? "node"
            return Command(
                executable: runtime,
                arguments: [scripts.claude.path, ClaudePingRunner.pingPrompt, providerBinary],
                environment: childEnvironment,
                workingDirectory: workingDirectory)
        case .codex:
            childEnvironment["AGENT_MANAGER_CODEX_SDK_CWD"] = workingDirectory.path
            let runtime = nonEmpty(environment["AGENT_MANAGER_PYTHON_BIN"]) ?? "python3"
            return Command(
                executable: runtime,
                arguments: [scripts.codex.path, CodexPingRunner.pingPrompt, providerBinary],
                environment: childEnvironment,
                workingDirectory: workingDirectory)
        }
    }

    /// Parse the last JSON object so an unexpected runtime notice before the
    /// helper's one-line summary does not erase otherwise valid turn evidence.
    static func parse(_ stdout: String) -> ParsedSummary? {
        for line in stdout.split(whereSeparator: \.isNewline).reversed() {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ok = object["ok"] as? Bool
            else { continue }
            let error = object["error"] as? String
            guard let outerUsage = object["usage"] as? [String: Any] else {
                return ParsedSummary(ok: ok, usage: nil, error: error)
            }
            let usage = (outerUsage["last"] as? [String: Any]) ?? outerUsage
            let input = integer(usage["input_tokens"] ?? usage["inputTokens"])
            let cached = integer(
                usage["cache_creation_input_tokens"]
                    ?? usage["cached_input_tokens"]
                    ?? usage["cachedInputTokens"])
            let output = integer(usage["output_tokens"] ?? usage["outputTokens"])
            let parsedUsage = input.flatMap { input in
                cached.flatMap { cached in
                    output.map { output in
                        HeadlessPingRunner.TokenUsage(input: input, cached: cached, output: output)
                    }
                }
            }
            return ParsedSummary(ok: ok, usage: parsedUsage, error: error)
        }
        return nil
    }

    public static func run(
        provider: Provider,
        binary: String,
        environment: [String: String],
        workingDirectory: URL,
        workspace: Workspace,
        timeout: TimeInterval = 90,
        fileManager: FileManager = .default)
        -> ClaudePingRunner.Result
    {
        let scripts: (claude: URL, codex: URL)
        do {
            scripts = try SDKPingScripts.materialize(in: workspace.sdkPingDir, fileManager: fileManager)
        } catch {
            return .init(
                ok: false,
                detail: "sdk ping unavailable: could not materialize helper scripts",
                transcript: "")
        }

        guard let providerBinary = ExecutableResolver.resolve(
            binary, environment: environment, fileManager: fileManager)
        else {
            return .init(
                ok: false,
                detail: "\(provider.cliBinaryName) binary not found on PATH",
                transcript: "")
        }
        let command = command(
            provider: provider,
            providerBinary: providerBinary,
            scripts: scripts,
            environment: environment,
            workingDirectory: workingDirectory)
        guard let runtime = ExecutableResolver.resolve(
            command.executable, environment: command.environment, fileManager: fileManager)
        else {
            let runtimeName = provider == .claude ? "node" : "python3"
            return .init(
                ok: false,
                detail: unavailableDetail(
                    provider: provider,
                    workspace: workspace,
                    reason: "\(runtimeName) not found on PATH"),
                transcript: "")
        }

        let output = PingProcessRunner.run(
            executable: runtime,
            arguments: command.arguments,
            environment: command.environment,
            workingDirectory: command.workingDirectory,
            timeout: timeout)
        let transcript = output.transcript
        if let launchError = output.launchError {
            return .init(
                ok: false,
                detail: "failed to launch sdk ping: \(launchError)",
                transcript: transcript)
        }
        if output.timedOut {
            return .init(ok: false, detail: "sdk ping timed out", transcript: transcript)
        }

        let parsed = parse(output.stdout)
        let dependencyMissing = dependencyIsMissing(
            provider: provider,
            stdout: output.stdout,
            stderr: output.stderr,
            parsedError: parsed?.error)
        if dependencyMissing {
            return .init(
                ok: false,
                detail: unavailableDetail(provider: provider, workspace: workspace),
                transcript: transcript)
        }
        guard output.exitStatus == 0, let parsed, parsed.ok, let usage = parsed.usage else {
            let reason = parsed?.error.map(oneLine) ?? "no completed turn evidence"
            return .init(
                ok: false,
                detail: "sdk ping failed: \(reason)",
                transcript: transcript)
        }
        return .init(
            ok: true,
            detail: "sdk turn completed (in=\(usage.input) cache=\(usage.cached) out=\(usage.output))",
            transcript: transcript)
    }

    static func unavailableDetail(
        provider: Provider,
        workspace: Workspace,
        reason: String? = nil)
        -> String
    {
        let command = setupCommand(provider: provider, workspace: workspace)
        let why = reason.map { " — \($0);" } ?? " —"
        return "sdk ping unavailable\(why) run: \(command)"
    }

    /// Exact user-run prerequisite command shown by both the SDK failure and
    /// Preferences' copy button. Keeping one source prevents UI instructions
    /// from drifting away from the runtime's actual module resolution rules.
    public static func setupCommand(provider: Provider, workspace: Workspace) -> String {
        switch provider {
        case .claude:
            "cd \(workspace.sdkPingDir.path.singleQuotedForShell) && npm install @anthropic-ai/claude-agent-sdk"
        case .codex:
            "python3 -m pip install openai-codex"
        }
    }

    private static func dependencyIsMissing(
        provider: Provider,
        stdout: String,
        stderr: String,
        parsedError: String?)
        -> Bool
    {
        let text = ([stdout, stderr, parsedError ?? ""].joined(separator: "\n")).lowercased()
        switch provider {
        case .claude:
            return text.contains("err_module_not_found")
                || text.contains("cannot find package '@anthropic-ai/claude-agent-sdk'")
                || text.contains("cannot find module '@anthropic-ai/claude-agent-sdk'")
        case .codex:
            return text.contains("openai-codex is not installed")
                || text.contains("no module named 'openai_codex'")
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func integer(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: number.intValue
        case let string as String: Int(string)
        default: nil
        }
    }

    private static func oneLine(_ value: String) -> String {
        String(value.split(whereSeparator: \.isNewline).first ?? "unknown error").prefix(300).description
    }
}
