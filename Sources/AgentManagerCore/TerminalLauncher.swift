import Foundation

/// Opens Terminal.app running the provider CLI *as* a given account — the
/// account's isolation env var is preset, so the interactive session is that
/// account while your other accounts (and your default login) keep running
/// untouched. Used for the one-time interactive login.
public enum TerminalLauncher {
    /// Open Terminal running the provider's interactive login as this account.
    /// Doing the login in a real terminal means the browser sign-in (and any
    /// code Claude asks you to paste back) just works — no PTY puppetry needed.
    @discardableResult
    public static func login(account: Account) -> Bool {
        // `cd` into the account's own managed home — the dir the seeder pre-trusted
        // — so the working dir is trusted and Claude's trust-folder dialog is
        // skipped, without us having to trust `$HOME` (no-op for Codex).
        let loginArgs = account.provider.loginArguments.joined(separator: " ")
        return run("cd \(account.homeShellQuoted) && \(account.provider.configHomeEnvKey)=\(account.home.singleQuotedForShell) \(account.provider.cliBinaryName) \(loginArgs)")
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
