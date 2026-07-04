import AgentManagerCore
import Foundation
#if canImport(Darwin)
import Darwin
#endif

// `am` — the small CLI that drives AgentManagerCore. Account lifecycle (add,
// connect, edit, reconcile, remove) and the work-hour schedule live in the
// Agent Manager app; the CLI keeps only the terminal-native verbs:
//
//   am run <id> [-- <args>]   launch a session as <id> (exec-replaces this process)
//   am list                   inventory accounts + connection status
//   am usage [<id>] [--week]  per-account capacity
//   am ping <id>              fire one tui-ping (manual, and what the scheduler fires)
//   am scheduler …            the resident scheduler daemon (run / status / uninstall)
//   am wake …                 undocumented: classic sudo install of the wake helper
//                             (the app's toggle + SMAppService is the supported path)

let rawArguments = Array(CommandLine.arguments.dropFirst())
// Honor a global `--root <path>` so a launchd-fired `am ping <id> --root <path>`
// (and tests) target the same workspace the scheduler compiled against. Only read
// it from the part *before* any `--` so it never shadows `am run`'s passthrough,
// and strip it out so the remaining args dispatch normally. It's an internal
// launchd/test knob, not an everyday flag, so it's intentionally left out of `--help`.
let globalArgs = Array(rawArguments.prefix { $0 != "--" })
let workspace: Workspace = value("--root", in: globalArgs)
    .map { Workspace(root: URL(fileURLWithPath: expandTilde($0), isDirectory: true)) }
    ?? Workspace.standard()
let arguments = stripGlobalRoot(rawArguments)

/// Remove the global `--root <value>` pair from the args, but only where it
/// appears before any `--` separator (so `am run` passthrough is untouched).
func stripGlobalRoot(_ args: [String]) -> [String] {
    let dash = args.firstIndex(of: "--") ?? args.count
    guard let i = args[..<dash].firstIndex(of: "--root") else { return args }
    var copy = args
    if i + 1 < dash { copy.remove(at: i + 1) }
    copy.remove(at: i)
    return copy
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(code)
}

func expandTilde(_ path: String) -> String {
    guard path == "~" || path.hasPrefix("~/") else { return path }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path == "~" ? home : home + String(path.dropFirst(1))
}

