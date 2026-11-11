import Foundation

/// Creates an account's on-disk presence — the managed home + the symlink farm —
/// and persists it as `disconnected`. **This is independent of logging in:** a
/// new agent exists immediately; logging in is a separate step that flips its
/// status to `connected` and can be retried any time.
public struct AccountProvisioner {
    public struct Options: Sendable {
        public var id: String
        public var label: String
        public var color: String
        public var provider: Provider
        /// Defaults to `provider.defaultSourceHome` (`~/.claude`).
        public var sourceHome: URL?
        public var rank: Int?
        public var reservedHours: Double?

        public init(
            id: String,
            label: String,
            color: String = "#7C7CFF",
            provider: Provider = .claude,
            sourceHome: URL? = nil,
            rank: Int? = nil,
            reservedHours: Double? = nil)
        {
            self.id = id
            self.label = label
            self.color = color
            self.provider = provider
            self.sourceHome = sourceHome
            self.rank = rank
            self.reservedHours = reservedHours
        }
    }

    public enum ProvisionError: Error, CustomStringConvertible {
        case invalidID(String)
        case duplicate(String)
        case homeCreationFailed(String)

        public var description: String {
            switch self {
            case let .invalidID(message): message
            case let .duplicate(id): "an account with id '\(id)' already exists"
            case let .homeCreationFailed(message): "could not create managed home: \(message)"
            }
        }
    }

    let workspace: Workspace
    let fileManager: FileManager
    let store: AccountStore
    let audit: AuditLog

    public init(workspace: Workspace, fileManager: FileManager = .default) {
        self.workspace = workspace
        self.fileManager = fileManager
        self.store = AccountStore(workspace: workspace, fileManager: fileManager)
        self.audit = AuditLog(workspace: workspace, fileManager: fileManager)
    }

    @discardableResult
    public func create(_ options: Options) throws -> Account {
        do {
            try AccountID.validate(options.id)
        } catch {
            throw ProvisionError.invalidID("\(error)")
        }
        if (try store.find(options.id)) != nil {
            throw ProvisionError.duplicate(options.id)
        }
        audit.append(accountID: options.id, action: "account.add.start", ok: true, detail: "provider=\(options.provider.rawValue)")

        // Managed home.
        let homeURL = workspace.managedHome(forAccountID: options.id)
        try createHome(id: options.id, provider: options.provider, at: homeURL)

        // Resolve the source home up front (default `~/.claude` / `~/.codex`, or a
        // caller override for a separate work/personal config) so we both farm
        // from it and record it on the account — the UI shows it as the folder
        // this agent "tracks".
        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        let sourceHome = options.sourceHome ?? options.provider.defaultSourceHome(homeDirectory: homeDirectory)

        // Persist the account up front, logged-out.
        let keychainService = options.provider == .claude
            ? KeychainProbe.claudeKeychainService(for: homeURL)
            : nil
        let account = Account(
            id: options.id,
            label: options.label,
            color: options.color,
            provider: options.provider,
            home: homeURL.path,
            sourceHome: sourceHome.path,
            rank: options.rank,
            reservedHours: options.reservedHours,
            status: .disconnected,
            keychainService: keychainService)
        try store.insert(account)

        try furnishHome(id: options.id, provider: options.provider, sourceHome: sourceHome, managedHome: homeURL)
        return account
    }

    /// Lay down a managed home for an *existing* account that has none — the
    /// switch from the default login back to a managed one
    /// (`DefaultLoginAccounts.useManagedLogin`) for an account that was created
    /// tracking the default login and so never had one. A home that already
    /// exists (an account converted earlier, whose managed home was left on
    /// disk on purpose) is only topped up: missing links are added, and the
    /// seeder keeps an existing `.claude.json`.
    public func prepareHome(for account: Account) throws {
        let homeURL = account.homeURL
        try createHome(id: account.id, provider: account.provider, at: homeURL)
        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        let sourceHome = URL(fileURLWithPath: account.effectiveSourceHome(homeDirectory: homeDirectory), isDirectory: true)
        try furnishHome(id: account.id, provider: account.provider, sourceHome: sourceHome, managedHome: homeURL)
    }

    private func createHome(id: String, provider: Provider, at homeURL: URL) throws {
        let home = ManagedHome(url: homeURL, provider: provider, fileManager: fileManager)
        do {
            try home.create()
        } catch {
            audit.append(accountID: id, action: "home.create", ok: false, detail: error.localizedDescription)
            throw ProvisionError.homeCreationFailed(error.localizedDescription)
        }
        audit.append(accountID: id, action: "home.create", ok: true, detail: homeURL.path)
    }

    /// Symlink farm from the source home, then (Claude) the `.claude.json` seed.
    private func furnishHome(id: String, provider: Provider, sourceHome: URL, managedHome homeURL: URL) throws {
        if fileManager.fileExists(atPath: sourceHome.path) {
            let farm = SymlinkFarm(provider: provider, sourceHome: sourceHome, managedHome: homeURL, fileManager: fileManager)
            let report = try farm.apply()
            audit.append(accountID: id, action: "symlink.farm", ok: report.failures.isEmpty, detail: report.summary)
        } else {
            audit.append(accountID: id, action: "symlink.farm", ok: true, detail: "source home \(sourceHome.path) absent; skipped")
        }

        // Seed a clean `.claude.json` so the one-time login skips onboarding/trust.
        if provider == .claude {
            let seeded = ClaudeConfigSeeder.seed(
                sourceHome: sourceHome, managedHome: homeURL, fileManager: fileManager)
            audit.append(
                accountID: id, action: "config.seed", ok: true,
                detail: seeded ? "seeded .claude.json (onboarding done, managed home trusted)" : "kept existing .claude.json")
        }
    }
}
