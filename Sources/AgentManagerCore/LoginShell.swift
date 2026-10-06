import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The user's login shell, as the `custom` ping method's login-shell form runs
/// it: `<shell> -l -c '<prologue><line>'` — a login, non-interactive shell, so
/// the user's startup files set up PATH, nvm/pyenv/uv, and their exports the
/// way they do in Terminal.
///
/// Why this exists at all: a *scheduled* custom ping inherits the scheduler
/// daemon's minimal launchd environment, not the user's profile, so an eval
/// that passes in Terminal can fail at 6am. Running it through the login
/// shell is what the user would otherwise do by hand (`/bin/zsh -lc '…'`);
/// this makes it a first-class, validated choice.
///
/// Which shell: the account's own, from the user database at **run time**
/// (`getpwuid(getuid())`'s `pw_shell`), never `$SHELL` — launchd doesn't set
/// it, so the daemon would see none — and never a value stored at save time,
/// so changing your shell (`chsh`) takes effect on the next ping. The lookup is
/// injected (`Lookup`) so tests never depend on the developer's own shell.
///
/// Which shells: only families whose `-l -c` semantics we know and whose
/// syntax our constant prologue is written in — POSIX (`zsh`, `bash`, `sh`,
/// `dash`, `ksh`) and `fish`. Anything else is refused up front rather than
/// guessed at: `tcsh`/`csh` can't combine `-l` with `-c`, and `nu`/`xonsh`/…
/// would need prologues we don't own. A refused shell fails the ping as
/// *never launched* (nothing ran, nothing to verify).
///
/// The prologue, and why values never enter the string: the login shell runs
/// the user's startup files *after* we set the environment, and those files
/// can undo our guarantees — re-export `ANTHROPIC_API_KEY` (the eval would bill
/// the API, not the subscription, and the window would never anchor), set
/// `CLAUDE_CONFIG_DIR` (it would run as the wrong account), or put another
/// `claude` ahead of the provider binary on `PATH`. So the `-c` string is a
/// constant, per-family prologue that re-asserts those three after the
/// profile has run, followed by the user's own line verbatim. Everything
/// variable — the managed home, the run's provider shim directory (one
/// symlink, never the binary's real directory, so the profile's node/python
/// stay first: see `ProviderShim`) — travels in namespaced
/// env vars (`configHomeEnvKey`, `providerBinDirEnvKey`) that the prologue only
/// *references*; the only names spelled into it are env-var names we own
/// (`Provider` properties). That is hard rule 5's narrow carve-out: no
/// interpolated value is ever handed to a shell, only the user's own line.
///
/// What the prologue does *not* guarantee: it runs once, in this shell,
/// before the line. A zsh or fish the line starts (an eval script with a
/// `#!/bin/zsh` shebang, `fish -c …`) re-reads `.zshenv` / `config.fish` and
/// can bring the key or another home back, and hooks the profile installed
/// (mise's or direnv's `cd` handlers) fire *during* the line. Usage
/// verification still decides anchoring, so such a run reads as not
/// anchored rather than as a false success; the README tells users to keep
/// provider keys out of those always-read files.
public struct LoginShell: Equatable, Sendable {
    /// The syntax a prologue is written in.
    public enum Family: String, Sendable, Equatable {
        case posix
        case fish
    }

    /// The two fields of the user's passwd entry this needs.
    public struct UserRecord: Sendable, Equatable {
        public var shell: String
        public var homeDirectory: String

        public init(shell: String, homeDirectory: String) {
            self.shell = shell
            self.homeDirectory = homeDirectory
        }
    }

    /// Reads the running user's passwd entry; `nil` when there is none.
    public typealias Lookup = @Sendable () -> UserRecord?

    /// The real lookup: `getpwuid(getuid())`. Read on every call, never cached,
    /// so a `chsh` between saving and the morning it fires is honored.
    public static let systemLookup: Lookup = {
        #if canImport(Darwin)
        guard let entry = getpwuid(getuid()) else { return nil }
        let shell = entry.pointee.pw_shell.map { String(cString: $0) } ?? ""
        let home = entry.pointee.pw_dir.map { String(cString: $0) } ?? ""
        return UserRecord(shell: shell, homeDirectory: home)
        #else
        return nil
        #endif
    }

    /// Env var carrying the managed home into the prologue (which re-exports
    /// it as `provider.configHomeEnvKey`). Namespaced so a profile has no
    /// reason to touch it.
    public static let configHomeEnvKey = "AGENT_MANAGER_CONFIG_HOME"
    /// Env var carrying the run's provider shim directory (`ProviderShim`:
    /// one `claude`/`codex` symlink, nothing else) into the prologue, which
    /// puts it first on `PATH`. Exported only when a binary was resolved and
    /// the shim was created — and the prologue mentions it only then.
    public static let providerBinDirEnvKey = "AGENT_MANAGER_PROVIDER_BIN_DIR"

    /// Absolute path to the shell binary.
    public let path: String
    public let family: Family
    /// `pw_dir` — the run's cwd, since a shell line has no executable whose
    /// directory could anchor it.
    public let homeDirectory: String

    public init(path: String, family: Family, homeDirectory: String) {
        self.path = path
        self.family = family
        self.homeDirectory = homeDirectory
    }

