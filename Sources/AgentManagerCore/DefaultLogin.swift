import Foundation

/// Read-only look at a provider's **default** login — the one the Claude
/// desktop app / a plain `claude` (or the Codex app / a plain `codex`) keeps
/// fresh, as opposed to an account's managed home. See `AccountLoginSource`
/// for why accounts can track it.
///
/// Reads only: the default Keychain item (`Provider.defaultKeychainService`),
/// and the default identity file (`Provider.defaultIdentityFile`). Nothing
/// here creates, writes, or deletes anything under the default home. Both
/// sources are injected — `homeDirectory` and the Keychain reader — so tests
/// never touch the real Keychain or the real `~/.claude`.
public struct DefaultLoginProbe: Sendable {
    /// Reads and classifies one Claude credential item (`service`,
    /// `allowInteraction`). Production: `ClaudeCredentials.status`.
    public typealias ClaudeCredentialReader = @Sendable (_ service: String, _ allowInteraction: Bool)
        -> ClaudeCredentials.Status?

    public var homeDirectory: URL
    public var readClaudeCredential: ClaudeCredentialReader

    public init(homeDirectory: URL, readClaudeCredential: @escaping ClaudeCredentialReader) {
        self.homeDirectory = homeDirectory
        self.readClaudeCredential = readClaudeCredential
    }

    /// The real thing: the user's home and the strategy-aware Keychain read.
    /// An interactive read goes through `/usr/bin/security` and marks the
    /// service granted in `KeychainGrantStore`, which is what lets later
    /// background usage reads of `Claude Code-credentials` stay silent.
    public static func live(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> DefaultLoginProbe
    {
        DefaultLoginProbe(homeDirectory: homeDirectory) { service, allowInteraction in
            ClaudeCredentials.status(keychainService: service, allowInteraction: allowInteraction)
        }
    }

    /// What the default login looks like right now.
    public struct Verification: Sendable, Equatable {
        /// A usable credential is present and not signed out — the
        /// definition of `connected` for a default-login account.
        public let connected: Bool
        /// From the default identity file; `nil` when absent/unreadable.
        public let identityEmail: String?
        /// One audit-safe line (presence and email only — never a token).
        public let detail: String
    }

    /// Check `provider`'s default login. `allowInteraction` is `true` only for
    /// a user action (adding/converting an account, Verify identity), which
    /// may show the Keychain prompt once; it is meaningless for Codex, whose
    /// default credential is a plain file.
    public func verify(provider: Provider, allowInteraction: Bool) -> Verification {
        switch provider {
        case .claude:
            let identity = IdentityVerifier.readOAuthAccount(at: provider.defaultIdentityFile(homeDirectory: homeDirectory))
            let emailNote = identity.present ? (identity.email ?? "present") : "absent"
            guard let service = provider.defaultKeychainService else {
                return Verification(connected: false, identityEmail: identity.email,
                                    detail: "default login: no keychain service")
            }
            switch readClaudeCredential(service, allowInteraction) {
            case .valid:
                return Verification(connected: true, identityEmail: identity.email,
                                    detail: "default keychain: present; oauthAccount: \(emailNote)")
            case .signedOut:
                return Verification(connected: false, identityEmail: identity.email,
                                    detail: "default keychain: signed out; oauthAccount: \(emailNote)")
            case nil:
                return Verification(connected: false, identityEmail: identity.email,
                                    detail: "default keychain: absent or unreadable; oauthAccount: \(emailNote)")
            }
        case .codex:
            // `IdentityVerifier`'s Codex check only *reads* `<home>/auth.json`;
            // `ManagedHome` here is just the path wrapper (nothing is created).
            let home = ManagedHome(url: provider.defaultSourceHome(homeDirectory: homeDirectory), provider: provider)
            let result = IdentityVerifier.verify(provider: provider, home: home, keychainBaseline: nil)
            return Verification(connected: result.connected, identityEmail: result.identityEmail, detail: "default \(result.detail)")
        }
    }
}

/// Why a default-login add or conversion was refused. Typed so the app and
/// tests can tell them apart; `description` is the user-facing line.
public enum DefaultLoginError: Error, Equatable, CustomStringConvertible {
    case notFound(String)
    case invalidID(String)
    case duplicate(String)
    /// No usable default credential (absent, unreadable, or signed out) —
    /// there is nothing to track until the user signs in where it lives.
    case unavailable(provider: Provider, detail: String)
    /// The default login belongs to a different person than this account.
    /// Converting would silently repoint the account (its history, its name)
    /// at someone else's usage, so it is refused with both emails named.
    case identityMismatch(provider: Provider, accountEmail: String, defaultEmail: String?)

