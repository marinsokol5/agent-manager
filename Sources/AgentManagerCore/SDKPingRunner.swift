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

    /// Asked of a candidate interpreter: can it see the SDK module?
    typealias ModuleProbe = @Sendable (_ interpreter: String, _ environment: [String: String]) -> Bool

    /// Which interpreter runs the helper — the decision the two runtimes make
    /// very differently, resolved before the pure command shape below.
    ///
    /// Node resolves `@anthropic-ai/claude-agent-sdk` by walking up from the
    /// helper *script*, so any `node` on any PATH finds the workspace's
    /// `node_modules`: there is nothing to choose. Python resolves imports from
    /// the *running interpreter's* site-packages, so for Codex the interpreter
    /// **is** the dependency location — and a bare `python3` is the one thing we
    /// must not settle for. `ChildEnvironment.enriched` prepends `/opt/homebrew/bin`
    /// ahead of the caller's PATH, and the scheduler daemon's sealed plist carries
    /// no user PATH at all, so the `python3` that runs the helper is routinely
    /// *not* the `python3` the user typed `pip install` into (Homebrew's shadows
    /// mise/pyenv/uv's, and Homebrew's is PEP 668 externally-managed anyway).
    /// `sdk-ping/.venv` is the fix: one interpreter, inside the workspace, that
    /// app, CLI, and daemon all resolve identically. The PATH probe behind it is
    /// a courtesy for an install that already put the module in *some* python.
    static func runtime(
        provider: Provider,
        workspace: Workspace,
        environment: [String: String],
        fileManager: FileManager = .default,
        probe: ModuleProbe = importProbe)
        -> String
    {
        switch provider {
        case .claude:
            return nonEmpty(environment["AGENT_MANAGER_NODE_BIN"]) ?? "node"
        case .codex:
            if let override = nonEmpty(environment["AGENT_MANAGER_PYTHON_BIN"]) { return override }
            // The venv wins on existence alone, never on a probe: the documented
            // install location must stay deterministic, so a venv missing the
            // module reports *that* rather than silently anchoring elsewhere.
            let venv = workspace.sdkPingVenvPython.path
            if fileManager.isExecutableFile(atPath: venv) { return venv }
            let candidates = ExecutableResolver.resolveAll(
                "python3", environment: environment, fileManager: fileManager)
            return candidates.first { probe($0, environment) } ?? candidates.first ?? "python3"
        }
    }

    /// Pure command shape after the interpreter, scripts, and provider CLI have
    /// been resolved.
    static func command(
        provider: Provider,
        providerBinary: String,
        runtime: String,
        scripts: (claude: URL, codex: URL),
        environment: [String: String],
        workingDirectory: URL)
        -> Command
    {
        switch provider {
        case .claude:
            return Command(
                executable: runtime,
                arguments: [scripts.claude.path, ClaudePingRunner.pingPrompt, providerBinary],
                environment: environment,
                workingDirectory: workingDirectory)
        case .codex:
            var childEnvironment = environment
            childEnvironment["AGENT_MANAGER_CODEX_SDK_CWD"] = workingDirectory.path
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
            runtime: runtime(
                provider: provider,
                workspace: workspace,
                environment: environment,
                fileManager: fileManager),
            scripts: scripts,
            environment: environment,
            workingDirectory: workingDirectory)
        guard let interpreter = ExecutableResolver.resolve(
            command.executable, environment: command.environment, fileManager: fileManager)
        else {
            return .init(
                ok: false,
                detail: unavailableDetail(
                    provider: provider,
                    workspace: workspace,
                    reason: "\(command.executable) not found on PATH"),
                transcript: "")
        }

        let output = PingProcessRunner.run(
            executable: interpreter,
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
            // Name the interpreter/runtime that came up short: with Python the
            // *which* is the whole failure, and "run pip install" on its own has
            // already been obeyed once by anyone reading this line.
            return .init(
                ok: false,
                detail: unavailableDetail(
                    provider: provider,
                    workspace: workspace,
                    reason: missingDependencyReason(provider: provider, runtime: interpreter)),
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
    /// from drifting away from the runtime's actual module resolution rules —
    /// which is why the Codex line installs into `sdk-ping/.venv` by absolute
    /// path rather than saying `python3 -m pip install`: whichever `python3` the
    /// user's shell happens to resolve is exactly what `runtime` cannot rely on.
    /// (`python3 -m venv` creates intermediate directories, so this works before
    /// the first ping has materialized anything; `mkdir -p` covers the same for
    /// npm's `cd`.)
    public static func setupCommand(provider: Provider, workspace: Workspace) -> String {
        let directory = workspace.sdkPingDir.path.singleQuotedForShell
        switch provider {
        case .claude:
            return "mkdir -p \(directory) && cd \(directory) && npm install @anthropic-ai/claude-agent-sdk"
        case .codex:
            return "python3 -m venv \(workspace.sdkPingVenv.path.singleQuotedForShell) && "
                + "\(workspace.sdkPingVenvPython.path.singleQuotedForShell) -m pip install openai-codex"
        }
    }

    /// Nothing in the package is imported — `find_spec` only *locates* it — and
    /// the probe runs from `/` so that a stray `openai_codex` directory in the
    /// caller's cwd (which Python puts on `sys.path` for `-c`) cannot vouch for
    /// an interpreter that doesn't actually have it installed.
    static let importProbe: ModuleProbe = { interpreter, environment in
        let output = PingProcessRunner.run(
            executable: interpreter,
            arguments: ["-c", "import importlib.util as u, sys; sys.exit(0 if u.find_spec('openai_codex') else 1)"],
            environment: environment,
            workingDirectory: URL(fileURLWithPath: "/"),
            timeout: 10)
        return output.launchError == nil && !output.timedOut && output.exitStatus == 0
    }

    private static func missingDependencyReason(provider: Provider, runtime: String) -> String {
        switch provider {
        case .claude: "\(runtime) cannot resolve @anthropic-ai/claude-agent-sdk"
        case .codex: "\(runtime) cannot import openai_codex"
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
