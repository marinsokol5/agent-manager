import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The `custom` ping method: run the user's own executable (an eval, a daily
/// job they wanted on a timer anyway) under the account's managed home, so the
/// window gets anchored by real work instead of a throwaway turn.
///
/// What this runner does and doesn't decide:
/// - It decides only whether the command **ran**. A command that exits on its
///   own is `ok: true` whatever its status — a failing eval is the eval's
///   verdict, not the ping's — and the status and duration go in the detail.
///   Anchoring is never inferred from that: the scheduled child verifies it
///   from usage exactly as for every other method.
/// - It never looks at credentials. The command gets the same environment the
///   built-in drivers get (managed `CLAUDE_CONFIG_DIR` / `CODEX_HOME`, enriched
///   `PATH`, direct-API keys stripped), so whatever it runs authenticates the
///   way the official CLI does under that home. We neither read nor relay a
///   token — this is the narrow carve-out from hard rules 2 and 5 in
///   AGENTS.md: the user's command, not ours. The argv form never builds a
///   string; the login-shell form adds only `LoginShell`'s constant prologue,
///   whose values travel through env vars.
///
/// Execution model, and why:
/// - **argv form.** `Process` + absolute `executableURL` + `arguments`. The
///   command was parsed into argv once, when the user saved it
///   (`CustomPingCommand`), and is re-validated here because the file can
///   change between saving it and the morning it fires.
/// - **login-shell form.** The user's login shell, resolved now from the user
///   database (`LoginShell`), launched as `<shell> -l -c '<prologue><line>'`
///   so their profile sets up PATH and tooling the way Terminal does. The
///   prologue is constant per shell family and re-asserts, *after* the
///   profile ran, the managed home, the API-key removal, and the provider
///   shim directory (below) first on `PATH` — reading their values from
///   namespaced env vars, so nothing of ours is interpolated into the string.
///   cwd is the user's home; an unsupported or missing shell fails as never
///   launched. Same timeout, group kill, transcript, and outcome as argv.
/// - **Environment additions.** `AGENT_MANAGER_ACCOUNT_ID` and
///   `AGENT_MANAGER_PROVIDER` say which account this run is for, and the
///   provider binary Agent Manager resolved is exported as
///   `provider.binaryOverrideEnvKey`, and a per-run **shim directory** holding
///   only a `claude` / `codex` symlink to it goes first on `PATH` — so a bare
///   `claude` in the user's script is the same binary we'd drive, not
///   whichever copy their login shell happens to find first.
/// - **Why a shim, not the binary's own directory.** That directory is the
///   `PATH` entry the binary was found in — typically `/opt/homebrew/bin`,
///   which also holds node, npm, python3, ruby, bun, pnpm. Putting it first
///   (in login-shell mode, *after* the profile) would shadow the nvm / mise /
///   pyenv toolchain the profile just set up — the very reason to load the
///   profile. The shim re-asserts the provider binary and nothing else. It is
///   created per run (`ProviderShim`) and removed on every exit path; if it
///   can't be created, no `PATH` entry is re-asserted at all (the override
///   env var still names the binary).
/// - **cwd** is the executable's own directory in argv form (scripts tend to
///   assume their siblings are reachable relatively); **stdin** is `/dev/null` (nobody is
///   there to answer a prompt at 6am).
/// - **stdout + stderr** share one pipe so the transcript interleaves them in
///   the order they happened, and only the tail is kept (`transcriptTailBytes`).
/// - **It waits.** An eval takes minutes, so this has its own `timeout`
///   instead of the 90 s sized for a one-line turn — for scheduled pings, Test
///   ping, and hand-run `am ping` alike. On timeout the whole process *group*
///   is terminated, not just the direct child (see `run`).
public enum CustomPingRunner {
    /// How long a custom command may run before it's killed: 8 minutes.
    ///
    /// Two ceilings bound it. First, the daemon's hard kill for the whole ping
    /// child (`SchedulerDaemon.pingChildTimeout`, 600 s): this timeout, the
    /// termination grace, and the postflight usage read must all fit under
    /// it, or the daemon kills a child about to report a verified anchor.
    /// `CustomPingTests.testTimeoutFitsInsideDaemonHardKill` pins that sum —
    /// raise one without the other and it fails. Second, the daemon drains due
    /// pings **sequentially**: every other account due at the same minute waits
    /// behind this one, and `StalePingPolicy.defaultGrace` (15 min) is the point
    /// at which a waiting ping is dropped as stale. A command that runs the
    /// full eight minutes, plus the termination grace and the postflight read,
    /// leaves those accounts roughly six to seven minutes of that grace — not
    /// much, which is why this isn't longer. The delay itself is mostly free:
    /// the provider floors anchors to 10-minute marks
    /// (`RuntimeAnchorPolicy.anchorQuantum`), so a ping held a few minutes
    /// behind the eval usually still lands in the same anchor bucket. A much
    /// longer command belongs on its own timer, with only its first turn
    /// needed to anchor.
    public static let timeout: TimeInterval = 8 * 60

