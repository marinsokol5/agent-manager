import Foundation

// The runtime state behind the cloud anchor routine (Claude only): a claude.ai
// routine — a scheduled cloud agent Anthropic runs — armed as a one-shot at
// each scheduled Claude fire, so the window anchors whether or not this Mac is
// awake for the minute. See `CloudFallbackPlanner` for the decision rules and
// `CloudFallbackEngine` for the API side.
//
// *Whether* to arm one is not stored here: it's Claude's `PingMethod.routine`
// in `preferences.json`, the same file the ping children read, so app, CLI and
// daemon can never disagree about what anchors an account. This file is the
// daemon's *runtime state* (which routine is armed per account, for when) —
// written only by the daemon's engine, so the app/CLI never race it. Same split
// as `scheduler.json` / `scheduler-status.json`.
//
// The `CloudFallback…` names (and the state file's) are historical: the feature
// began as a dead-man's *fallback* armed behind a local ping. That mode is
// retired — the routine is now one of the ping methods rather than a backstop
// for another one — but the names stayed put so an armed routine survives the
// upgrade instead of being orphaned by a renamed state file.

/// One account's slice of `cloud-fallback-state.json`.
///
/// `armedFor` is the routine's `run_once_at` — always a planned fire, and
/// always a **one-shot**: the worst a forgotten routine can ever do (app
/// uninstalled, account removed) is fire once and auto-disable server-side.
/// No field here is a secret.
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
    /// The routine is known to be `enabled: false` (method/scheduler off).
    public var disabled: Bool
    /// Which generation of the routine's *instructions* the live routine holds
    /// (`CloudFallbackEngine.routineRevision`). Re-arming only moves
    /// `run_once_at`, so without this a routine created — or adopted — under an
    /// older build keeps describing behavior the app no longer has, forever.
    /// `nil` means "predates the tracking", which is exactly the case that
    /// needs a rewrite.
    public var routineRevision: Int?
    /// Last API/keychain problem, for the Monitoring row + retry backoff.
    /// Cleared on the next successful sync.
    public var lastError: String?
    public var lastErrorAt: Date?

    public init(
        triggerID: String? = nil,
        environmentID: String? = nil,
        armedFor: Date? = nil,
        disabled: Bool = false,
        routineRevision: Int? = nil,
        lastError: String? = nil,
        lastErrorAt: Date? = nil)
    {
        self.triggerID = triggerID
        self.environmentID = environmentID
        self.armedFor = armedFor
        self.disabled = disabled
        self.routineRevision = routineRevision
        self.lastError = lastError
        self.lastErrorAt = lastErrorAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        triggerID = try c.decodeIfPresent(String.self, forKey: .triggerID)
        environmentID = try c.decodeIfPresent(String.self, forKey: .environmentID)
        armedFor = try c.decodeIfPresent(Date.self, forKey: .armedFor)
        disabled = try c.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        routineRevision = try c.decodeIfPresent(Int.self, forKey: .routineRevision)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        lastErrorAt = try c.decodeIfPresent(Date.self, forKey: .lastErrorAt)
    }
}

/// "Has this account's armed one-shot actually run?" — asked of the routines
/// API, whose `last_fired_at` is the only authority on the question.
///
/// This exists because the clock is *not* an answer. claude.ai dispatches a
/// `run_once_at` routine tens of seconds after its moment, and `run_once_at` is
/// also the server's only handle on that pending run: moving it forward cancels
/// the run. A daemon that assumed "the minute passed, so it ran" therefore
/// deleted the very run it was about to credit, and logged a false anchor for
/// it. Injected (rather than called directly) so the daemon's tests can answer
/// the question without a network.
///
/// `nil` means *could not tell* — never "it didn't run".
public typealias CloudRunConfirmer = @Sendable (String) async -> CloudTrigger?

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