/// Collapse a leading home-directory prefix back to `~` for display.
func abbreviateHome(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path == home { return "~" }
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

/// Pull `--name value` out of an argument list.
func value(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func hasFlag(_ name: String, in args: [String]) -> Bool {
    args.contains(name)
}

let usage = """
am — Agent Manager CLI

USAGE:
  am run <id> [-- <args>]   launch a session under account <id>; everything after
                            `--` is forwarded verbatim to the underlying claude/codex
  am list                   inventory: every account with connection status + provider
  am usage [<id>] [--provider claude|codex] [--sort tokens|time] [--week] [--no-color]
                            capacity for connected accounts (or just <id>); one-row
                            table for 2+ accounts (rank order; --sort reorders it,
                            --provider filters by provider), --week shows the 7d window
  am ping <id>              fire one tui-ping now — anchors <id>'s 5h window; this is
                            also exactly what the background scheduler fires per slot
"""
// Deliberately unlisted verb sets (functional, but the supported surfaces
// live elsewhere):
// - `am scheduler run|status|uninstall` — the resident scheduler daemon.
//   `run` is what the launchd agent invokes (safe to run by hand for
//   debugging); the user-facing control is the app's Scheduler toggle.
// - `am wake install|uninstall|enable|disable|status` — the classic sudo
//   install path for dev/bare-binary setups; the supported surface is the
//   app's "Wake Mac for pings" toggle (SMAppService).
// - `am cloud status|enable|disable` — the experimental cloud fallback; the
//   supported surface is the Preferences toggle.

guard let command = arguments.first else {
    print(usage)
    exit(0)
}

switch command {
case "run":
    runAgent(Array(arguments.dropFirst()))
case "list":
    runList(Array(arguments.dropFirst()))
case "usage":
    await runUsage(Array(arguments.dropFirst()))
case "ping":
    runPing(Array(arguments.dropFirst()))
case "scheduler":
    await runScheduler(Array(arguments.dropFirst()))
case "wake":
    runWake(Array(arguments.dropFirst()))
case "cloud":
    runCloud(Array(arguments.dropFirst()))
case "help", "-h", "--help":
    print(usage)
default:
    fail("unknown command '\(command)'\n\n\(usage)")
}

// MARK: - run (journey 2: launch an agent under an account)

/// `am run <id> [-- <args>]` — resolve the account, then **replace this process**
/// with the underlying `claude`/`codex` binary under the account's isolated home.
/// `exec` (not spawn) makes the launch terminal-native: the CLI inherits our tty,
/// signals, and exit status, so the chosen account *is* the session.
func runAgent(_ args: [String]) {
    guard let id = args.first, id != "--" else {
        fail("usage: am run <id> [-- <args>]")
    }
    // Passthrough = everything after the id, with an optional leading `--`
    // separator stripped (so both `am run x -- --model opus` and the bare
    // `am run x --model opus` work).
    var passthrough = Array(args.dropFirst())
    if passthrough.first == "--" { passthrough.removeFirst() }

    let plan: AccountRunner.Plan
    do {
        plan = try AccountRunner(workspace: workspace).plan(id, passthrough: passthrough)
    } catch let error as AccountRunner.RunError {
        switch error {
        case .notFound:
            fail("\(error)\n  see your accounts with `am list`", code: 2)
        case .notConnected:
            fail("\(error)\n  reconnect '\(id)' in the Agent Manager app, then retry", code: 2)
        case let .binaryNotFound(name):
            fail("\(error)\n  is `\(name)` installed and on your PATH?", code: 2)
        }
    } catch {
        fail("\(error)")
    }

    // Audit before exec — once we hand off, this process is gone. Never log args
    // verbatim (they may carry prompts/paths); a count is enough to reconstruct.
    let argsNote = passthrough.isEmpty ? "" : " (+\(passthrough.count) args)"
    AuditLog(workspace: workspace).append(
        accountID: plan.accountID, action: "run.exec", ok: true,
        detail: "\(plan.provider.rawValue): \(plan.executablePath)\(argsNote)")

    execReplacing(path: plan.executablePath, arguments: plan.arguments, environment: plan.environment)
}

/// Replace the current process image with `path`, passing `arguments` and a fresh
/// `environment`. Returns only if `execve` fails.
func execReplacing(path: String, arguments: [String], environment: [String: String]) -> Never {
    var cArgs: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) }
    cArgs.append(nil)
    var cEnv: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
    cEnv.append(nil)

    execve(path, &cArgs, &cEnv)

    // Only reached if exec failed.
    let reason = String(cString: strerror(errno))
    cArgs.forEach { free($0) }
    cEnv.forEach { free($0) }
    fail("could not exec \(path): \(reason)")
}

// MARK: - list (account inventory)

/// `am list` — the ids you feed to `am run` / `am ping`, plus each account's
/// connection status and provider. Read-only and offline (no network); account
/// lifecycle itself happens in the app. The leading dot is the account's own color
/// (its menu-bar/identity color); the status icon + word (e.g. `✅ connected`)
/// carry connection state. Every managed home lives under one workspace root, so
/// that root is printed once at the top rather than repeated on each row.
func runList(_ args: [String]) {
    let color = !hasFlag("--no-color", in: args) && isatty(STDOUT_FILENO) != 0
    do {
        let accounts = try AccountStore(workspace: workspace).load().inPriorityOrder()
        if accounts.isEmpty { print("no accounts yet — add one in the Agent Manager app"); return }
        // Print the real homes/ directory (no `<id>` placeholder) so terminals can
        // turn it into a clickable link; each account's home is a child named <id>.
        print("homes: \(abbreviateHome(workspace.homesDir.path))\n")
        for (i, account) in accounts.enumerated() {
            let email = account.identityEmail.map { " <\($0)>" } ?? ""
            let provider = account.provider.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0)
            print("\(i + 1). \(TerminalColor.dot(hex: account.color, color: color))  \(account.id.padding(toLength: 16, withPad: " ", startingAt: 0)) \(provider)  \(statusIcon(account.status)) \(account.status.rawValue)\(email)")
        }
    } catch {
        fail("\(error)")
    }
}