    /// SIGTERM → SIGKILL gap on timeout: long enough for a script's trap or a
    /// CLI's own cleanup, short against the budget above.
    public static let terminationGrace: TimeInterval = 5

    /// What the scheduled child still has to do after the command returns:
    /// one read-only usage fetch (30 s request timeout, at most two requests
    /// with a token refresh in between). Only used to size `timeout`.
    public static let postflightAllowance: TimeInterval = 60

    /// Output kept for the transcript — the tail, where an eval's verdict or a
    /// script's error is. Everything is still read so the child never blocks.
    static let transcriptTailBytes = 256 * 1024

    /// Env vars a custom command can rely on, besides the managed home's own.
    public static let accountIDEnvKey = "AGENT_MANAGER_ACCOUNT_ID"
    public static let providerEnvKey = "AGENT_MANAGER_PROVIDER"

    /// The custom command's environment: `base` (already the managed-home env
    /// with API keys stripped — `AccountPinger.runTurn` builds it), plus the
    /// account/provider identity, the resolved provider binary, and — when
    /// one was created — the run's shim directory first on `PATH` (never the
    /// binary's own directory; see the type doc). Pure, so the exact contract
    /// the README documents is testable without a process.
    static func environment(
        base: [String: String],
        accountID: String,
        provider: Provider,
        providerBinary: String?,
        shimDirectory: String?)
        -> [String: String]
    {
        var env = base
        env[accountIDEnvKey] = accountID
        env[providerEnvKey] = provider.rawValue
        if let providerBinary {
            env[provider.binaryOverrideEnvKey] = providerBinary
        }
        if let shimDirectory {
            let rest = (env["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0 != shimDirectory }
            env["PATH"] = ([shimDirectory] + rest).joined(separator: ":")
        }
        return env
    }

    /// The login-shell form's additions on top of `environment(...)`: the
    /// namespaced carriers the constant prologue reads (`LoginShell`) — the
    /// managed home, and the run's shim directory when one was created.
    /// Returns which prologue clauses those make safe to emit, so a clause is
    /// never present without the var it reads. Pure, like `environment`.
    static func loginShellEnvironment(
        _ env: [String: String],
        provider: Provider,
        shimDirectory: String?)
        -> (env: [String: String], reassertsConfigHome: Bool, prependsProviderBinDir: Bool)
    {
        var env = env
        var home = false
        var binDir = false
        if let managed = env[provider.configHomeEnvKey], !managed.isEmpty {
            env[LoginShell.configHomeEnvKey] = managed
            home = true
        }
        if let shimDirectory {
            env[LoginShell.providerBinDirEnvKey] = shimDirectory
            binDir = true
        }
        return (env, home, binDir)
    }

    public static func run(
        command: CustomPingCommand?,
        accountID: String,
        provider: Provider,
        binary: String,
        environment base: [String: String],
        timeout: TimeInterval = timeout,
        fileManager: FileManager = .default,
        loginShell lookup: LoginShell.Lookup = LoginShell.systemLookup)
        -> ClaudePingRunner.Result
    {
        // Never launched → `ok: false`, nothing to verify (no turn can have run).
        guard let command else {
            return .init(
                ok: false,
                detail: "no custom command set — choose one in Preferences → Ping method",
                transcript: "")
        }
        do {
            try command.validate(fileManager: fileManager, loginShell: lookup)
        } catch {
            return .init(ok: false, detail: "custom command unusable: \(error)", transcript: "")
        }

        // An unresolvable provider binary isn't fatal: the user's command may
        // not call the CLI at all. It just doesn't get the override exported.
        let providerBinary = ExecutableResolver.resolve(binary, environment: base, fileManager: fileManager)
        // The one-symlink directory that puts the provider binary — and only
        // it — first on PATH. Removed on every path out of this function:
        // validation already passed, and everything below either returns
        // early or waits for the child (and, on timeout, its killed group).
        let shim = providerBinary.flatMap {
            ProviderShim.create(binary: $0, name: provider.cliBinaryName, fileManager: fileManager)
        }
        defer { shim.map { ProviderShim.remove($0, fileManager: fileManager) } }
        var env = environment(
            base: base, accountID: accountID, provider: provider,
            providerBinary: providerBinary, shimDirectory: shim?.path)

        // What to launch. Both forms share everything below — timeout, group
        // kill, transcript, outcome — and differ only here.
        let executable: String
        let arguments: [String]
        let workingDirectory: String
        // "custom command" or "custom command (fish login shell)": prefixes
        // the detail, and heads the transcript with the executable or shell.
        // Our header never repeats the arguments or the line, which can carry
        // secrets — though the shell's own error output may (see README).
        let label: String
        switch command {
        case let .argv(exe, args):
            executable = exe
            arguments = args
            workingDirectory = (exe as NSString).deletingLastPathComponent
            label = "custom command"
        case let .loginShell(line):
            // Re-resolved rather than reused from `validate`: same lookup, and
            // reading it once more keeps `validate` a plain yes/no.
            guard case let .success(shell) = LoginShell.resolve(lookup: lookup, fileManager: fileManager) else {
                return .init(ok: false, detail: "custom command unusable: login shell unavailable", transcript: "")
            }
            let prepared = loginShellEnvironment(env, provider: provider, shimDirectory: shim?.path)
            env = prepared.env
            executable = shell.path
            arguments = shell.arguments(
                running: line, provider: provider,
                reassertsConfigHome: prepared.reassertsConfigHome,
                prependsProviderBinDir: prepared.prependsProviderBinDir)
            // No executable to anchor a cwd: the shell starts where a login
            // shell in Terminal would, the user's home (`pw_dir`).
            workingDirectory = shell.homeDirectory
            label = "custom command (\(shell.name) login shell)"
        }

        let output = AsyncPipeCapture(tailLimit: transcriptTailBytes)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = env
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output.pipe
        process.standardError = output.pipe

        let started = Date()
        do {
            try process.run()
        } catch {
            return .init(
                ok: false,
                detail: "failed to launch \(label): \(error.localizedDescription)",
                transcript: "")
        }
        output.closeParentWriterAndStart()
        let pid = process.processIdentifier
        // `Process` starts the child as its own process-group leader (pgid ==
        // pid), which is what lets a timeout reach the whole tree — script →
        // claude → node — instead of orphaning the grandchildren that are
        // actually spending the turns. That holds for the login-shell form
        // too: a non-interactive shell (`-c`) does no job control, so it never
        // moves its children into groups of their own. Checked once, now,
        // while the child is certainly alive; if that ever stops holding we
        // fall back to signalling the child alone rather than a group we
        // don't own.
        let ownsGroup = getpgid(pid) == pid

        let deadline = started.addingTimeInterval(max(timeout, 0))
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        let timedOut = process.isRunning
        if timedOut {
            signal(ownsGroup ? -pid : pid, SIGTERM)
            let grace = Date().addingTimeInterval(terminationGrace)
            while process.isRunning, Date() < grace {
                Thread.sleep(forTimeInterval: 0.05)
            }
            // Unconditionally for the group: the direct child may have honored
            // SIGTERM while a grandchild ignored it. The group id can't have
            // been recycled while any member is still alive.
            signal(ownsGroup ? -pid : pid, SIGKILL)
        }
        process.waitUntilExit()
        let elapsed = Date().timeIntervalSince(started)
        let transcript = "\(label): \(executable)\n" + output.finish()

        if timedOut {
            // Launched, so turns may have run before the kill: verify, don't
            // write off (see `Result.mayHaveRunTurns`).
            return .init(
                ok: false,
                detail: "\(label) timed out after \(duration(elapsed)) — process group killed",
                transcript: transcript,
                mayHaveRunTurns: true)
        }
        let how = process.terminationReason == .uncaughtSignal
            ? "was killed by signal \(process.terminationStatus)"
            : "exited \(process.terminationStatus)"
        return .init(ok: true, detail: "\(label) \(how) after \(duration(elapsed))", transcript: transcript)
    }

    /// "42s", "5m02s" — the eval-sized durations the detail reports.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded()), 0)
        guard total >= 60 else { return "\(total)s" }
        return String(format: "%dm%02ds", total / 60, total % 60)
    }

    private static func signal(_ target: pid_t, _ sig: Int32) {
        #if canImport(Darwin)
        _ = kill(target, sig)
        #endif
    }
}

/// The per-run directory that re-asserts the provider binary on `PATH`:
/// exactly one entry, a symlink named `claude` / `codex` pointing at the
/// binary Agent Manager resolved. Its siblings in the binary's real directory
/// (node, python3, … in `/opt/homebrew/bin`) are deliberately *not* reachable
/// through it, so re-asserting the provider never shadows the toolchain the
/// user's profile chose. See `CustomPingRunner`'s "why a shim" note.
enum ProviderShim {
    /// Directory-name prefix under the temp dir — distinctive, so a leftover
    /// from a crashed run is recognizable as ours.
    static let directoryPrefix = "am-provider-shim-"

    /// Make a fresh `0o700` directory under `parent` (default: the user's temp
    /// dir) holding the one symlink. `nil` on any failure, with whatever was
    /// made cleaned up — the caller then re-asserts no `PATH` entry rather
    /// than a half-built one.
    static func create(
        binary: String,
        name: String,
        fileManager: FileManager = .default,
        parent: URL? = nil)
        -> URL?
    {
        let root = parent ?? fileManager.temporaryDirectory
        let directory = root.appendingPathComponent(directoryPrefix + UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            return nil
        }
        do {
            try fileManager.createSymbolicLink(
                atPath: directory.appendingPathComponent(name).path, withDestinationPath: binary)
        } catch {
            remove(directory, fileManager: fileManager)
            return nil
        }
        return directory
    }

    /// Best-effort removal; a leftover temp dir never fails a ping.
    static func remove(_ directory: URL, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: directory)
    }
}
