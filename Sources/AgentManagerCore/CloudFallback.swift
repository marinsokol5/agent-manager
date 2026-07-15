import Foundation

// The two on-disk files behind the experimental "cloud fallback" feature
// (Claude only): a claude.ai routine — a scheduled cloud agent Anthropic runs —
// armed as a dead-man's switch five minutes after each scheduled local ping.
// A successful local ping re-arms the routine forward, so the cloud runs *only*
// when the Mac provably couldn't ping (asleep on battery with the lid closed,
// where RTC wakes are firmware-blocked). See `CloudFallbackPlanner` for the
// decision rules and `CloudFallbackEngine` for the API side.
//
// Same split as `scheduler.json` / `scheduler-status.json`:
// - `cloud-fallback.json` is the operator's *intent* (the Preferences toggle),
//   written by the app / `am cloud enable|disable`, read by the daemon each tick.
// - `cloud-fallback-state.json` is the daemon's *runtime state* (which routine
//   is armed per account, for when) — written only by the daemon's engine, so
//   the two writers never race one file.

/// `cloud-fallback.json` — should the daemon keep cloud anchor routines armed?
public struct CloudFallbackConfig: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var enabled: Bool
    /// Promote the claude.ai routine from a dead-man's-switch *backstop* to the
    /// *only* anchor for Claude accounts: the daemon arms it at each planned
    /// fire (no `+lead`) and never spawns a local Claude ping — the reverse of
    /// the fallback default, for a Mac that can't be trusted to ping reliably
    /// (chronic sleep races). Codex accounts are unaffected (they have no cloud
    /// routine and keep pinging locally). Meaningless unless `enabled` — a
    /// fallback you don't run can't be the primary. Off by default.
    public var cloudPrimary: Bool

    public init(
        version: Int = CloudFallbackConfig.currentVersion,
        enabled: Bool = false,
        cloudPrimary: Bool = false)
    {
        self.version = version
        self.enabled = enabled
        self.cloudPrimary = cloudPrimary
    }

    private enum CodingKeys: String, CodingKey { case version, enabled, cloudPrimary }

    /// Forgiving decode so a `cloud-fallback.json` written before `cloudPrimary`
    /// existed still loads (and keeps `enabled` on) instead of failing the
    /// whole file and silently reverting to disabled on upgrade.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? CloudFallbackConfig.currentVersion
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        cloudPrimary = try c.decodeIfPresent(Bool.self, forKey: .cloudPrimary) ?? false
    }
}

/// Reads/writes `cloud-fallback.json`. Forgiving load (missing/corrupt →
/// disabled — never arm cloud runs on state we can't read), atomic save.
public struct CloudFallbackConfigStore {
    let fileURL: URL
    let fileManager: FileManager

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public init(workspace: Workspace, fileManager: FileManager = .default) {
        self.init(fileURL: workspace.cloudFallbackConfigFile, fileManager: fileManager)
    }

    public func load() -> CloudFallbackConfig {
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let config = try? JSONDecoder().decode(CloudFallbackConfig.self, from: data)
        else { return CloudFallbackConfig() }
        return config
    }

    public func save(_ config: CloudFallbackConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        let dir = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try data.write(to: fileURL, options: [.atomic])
    }
}

/// One account's slice of `cloud-fallback-state.json`.
///
/// `armedFor` is the routine's `run_once_at` — always "some local fire + the
/// planner's lead", and always a **one-shot**: the worst a forgotten routine
/// can ever do (app uninstalled, account removed) is fire once and
/// auto-disable server-side. No field here is a secret.
public struct AccountCloudFallbackState: Codable, Sendable, Equatable {
    /// The claude.ai routine (`trig_…`) this account owns, created lazily on
    /// first arm and reused (re-armed) forever after. `nil` until then, or
    /// after a 404 told us the user deleted it on the web.
    public var triggerID: String?
    /// The org's cloud environment (`env_…`) routines must reference,
    /// discovered once (or created) and cached — it never changes for an org.
    public var environmentID: String?
    /// When the armed one-shot fires (UTC). `nil` = nothing armed.
    public var armedFor: Date?
    /// The routine is known to be `enabled: false` (feature/scheduler off).
    public var disabled: Bool
    /// Last API/keychain problem, for the Monitoring row + retry backoff.
    /// Cleared on the next successful sync.
    public var lastError: String?
    public var lastErrorAt: Date?

    public init(
        triggerID: String? = nil,
        environmentID: String? = nil,
        armedFor: Date? = nil,
        disabled: Bool = false,
        lastError: String? = nil,
        lastErrorAt: Date? = nil)
    {
        self.triggerID = triggerID
        self.environmentID = environmentID
        self.armedFor = armedFor
        self.disabled = disabled
        self.lastError = lastError
        self.lastErrorAt = lastErrorAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        triggerID = try c.decodeIfPresent(String.self, forKey: .triggerID)
        environmentID = try c.decodeIfPresent(String.self, forKey: .environmentID)
        armedFor = try c.decodeIfPresent(Date.self, forKey: .armedFor)
        disabled = try c.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        lastErrorAt = try c.decodeIfPresent(Date.self, forKey: .lastErrorAt)
    }
}

/// `cloud-fallback-state.json` — per-account routine state, keyed by account id.
public struct CloudFallbackState: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var accounts: [String: AccountCloudFallbackState]

    public init(
        version: Int = CloudFallbackState.currentVersion,
        accounts: [String: AccountCloudFallbackState] = [:])
    {
        self.version = version
        self.accounts = accounts
    }
}

/// Reads/writes `cloud-fallback-state.json` with ISO-8601 dates (human-readable,
/// like the heartbeat). Forgiving load — missing/corrupt reads as "nothing
/// armed", which fails safe: the engine just re-arms or recreates as needed.
public struct CloudFallbackStateStore {
    let fileURL: URL
    let fileManager: FileManager

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public init(workspace: Workspace, fileManager: FileManager = .default) {
        self.init(fileURL: workspace.cloudFallbackStateFile, fileManager: fileManager)
    }

    public func load() -> CloudFallbackState {
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL)
        else { return CloudFallbackState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(CloudFallbackState.self, from: data)) ?? CloudFallbackState()
    }

    /// Best-effort, like the heartbeat: a failed state write must never break
    /// the scheduling flow it describes (the next sync self-heals).
    public func save(_ state: CloudFallbackState) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        let dir = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try? data.write(to: fileURL, options: [.atomic])
    }
}
