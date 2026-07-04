import Foundation

/// Journey 2 — *run an agent*. Resolves an account to a concrete launch plan:
/// the account's provider + isolated managed home become the underlying
/// `claude`/`codex` binary, its passthrough args, and an environment with the
/// account's `CLAUDE_CONFIG_DIR` / `CODEX_HOME` injected.
///
/// This type is pure and side-effect-free (no `exec`, no spawn) so it stays
/// unit-testable; the CLI takes the `Plan` and `exec`s it, replacing its own
/// process so the chosen account *is* the terminal session — parallel-safe,
/// since each account has its own home + Keychain item.
public struct AccountRunner {
    public enum RunError: Error, CustomStringConvertible, Equatable {
        case notFound(String)
        case notConnected(AccountStatus)
        case binaryNotFound(String)

        public var description: String {
            switch self {
            case let .notFound(id): "no account with id '\(id)'"
            case let .notConnected(status): "account is \(status.rawValue) — run requires a connected account"
            case let .binaryNotFound(name): "could not find the '\(name)' binary on PATH"
            }
        }
    }

    /// A resolved, ready-to-`exec` launch. All value types so it crosses the
    /// Core/CLI boundary cleanly.
    public struct Plan: Sendable, Equatable {
        /// Absolute path to the provider CLI to exec.
        public let executablePath: String
        /// Verbatim passthrough args (everything after `am run <id> --`).
        public let arguments: [String]
        /// Child environment with the account's isolation env var injected.
        public let environment: [String: String]
        public let accountID: String
        public let provider: Provider
    }

    let store: AccountStore

    public init(workspace: Workspace, fileManager: FileManager = .default) {
        self.store = AccountStore(workspace: workspace, fileManager: fileManager)
    }

    /// Build the launch plan for `id`, forwarding `passthrough` to the CLI.
    /// `baseEnvironment` is the caller's environment (overridable for tests).
    public func plan(
        _ id: String,
        passthrough: [String] = [],
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment)
        throws -> Plan
    {
        guard let account = try store.find(id) else { throw RunError.notFound(id) }
        guard account.status == .connected else { throw RunError.notConnected(account.status) }

        let home = ManagedHome(url: account.homeURL, provider: account.provider)
        let environment = ChildEnvironment.make(for: home, base: baseEnvironment)
        let binary = ChildEnvironment.binary(for: account.provider, environment: environment)
        guard let executablePath = ExecutableResolver.resolve(binary, environment: environment) else {
            throw RunError.binaryNotFound(binary)
        }

        return Plan(
            executablePath: executablePath,
            arguments: passthrough,
            environment: environment,
            accountID: account.id,
            provider: account.provider)
    }
}
