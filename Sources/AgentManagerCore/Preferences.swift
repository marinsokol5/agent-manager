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
    /// The command each provider's `custom` ping method runs. Optional and
    /// omitted from the file while nil (synthesized `encodeIfPresent`), so a
    /// `preferences.json` written before this existed stays byte-identical
    /// until someone actually sets one. Kept even while another method is
    /// selected, so switching away and back doesn't lose it. These are the
    /// provider-scope commands only; what a given account runs comes from
    /// `customCommand(forAccount:provider:)`, which honors its override.
    public var claudeCustomCommand: CustomPingCommand?
    public var codexCustomCommand: CustomPingCommand?
    /// Per-account exceptions to the provider-wide method above, keyed by
    /// account id. The provider-level fields stay the *defaults*; an account
    /// listed here uses its own method (and, for `custom`, its own command)
    /// instead. The case it exists for: a daily eval that belongs on exactly
    /// one Claude account, not on every one of them — and not stacked back to
    /// back by a daemon that drains due pings sequentially.
    ///
    /// Never read this directly to decide what runs: go through
    /// `pingMethod(forAccount:provider:)` / `customCommand(forAccount:provider:)`,
    /// which sanitize against the account's provider and keep the command in
    /// the same scope as the method. Keys are account ids, which are validated
    /// slugs (AGENTS.md hard rule 6) — decode drops any key that isn't. Omitted
    /// from the file while empty, so a `preferences.json` written before this
    /// existed stays byte-identical until someone sets an override.
    public private(set) var accountPingOverrides: [String: AccountPingOverride]

    /// Both methods are sanitized against their provider, so a `Preferences`
    /// value can never carry a method that provider doesn't offer (only Claude
    /// has cloud routines) — however it was built, decoded, or migrated.
    public init(
        clockStyle: ClockStyle = .twelveHour,
        theme: AppTheme = .system,
        claudePingMethod: PingMethod = .headless,
        codexPingMethod: PingMethod = .headless,
        claudeCustomCommand: CustomPingCommand? = nil,
        codexCustomCommand: CustomPingCommand? = nil,
        accountPingOverrides: [String: AccountPingOverride] = [:])
    {
        self.clockStyle = clockStyle
        self.theme = theme
        self.claudePingMethod = claudePingMethod.sanitized(for: .claude)
        self.codexPingMethod = codexPingMethod.sanitized(for: .codex)
        self.claudeCustomCommand = claudeCustomCommand
        self.codexCustomCommand = codexCustomCommand
        self.accountPingOverrides = accountPingOverrides.filter { (try? AccountID.validate($0.key)) != nil }
    }

    /// The command the `custom` method runs for `provider`'s accounts, or nil
    /// when none is set (a custom ping then fails without launching anything).
    public func customCommand(for provider: Provider) -> CustomPingCommand? {
        switch provider {
        case .claude: claudeCustomCommand
        case .codex: codexCustomCommand
        }
    }

    public mutating func setCustomCommand(_ command: CustomPingCommand?, for provider: Provider) {
        switch provider {
        case .claude: claudeCustomCommand = command
        case .codex: codexCustomCommand = command
        }
    }

    /// Provider-wide anchoring method — the *default* for that provider's
    /// accounts. Anything deciding what a specific account runs must use
    /// `pingMethod(forAccount:provider:)`, which honors per-account overrides.
    /// Loaded afresh by every ping invocation and by every scheduler tick, so
    /// changing Preferences affects manual turns, future daemon children,
    /// *and* cloud-routine arming without replanning or restarting the
    /// scheduler.
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

    // MARK: - per-account overrides

    /// The account's own override, or nil when it inherits its provider's
    /// method. For the UI's "is this account overridden?" question — anything
    /// deciding what *runs* wants the resolved accessors below.
    public func pingOverride(forAccount id: String) -> AccountPingOverride? {
        accountPingOverrides[id]
    }

    /// Set (or, with nil, clear) one account's override. Clearing is also the
    /// pruning path for a removed account: a slug that is later re-added must
    /// start from its provider's default, not silently inherit a stale method
    /// or command (see `removeAccount`). Invalid ids are ignored rather than
    /// persisted — the key has to be safe wherever an account id is used.
    public mutating func setPingOverride(_ override: AccountPingOverride?, forAccount id: String) {
        guard (try? AccountID.validate(id)) != nil else { return }
        accountPingOverrides[id] = override
    }

    /// Forget everything this file holds about an account that was removed.
    public mutating func removeAccount(_ id: String) {
        accountPingOverrides.removeValue(forKey: id)
    }

    /// The method that anchors this account: its override when it has one,
    /// else its provider's method. The override is sanitized against the
    /// account's provider exactly like the provider-wide value is, so a
    /// hand-edited `routine` on a Codex account lands on `terminal` instead of
    /// meaning "never ping this account, and nothing anchors it either".
    ///
    /// Like `pingMethod(for:)`, callers about to run a turn on this Mac want
    /// `.localDriver` off the result.
    public func pingMethod(forAccount id: String, provider: Provider) -> PingMethod {
        if let override = accountPingOverrides[id] {
            return override.method.sanitized(for: provider)
        }
        return pingMethod(for: provider)
    }

    /// The command the `custom` method runs for this account — always from the
    /// **same scope that chose the method**: the override's own command when
    /// the account is overridden, the provider's when it inherits. There is
    /// deliberately no cross-scope fallback (an overridden account with no
    /// command of its own does *not* borrow the provider's): what runs must be
    /// exactly what the scope the user is looking at shows, or an eval meant
    /// for one account could quietly run a command configured for all of them.
    public func customCommand(forAccount id: String, provider: Provider) -> CustomPingCommand? {
        if let override = accountPingOverrides[id] { return override.customCommand }
        return customCommand(for: provider)
    }

    /// The command shown and edited in `scope` (the Preferences field). An
    /// account scope without an override has no command of its own — nil —
    /// and setting one there is a no-op: the field only exists while the
    /// account's override is `custom`.
    public func customCommand(in scope: PingMethodScope) -> CustomPingCommand? {
        switch scope {
        case let .provider(provider): customCommand(for: provider)
        case let .account(id, _): accountPingOverrides[id]?.customCommand
        }
    }

    public mutating func setCustomCommand(_ command: CustomPingCommand?, in scope: PingMethodScope) {
        switch scope {
        case let .provider(provider):
            setCustomCommand(command, for: provider)
        case let .account(id, _):
            accountPingOverrides[id]?.customCommand = command
        }
    }

    /// The method selected in `scope` — what the Preferences cards show as
    /// picked. A provider scope always has one (its default); an account scope
    /// has its override's method, sanitized for that account's provider
    /// exactly as `pingMethod(forAccount:provider:)` resolves it, or nil while
    /// the account inherits (the "Same as all … accounts" card).
    public func pingMethod(in scope: PingMethodScope) -> PingMethod? {
        switch scope {
        case let .provider(provider): pingMethod(for: provider)
        case let .account(id, provider): accountPingOverrides[id]?.method.sanitized(for: provider)
        }
    }

    /// Select `method` in `scope` — the one write the Preferences cards make,
    /// whichever scope they show.
    ///
    /// For a provider, sets its sanitized default (nil is meaningless there and
    /// ignored: a provider always has a method). For an account, nil clears the
    /// override so it inherits again, and a method sets it **keeping the
    /// override's existing `customCommand`** — the rule `AccountPingOverride`
    /// promises, enforced here rather than in a UI layer so every writer gets
    /// it: flipping an account Custom → SDK → Custom must not lose the command
    /// the user typed for it, just as the provider-level command survives the
    /// same round trip.
    public mutating func setPingMethod(_ method: PingMethod?, in scope: PingMethodScope) {
        switch scope {
        case let .provider(provider):
            guard let method else { return }
            switch provider {
            case .claude: claudePingMethod = method.sanitized(for: .claude)
            case .codex: codexPingMethod = method.sanitized(for: .codex)
            }
        case let .account(id, _):
            let kept = accountPingOverrides[id]?.customCommand
            setPingOverride(method.map { AccountPingOverride(method: $0, customCommand: kept) }, forAccount: id)
        }
    }

    /// The accounts, among `accounts`, whose *resolved* method is the cloud
    /// routine — the set the scheduler daemon arms routines for and spawns no
    /// local ping for. Computed from the same resolution every ping child
    /// uses, so the daemon and the children can never disagree about what
    /// anchors an account. Only Claude accounts can be in it (`sanitized`).
    public func cloudRoutineAccounts(_ accounts: [Account]) -> Set<String> {
        Set(accounts
            .filter { pingMethod(forAccount: $0.id, provider: $0.provider).usesCloudRoutine }
            .map(\.id))
    }

    /// What anchors these accounts changed between two preference values: the
    /// accounts that crossed *into* resolved `routine` and those that crossed
    /// *out*, each sorted. Covers provider-level and account-level edits alike
    /// — a provider switch moves every inheriting account and none of the
    /// overridden ones.
    public static func cloudRoutineTransition(
        from old: Preferences, to new: Preferences, accounts: [Account])
        -> CloudRoutineTransition
    {
        let before = old.cloudRoutineAccounts(accounts)
        let after = new.cloudRoutineAccounts(accounts)
        return CloudRoutineTransition(
            entered: after.subtracting(before).sorted(),
            left: before.subtracting(after).sorted())
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
        case claudeCustomCommand, codexCustomCommand
        case accountPingOverrides
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
        // A malformed command decodes as "none set" rather than discarding the
        // whole file: the custom ping then fails loudly, everything else holds.
        claudeCustomCommand = (try? c.decodeIfPresent(CustomPingCommand.self, forKey: .claudeCustomCommand)) ?? nil
        codexCustomCommand = (try? c.decodeIfPresent(CustomPingCommand.self, forKey: .codexCustomCommand)) ?? nil
        // Per entry: one override we can't decode (an unknown method, a
        // malformed command) is dropped by itself — that account inherits its
        // provider's method again — while its siblings and the rest of the
        // file survive. Keys that aren't valid account slugs are dropped too.
        let raw = (try? c.decodeIfPresent([String: Lossy<AccountPingOverride>].self, forKey: .accountPingOverrides)) ?? nil
        var overrides: [String: AccountPingOverride] = [:]
        for (id, entry) in raw ?? [:] {
            guard let value = entry.value, (try? AccountID.validate(id)) != nil else { continue }
            overrides[id] = value
        }
        accountPingOverrides = overrides
    }

    /// Written by hand (rather than synthesized) only to *omit* an empty
    /// override map: every other key encodes exactly as the synthesized
    /// encoder did, so a file nobody overrode anything in stays byte-identical.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(clockStyle, forKey: .clockStyle)
        try c.encode(theme, forKey: .theme)
        try c.encode(claudePingMethod, forKey: .claudePingMethod)
        try c.encode(codexPingMethod, forKey: .codexPingMethod)
        try c.encodeIfPresent(claudeCustomCommand, forKey: .claudeCustomCommand)
        try c.encodeIfPresent(codexCustomCommand, forKey: .codexCustomCommand)
        if !accountPingOverrides.isEmpty {
            try c.encode(accountPingOverrides, forKey: .accountPingOverrides)
        }
    }
}