    /// The shell's name as the user knows it ("fish", "zsh") — for the UI and
    /// for the run's detail/transcript header.
    public var name: String { (path as NSString).lastPathComponent }

    /// Why the login shell can't be used. Each case names the remedy, because
    /// it surfaces verbatim in the Preferences field and in the ping detail.
    public enum Problem: Error, Equatable, CustomStringConvertible {
        case unknown
        case notAbsolute(String)
        case notExecutable(String)
        case unsupported(String)
        case noHomeDirectory(String)

        public var description: String {
            switch self {
            case .unknown:
                "Couldn't read your login shell from the user database."
            case let .notAbsolute(p):
                "Your login shell \"\(p)\" is not an absolute path."
            case let .notExecutable(p):
                "Your login shell \(p) is missing or not executable."
            case let .unsupported(name):
                "Your login shell (\(name)) isn't supported — only zsh, bash, sh, dash, ksh, and fish are. Turn this off and use an absolute path to a script instead."
            case let .noHomeDirectory(p):
                "Your home directory \"\(p)\" from the user database doesn't exist."
            }
        }
    }

    /// Family by basename. Deliberately an exact list: a shell we haven't
    /// written a prologue for must be refused, not run with the wrong syntax.
    public static func family(forShellNamed name: String) -> Family? {
        switch name {
        case "zsh", "bash", "sh", "dash", "ksh": .posix
        case "fish": .fish
        default: nil
        }
    }

    /// Resolve the running user's login shell, or say why it can't be used.
    /// Order: present → absolute → executable file → supported family → home
    /// directory, so the message names the first thing actually wrong.
    public static func resolve(
        lookup: Lookup = systemLookup,
        fileManager: FileManager = .default)
        -> Result<LoginShell, Problem>
    {
        guard let record = lookup() else { return .failure(.unknown) }
        let shell = record.shell.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shell.isEmpty else { return .failure(.unknown) }
        guard shell.hasPrefix("/") else { return .failure(.notAbsolute(shell)) }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: shell, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              fileManager.isExecutableFile(atPath: shell)
        else { return .failure(.notExecutable(shell)) }
        let name = (shell as NSString).lastPathComponent
        guard let family = family(forShellNamed: name) else { return .failure(.unsupported(name)) }
        let home = record.homeDirectory
        isDirectory = false
        guard home.hasPrefix("/"),
              fileManager.fileExists(atPath: home, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return .failure(.noHomeDirectory(home)) }
        return .success(LoginShell(path: shell, family: family, homeDirectory: home))
    }

    /// `Process.arguments` for running `line`: `["-l", "-c", prologue + line]`.
    /// The flags say login (startup files load) and non-interactive (`-c`; no
    /// job control, so every child stays in the process group a timeout kills).
    public func arguments(
        running line: String,
        provider: Provider,
        reassertsConfigHome: Bool,
        prependsProviderBinDir: Bool)
        -> [String]
    {
        let prologue = Self.prologue(
            family: family, provider: provider,
            reassertsConfigHome: reassertsConfigHome,
            prependsProviderBinDir: prependsProviderBinDir)
        return ["-l", "-c", prologue + line]
    }

    /// The constant re-assertion that runs after the profile and before the
    /// user's line. Built only from env-var *names* — `Provider` properties and
    /// the two namespaced keys above — never from a value. Each clause is
    /// present only when the runner exported the var it reads, so a clause can
    /// never set something to empty.
    ///
    /// fish needs one subtlety POSIX doesn't: a *universal* exported variable
    /// (`set -Ux ANTHROPIC_API_KEY …`, persisted in `fish_variables`) survives
    /// `set -e -g` and is still exported to children even when an unexported
    /// global shadows it. Erasing it outright (`set -e` / `-U`) would delete the
    /// user's persisted setting, so instead: erase only the global (what the
    /// profile or our environment set), and if the name is *still* visible —
    /// i.e. a universal — shadow it with an exported, empty global. The child
    /// then sees an empty key, which carries no secret and selects no API
    /// billing; the user's universal is untouched.
    static func prologue(
        family: Family,
        provider: Provider,
        reassertsConfigHome: Bool,
        prependsProviderBinDir: Bool)
        -> String
    {
        let home = provider.configHomeEnvKey
        var clauses: [String] = []
        switch family {
        case .posix:
            if reassertsConfigHome { clauses.append("export \(home)=\"$\(configHomeEnvKey)\"") }
            for key in provider.apiKeyEnvironmentKeys { clauses.append("unset \(key)") }
            if prependsProviderBinDir { clauses.append("export PATH=\"$\(providerBinDirEnvKey):$PATH\"") }
        case .fish:
            if reassertsConfigHome { clauses.append("set -gx \(home) $\(configHomeEnvKey)") }
            for key in provider.apiKeyEnvironmentKeys {
                clauses.append("set -e -g \(key)")
                clauses.append("set -q \(key); and set -gx \(key)")
            }
            if prependsProviderBinDir { clauses.append("set -gx PATH $\(providerBinDirEnvKey) $PATH") }
        }
        return clauses.map { $0 + "; " }.joined()
    }
}
