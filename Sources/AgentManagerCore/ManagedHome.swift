import Foundation

/// A managed, isolated config home for one account — the directory pointed at by
/// `CLAUDE_CONFIG_DIR`. Creating it and injecting its env var is all that's
/// needed for the CLI to treat it as a separate, independently-anchored account.
public struct ManagedHome {
    public let url: URL
    public let provider: Provider
    let fileManager: FileManager

    public init(url: URL, provider: Provider, fileManager: FileManager = .default) {
        self.url = url
        self.provider = provider
        self.fileManager = fileManager
    }

    /// The per-account identity file (`<home>/.claude.json`) — kept real, never
    /// symlinked. Written by the guided login.
    public var identityFileURL: URL {
        url.appendingPathComponent(provider.identityFileName)
    }

    /// Create the home directory if missing, with owner-only (0700) permissions
    /// since it sits next to credential-bearing state.
    @discardableResult
    public func create() throws -> URL {
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        return url
    }

    /// Return `base` with this home's isolation env var injected, so a spawned
    /// CLI runs *as this account*.
    public func injecting(into base: [String: String]) -> [String: String] {
        var env = base
        env[provider.configHomeEnvKey] = url.path
        return env
    }
}
