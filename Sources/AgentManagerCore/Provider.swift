import Foundation

/// A supported agent provider.
///
/// Every provider-specific fact is expressed as a property here so the rest of
/// Core stays provider-agnostic and the compiler forces each `switch` to be
/// filled in when a provider is added.
public enum Provider: String, Codable, Sendable, CaseIterable {
    case claude
    case codex

    /// Environment variable that isolates this provider's credentials/config to
    /// a managed home. Each distinct value is its own independently-anchored
    /// account.
    public var configHomeEnvKey: String {
        switch self {
        case .claude: "CLAUDE_CONFIG_DIR"
        case .codex: "CODEX_HOME"
        }
    }

    /// The CLI binary name we puppet (resolved against PATH + common bin dirs).
    public var cliBinaryName: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        }
    }

    /// Env var that overrides the resolved CLI binary path. The `claude` on
    /// `PATH` is often a session shim, so this points at the real binary (and
    /// lets tests inject a stub).
    public var binaryOverrideEnvKey: String {
        switch self {
        case .claude: "AGENT_MANAGER_CLAUDE_BIN"
        case .codex: "AGENT_MANAGER_CODEX_BIN"
        }
    }

    /// Arguments that drive the provider's one-time interactive login.
    public var loginArguments: [String] {
        switch self {
        case .claude: ["/login"]      // a slash command on the `claude` binary
        case .codex: ["login"]        // a `codex` subcommand
        }
    }

    /// The single identity file kept **real and per-account** inside each managed
    /// home — never symlinked. Claude's `.claude.json` carries the `oauthAccount`
    /// record (the OAuth secret is in Keychain, keyed by the config-dir path);
    /// Codex's `auth.json` carries the tokens directly. Either way this one file
    /// is the whole identity boundary.
    public var identityFileName: String {
        switch self {
        case .claude: ".claude.json"
        case .codex: "auth.json"
        }
    }

    /// Depth-1 children of the source home that the CLI tends to **rewrite** in
    /// place. Copied on create rather than symlinked, so an edit by one account
    /// never bleeds back into the shared source and across the other accounts.
    public var rewrittenConfigFiles: Set<String> {
        switch self {
        case .claude: ["settings.json"]
        case .codex: ["config.toml"]
        }
    }

    /// Depth-1 children kept **per-account and local** — never symlinked. For
    /// Claude, `backups/` holds `.claude.json.backup` copies of the *source's*
    /// identity; linking them makes the CLI try to restore the source account
    /// into this one ("config not found, a backup exists…"). Left absent so the
    /// CLI creates its own. Codex has no such directory.
    public var localOnlyEntries: Set<String> {
        switch self {
        case .claude: ["backups"]
        case .codex: []
        }
    }

    /// Keychain generic-password service prefix for this provider's per-config-dir
    /// credential items on macOS (Claude writes `Claude Code-credentials-<hash>`).
    /// `nil` for providers whose token is a plain file (Codex `auth.json`).
    public var keychainServicePrefix: String? {
        switch self {
        case .claude: "Claude Code-credentials"
        case .codex: nil
        }
    }

    /// Default source home whose depth-1 children seed a new account's managed
    /// home: `~/.claude` for Claude, `~/.codex` for Codex.
    public func defaultSourceHome(homeDirectory: URL) -> URL {
        switch self {
        case .claude: homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        case .codex: homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        }
    }

    /// Whether this provider has a first-party *hosted* scheduler that can
    /// anchor the account's window while the Mac sleeps (the cloud-fallback
    /// feature). Claude has routines (claude.ai/code/routines, driven via
    /// `TriggerClient`); Codex's "automations" run locally in the Codex app —
    /// same awake-machine constraint as our own scheduler — so there is
    /// nothing cloud-side to arm.
    public var supportsCloudAnchorRoutines: Bool {
        switch self {
        case .claude: true
        case .codex: false
        }
    }
}
