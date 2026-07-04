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

    public var description: String {
        switch self {
        case let .unsupportedVersion(v): "accounts.json has unsupported version \(v)"
        case let .duplicateID(id): "an account with id '\(id)' already exists"
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

    /// Insert or replace an account by id, preserving the order of the rest.
    public func upsert(_ account: Account) throws {
        var accounts = try load()
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