func statusIcon(_ status: AccountStatus) -> String {
    switch status {
    case .connected: "✅"
    case .connecting: "⏳"
    case .expired: "⚠️"
    case .disconnected: "⛔️"
    }
}

// MARK: - usage (pretty per-account usage report)

/// `am usage [<id>] [--provider claude|codex] [--sort tokens|time] [--week] [--no-color]` —
/// fetch and pretty-print 5h + 7d usage for the connected accounts (or a single
/// `<id>`). A one-row-per-account table when there's more than one target, the
/// detailed two-bar view for a single one. The table is in rank order by default;
/// `--sort` reorders it (handy at many accounts). `--week` switches both the table
/// and the sort key to the 7d window. Colors auto-disable when stdout isn't a TTY
/// (or with `--no-color`) so it pipes cleanly.
func runUsage(_ args: [String]) async {
    let accounts = ((try? AccountStore(workspace: workspace).load()) ?? []).inPriorityOrder()

    // `--sort <key>`; its value is a key, not the positional <id>.
    let sort: UsageSort?
    if let raw = value("--sort", in: args) {
        guard let parsed = UsageSort(raw) else { fail("unknown --sort '\(raw)' (use: tokens | time)") }
        sort = parsed
    } else {
        sort = nil
    }
    // `--provider <claude|codex>` narrows the connected set to one provider.
    let providerFilter: Provider?
    if let raw = value("--provider", in: args) {
        guard let p = Provider(rawValue: raw.lowercased()) else {
            fail("unknown --provider '\(raw)' (use: \(Provider.allCases.map(\.rawValue).joined(separator: " | ")))")
        }
        providerFilter = p
    } else {
        providerFilter = nil
    }
    // Positional <id> = first non-flag token that isn't a flag's value.
    let valueFlags: Set<String> = ["--sort", "--provider"]
    let idArg = args.enumerated().first { i, a in
        !a.hasPrefix("-") && !(i > 0 && valueFlags.contains(args[i - 1]))
    }?.element

    let targets: [Account]
    if let idArg {
        guard let account = accounts.first(where: { $0.id == idArg }) else { fail("no account with id '\(idArg)'") }
        targets = [account]
    } else {
        targets = accounts.filter { $0.status == .connected && (providerFilter == nil || $0.provider == providerFilter) }
    }
    guard !targets.isEmpty else {
        let only = providerFilter.map { " \($0.rawValue)" } ?? ""
        print(accounts.isEmpty
            ? "No accounts yet — add one in the Agent Manager app."
            : "No connected\(only) accounts. Connect one in the app, then retry.")
        return
    }

    let color = !hasFlag("--no-color", in: args) && isatty(STDOUT_FILENO) != 0
    let gate = UsageRateLimitGate(workspace: workspace)
    let clockStyle = PreferencesStore(workspace: workspace).load().clockStyle
    let week = hasFlag("--week", in: args)
    // Record every CLI usage fetch to the shared network log (token masked), so
    // `am usage` calls are auditable alongside the app's when chasing rate-limits.
    let netLog = NetworkLog(workspace: workspace)

    // More than one target → the compact one-row-per-account table; a single
    // target → the detailed two-bar view.
    if targets.count > 1 {
        var rows: [UsageReportRenderer.Row] = []
        for account in targets {
            do {
                let reading = try await UsageService.fetch(account: account, gate: gate, allowInteraction: true, log: netLog)
                rows.append(.init(account: account, reading: reading))
            } catch {
                rows.append(.init(account: account, reading: nil, error: shortUsageError(error)))
            }
        }
        if let sort { rows = sortRows(rows, by: sort, week: week) }
        print(UsageReportRenderer.renderCompact(rows, window: week ? .week : .session, clockStyle: clockStyle, color: color))
        return
    }

    let account = targets[0]
    do {
        let reading = try await UsageService.fetch(account: account, gate: gate, allowInteraction: true, log: netLog)
        print(UsageReportRenderer.render(account: account, reading: reading, clockStyle: clockStyle, color: color))
    } catch {
        print(UsageReportRenderer.renderError(account: account, message: shortUsageError(error), color: color))
    }
}

