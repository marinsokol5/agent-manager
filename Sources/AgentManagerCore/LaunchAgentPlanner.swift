import Foundation

// Compile the weekly plan into launchd terms.
//
// There is exactly **one** LaunchAgent — `com.agent-manager.scheduler`, a
// KeepAlive resident daemon (`SchedulerDaemon`) that fires every account's
// pings from an in-process queue. It used to be one calendar job per account,
// but macOS 13+ posts a "background items added" notification every time a
// LaunchAgent is (re)registered, so N per-account jobs meant N notifications on
// every Schedule click. The single agent is registered once and never churned;
// Schedule/Clear only edit the daemon's queue inputs (`scheduler.json`).
//
// The per-account weekly triggers (`CalEntry`) survive as the *plan* currency:
// the daemon resolves them to concrete fire dates (`PingQueuePlanner`), and the
// UI renders them. They keep launchd's `Weekday`/`Hour`/`Minute` convention
// (Sunday = 0) in **local** time — the user picks hours in their own timezone
// and the Mac's local time matches. Day rollover for early pre-pings is handled
// by modular arithmetic in `toCalEntry`.

/// A concrete launchd calendar trigger. `weekday` uses launchd's convention:
/// 0 = Sunday .. 6 = Saturday.
public struct CalEntry: Equatable, Sendable {
    public var weekday: Int
    public var hour: Int
    public var minute: Int
    public init(weekday: Int, hour: Int, minute: Int) {
        self.weekday = weekday
        self.hour = hour
        self.minute = minute
    }
}

public enum LaunchAgentPlanner {
    /// Prefix for every launchd Label / plist filename this app owns.
    public static let labelPrefix = "com.agent-manager."

    /// The one LaunchAgent this app installs: the resident scheduler daemon.
    public static let schedulerLabel = labelPrefix + "scheduler"

    /// Plist filename for the scheduler agent.
    public static let schedulerFilename = schedulerLabel + ".plist"

    /// Map a `(weekdayMon0, atMin)` plan point — where `weekdayMon0` is
    /// 0 = Monday .. 6 = Sunday and `atMin` may be negative (previous day) or
    /// `>= 1440` (next day) — to a launchd `CalEntry`.
    public static func toCalEntry(weekdayMon0: Int, atMin: Int) -> CalEntry {
        let dayShift = floorDiv(atMin, 1440)
        let minuteOfDay = atMin - dayShift * 1440
        let wdMon0 = floorMod(weekdayMon0 + dayShift, 7)
        // Mon0 (0=Mon..6=Sun) -> launchd (0=Sun..6=Sat): Mon->1, .., Sat->6, Sun->0.
        let launchdWd = (wdMon0 + 1) % 7
        return CalEntry(weekday: launchdWd, hour: minuteOfDay / 60, minute: minuteOfDay % 60)
    }

    /// All launchd calendar entries for one account across the whole week, in
    /// chronological order (Mon→Sun, earliest first within a day). `accountIDs`
    /// is the rank-ordered set of *all* scheduled accounts (the stagger depends on
    /// the full set), `accountID` is the one we want entries for.
    public static func entries(forAccountID accountID: String, accountIDs: [String], schedule: WorkSchedule) -> [CalEntry] {
        var entries: [CalEntry] = []
        let parallelism = schedule.resolvedParallelism(accountCount: accountIDs.count)
        for wd in 0..<7 {
            let blocks = schedule.blocks(forWeekday: wd)
            let dayPlan = ScheduleEngine.planDay(forAccountIDs: accountIDs, workBlocks: blocks, window: schedule.windowMinutes, parallelism: parallelism)
            if let plan = dayPlan.accounts.first(where: { $0.accountID == accountID }) {
                for p in plan.pings {
                    entries.append(toCalEntry(weekdayMon0: wd, atMin: p.atMin))
                }
            }
        }
        return entries
    }

    /// Render the one `com.agent-manager.scheduler.plist` this app installs: a
    /// `KeepAlive` agent running `am scheduler run --root <root>` — the resident
    /// daemon that fires all scheduled pings itself.
    ///
    /// This plist must stay **byte-stable across applies**: `Scheduler.apply`
    /// rewrites/re-bootstraps it only when this rendering differs from what's on
    /// disk, because any launchd (re)registration makes macOS re-notify
    /// "background items added". Everything schedule-shaped therefore lives in
    /// the workspace files the daemon watches, never in here; the plist changes
    /// only when the `am` path or the baked environment does.
    ///
    /// `environment` is baked into `EnvironmentVariables` so the daemon (and the
    /// ping children it spawns) inherit a usable `PATH` + any provider binary
    /// override (launchd otherwise passes an almost-empty env).
    public static func renderSchedulerAgentPlist(
        program: String,
        root: String,
        logDir: String,
        environment: [String: String] = [:])
        -> String
    {
        var programArgs = ""
        for a in [program, "scheduler", "run", "--root", root] {
            programArgs += "    <string>\(xmlEscape(a))</string>\n"
        }

        var envBlock = ""
        let env = environment.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        if !env.isEmpty {
            envBlock = "  <key>EnvironmentVariables</key>\n  <dict>\n"
            for key in env.keys.sorted() {
                envBlock += "    <key>\(xmlEscape(key))</key><string>\(xmlEscape(env[key]!))</string>\n"
            }
            envBlock += "  </dict>\n"
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>\(schedulerLabel)</string>
          <key>ProgramArguments</key>
          <array>
        \(programArgs)  </array>
        \(envBlock)  <key>RunAtLoad</key>
          <true/>
          <key>KeepAlive</key>
          <true/>
          <key>StandardOutPath</key>
          <string>\(logDir)/scheduler.out.log</string>
          <key>StandardErrorPath</key>
          <string>\(logDir)/scheduler.err.log</string>
          <key>ProcessType</key>
          <string>Background</string>
        </dict>
        </plist>

        """
    }

}

/// Floored integer division (matches Rust's `div_euclid` for our positive divisor).
private func floorDiv(_ a: Int, _ b: Int) -> Int {
    Int(floor(Double(a) / Double(b)))
}

/// Floored modulo in `0..<b` (matches Rust's `rem_euclid` for positive `b`).
private func floorMod(_ a: Int, _ b: Int) -> Int {
    let r = a % b
    return r < 0 ? r + b : r
}

// Internal (not private): the wake-helper installer renders its LaunchDaemon
// plist with the same escaping.
func xmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}
