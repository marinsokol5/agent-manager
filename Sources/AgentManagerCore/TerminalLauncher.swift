import Foundation

/// Opens Terminal.app running the provider CLI *as* a given account — the
/// account's isolation env var is preset, so the interactive session is that
/// account while your other accounts (and your default login) keep running
/// untouched. For an account on the default login the variable is removed
/// instead, so the login lands in the default login. Used for the interactive
/// login ("Log in" / "Log in again").
public enum TerminalLauncher {
    /// Open Terminal running the provider's interactive login as this account.
    /// Doing the login in a real terminal means the browser sign-in (and any
    /// code Claude asks you to paste back) just works — no PTY puppetry needed.
    @discardableResult
    public static func login(account: Account) -> Bool {
        run(loginCommand(for: account))
    }

    /// The shell line Terminal runs for `login(account:)`. Pure so tests can
    /// pin it; built only from the account's validated managed path
    /// (`AccountID.validate`d slug under the workspace, single-quoted) and
    /// `Provider` constants — never from free-form input (hard rule 5).
    ///
    /// - Managed: `cd` into the account's own managed home — the dir the seeder
    ///   pre-trusted — so Claude's trust-folder dialog is skipped without us
    ///   having to trust `$HOME` (no-op for Codex), and preset the isolation
    ///   variable to that home for this one command.
    /// - Default login: the variable must be *absent*, not set to `~/.claude`
    ///   (Claude Code picks its Keychain item from it — see
    ///   `ChildEnvironment.make(for:base:)`), and the user's interactive shell
    ///   may well export it. `/usr/bin/env -u` removes it for this one command
    ///   in any shell Terminal runs (zsh, bash, fish alike — none of them
    ///   share an `unset` syntax). No `cd`: there is no pre-trusted folder for
    ///   the default login, and Terminal already opens in the home folder;
    ///   the user answers Claude's trust dialog there, as with a plain
    ///   `claude`.
    public static func loginCommand(for account: Account) -> String {
        let provider = account.provider
        let loginArgs = provider.loginArguments.joined(separator: " ")
        if account.tracksDefaultLogin {
            return "/usr/bin/env -u \(provider.configHomeEnvKey) \(provider.cliBinaryName) \(loginArgs)"
        }
        return "cd \(account.homeShellQuoted) && \(provider.configHomeEnvKey)=\(account.home.singleQuotedForShell) \(provider.cliBinaryName) \(loginArgs)"
    }

    @discardableResult
    private static func run(_ command: String) -> Bool {
        let script = """
        tell application "Terminal"
            activate
            do script "\(appleScriptEscaped(command))"
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    /// Escape a shell command for embedding inside an AppleScript string literal.
    private static func appleScriptEscaped(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