func shortUsageError(_ error: Error) -> String {
    (error as? UsageFetchError)?.errorDescription ?? error.localizedDescription
}

/// How `am usage --sort` orders the compact table (default order is rank).
enum UsageSort {
    case leftTokens   // most capacity remaining first — "who can I lean on now"
    case renewalTime  // soonest window reset first — "what refreshes soonest"

    init?(_ raw: String) {
        switch raw.lowercased() {
        case "tokens", "left-tokens", "left", "remaining", "free": self = .leftTokens
        case "time", "reset", "expiry", "expires", "renewal-time", "renewal", "soonest": self = .renewalTime
        default: return nil
        }
    }
}

/// Reorder the usage rows for the chosen window. Rows missing the sort key (no
/// data / errored) always sink to the bottom, and ties keep the incoming rank
/// order, so the sort is stable.
func sortRows(_ rows: [UsageReportRenderer.Row], by sort: UsageSort, week: Bool) -> [UsageReportRenderer.Row] {
    func remaining(_ r: UsageReportRenderer.Row) -> Int? { week ? r.reading?.secondaryRemainingPercent : r.reading?.primaryRemainingPercent }
    func reset(_ r: UsageReportRenderer.Row) -> Date? { week ? r.reading?.secondaryResetsAt : r.reading?.primaryResetsAt }

    func ordered<T: Comparable>(_ key: (UsageReportRenderer.Row) -> T?, ascending: Bool) -> [UsageReportRenderer.Row] {
        rows.enumerated().sorted { a, b in
            switch (key(a.element), key(b.element)) {
            case let (x?, y?): return x == y ? a.offset < b.offset : (ascending ? x < y : x > y)
            case (_?, nil): return true        // a present, b missing → a first
            case (nil, _?): return false
            case (nil, nil): return a.offset < b.offset
            }
        }.map(\.element)
    }

    switch sort {
    case .leftTokens:  return ordered({ remaining($0) }, ascending: false) // fullest first
    case .renewalTime: return ordered({ reset($0) }, ascending: true)       // soonest first
    }
}

// MARK: - ping (manual + scheduled anchoring)