/// One account's exception to its provider's ping method: the method, plus —
/// for `custom` — that account's **own** command. The command lives on the
/// override rather than being looked up from the provider so each scope runs
/// exactly what it shows (see `Preferences.customCommand(forAccount:provider:)`).
/// Kept when the method moves off `custom`, like the provider-level command,
/// so switching away and back doesn't lose it.
public struct AccountPingOverride: Codable, Sendable, Equatable {
    /// Stored unsanitized (the override doesn't know its account's provider);
    /// every reader resolves it through `Preferences.pingMethod(forAccount:provider:)`.
    public var method: PingMethod
    public var customCommand: CustomPingCommand?

    public init(method: PingMethod, customCommand: CustomPingCommand? = nil) {
        self.method = method
        self.customCommand = customCommand
    }
}

/// Where a ping-method setting lives: the provider-wide default, or one
/// account's override of it. The Preferences screen edits one scope at a time,
/// and the custom-command field reads and writes through this so the same
/// field serves both.
public enum PingMethodScope: Hashable, Sendable {
    case provider(Provider)
    case account(id: String, provider: Provider)

    public var provider: Provider {
        switch self {
        case let .provider(provider): provider
        case let .account(_, provider): provider
        }
    }
}

/// Accounts whose resolved method crossed into or out of the cloud routine
/// across one preferences edit — see `Preferences.cloudRoutineTransition`.
public struct CloudRoutineTransition: Sendable, Equatable {
    public var entered: [String]
    public var left: [String]

