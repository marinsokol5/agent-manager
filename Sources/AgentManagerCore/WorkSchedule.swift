import Foundation

/// The painted weekly work-hour selection that drives the planner.
///
/// `hoursByWeekday[d]` is the set of selected work hours (0...23) for weekday
/// `d`, where **index 0 = Monday .. 6 = Sunday** — the same convention as the
/// engine's launchd mapping. Accounts live separately in `accounts.json`
/// (`AccountStore`); this file holds only the calendar + window length so the two
/// surfaces (App grid + CLI) edit one thing each.
public struct WorkSchedule: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    /// Rolling-window length in minutes (default 300 = 5h).
    public var windowMinutes: Int
    /// Selected work hours per weekday; index 0 = Monday .. 6 = Sunday.
    public var hoursByWeekday: [[Int]]
    /// How many accounts the user wants live **at the same time** (parallel
    /// lanes). `nil` = auto: every account in its own lane (max parallelism, the
    /// default). The engine partitions accounts into this many lanes, serially
    /// rotates the accounts *within* a lane (today's stagger), and runs the lanes
    /// in parallel — so a smaller number rests spare accounts while keeping N hot.
    /// Optional so old `schedule.json` files (which lack the key) decode to `nil`.
    public var parallelism: Int?
    /// The engine's budget-slice floor (minutes): the shortest usable in-block
    /// stretch a scheduled token budget is worth anchoring a ping for. `nil` =
    /// the default (`defaultMinSliceMinutes`, 1h). Raising it trades budget
    /// *count* for usable budget *length* — the planner stops pre-pinging for
    /// edge slivers shorter than this and rebalances each block into fewer,
    /// longer slices (a 6h day at 60+ becomes 3h + 3h on two pings instead of
    /// 30m + 5h + 30m on three). Optional so old `schedule.json` files (which
    /// lack the key) decode to `nil`.
    public var minSliceMinutes: Int?

    public init(
        version: Int = WorkSchedule.currentVersion,
        windowMinutes: Int = defaultWindowMinutes,
        hoursByWeekday: [[Int]] = Array(repeating: [], count: 7),
        parallelism: Int? = nil,
        minSliceMinutes: Int? = nil)
    {
        self.version = version
        self.windowMinutes = windowMinutes
        self.parallelism = parallelism
        self.minSliceMinutes = minSliceMinutes
        // Defend against a short/long array sneaking in from hand-edited JSON.
        var days = hoursByWeekday
        while days.count < 7 { days.append([]) }
        if days.count > 7 { days = Array(days.prefix(7)) }
        self.hoursByWeekday = days
    }

    /// Resolve the configured parallelism against the live account count: `nil`
    /// (auto) → all accounts in parallel (max), otherwise clamped to
    /// `1...accountCount`. Always ≥ 1 so there is at least one lane to plan.
    public func resolvedParallelism(accountCount: Int) -> Int {
        let cap = max(accountCount, 1)
        return min(max(parallelism ?? cap, 1), cap)
    }

    /// Resolve the configured budget-slice floor for the engine: the stored
    /// preference clamped into `minSliceFloorMinutes...windowMinutes` (below
    /// 15 min a "budget" stops being one; above one window nothing could ever
    /// satisfy it). `nil` — the default — resolves to `defaultMinSliceMinutes`.
    public var resolvedMinSliceMinutes: Int {
        let cap = max(windowMinutes, minSliceFloorMinutes)
        return min(max(minSliceMinutes ?? defaultMinSliceMinutes, minSliceFloorMinutes), cap)
    }

    /// Weekday labels, index 0 = Monday.
    public static let weekdayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    /// Normalized (sorted, unique, in-range) selected hours for weekday `d`.
    public func hours(forWeekday d: Int) -> [Int] {
        guard hoursByWeekday.indices.contains(d) else { return [] }
        return Array(Set(hoursByWeekday[d].filter { $0 >= 0 && $0 < 24 })).sorted()
    }

    /// Work blocks for weekday `d`, ready for the engine.
    public func blocks(forWeekday d: Int) -> [Block] {
        ScheduleEngine.slotsToBlocks(hours(forWeekday: d))
    }

    /// Toggle one hour on weekday `d`, keeping the day's list normalized.
    public mutating func toggle(weekday d: Int, hour: Int) {
        guard hoursByWeekday.indices.contains(d), (0..<24).contains(hour) else { return }
        var set = Set(hoursByWeekday[d])
        if set.contains(hour) { set.remove(hour) } else { set.insert(hour) }
        hoursByWeekday[d] = set.sorted()
    }

    /// Set weekday `d` to exactly `hours`.
    public mutating func set(weekday d: Int, hours: [Int]) {
        guard hoursByWeekday.indices.contains(d) else { return }
        hoursByWeekday[d] = Array(Set(hours.filter { $0 >= 0 && $0 < 24 })).sorted()
    }

    /// Copy Monday's selection onto Tue–Fri (the "copy Mon→weekdays" helper).
    public mutating func copyMondayToWeekdays() {
        let mon = hoursByWeekday[0]
        for d in 1..<5 { hoursByWeekday[d] = mon }
    }

    /// Clear every day.
    public mutating func clearAll() {
        hoursByWeekday = Array(repeating: [], count: 7)
    }

    /// Total selected hours across the week (drives "N hrs/week" summaries).
    public var totalSelectedHours: Int {
        (0..<7).reduce(0) { $0 + hours(forWeekday: $1).count }
    }
}

/// Reads and writes `schedule.json` as pretty JSON, atomically. Mirrors
/// `AccountStore` so the App and CLI share one on-disk representation.
public struct ScheduleStore {
    let fileURL: URL
    let fileManager: FileManager

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public init(workspace: Workspace, fileManager: FileManager = .default) {
        self.init(fileURL: workspace.scheduleFile, fileManager: fileManager)
    }

    /// Load the schedule, or a fresh empty one if no file exists yet.
    public func load() throws -> WorkSchedule {
        guard fileManager.fileExists(atPath: fileURL.path) else { return WorkSchedule() }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(WorkSchedule.self, from: data)
    }

    public func save(_ schedule: WorkSchedule) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(schedule)
        let dir = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try data.write(to: fileURL, options: [.atomic])
    }
}