/// `am ping <id>` — fire one minimal tui-ping for `id` now, anchoring its 5h
/// window. This is the one ping operation: the manual "test ping" *and* exactly
/// what the resident scheduler daemon spawns for each queue entry
/// (`am ping <id> --root <root> --manage-sleep --scheduled-for <epoch>`), so a
/// hand-run ping and a scheduled one take an identical path through
/// `AccountPinger.ping`.
func runPing(_ args: [String]) {
    // The positional <id>: first non-flag token that isn't a value-flag's value.
    let valueFlags: Set<String> = ["--scheduled-for"]
    let id = args.enumerated().first { i, a in
        !a.hasPrefix("-") && !(i > 0 && valueFlags.contains(args[i - 1]))
    }?.element
    guard let id else { fail("usage: am ping <id>") }
    // `--manage-sleep` is the internal knob the scheduler passes (never a
    // hand-run `am ping`): hold the Mac awake for the turn, then — only if it's
    // provably unattended — return it to sleep. A manual ping leaves power alone.
    let manageSleep = hasFlag("--manage-sleep", in: args)

    // A scheduled ping that runs long after its minute means the Mac slept
    // through the scheduled time. Anchoring that late is worse than skipping, so
    // bail before we touch power or burn a turn. Manual pings (no
    // `--manage-sleep`) are never subject to this.
    if manageSleep {
        let now = Date()
        // The scheduler daemon passes the queue entry's planned time; without
        // it there is nothing to be late against (fail-open, never suppress).
        let scheduled = value("--scheduled-for", in: args).flatMap(Double.init)
            .map(Date.init(timeIntervalSince1970:))
        if StalePingPolicy.isStale(scheduledFire: scheduled, now: now), let scheduled {
            let lateMin = Int((now.timeIntervalSince(scheduled) / 60).rounded())
            let detail = "skipped: stale ping (fired \(lateMin)m late)"
            AuditLog(workspace: workspace).append(accountID: id, action: "ping.skip", ok: true, detail: detail)
            ActivityLog(workspace: workspace).append(
                ActivityRecord(time: now, accountID: id, ok: true, anchored: false, detail: detail))
            print("⏭️  [\(id)] \(detail)")
            // A distinct code (not 0): the daemon must not read a skip as an
            // anchored window when deciding whether to re-arm the cloud fallback.
            exit(PingOutcome.skippedStaleExitCode)
        }
    }

    // Sample how we found the machine *before* asserting (so we don't read our own
    // caffeinate), and keep the system awake until our process exits — `-w <pid>`
    // makes that crash-safe, covering the fail/exit paths below for free.
    let entry = manageSleep ? PowerProbe().read() : nil
    let caffeinate = manageSleep ? SystemPower.holdIdleAssertion(untilPID: getpid()) : nil
    do {
        let result = try AccountPinger(workspace: workspace).ping(id)
        caffeinate?.terminate()
        print("\(result.ok ? "✅" : "✗") [\(id)] \(result.detail)")
        if let entry, ReSleepPolicy.shouldReturnToSleep(entry: entry, exit: PowerProbe().read()) {
            SystemPower.sleepNow()
        }
        exit(result.ok ? PingOutcome.anchoredExitCode : PingOutcome.failedExitCode)
    } catch let error as AccountPinger.PingError {
        fail("\(error)", code: PingOutcome.failedExitCode)
    } catch {
        fail("\(error)")
    }
}

// MARK: - scheduler (the resident daemon + its controls)

/// `am scheduler run|status|uninstall` — the single always-on LaunchAgent
/// (`com.agent-manager.scheduler`) hosts `run`; it fires every scheduled ping
/// from an in-process queue derived from `schedule.json` + `accounts.json` +
/// the active flag in `scheduler.json`. The app's Scheduler toggle and calendar
/// edits only write those files — launchd is never churned, so macOS's
/// "background items added" notification appears once at install, not on every
/// flip of the toggle.
func runScheduler(_ args: [String]) async {
    switch args.first {
    case "run":
        // launchd already guarantees one instance of the label; the flock stops
        // a hand-run copy from double-firing next to it.
        guard SchedulerDaemon.acquireSingletonLock(at: workspace.schedulerLockFile) else {
            fail("another scheduler daemon is already running for this workspace")
        }
        // Watch our own binary for rebuilds only when launchd (pid 1) is the
        // parent — its KeepAlive relaunches us after the exit-for-update. A
        // hand-run daemon has no such safety net, so it just keeps running.
        let executablePath = getppid() == 1 ? Bundle.main.executablePath : nil
        await SchedulerDaemon(workspace: workspace, executablePath: executablePath).runForever()
        print("am binary updated on disk — exiting for launchd relaunch")
    case "status":
        printSchedulerStatus()
    case "uninstall":
        do {
            let report = try Scheduler(workspace: workspace).uninstall()
            print(report.removed.isEmpty
                ? "nothing installed — no scheduler agent found"
                : "removed: \(report.removed.joined(separator: ", "))")
        } catch {
            fail("\(error)")
        }
    default:
        fail("usage: am scheduler run | status | uninstall")
    }
}

