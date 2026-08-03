import Foundation

/// How clock times are rendered, everywhere the app or the `am` CLI shows one.
/// Every absolute-time display goes through one of these helpers (kept here,
/// not in views) so the GUI and CLI can never disagree on a timestamp.
public enum ClockStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    /// 12-hour clock with am/pm — "4:00pm". Round hours drop the minutes ("4pm").
    case twelveHour
    /// 24-hour clock — "16:00".
    case twentyFourHour

    public var id: String { rawValue }

    /// Renders just the time-of-day, e.g. "4:00pm" / "16:00".
    public func timeString(_ date: Date, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let roundHour = cal.component(.minute, from: date) == 0

        switch self {
        case .twelveHour:
            return Self.formatter(roundHour ? "ha" : "h:mma", timeZone).string(from: date).lowercased()
        case .twentyFourHour:
            return Self.formatter("HH:mm", timeZone).string(from: date)
        }
    }

    /// Time-of-day with seconds — "4:13:42pm" / "16:13:42" — for the live wall
    /// clock, log stamps, and RTC wake times where the exact second matters.
    /// Unlike `timeString`, round hours keep their minutes and seconds so a
    /// ticking clock never changes shape mid-minute.
    public func preciseTimeString(_ date: Date, timeZone: TimeZone = .current) -> String {
        switch self {
        case .twelveHour:
            return Self.formatter("h:mm:ssa", timeZone).string(from: date).lowercased()
        case .twentyFourHour:
            return Self.formatter("HH:mm:ss", timeZone).string(from: date)
        }
    }

    /// Abbreviated weekday + time — "Wed 4:05pm" / "Wed 14:05" — for fire and
    /// wake times, which are always within the coming week, so the weekday
    /// alone dates them.
    public func dayTimeString(_ date: Date, timeZone: TimeZone = .current) -> String {
        Self.formatter("EEE", timeZone).string(from: date) + " " + timeString(date, timeZone: timeZone)
    }

    /// Full date + time — "Wed 01 Jul 4:05pm" / "Wed 01 Jul 14:05" — for CLI
    /// status lines. Pass `seconds: true` where the exact second matters
    /// (RTC wakes are armed ~45 s ahead of their fire).
    public func dateTimeString(_ date: Date, timeZone: TimeZone = .current, seconds: Bool = false) -> String {
        let time = seconds
            ? preciseTimeString(date, timeZone: timeZone)
            : timeString(date, timeZone: timeZone)
        return Self.formatter("EEE dd MMM", timeZone).string(from: date) + " " + time
    }

    /// Compact log-row stamp — "07-01 16:04:15" / "07-01 4:04:15pm". The
    /// numeric month keeps rows narrow in the Monitoring feeds.
    public func stampString(_ date: Date, timeZone: TimeZone = .current) -> String {
        Self.formatter("MM-dd", timeZone).string(from: date) + " " + preciseTimeString(date, timeZone: timeZone)
    }

    /// A schedule-grid minute-of-day — 300 → "5am" / "05:00", 1410 →
    /// "11:30pm" / "23:30". No `Date` involved: planner times are zone-less
    /// minute offsets. Accepts 1440 ("12am" / "24:00") so painted ranges can
    /// name end-of-day.
    public func minuteString(_ minuteOfDay: Int) -> String {
        let h = minuteOfDay / 60, m = minuteOfDay % 60
        switch self {
        case .twentyFourHour:
            return String(format: "%02d:%02d", h, m)
        case .twelveHour:
            let h12 = h % 12 == 0 ? 12 : h % 12
            let suffix = (h % 24) < 12 ? "am" : "pm"
            return m == 0 ? "\(h12)\(suffix)" : "\(h12):\(String(format: "%02d", m))\(suffix)"
        }
    }

    /// Compact hour label for the paint/coverage grid axes — 14 → "14" / "2p".
    /// A single a/p letter keeps the 9 pt gutter labels from colliding.
    public func hourTick(_ hour: Int) -> String {
        switch self {
        case .twentyFourHour:
            return String(format: "%02d", hour)
        case .twelveHour:
            let h = hour % 24
            let h12 = h % 12 == 0 ? 12 : h % 12
            return "\(h12)\(h < 12 ? "a" : "p")"
        }
    }

    /// en_US_POSIX formatter — every string this enum renders is a fixed,
    /// locale-independent format so GUI and CLI output stay byte-identical.
    private static func formatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = format
        return f
    }
}

/// The app's color scheme: pinned light, pinned dark, or following macOS.
/// Lives here (not in the app target) so it persists in `preferences.json`
/// alongside the other display preferences; the `am` CLI ignores it but
/// round-trips it when it rewrites the file.
public enum AppTheme: String, Codable, Sendable, CaseIterable, Identifiable {
    case light
    case dark
    /// Follow the macOS system appearance.
    case system

    public var id: String { rawValue }
}

/// User preferences shared by the GUI app and the `am` CLI, persisted as
/// `preferences.json` in the workspace so both processes agree on display
/// choices. Decoding is forgiving: a missing/corrupt file or unknown fields
/// fall back to defaults rather than throwing.
public struct Preferences: Codable, Sendable, Equatable {
    public var clockStyle: ClockStyle
    public var theme: AppTheme
    /// Claude's anchoring method — including `.routine`, the claude.ai cloud
    /// routine, which is a method rather than a separate opt-in so there is one
    /// answer to "what anchors this account?".
    public var claudePingMethod: PingMethod
    public var codexPingMethod: PingMethod

