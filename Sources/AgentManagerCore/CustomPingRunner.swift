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
///   AGENTS.md: argv, not a shell string; the user's executable, not ours.
///
/// Execution model, and why:
/// - **argv only.** `Process` + absolute `executableURL` + `arguments`. The
///   command was parsed into argv once, when the user saved it
///   (`CustomPingCommand`), and is re-validated here because the file can
///   change between saving it and the morning it fires.
/// - **Environment additions.** `AGENT_MANAGER_ACCOUNT_ID` and
///   `AGENT_MANAGER_PROVIDER` say which account this run is for, and the
///   provider binary Agent Manager resolved is exported as
///   `provider.binaryOverrideEnvKey` with its directory put first on `PATH` —
///   so a bare `claude` in the user's script is the same binary we'd drive,
///   not whichever shim their login shell happens to find first.
/// - **cwd** is the executable's own directory (scripts tend to assume their
///   siblings are reachable relatively); **stdin** is `/dev/null` (nobody is
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
    /// account/provider identity and the resolved provider binary. Pure, so the
    /// exact contract the README documents is testable without a process.
    static func environment(
        base: [String: String],
        accountID: String,
        provider: Provider,
        providerBinary: String?)
        -> [String: String]
    {
        var env = base
        env[accountIDEnvKey] = accountID
        env[providerEnvKey] = provider.rawValue
        if let providerBinary {
            env[provider.binaryOverrideEnvKey] = providerBinary
            let dir = (providerBinary as NSString).deletingLastPathComponent
            let rest = (env["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0 != dir }
            env["PATH"] = ([dir] + rest).joined(separator: ":")
        }
        return env
    }

    public static func run(
        command: CustomPingCommand?,
        accountID: String,
        provider: Provider,
        binary: String,
        environment base: [String: String],
        timeout: TimeInterval = timeout,
        fileManager: FileManager = .default)
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
            try command.validate(fileManager: fileManager)
        } catch {
            return .init(ok: false, detail: "custom command unusable: \(error)", transcript: "")
        }

        // An unresolvable provider binary isn't fatal: the user's command may
        // not call the CLI at all. It just doesn't get the override exported.
        let providerBinary = ExecutableResolver.resolve(binary, environment: base, fileManager: fileManager)
        let env = environment(base: base, accountID: accountID, provider: provider, providerBinary: providerBinary)

        let output = AsyncPipeCapture(tailLimit: transcriptTailBytes)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.environment = env
        process.currentDirectoryURL = URL(fileURLWithPath: command.executable).deletingLastPathComponent()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output.pipe
        process.standardError = output.pipe

        let started = Date()
        do {
            try process.run()
        } catch {
            return .init(
                ok: false,
                detail: "failed to launch custom command: \(error.localizedDescription)",
                transcript: "")
        }
        output.closeParentWriterAndStart()
        let pid = process.processIdentifier
        // `Process` starts the child as its own process-group leader (pgid ==
        // pid), which is what lets a timeout reach the whole tree — script →
        // claude → node — instead of orphaning the grandchildren that are
        // actually spending the turns. Checked once, now, while the child is
        // certainly alive; if that ever stops holding we fall back to
        // signalling the child alone rather than a group we don't own.
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
        let transcript = "custom command: \(command.executable)\n" + output.finish()

        if timedOut {
            // Launched, so turns may have run before the kill: verify, don't
            // write off (see `Result.mayHaveRunTurns`).
            return .init(
                ok: false,
                detail: "custom command timed out after \(duration(elapsed)) — process group killed",
                transcript: transcript,
                mayHaveRunTurns: true)
        }
        let how = process.terminationReason == .uncaughtSignal
            ? "was killed by signal \(process.terminationStatus)"
            : "exited \(process.terminationStatus)"
        return .init(ok: true, detail: "custom command \(how) after \(duration(elapsed))", transcript: transcript)
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