    public var description: String {
        switch self {
        case let .notFound(id): "no account with id '\(id)'"
        case let .invalidID(message): message
        case let .duplicate(id): "an account with id '\(id)' already exists"
        case let .unavailable(provider, detail):
            "no usable default \(provider.displayName) login (\(detail)) — sign in with \(provider.defaultLoginClients) first"
        case let .identityMismatch(provider, accountEmail, defaultEmail):
            "this account is \(accountEmail), but your default \(provider.displayName) login is "
                + "\(defaultEmail ?? "an unknown identity") — sign the default login in as \(accountEmail) first,"
                + " or add a separate account for it"
        }
    }
}

/// The Core operations behind the "Login" choice: add an account that tracks
/// the default login, and switch an existing account between its managed home
/// and the default login (and back). The app and any future CLI verb call
/// these; they never run the CLI, and for the default login they only read.
///
/// One default-login account per provider is enforced twice: up front here
/// (a clear error before any work) and by `AccountStore.insert`/`upsert`
/// (`AccountStoreError.defaultLoginTaken`), so no path can persist a second.
public struct DefaultLoginAccounts {
    /// Verifies a managed home (switching back). Injected so tests don't
    /// enumerate the real Keychain (`IdentityVerifier`'s Claude check does).
    public typealias ManagedVerifier = (Provider, ManagedHome) -> IdentityVerifier.Result

    let workspace: Workspace
    let fileManager: FileManager
    let store: AccountStore
    let audit: AuditLog
    let probe: DefaultLoginProbe
    let verifyManaged: ManagedVerifier

    public init(
        workspace: Workspace,
        fileManager: FileManager = .default,
        probe: DefaultLoginProbe = .live(),
        verifyManaged: @escaping ManagedVerifier = { IdentityVerifier.verify(provider: $0, home: $1, keychainBaseline: nil) })
    {
        self.workspace = workspace
        self.fileManager = fileManager
        self.store = AccountStore(workspace: workspace, fileManager: fileManager)
        self.audit = AuditLog(workspace: workspace, fileManager: fileManager)
        self.probe = probe
        self.verifyManaged = verifyManaged
    }

    /// The identity rule for pointing an existing account at the default
    /// login: an account with a known email may only track a default login
    /// signed in as that same email (case-insensitive). A default login whose
    /// email can't be read counts as different — we can't show it's the same
    /// person. An account with no email yet (never logged in) adopts whatever
    /// the default login is.
    public static func checkIdentity(provider: Provider, accountEmail: String?, defaultEmail: String?) throws {
        guard let accountEmail else { return }
        guard let defaultEmail, defaultEmail.caseInsensitiveCompare(accountEmail) == .orderedSame else {
            throw DefaultLoginError.identityMismatch(
                provider: provider, accountEmail: accountEmail, defaultEmail: defaultEmail)
        }
    }

    /// Create an account that tracks `provider`'s default login. Skips
    /// everything a managed account needs — no managed home is created, no
    /// symlink farm, no seed, no guided login — and saves it `connected` once
    /// the default credential verifies. `home` / `keychainService` /
    /// `sourceHome` are still filled with what a managed account of this id
    /// would get, so a later switch to the managed home has its paths ready;
    /// the directory itself is only laid down on that switch.
    @discardableResult
    public func add(
        id: String,
        label: String,
        color: String = "#7C7CFF",
        provider: Provider,
        rank: Int? = nil,
        allowInteraction: Bool = true) throws -> Account
    {
        do { try AccountID.validate(id) } catch { throw DefaultLoginError.invalidID("\(error)") }
        let accounts = try store.load()
        if accounts.contains(where: { $0.id == id }) { throw DefaultLoginError.duplicate(id) }
        if let owner = AccountStore.defaultLoginOwner(provider: provider, in: accounts) {
            throw AccountStoreError.defaultLoginTaken(provider: provider, accountID: owner.id)
        }

        let verification = probe.verify(provider: provider, allowInteraction: allowInteraction)
        audit.append(accountID: id, action: "verify", ok: verification.connected, detail: verification.detail)
        guard verification.connected else {
            throw DefaultLoginError.unavailable(provider: provider, detail: verification.detail)
        }

        let homeURL = workspace.managedHome(forAccountID: id)
        let account = Account(
            id: id,
            label: label,
            color: color,
            provider: provider,
            home: homeURL.path,
            sourceHome: provider.defaultSourceHome(homeDirectory: probe.homeDirectory).path,
            rank: rank,
            status: .connected,
            identityEmail: verification.identityEmail,
            keychainService: provider == .claude ? KeychainProbe.claudeKeychainService(for: homeURL) : nil,
            loginSource: .providerDefault,
            lastVerifiedAt: Date())
        try store.insert(account)
        audit.append(accountID: id, action: "account.add", ok: true,
                     detail: "provider=\(provider.rawValue) login=default")
        return account
    }

