import Foundation

// The two small state files behind the app's "Scheduler active" toggle.
//
// The whole point of the single-agent design is that the toggle **never
// touches launchd** after the agent is installed once — churning launchd jobs
// makes macOS re-notify "background items added" on every registration.
// Instead the toggle writes `scheduler.json` (the active flag, below) and the
// resident daemon picks the change up on its next tick. The daemon in turn
// writes `scheduler-status.json` so the app can show live ground truth (is the
// daemon actually running, what will it fire next) without asking launchd.

/// `scheduler.json` — the operator's intent: should the resident daemon fire the
/// painted schedule? Written by the Scheduler toggle (on = active); read by the
/// daemon every tick. The painted calendar itself stays in `schedule.json`, so
/// toggling off keeps the calendar and toggling back on restores it — same
/// contract as the old per-account jobs.
public struct SchedulerConfig: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var active: Bool

    public init(version: Int = SchedulerConfig.currentVersion, active: Bool = false) {
        self.version = version
        self.active = active
    }
}

/// Reads/writes `scheduler.json`. Forgiving load (missing/corrupt → inactive —
/// the daemon must never fire on state it can't read), atomic save.
public struct SchedulerConfigStore {
    let fileURL: URL
    let fileManager: FileManager

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public init(workspace: Workspace, fileManager: FileManager = .default) {
        self.init(fileURL: workspace.schedulerConfigFile, fileManager: fileManager)
    }

    public func load() -> SchedulerConfig {
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let config = try? JSONDecoder().decode(SchedulerConfig.self, from: data)
        else { return SchedulerConfig() }
        return config
    }

    public func save(_ config: SchedulerConfig) throws {
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

/// A queue entry durably marked as running, but not yet resolved into the
/// `lastHandled` watermark.
///
/// Keeping this separate is what lets a child report "window still open"
/// without a crash window that permanently consumes its nominal slot. If the
/// daemon dies mid-child, the next incarnation either recovers exact evidence
/// that the window predated the attempt (leave the slot pending) or resolves
/// the abandoned attempt conservatively (advance it, preserving the older
/// no-double-fire guarantee).
public struct SchedulerInFlight: Codable, Sendable, Equatable {
    public var accountID: String
    public var nominalFireAt: Date
    public var effectiveFireAt: Date
    public var startedAt: Date
    /// The rolling-window length used by this attempt. Persist it because the
    /// user can repaint/change planner knobs while the child is running.
    public var windowSeconds: TimeInterval

    public init(
        accountID: String,
        nominalFireAt: Date,
        effectiveFireAt: Date,
        startedAt: Date,
        windowSeconds: TimeInterval)
    {
        self.accountID = accountID
        self.nominalFireAt = nominalFireAt
        self.effectiveFireAt = effectiveFireAt
        self.startedAt = startedAt
        self.windowSeconds = windowSeconds
    }
}

/// `scheduler-status.json` — the daemon's heartbeat + introspection snapshot,
/// rewritten on every tick. This is how the app answers "is the background
/// scheduler actually alive and what happens next" without polling launchd, and
/// how a restarted daemon remembers what it already fired (`lastHandled` /
/// `horizonFloor`) so it never double-pings or dredges up entries from before it
/// was activated.
public struct SchedulerDaemonStatus: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var pid: Int32
    public var startedAt: Date
    /// Heartbeat: bumped every tick; staleness beyond a couple of poll intervals
    /// means the daemon is loaded-but-dead (or unloaded).
    public var updatedAt: Date
    public var active: Bool
    /// The next planned fires (capped — enough for any UI), earliest first.
    public var upcoming: [QueueEntry]
    /// Per account, the fire time of the last queue entry the daemon *handled*
    /// (fired or deliberately dropped as stale). Queue rebuilds exclude anything
    /// at/before this, which is what makes rebuild-every-tick idempotent and a
    /// daemon restart double-fire-safe. A running child lives in `inFlight`
    /// until its outcome is known; its slot is not advanced here early.
    public var lastHandled: [String: Date]
    /// Entries scheduled before this are out of scope entirely (set to
    /// "activation time − grace" whenever the daemon starts fresh or the
    /// scheduler is toggled back on), so a long-inactive schedule never floods
    /// the log with drops.
    public var horizonFloor: Date
    /// Set while a ping child is in flight, for "pinging <id>…" display.
    /// Kept for the compact UI/readers; `inFlight` carries the durable identity.
    public var currentAccountID: String?
    /// The durable identity of that child attempt. Unlike `lastHandled`, this
    /// does not consume the slot before the child outcome is known.
    public var inFlight: SchedulerInFlight?
    /// Per account, the best-known exact or event-derived expiry of the current
    /// window — what runtime deferral (`RuntimeAnchorPolicy`) schedules around.
    /// Persisted so a daemon restart reconstructs the same deferral instead of
    /// re-firing a phantom into a window it just anchored. Optional so status
    /// files written before this field decode unchanged.
    public var windowStates: [String: AccountWindowState]?
    /// Per account, the latest effective local-fire time whose cloud backstop
    /// is resolved: a verified local anchor, a passed cloud one-shot, or a slot
    /// already covered by a known window. Persisting this prevents a daemon
    /// restart between local resolution and API re-arm from letting the old
    /// one-shot fire redundantly.
    public var lastResolvedFire: [String: Date]?

    public init(
        version: Int = SchedulerDaemonStatus.currentVersion,
        pid: Int32,
        startedAt: Date,
        updatedAt: Date,
        active: Bool,
        upcoming: [QueueEntry],
        lastHandled: [String: Date],
        horizonFloor: Date,
        currentAccountID: String? = nil,
        inFlight: SchedulerInFlight? = nil,
        windowStates: [String: AccountWindowState]? = nil,
        lastResolvedFire: [String: Date]? = nil)
    {
        self.version = version
        self.pid = pid
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.active = active
        self.upcoming = upcoming
        self.lastHandled = lastHandled
        self.horizonFloor = horizonFloor
        self.currentAccountID = currentAccountID
        self.inFlight = inFlight
        self.windowStates = windowStates
        self.lastResolvedFire = lastResolvedFire
    }

    /// Whether the heartbeat is recent enough to call the daemon alive.
    /// `tolerance` defaults to a few poll intervals so one slow tick (a ping in
    /// flight bumps the heartbeat before and after, but a long turn can stretch
    /// a gap) doesn't read as dead.
    public func isFresh(asOf now: Date, tolerance: TimeInterval = 180) -> Bool {
        now.timeIntervalSince(updatedAt) <= tolerance
    }
}

/// Reads/writes `scheduler-status.json` with ISO-8601 dates (matches the JSONL
/// logs, and keeps the file human-readable for debugging). Load is forgiving —
/// a missing/corrupt status just reads as "no daemon has reported yet".
public struct SchedulerStatusStore {
    let fileURL: URL
    let fileManager: FileManager

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public init(workspace: Workspace, fileManager: FileManager = .default) {
        self.init(fileURL: workspace.schedulerStatusFile, fileManager: fileManager)
    }

    public func load() -> SchedulerDaemonStatus? {
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL)
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SchedulerDaemonStatus.self, from: data)
    }

    /// Best-effort, like the logs: a failed status write must never break the
    /// scheduling flow it describes.
    public func save(_ status: SchedulerDaemonStatus) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(status) else { return }
        let dir = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try? data.write(to: fileURL, options: [.atomic])
    }
}
