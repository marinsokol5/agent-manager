import Foundation

/// Seeds a clean `.claude.json` into a new Claude managed home so the one-time
/// login is just the login — not a first-run gauntlet.
///
/// It copies the source `.claude.json` (theme, onboarding flags, tips, MCP
/// config…) **minus identity** (`oauthAccount`/`userID`), marks onboarding
/// complete, and pre-accepts the trust dialog for the **managed home itself** —
/// the directory both the one-time login (`TerminalLauncher.login` does
/// `cd <home>`) and scheduled pings (`workingDirectory: home`) run Claude in.
///
/// Trusting the isolated home rather than `$HOME` skips those dialogs *without*
/// trusting `~`: real project dirs then still get their own trust prompt (so the
/// user keeps that choice), and we avoid Claude Code's bug where a trusted parent
/// suppresses the trust dialog for every subfolder (anthropics/claude-code#72547).
/// Login then writes this account's own `oauthAccount` into the same file. Never
/// overwrites an existing `.claude.json`.
public enum ClaudeConfigSeeder {
    private static let identityKeys = ["oauthAccount", "userID"]

    @discardableResult
    public static func seed(
        sourceHome: URL,
        managedHome: URL,
        fileManager: FileManager = .default)
        -> Bool
    {
        let target = managedHome.appendingPathComponent(".claude.json")
        guard !fileManager.fileExists(atPath: target.path) else { return false }

        // Start from the source config if readable, else an empty object.
        var config: [String: Any] = {
            let source = sourceHome.appendingPathComponent(".claude.json")
            guard let data = try? Data(contentsOf: source),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [:] }
            return object
        }()

        for key in identityKeys { config.removeValue(forKey: key) }
        config["hasCompletedOnboarding"] = true

        // Pre-trust the login/ping cwd (the managed home itself) so the trust
        // dialog is skipped — without trusting `$HOME`, which would suppress the
        // dialog for real project dirs (anthropics/claude-code#72547).
        var projects = config["projects"] as? [String: Any] ?? [:]
        var homeEntry = projects[managedHome.path] as? [String: Any] ?? [:]
        homeEntry["hasTrustDialogAccepted"] = true
        homeEntry["hasCompletedProjectOnboarding"] = true
        projects[managedHome.path] = homeEntry
        config["projects"] = projects

        guard let out = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]) else {
            return false
        }
        do {
            try out.write(to: target, options: [.atomic])
            return true
        } catch {
            return false
        }
    }
}
