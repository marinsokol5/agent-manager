import Foundation

/// Builds the environment for a CLI we puppet under an isolated managed home:
/// inherit the caller's env (HOME, LANG, …), ensure a usable `TERM`, enrich
/// `PATH` with the usual install dirs so a bare `claude` resolves even under a
/// stripped environment, then inject the account's isolation env var.
public enum ChildEnvironment {
    public static func make(
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