func printSchedulerStatus() {
    let status = Scheduler(workspace: workspace).status()
    let now = Date()

    let agent: String
    if !status.agentInstalled {
        agent = "not installed — turn the Scheduler on in the app"
    } else if !status.agentLoaded {
        agent = "installed, but not loaded in launchd"
    } else if let daemon = status.daemon, daemon.isFresh(asOf: now) {
        agent = "running (pid \(daemon.pid), heartbeat \(Int(now.timeIntervalSince(daemon.updatedAt)))s ago)"
    } else {
        agent = "loaded, but no recent heartbeat — check logs/scheduler.err.log"
    }
    print("agent:  \(agent)")
    print("state:  \(status.active ? "active" : "inactive (turn the Scheduler on in the app)")")

    let upcoming = status.daemon?.upcoming ?? []
    if upcoming.isEmpty {
        print("next:   —")
    } else {
        let clockStyle = PreferencesStore(workspace: workspace).load().clockStyle
        for entry in upcoming.prefix(8) {
            print("next:   \(clockStyle.dateTimeString(entry.fireAt))  \(entry.accountID)")
        }
    }
    for account in status.accounts {
        print("plan:   \(account.accountID)  \(account.pingsPerWeek) pings/wk\(account.scheduled ? "" : "  (inactive)")")
    }
}

// MARK: - cloud (the experimental cloud-fallback controls)

/// `am cloud status|enable|disable` — undocumented controls for the
/// experimental cloud fallback (Claude only): a claude.ai routine
/// ("AgentManager Routine") kept armed as a one-shot five minutes after each
/// scheduled ping, so a Mac that sleeps through a ping (closed lid on battery,
/// where RTC wakes are firmware-blocked) still gets its window anchored — from
/// Anthropic's cloud. enable/disable just write `cloud-fallback.json`; the
/// resident scheduler daemon does all the arming/disabling on its next tick.
func runCloud(_ args: [String]) {
    switch args.first {
    case "enable", "disable":
        let on = args.first == "enable"
        do {
            try CloudFallbackConfigStore(workspace: workspace).save(CloudFallbackConfig(enabled: on))
        } catch { fail("could not write cloud-fallback.json: \(error)") }
        AuditLog(workspace: workspace).append(
            accountID: nil, action: on ? "cloud.enable" : "cloud.disable", ok: true, detail: "via am cloud")
        print(on
            ? "cloud fallback on — the scheduler daemon arms claude.ai anchor routines on its next tick"
            : "cloud fallback off — armed routines are disabled on the daemon's next tick")
    case "status", nil:
        let config = CloudFallbackConfigStore(workspace: workspace).load()
        let state = CloudFallbackStateStore(workspace: workspace).load()
        let clock = PreferencesStore(workspace: workspace).load().clockStyle
        print("cloud fallback: \(config.enabled ? "enabled" : "disabled")")
        if state.accounts.isEmpty {
            print("routines:       none tracked yet (the daemon arms them on its next tick after a plan exists)")
        } else {
            for (id, s) in state.accounts.sorted(by: { $0.key < $1.key }) {
                var bits: [String] = [s.triggerID ?? "no routine"]
                if s.disabled {
                    bits.append("disabled")
                } else if let at = s.armedFor {
                    bits.append("armed for \(clock.dayTimeString(at))")
                }
                if let err = s.lastError { bits.append("error: \(err)") }
                print("  \(id): \(bits.joined(separator: " · "))")
            }
        }
    default:
        fail("usage: am cloud status | enable | disable")
    }
}

// MARK: - wake (the root helper that wakes a sleeping Mac for its pings)

