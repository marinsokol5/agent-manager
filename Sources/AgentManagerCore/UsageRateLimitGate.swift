import Foundation

/// Per-account "don't hit the usage API again until" gate, persisted to disk.
///
/// This is the safeguard that was missing when we got rate-limited: a 429 (or a
/// `Retry-After`) records a block for *that account*, and the block is honored
/// across refreshes and — because it's on disk — across app relaunches. Without
/// it, every relaunch wiped the in-memory throttle and re-hammered the endpoint.
///
/// An `actor` so concurrent per-account fetches serialize their read-modify-write
/// of the backing file. A successful fetch clears the account's block. A user-
/// initiated refresh may bypass the gate (the caller decides), but a network 429
/// will immediately re-arm it.
public actor UsageRateLimitGate {
    /// Fallback block when the server doesn't send a usable `Retry-After`.
    public static let defaultCooldown: TimeInterval = 60 * 5

    private let fileURL: URL
    private let fileManager: FileManager
    private var blocked: [String: Date]?

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public init(workspace: Workspace, fileManager: FileManager = .default) {
        self.init(fileURL: workspace.usageRateLimitFile, fileManager: fileManager)
    }

    /// The instant `accountID` is allowed to call the usage API again, or `nil`
    /// if it isn't currently blocked. Expired entries are pruned on read.
    public func blockedUntil(accountID: String, now: Date = Date()) -> Date? {
        loadIfNeeded()
        guard let until = blocked?[accountID] else { return nil }
        if until > now { return until }
        blocked?[accountID] = nil
        persist()
        return nil
    }

    /// Record a rate limit for `accountID`: block until `retryAfter` if it's in
    /// the future, otherwise for `defaultCooldown`. Returns the effective block
    /// instant so callers can surface the *real* backoff — the server often sends
    /// `Retry-After: 0`, so the raw header is useless for telling the user when
    /// we'll actually retry.
    @discardableResult
    public func recordRateLimit(accountID: String, retryAfter: Date?, now: Date = Date()) -> Date {
        loadIfNeeded()
        let until: Date = if let retryAfter, retryAfter > now {
            retryAfter
        } else {
            now.addingTimeInterval(Self.defaultCooldown)
        }
        blocked?[accountID] = until
        persist()
        return until
    }

    /// Clear any block for `accountID` after a successful fetch.
    public func recordSuccess(accountID: String) {
        loadIfNeeded()
        guard blocked?[accountID] != nil else { return }
        blocked?[accountID] = nil
        persist()
    }

    // MARK: - Persistence

    private func loadIfNeeded() {
        guard blocked == nil else { return }
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL)
        else { blocked = [:]; return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        blocked = (try? decoder.decode([String: Date].self, from: data)) ?? [:]
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(blocked ?? [:]) else { return }
        let dir = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try? data.write(to: fileURL, options: [.atomic])
    }
}