    public init(entered: [String] = [], left: [String] = []) {
        self.entered = entered
        self.left = left
    }

    public var isEmpty: Bool { entered.isEmpty && left.isEmpty }
}

/// Decodes to nil instead of throwing, so one bad element of a keyed
/// collection costs only itself.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
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

    /// Apply one ping-method edit — provider-wide or per account — and put
    /// any change in what anchors an account on the record.
    ///
    /// Loads afresh, mutates, saves, and diffs the resolved cloud-routine set
    /// before and after over `accounts`. Every account that crossed into or
    /// out of `routine` gets its own `cloud.enable` / `cloud.disable` audit
    /// line (with its `accountID`): that is the moment the daemon starts or
    /// stops arming real claude.ai routines for it, and the runbook needs it
    /// whichever scope the edit came from. `via` names the scope for the
    /// detail. Returns the transition so the caller can say what happened.
    @discardableResult
    public func updatePingMethods(
        accounts: [Account],
        audit: AuditLog,
        via: String,
        _ change: (inout Preferences) -> Void)
        -> (preferences: Preferences, transition: CloudRoutineTransition)
    {
        let old = load()
        var new = old
        change(&new)
        if new != old { save(new) }
        let transition = Preferences.cloudRoutineTransition(from: old, to: new, accounts: accounts)
        for id in transition.entered {
            audit.append(accountID: id, action: "cloud.enable", ok: true, detail: "via \(via)")
        }
        for id in transition.left {
            audit.append(accountID: id, action: "cloud.disable", ok: true, detail: "via \(via)")
        }
        return (new, transition)
    }

    /// Prune a removed account's override, if it had one, and return what's
    /// on disk afterwards. Deliberately not `updatePingMethods`: the account is
    /// gone from the inventory, so no remaining account's resolved method can
    /// change and there is no `cloud.*` transition to log. Only rewrites the
    /// file when there was something to forget, so removing an ordinary
    /// account never touches `preferences.json`.
    @discardableResult
    public func removeAccount(_ id: String) -> Preferences {
        var prefs = load()
        guard prefs.pingOverride(forAccount: id) != nil else { return prefs }
        prefs.removeAccount(id)
        save(prefs)
        return prefs
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