/// `am wake install|uninstall|enable|disable|status` — manages the one
/// privileged component: a root LaunchDaemon that arms RTC wakes just before
/// each scheduled ping so a lid-closed Mac (on AC) still fires. install/
/// uninstall are the only sudo moments in the whole tool; enable/disable just
/// write `wake.json`, which the helper re-reads every minute.
func runWake(_ args: [String]) {
    // Under sudo, HOME points at /var/root — resolve the invoking user's
    // workspace instead, unless an explicit --root already pinned it.
    let ws = value("--root", in: globalArgs) != nil ? workspace : Workspace.sudoInvoker()
    let setup = WakeHelperSetup(workspace: ws)

    switch args.first {
    case "install":
        do {
            let report = try setup.install()
            var parts = [report.binaryUpdated ? "helper installed" : "helper up to date"]
            if report.plistUpdated { parts.append("daemon plist written") }
            parts.append(report.loaded ? "daemon running" : "daemon FAILED to load: \(report.loadOutput)")
            print(parts.joined(separator: " · "))
            if !WakeConfigStore(workspace: ws).load().enabled {
                print("note:   wake is installed but not enabled — run `am wake enable` or flip it in the app")
            }
        } catch { fail("\(error)") }
    case "uninstall":
        do {
            let report = try setup.uninstall()
            print(report.removed.isEmpty
                ? "nothing installed — no wake helper found"
                : "removed: \(report.removed.joined(separator: ", "))")
        } catch { fail("\(error)") }
    case "enable", "disable":
        let enabled = args.first == "enable"
        do {
            try WakeConfigStore(workspace: ws).save(WakeConfig(enabled: enabled))
            print(enabled ? "wake enabled — takes effect on the helper's next pass (≤1 min)"
                          : "wake disabled — scheduled wakes clear on the helper's next pass")
            // The flag is only half the feature — warn when no daemon process
            // exists to obey it, pointing at the supported (app) setup path.
            if enabled, !setup.processState().isRunning {
                print("note:   no helper daemon is running — flip \u{201C}Wake Mac for pings\u{201D} in the app to set one up")
            }
        } catch { fail("\(error)") }
    case "status":
        printWakeStatus(setup, workspace: ws)
    default:
        // `install`/`uninstall` (the classic sudo path) stay functional but
        // unlisted: for a packaged .app the bundled SMAppService toggle is the
        // supported route, and advertising a sudo command here would misdirect
        // exactly the users who never need it.
        fail("usage: am wake enable | disable | status")
    }
}

func printWakeStatus(_ setup: WakeHelperSetup, workspace ws: Workspace) {
    let status = setup.status()

    let helper: String
    if !status.binaryInstalled || !status.plistInstalled {
        // No *classic* install — the normal state for .app users, whose helper
        // is the bundled SMAppService daemon (its liveness prints below).
        helper = "no classic install — the app\u{2019}s \u{201C}Wake Mac for pings\u{201D} toggle is the normal path"
    } else if !status.rootMatches {
        helper = "installed, but serving \(status.installedForRoot ?? "another workspace") — re-run: sudo am wake install"
    } else if status.needsUpdate {
        helper = "installed, but outdated — re-run: sudo am wake install"
    } else {
        helper = "installed"
    }
    print("helper: \(helper)")

    // Registration and reality can disagree (a re-signed bundle can leave the
    // Background-items approval pointing at a signature launchd now rejects),
    // so report the live process, not just the install.
    let daemon: String
    switch setup.processState() {
    case .running(let pid):
        daemon = "running (pid \(pid))"
    case .spawnFailed(let detail):
        // Lead with the heal that re-records macOS's code-requirement pin —
        // the confirmed fix when a re-signed bundle broke the approval.
        daemon = "FAILING to start (\(detail)) — toggle \u{201C}Agent Manager\u{201D} off/on in System Settings → Login Items (classic installs instead re-run: sudo am wake install)"
    case .notLoaded:
        daemon = "not loaded"
    case .starting:
        daemon = "loaded, starting…"
    }
    print("daemon: \(daemon)")
    print("opt-in: \(status.enabled ? "enabled" : "disabled (am wake enable)")")

    if status.scheduledWakes.isEmpty {
        print("wakes:  none scheduled")
    } else {
        // Seconds matter here: wakes are armed ~45 s ahead of their fires.
        let clockStyle = PreferencesStore(workspace: ws).load().clockStyle
        for wake in status.scheduledWakes.prefix(8) {
            print("wakes:  \(clockStyle.dateTimeString(wake, seconds: true))")
        }
    }
    print("note:   a closed lid wakes on AC power only (firmware rule); open lids wake on battery too")
}
