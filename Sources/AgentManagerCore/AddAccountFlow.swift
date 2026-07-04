import Foundation

/// Orchestrates user journey 1 — *add an account* — end to end:
///
/// 1. create the managed home and point `CLAUDE_CONFIG_DIR` at it;
/// 2. symlink-farm the static config from the source home (identity kept real);
/// 3. guided login over a PTY (capture URL → browser → wait for success);
/// 4. verify identity and drive `disconnected → connecting → connected/expired`.
///
/// Every step is appended to the audit log (never tokens). The flow persists a
/// `connecting` account up front so it's visible while login is in progress, and
/// returns the account in whatever terminal state it reached.
public struct AddAccountFlow {
    public struct Options: Sendable {
        public var id: String
        public var label: String
        public var color: String
        public var provider: Provider
        /// Defaults to `provider.defaultSourceHome` (`~/.claude`).
        public var sourceHome: URL?
        public var rank: Int?
        public var reservedHours: Double?
        public var loginTimeout: TimeInterval
        public var openBrowser: Bool

        public init(
            id: String,
            label: String,
            color: String = "#7C7CFF",
            provider: Provider = .claude,
            sourceHome: URL? = nil,
            rank: Int? = nil,
            reservedHours: Double? = nil,
            loginTimeout: TimeInterval = 180,
            openBrowser: Bool = true)
        {
            self.id = id
            self.label = label
            self.color = color
            self.provider = provider
            self.sourceHome = sourceHome
            self.rank = rank
            self.reservedHours = reservedHours
            self.loginTimeout = loginTimeout
            self.openBrowser = openBrowser
        }
    }

    public enum Event: Sendable {
        case status(String)
        case symlinkReport(String)
        case authURLReady(String)
        case browserOpened(String)
        case verified(connected: Bool, detail: String)
    }

    public enum FlowError: Error, CustomStringConvertible {
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
    public func run(_ options: Options, onEvent: @escaping (Event) -> Void) throws -> Account {
        // 1–2. Create the account (managed home + symlink farm), persisted
        // logged-out. Add is independent of login.
        let provisioner = AccountProvisioner(workspace: workspace, fileManager: fileManager)
        var account: Account
        do {
            account = try provisioner.create(AccountProvisioner.Options(
                id: options.id,
                label: options.label,
                color: options.color,
                provider: options.provider,
                sourceHome: options.sourceHome,
                rank: options.rank,
                reservedHours: options.reservedHours))
        } catch let AccountProvisioner.ProvisionError.invalidID(message) {
            throw FlowError.invalidID(message)
        } catch AccountProvisioner.ProvisionError.duplicate {
            throw FlowError.duplicate(options.id)
        } catch let AccountProvisioner.ProvisionError.homeCreationFailed(message) {
            throw FlowError.homeCreationFailed(message)
        }
        onEvent(.status("managed home ready at \(account.home)"))

        let home = ManagedHome(url: account.homeURL, provider: options.provider, fileManager: fileManager)
        account.status = .connecting
        try store.upsert(account)

        // 3. Keychain baseline + guided login.
        let baseline: Set<String> = options.provider.keychainServicePrefix.map {
            KeychainProbe.genericPasswordServices(prefix: $0)
        } ?? []
        audit.append(accountID: options.id, action: "login.start", ok: true, detail: "timeout=\(Int(options.loginTimeout))s")

        let login = GuidedLogin(provider: options.provider, home: home).run(
            timeout: options.loginTimeout,
            openBrowser: options.openBrowser,
            onEvent: { event in
                switch event {
                case .launching:
                    onEvent(.status("launching \(options.provider.cliBinaryName) /login…"))
                case let .authURLReady(url):
                    audit.append(accountID: options.id, action: "login.url", ok: true, detail: url)
                    onEvent(.authURLReady(url))
                case let .browserOpened(url):
                    onEvent(.browserOpened(url))
                }
            })

        writeTranscript(login.transcript, accountID: options.id)
        audit.append(accountID: options.id, action: "login.result", ok: login.succeeded, detail: login.detail)

        // 4. Verify identity → state machine.
        let verification = IdentityVerifier.verify(provider: options.provider, home: home, keychainBaseline: baseline)
        audit.append(accountID: options.id, action: "verify", ok: verification.connected, detail: verification.detail)
        onEvent(.verified(connected: verification.connected, detail: verification.detail))

        if verification.connected {
            account.status = .connected
            account.identityEmail = verification.identityEmail
            account.lastVerifiedAt = Date()
        } else if login.succeeded {
            // Login claimed success but identity didn't verify → needs re-connect.
            account.status = .expired
        } else {
            account.status = .disconnected
        }
        try store.upsert(account)
        return account
    }

    /// Persist the raw login transcript for debugging (`logs/<id>-login.log`).
    /// It can contain the auth URL but never the OAuth token (the CLI doesn't
    /// print it).
    private func writeTranscript(_ transcript: String, accountID: String) {
        let logsDir = workspace.root.appendingPathComponent("logs", isDirectory: true)
        try? fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let url = logsDir.appendingPathComponent("\(accountID)-login.log")
        try? transcript.data(using: .utf8)?.write(to: url, options: [.atomic])
    }
}