    /// Point an existing account at the default login. Refused when another
    /// account already tracks it, when it isn't usable, or when it is a
    /// different person (`checkIdentity`). The managed home, its Keychain item,
    /// the stored `keychainService`, and `excludedFromScheduling` are all left
    /// exactly as they were, so `useManagedLogin` can switch back. Idempotent.
    @discardableResult
    public func useDefaultLogin(_ id: String, allowInteraction: Bool = true) throws -> Account {
        let accounts = try store.load()
        guard var account = accounts.first(where: { $0.id == id }) else { throw DefaultLoginError.notFound(id) }
        if let owner = AccountStore.defaultLoginOwner(provider: account.provider, in: accounts, excludingID: id) {
            throw AccountStoreError.defaultLoginTaken(provider: account.provider, accountID: owner.id)
        }

        let verification = probe.verify(provider: account.provider, allowInteraction: allowInteraction)
        audit.append(accountID: id, action: "verify", ok: verification.connected, detail: verification.detail)
        guard verification.connected else {
            throw DefaultLoginError.unavailable(provider: account.provider, detail: verification.detail)
        }
        try Self.checkIdentity(
            provider: account.provider, accountEmail: account.identityEmail, defaultEmail: verification.identityEmail)

        account.loginSource = .providerDefault
        account.status = .connected
        account.identityEmail = verification.identityEmail ?? account.identityEmail
        account.lastVerifiedAt = Date()
        try store.upsert(account)
        audit.append(accountID: id, action: "account.login-source", ok: true,
                     detail: "default login; managed home kept")
        return account
    }

    /// Point an account back at its managed home. Lays the home down first if
    /// it never had one (an account created on the default login), then
    /// re-verifies it: the status becomes whatever that home really is —
    /// usually `expired` or `disconnected`, since an unused managed login is
    /// exactly what started all this — and the user logs it in the usual way.
    @discardableResult
    public func useManagedLogin(_ id: String) throws -> Account {
        guard var account = try store.find(id) else { throw DefaultLoginError.notFound(id) }
        account.loginSource = .managed
        if account.provider == .claude, account.keychainService == nil {
            account.keychainService = KeychainProbe.claudeKeychainService(for: account.homeURL)
        }
        try AccountProvisioner(workspace: workspace, fileManager: fileManager).prepareHome(for: account)

        let home = ManagedHome(url: account.homeURL, provider: account.provider, fileManager: fileManager)
        let result = verifyManaged(account.provider, home)
        audit.append(accountID: id, action: "verify", ok: result.connected, detail: result.detail)
        account.status = result.connected ? .connected : .disconnected
        // `IdentityVerifier` only sees the identity file, which outlives the
        // login: a managed home whose login Claude Code ended (the blanked
        // Keychain item — the very state that sends people to the default
        // login) still has its `oauthAccount`. Read as `connected`, it would
        // rejoin the schedule and the daemon would ping a dead login, so ask
        // the credential itself. Switching back is a user action, hence the
        // interactive read; an unreadable item proves nothing and changes
        // nothing.
        if result.connected, account.provider == .claude, let service = account.keychainService,
           case .signedOut = probe.readClaudeCredential(service, true)
        {
            account.status = .expired
            audit.append(accountID: id, action: "verify", ok: false, detail: "managed keychain: signed out")
        }
        if account.status == .connected {
            account.identityEmail = result.identityEmail ?? account.identityEmail
            account.lastVerifiedAt = Date()
        }
        try store.upsert(account)
        audit.append(accountID: id, action: "account.login-source", ok: true,
                     detail: "managed home (\(account.status.rawValue))")
        return account
    }

    /// Re-check a default-login account (the row's Verify identity): still
    /// connected only while the default credential is usable *and* still the
    /// same person. A default login that was signed in as someone else since
    /// is reported `expired` with the mismatch as the detail — never adopted.
    /// Returns the audit-safe detail line.
    @discardableResult
    public func reverify(_ id: String, allowInteraction: Bool = true) throws -> String {
        guard var account = try store.find(id) else { throw DefaultLoginError.notFound(id) }
        guard account.tracksDefaultLogin else { return "account uses its managed home" }
        let verification = probe.verify(provider: account.provider, allowInteraction: allowInteraction)
        var detail = verification.detail
        var connected = verification.connected
        if connected {
            do {
                try Self.checkIdentity(
                    provider: account.provider, accountEmail: account.identityEmail,
                    defaultEmail: verification.identityEmail)
            } catch {
                connected = false
                detail = "\(error)"
            }
        }
        audit.append(accountID: id, action: "verify", ok: connected, detail: detail)
        account.status = connected ? .connected : .expired
        if connected {
            account.identityEmail = verification.identityEmail ?? account.identityEmail
            account.lastVerifiedAt = Date()
        }
        try store.upsert(account)
        return detail
    }
}
