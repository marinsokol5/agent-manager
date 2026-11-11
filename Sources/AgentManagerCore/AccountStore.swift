import Foundation

/// On-disk shape of `accounts.json`.
public struct AccountSet: Codable, Sendable {
    public var version: Int
    public var accounts: [Account]

    public init(version: Int, accounts: [Account]) {
        self.version = version
        self.accounts = accounts
    }
}

public enum AccountStoreError: Error, Equatable, CustomStringConvertible {
    case unsupportedVersion(Int)
    case duplicateID(String)
    /// Another account of `provider` already tracks the default login
    /// (`AccountLoginSource.providerDefault`). One per provider: there is only
    /// one default login, and two accounts over it would double-count it in
    /// every usage surface and make "which account is my desktop app?" a
    /// question with two answers.
    case defaultLoginTaken(provider: Provider, accountID: String)

    public var description: String {
        switch self {
        case let .unsupportedVersion(v): "accounts.json has unsupported version \(v)"
        case let .duplicateID(id): "an account with id '\(id)' already exists"
        case let .defaultLoginTaken(provider, accountID):
            "'\(accountID)' already uses your default \(provider.displayName) login — only one account per provider can"
        }
    }
}

/// Reads and writes the account inventory as pretty JSON. Atomic writes; the
/// file is created on first save. No tokens are ever stored here — only the
/// account model (identity *email* is fine; secrets stay in Keychain/`auth.json`).
public struct AccountStore {
    public static let currentVersion = 1

    let fileURL: URL
    let fileManager: FileManager

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public init(workspace: Workspace, fileManager: FileManager = .default) {
        self.init(fileURL: workspace.accountsFile, fileManager: fileManager)
    }

    public func load() throws -> [Account] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let set = try decoder.decode(AccountSet.self, from: data)
        guard set.version == Self.currentVersion else {
            throw AccountStoreError.unsupportedVersion(set.version)
        }
        return set.accounts
    }

    public func save(_ accounts: [Account]) throws {
        let set = AccountSet(version: Self.currentVersion, accounts: accounts)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(set)
        let dir = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try data.write(to: fileURL, options: [.atomic])
    }

    /// The account (other than `excludingID`) that already tracks `provider`'s
    /// default login, if any. Pure, so the UI can grey out the option with the
    /// same rule the store enforces.
    public static func defaultLoginOwner(
        provider: Provider, in accounts: [Account], excludingID: String? = nil) -> Account?
    {
        accounts.first { $0.provider == provider && $0.tracksDefaultLogin && $0.id != excludingID }
    }

    /// The store-level guard behind one-default-login-per-provider: every write
    /// of a single account (`insert` / `upsert`) goes through it, so no flow —
    /// app, CLI, or a future one — can persist a second one. `save` is left
    /// unchecked on purpose: it rewrites the whole inventory (reorder, rank
    /// normalization) and must keep working on a hand-edited file.
    static func checkDefaultLogin(_ account: Account, against accounts: [Account]) throws {
        guard account.tracksDefaultLogin,
              let owner = defaultLoginOwner(provider: account.provider, in: accounts, excludingID: account.id)
        else { return }
        throw AccountStoreError.defaultLoginTaken(provider: account.provider, accountID: owner.id)
    }

    /// Insert or replace an account by id, preserving the order of the rest.
    public func upsert(_ account: Account) throws {
        var accounts = try load()
        try Self.checkDefaultLogin(account, against: accounts)
        if let idx = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[idx] = account
        } else {
            accounts.append(account)
        }
        try save(accounts)
    }

    /// Insert a brand-new account; throws if the id is already taken.
    public func insert(_ account: Account) throws {
        var accounts = try load()
        guard !accounts.contains(where: { $0.id == account.id }) else {
            throw AccountStoreError.duplicateID(account.id)
        }
        try Self.checkDefaultLogin(account, against: accounts)
        accounts.append(account)
        try save(accounts)
    }

    public func find(_ id: String) throws -> Account? {
        try load().first { $0.id == id }
    }

    public func remove(_ id: String) throws {
        var accounts = try load()
        accounts.removeAll { $0.id == id }
        try save(accounts)
    }
}