    /// Both methods are sanitized against their provider, so a `Preferences`
    /// value can never carry a method that provider doesn't offer (only Claude
    /// has cloud routines) — however it was built, decoded, or migrated.
    public init(
        clockStyle: ClockStyle = .twelveHour,
        theme: AppTheme = .system,
        claudePingMethod: PingMethod = .headless,
        codexPingMethod: PingMethod = .headless)
    {
        self.clockStyle = clockStyle
        self.theme = theme
        self.claudePingMethod = claudePingMethod.sanitized(for: .claude)
        self.codexPingMethod = codexPingMethod.sanitized(for: .codex)
    }

    /// Provider-wide anchoring method, loaded afresh by every ping invocation
    /// and by every scheduler tick, so changing Preferences affects manual
    /// turns, future daemon children, *and* cloud-routine arming without
    /// replanning or restarting the scheduler.
    ///
    /// Callers that are about to run a turn on this Mac want `.localDriver`
    /// off the result: `.routine` is a scheduling choice, not a way to deliver
    /// a turn here.
    public func pingMethod(for provider: Provider) -> PingMethod {
        switch provider {
        case .claude: claudePingMethod
        case .codex: codexPingMethod
        }
    }

    /// What a **fresh install** starts with: the programmatic CLI (`claude -p` /
    /// `codex exec`) on both providers. It is the lightest turn that still
    /// completes a real billed exchange, it needs nothing installed beyond the
    /// provider's own CLI (unlike `.sdk`), and it doesn't depend on a TUI's
    /// screen output staying the shape we parse (unlike `.terminal`) — so it is
    /// the method most likely to keep working untouched.
    public static let `default` = Preferences()

    /// What an install that predates that default keeps: the terminal driver.
    ///
    /// Anchoring is the whole product, and `.terminal` is the method a working
    /// install was verified on — silently moving a user who already has
    /// scheduled pings onto a different one is not a thing an upgrade may do.
    /// So "which default applies" is decided once, from evidence that the
    /// workspace was in use before (see `PreferencesStore.load`), and frozen to
    /// disk. Everything else here matches `default`; only the methods differ.
    public static let legacyDefault = Preferences(claudePingMethod: .terminal, codexPingMethod: .terminal)

    private enum CodingKeys: String, CodingKey {
        case clockStyle, theme, claudePingMethod, codexPingMethod
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clockStyle = (try? c.decode(ClockStyle.self, forKey: .clockStyle)) ?? Self.default.clockStyle
        theme = (try? c.decode(AppTheme.self, forKey: .theme)) ?? Self.default.theme
        // A `preferences.json` that exists but names no method was written
        // before the programmatic default did — an existing install, whose
        // pings have been anchoring over the terminal. Same for a method we
        // can't parse: an unhonorable stored value is not a place to switch
        // someone's anchoring method.
        claudePingMethod = ((try? c.decode(PingMethod.self, forKey: .claudePingMethod))
            ?? Self.legacyDefault.claudePingMethod).sanitized(for: .claude)
        codexPingMethod = ((try? c.decode(PingMethod.self, forKey: .codexPingMethod))
            ?? Self.legacyDefault.codexPingMethod).sanitized(for: .codex)
    }
}

/// On-disk persistence for `Preferences`, mirroring `UsageCache`: whole-file,
/// atomic writes, and a forgiving load that never fails over a missing/corrupt
/// file.
public struct PreferencesStore {
    let fileURL: URL
    /// A file that only an install predating the programmatic default can have:
    /// the account inventory. `nil` (the bare-`fileURL` init) means "no way to
    /// tell" and reads as a fresh install — see `load`.
    let priorUseMarker: URL?
    let fileManager: FileManager

    public init(fileURL: URL, priorUseMarker: URL? = nil, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.priorUseMarker = priorUseMarker
        self.fileManager = fileManager
    }

    public init(workspace: Workspace, fileManager: FileManager = .default) {
        self.init(
            fileURL: workspace.preferencesFile,
            priorUseMarker: workspace.accountsFile,
            fileManager: fileManager)
    }

    /// Preferences as stored, or — for a workspace that has none yet — the
    /// defaults for *this* install, seeded to disk so the choice is made once.
    ///
    /// The seed is the whole reason this isn't a plain `?? .default`. The
    /// fresh-vs-existing question is answered from `priorUseMarker`, and that
    /// evidence appears the moment the user adds their first account — so a new
    /// install read twice, once before and once after, would answer differently
    /// and silently move a real user off the method their pings were set up on.
    /// Writing the answer down on first read fixes it: the app loads
    /// preferences at launch, long before any account exists, and every later
    /// reader (CLI, ping child, daemon) finds a file and never consults the
    /// marker again.
    public func load() -> Preferences {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            let seeded = defaultsForThisInstall()
            // Not under `sudo am wake …`: a root-owned preferences.json in the
            // user's workspace would make every later save silently fail.
            if geteuid() != 0 { save(seeded) }
            return seeded
        }
        guard let data = try? Data(contentsOf: fileURL),
              let prefs = try? JSONDecoder().decode(Preferences.self, from: data)
        // A file we can't read still proves this install chose once, so it gets
        // the conservative defaults — and is left alone rather than clobbered.
        else { return .legacyDefault }
        return prefs
    }

    /// `Preferences.default` for a workspace that has never held an account,
    /// `.legacyDefault` for one that has.
    private func defaultsForThisInstall() -> Preferences {
        guard let priorUseMarker, fileManager.fileExists(atPath: priorUseMarker.path)
        else { return .default }
        return .legacyDefault
    }

    public func save(_ prefs: Preferences) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(prefs) else { return }
        let dir = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try? data.write(to: fileURL, options: [.atomic])
    }
}
