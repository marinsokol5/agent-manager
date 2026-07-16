import Foundation

/// Resolves every on-disk path the app owns, rooted at a single directory.
///
/// In production the root is `~/Library/Application Support/AgentManager`.
/// Tests inject a temp directory, and the `AGENT_MANAGER_ROOT` env var overrides
/// it for the CLI — so nothing in Core hard-codes the real app-support path.
public struct Workspace: Sendable {
    /// The AgentManager app-support directory.
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Standard production workspace, honoring `AGENT_MANAGER_ROOT` if set.
    public static func standard(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default)
        -> Workspace
    {
        if let override = environment["AGENT_MANAGER_ROOT"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty
        {
            return Workspace(root: URL(fileURLWithPath: override, isDirectory: true))
        }
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return Workspace(root: base.appendingPathComponent(AppVariant.workspaceDirName, isDirectory: true))
    }

    /// The workspace of the human behind `sudo`. Under sudo, HOME (and so
    /// `standard()`) points at root's home — but the workspace being
    /// administered (`sudo am wake install`) is the *invoking user's*. Resolve
    /// `SUDO_USER`'s home via the passwd database; outside sudo (or with an
    /// explicit `AGENT_MANAGER_ROOT`) this is exactly `standard()`.
    public static func sudoInvoker(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default)
        -> Workspace
    {
        if let override = environment["AGENT_MANAGER_ROOT"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty
        {
            return standard(environment: environment, fileManager: fileManager)
        }
        guard geteuid() == 0,
              let sudoUser = environment["SUDO_USER"], !sudoUser.isEmpty,
              let passwd = getpwnam(sudoUser)
        else { return standard(environment: environment, fileManager: fileManager) }
        let home = URL(fileURLWithPath: String(cString: passwd.pointee.pw_dir), isDirectory: true)
        return Workspace(root: home.appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(AppVariant.workspaceDirName, isDirectory: true))
    }

    /// `homes/` — one managed config-dir per account.
    public var homesDir: URL { root.appendingPathComponent("homes", isDirectory: true) }

    /// The managed home (`CLAUDE_CONFIG_DIR`) for a given account id.
    public func managedHome(forAccountID id: String) -> URL {
        homesDir.appendingPathComponent(id, isDirectory: true)
    }

    /// `accounts.json` — persisted account inventory.
    public var accountsFile: URL { root.appendingPathComponent("accounts.json") }

    /// `schedule.json` — persisted weekly work-hour selection + window length.
    public var scheduleFile: URL { root.appendingPathComponent("schedule.json") }

    /// `usage.json` — last-known usage reading per account, loaded on launch so
    /// the menu bar shows numbers immediately without an eager network fetch.
    public var usageCacheFile: URL { root.appendingPathComponent("usage.json") }

    /// `usage-ratelimit.json` — per-account "blocked until" timestamps so a 429
    /// from the usage API is respected across refreshes *and* app relaunches.
    public var usageRateLimitFile: URL { root.appendingPathComponent("usage-ratelimit.json") }

    /// `preferences.json` — display and provider ping-method preferences shared
    /// by the GUI app and the `am` CLI.
    public var preferencesFile: URL { root.appendingPathComponent("preferences.json") }

    /// `sdk-ping/` — versioned helper scripts materialized on demand for SDK
    /// pings. Dependencies are intentionally user-installed beside the scripts;
    /// Agent Manager never contacts a package registry or installs them itself.
    public var sdkPingDir: URL { root.appendingPathComponent("sdk-ping", isDirectory: true) }

    /// `keychain-grants.json` — Keychain services for which a `/usr/bin/security`
    /// read is verified to succeed silently. Shared by the app, `am`, and the
    /// scheduler daemon so a background read in any of them can use the CLI path
    /// without risking a prompt — see `KeychainGrantStore` for why this must not
    /// live in per-process `UserDefaults`.
    public var keychainGrantsFile: URL { root.appendingPathComponent("keychain-grants.json") }

    /// `scheduler.json` — the resident scheduler's active flag. The app's
    /// "Scheduler active" toggle writes this (never launchd) so switching the
    /// scheduler on/off can't re-fire macOS's "background items" notifications.
    public var schedulerConfigFile: URL { root.appendingPathComponent("scheduler.json") }

    /// `scheduler-status.json` — heartbeat + upcoming-queue snapshot written by
    /// the scheduler daemon each tick; read by the app/CLI for live status.
    /// Also read (fire times + freshness only) by the root wake helper.
    public var schedulerStatusFile: URL { root.appendingPathComponent("scheduler-status.json") }

    /// `wake.json` — the "Wake Mac for pings" opt-in. Written by the app/CLI;
    /// read by the root wake helper, which arms RTC wakes only while this says
    /// enabled. Like `scheduler.json`, the file *is* the control channel — the
    /// helper has no other input surface.
    public var wakeConfigFile: URL { root.appendingPathComponent("wake.json") }

    /// `cloud-fallback.json` — the experimental "cloud fallback" opt-in (Claude
    /// only): keep a claude.ai routine armed as a dead-man's switch so a ping
    /// the sleeping Mac misses is anchored from Anthropic's cloud instead.
    /// Written by the app toggle / `am cloud enable|disable`; read by the daemon.
    public var cloudFallbackConfigFile: URL { root.appendingPathComponent("cloud-fallback.json") }

    /// `cloud-fallback-state.json` — which routine is armed per account and for
    /// when. Written only by the scheduler daemon's engine (single writer);
    /// read by the app's Monitoring row and `am cloud status`.
    public var cloudFallbackStateFile: URL { root.appendingPathComponent("cloud-fallback-state.json") }

    /// `scheduler.lock` — flock()ed by the running daemon so a hand-run
    /// `am scheduler run` can't double-fire next to the launchd-managed one.
    public var schedulerLockFile: URL { root.appendingPathComponent("scheduler.lock") }

    /// `audit.log.jsonl` — append-only audit trail (never tokens).
    public var auditLogFile: URL { root.appendingPathComponent("audit.log.jsonl") }

    /// `activity.jsonl` — append-only ping-result log (the Activity screen reads
    /// this for ✓/✗ + anchor verification).
    public var activityLogFile: URL { root.appendingPathComponent("activity.jsonl") }

    /// `network.jsonl` — append-only log of every HTTP exchange (request +
    /// response, token-redacted) the app makes. Read by Monitoring → Logs.
    public var networkLogFile: URL { root.appendingPathComponent("network.jsonl") }

    /// `logs/` — per-ping launchd stdout/stderr and saved failure transcripts.
    public var logsDir: URL { root.appendingPathComponent("logs", isDirectory: true) }

    /// `~/Library/LaunchAgents` — where compiled per-account plists live. Honors
    /// `AGENT_MANAGER_LAUNCH_AGENTS_DIR` so tests (and `apply --out`) can redirect
    /// it away from the real launchd directory.
    public static func launchAgentsDir(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default)
        -> URL
    {
        if let override = environment["AGENT_MANAGER_LAUNCH_AGENTS_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty
        {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }
}
