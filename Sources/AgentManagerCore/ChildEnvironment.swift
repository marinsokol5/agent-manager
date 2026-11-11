import Foundation

/// Builds the environment for a CLI we puppet as an account: inherit the
/// caller's env (HOME, LANG, …), ensure a usable `TERM`, enrich `PATH` with the
/// usual install dirs so a bare `claude` resolves even under a stripped
/// environment, then point the provider's isolation env var at the account's
/// home — or, for an account on the provider's default login, remove it.
public enum ChildEnvironment {
    /// The child environment for running the CLI **as `account`** — the one
    /// account-aware way to build it. Every runner that acts for an account
    /// (`am run`, every ping method, the delegated token refresh) goes through
    /// here, so no call site can hand a default-login account a managed path.
    ///
    /// - Managed account: `CLAUDE_CONFIG_DIR` / `CODEX_HOME` = its managed home.
    /// - Default-login account (`Account.tracksDefaultLogin`): the variable is
    ///   **removed**, including a value inherited from `base` (a developer
    ///   shell, a profile). Never set to `~/.claude`: Claude Code picks its
    ///   Keychain item from that variable — set to *anything*, it uses
    ///   `Claude Code-credentials-<hash>` and `<dir>/.claude.json`; only unset
    ///   does it use the unsuffixed `Claude Code-credentials` and
    ///   `~/.claude.json`, the login the desktop app keeps fresh. Codex has no
    ///   such suffix, but unset is equally exactly what a plain `codex` sees.
    ///
    /// Everything else (TERM, PATH enrichment) is identical for both; callers
    /// strip API keys and add their own variables on top as before.
    public static func make(
        for account: Account,
        base: [String: String] = ProcessInfo.processInfo.environment)
        -> [String: String]
    {
        var env = enriched(base: base)
        if account.tracksDefaultLogin {
            env.removeValue(forKey: account.provider.configHomeEnvKey)
            return env
        }
        return ManagedHome(url: account.homeURL, provider: account.provider).injecting(into: env)
    }

    /// The environment for a CLI run inside a bare managed home that is not
    /// (yet) driven through an `Account` — the guided login of a freshly
    /// provisioned home. Internal on purpose: anything acting for an existing
    /// account must use `make(for: Account)`, which knows about the default
    /// login.
    static func make(
        for home: ManagedHome,
        base: [String: String] = ProcessInfo.processInfo.environment)
        -> [String: String]
    {
        home.injecting(into: enriched(base: base))
    }

    /// The home-independent part of `make`: TERM + the enriched PATH. Split out
    /// so the scheduler agent's plist can bake a usable environment without
    /// binding it to any one account's config home.
    public static func enriched(
        base: [String: String] = ProcessInfo.processInfo.environment)
        -> [String: String]
    {
        var env = base
        if (env["TERM"] ?? "").isEmpty { env["TERM"] = "xterm-256color" }

        let homeDir = env["HOME"] ?? NSHomeDirectory()
        let preferred = ["\(homeDir)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let existing = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        var dirs: [String] = []
        for dir in preferred + existing where !dir.isEmpty && seen.insert(dir).inserted {
            dirs.append(dir)
        }
        env["PATH"] = dirs.joined(separator: ":")

        return env
    }

    /// Resolve the CLI binary to puppet: the provider's override env var (the real
    /// `claude` is often a shim; tests inject a stub) falls back to the binary name.
    public static func binary(for provider: Provider, environment: [String: String]) -> String {
        environment[provider.binaryOverrideEnvKey].flatMap { $0.isEmpty ? nil : $0 } ?? provider.cliBinaryName
    }
}
