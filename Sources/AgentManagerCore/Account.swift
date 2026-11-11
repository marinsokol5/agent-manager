import Foundation

/// Connection lifecycle for an account.
///
/// `Ping` and `Launch` (later journeys) are disabled unless `.connected`; an
/// `.expired` account offers Re-connect. Transitions:
/// `disconnected → connecting → connected → expired` (and `expired → connecting`
/// on re-connect, or back to `disconnected` on a failed add).
public enum AccountStatus: String, Codable, Sendable {
    case disconnected
    case connecting
    case connected
    case expired
}

/// Where an account's login lives — the one thing that differs between the two
/// kinds of account Agent Manager tracks.
///
/// `.managed` is the original model: the account owns an isolated home
/// (`homes/<id>`, its own `CLAUDE_CONFIG_DIR` / `CODEX_HOME`, its own Keychain
/// item `Claude Code-credentials-<hash>`) and we drive the official CLI inside
/// it for login, pings, and token refresh.
///
/// `.providerDefault` exists because of a real outage: the owner moved to the
/// Claude desktop app, which signs in the provider's *default* login (`~/.claude`
/// + `~/.claude.json`, Keychain item exactly `Claude Code-credentials`). The
/// managed login of their main account then went unused, Claude Code ended it
/// at its time limit, and usage tracking died — while the default login, the
/// one actually in use, stayed perfectly fresh. A default-login account is a
/// fully functional account **whose home is that default one**: `am run <id>`
/// is the same as running a plain `claude`, and every ping method, scheduling,
/// Test ping, the delegated `/status` refresh, cloud routines, and the
/// terminal login all work for it exactly as for a managed account — against
/// the default login.
///
/// How "the home is the default one" is implemented: the child environment has
/// the provider's isolation variable (`CLAUDE_CONFIG_DIR` / `CODEX_HOME`)
/// **removed**, never set to `~/.claude`. Claude Code derives its Keychain item
/// from that variable: when it is set — to anything, `~/.claude` included — it
/// uses `Claude Code-credentials-<hash>` and `<dir>/.claude.json`; only with it
/// unset does it use the unsuffixed `Claude Code-credentials` and
/// `~/.claude.json`, the login the desktop app keeps fresh. See
/// `ChildEnvironment.make(for:base:)`, the one place that decides it.
///
/// What stays different, on purpose: we never provision, symlink, seed, or
/// delete anything in the default home ourselves (hard rule 3) — only the
/// official CLI we run writes there, as it would for the user.
public enum AccountLoginSource: String, Codable, Sendable, CaseIterable {
    case managed
    case providerDefault
}

/// A managed, isolated agent account.
///
/// `home` is the account's `CLAUDE_CONFIG_DIR` (a directory under the app's
/// managed `homes/`). `id` is a filesystem-safe slug used both as the account
/// key and as the managed-home directory name. `home` stays that managed path
/// even for a default-login account (`loginSource == .providerDefault`): lots
/// of code writes into or deletes `home` (provisioner, symlink farm, config
/// seeder, remove-account), so pointing it at `~/.claude` would aim all of that
/// at the user's real login. Reads go through `effectiveKeychainService` /
/// `configHomeURL` / `identityFileURL` instead, and CLI children get their
/// environment from `ChildEnvironment.make(for:base:)`.
public struct Account: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var label: String
    /// `#RRGGBB` swatch used in the menu bar / planner.
    public var color: String
    public var provider: Provider
    /// Absolute path to the managed home (`CLAUDE_CONFIG_DIR`).
    public var home: String
    /// Absolute path of the source home this account's shareable config (and
    /// session history) is symlinked from — `~/.claude` / `~/.codex` by default,
    /// or a custom folder chosen at add time (e.g. a separate work vs. personal
    /// config). Fixed at creation: the symlink farm is laid down once, so
    /// re-pointing it later isn't supported. `nil` on accounts created before this
    /// was tracked → resolve to the provider default via `effectiveSourceHome`.
    public var sourceHome: String?
    /// Optional rank for rotation ordering.
    public var rank: Int?
    /// Optional reserved hours (e.g. "save Pro for deep work").
    public var reservedHours: Double?
    public var status: AccountStatus
    /// Identity email, learned from `oauthAccount` after a successful login.
    public var identityEmail: String?
    /// The Keychain generic-password service name written by Claude CLI for this
    /// managed home — discovered via baseline-diff at login time and stored so
    /// UsageFetcher can retrieve the access token without guessing the hash.
    /// `nil` for Codex accounts (token lives in `auth.json`) and for legacy
    /// Claude accounts that pre-date this field.
    public var keychainService: String?
    /// Whether this account shows in the menu-bar compact display. A straight
    /// per-account visibility toggle: the menu bar surfaces exactly the pinned
    /// connected accounts. Defaults to `true` (init and decode alike) so new
    /// accounts — and pre-existing inventories that predate the field — show
    /// up without any action; unpinning is the opt-out.
    public var pinned: Bool
    /// Whether this account opts out of the planner/scheduler. Excluded
    /// accounts get no scheduled pings, take no lane in the planned week, and
    /// have any armed cloud routine disabled on the daemon's next sync — but
    /// stay fully usable for manual runs, pings, and usage display. Distinct
    /// from `status`: exclusion is a user choice, not a connection state.
    public var excludedFromScheduling: Bool
    /// How often (seconds) the menu bar auto-refreshes this account's usage.
    /// `nil` → the app default (`defaultUsageRefreshSeconds`, 5 min); `0` →
    /// manual only (no auto-refresh); any positive value → that interval.
    public var usageRefreshSeconds: Int?
    /// Where this account's login lives (see `AccountLoginSource`). Omitted
    /// from `accounts.json` while `.managed`, so every inventory written before
    /// this existed re-encodes byte-identically until the user picks the
    /// default login for an account; a missing key decodes as `.managed`.
    public var loginSource: AccountLoginSource
    public var createdAt: Date
    public var lastVerifiedAt: Date?

    /// App default usage auto-refresh cadence when an account doesn't override it.
    /// The usage reads are lightweight, read-only GETs (gated + 429-backed-off),
    /// but the API rate-limits aggressively when several accounts poll in lockstep,
    /// so a relaxed 5-minute cadence keeps the menu bar fresh without tripping 429s.
    public static let defaultUsageRefreshSeconds = 300

    /// Whether usage should auto-refresh for this account at all (`0` = manual).
    public var usageAutoRefreshEnabled: Bool { usageRefreshSeconds != 0 }

    /// Effective auto-refresh cadence; only meaningful when `usageAutoRefreshEnabled`.
    public var usageRefreshInterval: TimeInterval {
        let s = usageRefreshSeconds ?? Self.defaultUsageRefreshSeconds
        return TimeInterval(s > 0 ? s : Self.defaultUsageRefreshSeconds)
    }

    public init(
        id: String,
        label: String,
        color: String = "#7C7CFF",
        provider: Provider,
        home: String,
        sourceHome: String? = nil,
        rank: Int? = nil,
        reservedHours: Double? = nil,
        status: AccountStatus = .disconnected,
        identityEmail: String? = nil,
        keychainService: String? = nil,
        pinned: Bool = true,
        excludedFromScheduling: Bool = false,
        usageRefreshSeconds: Int? = nil,
        loginSource: AccountLoginSource = .managed,
        createdAt: Date = Date(),
        lastVerifiedAt: Date? = nil)
    {
        self.id = id
        self.label = label
        self.color = color
        self.provider = provider
        self.home = home
        self.sourceHome = sourceHome
        self.rank = rank
        self.reservedHours = reservedHours
        self.status = status
        self.identityEmail = identityEmail
        self.keychainService = keychainService
        self.pinned = pinned
        self.excludedFromScheduling = excludedFromScheduling
        self.usageRefreshSeconds = usageRefreshSeconds
        self.loginSource = loginSource
        self.createdAt = createdAt
        self.lastVerifiedAt = lastVerifiedAt
    }

    /// URL of the managed home directory.
    public var homeURL: URL { URL(fileURLWithPath: home, isDirectory: true) }

    /// The source home this account tracks (for display) — the folder its
    /// shareable config and session history are symlinked from. Falls back to the
    /// provider default when `sourceHome` is unset (legacy accounts).
    public func effectiveSourceHome(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        sourceHome ?? provider.defaultSourceHome(homeDirectory: homeDirectory).path
    }

    /// The canonical CLI invocation to run this agent — what the Agents row shows
    /// with a copy button. `am run <id>` resolves the provider, presets isolation,
    /// and execs the CLI.
    public var runCommand: String { "am run \(id)" }

    /// The managed home path, shell-quoted so it pastes cleanly into a terminal
    /// (e.g. after typing `cd `). Survives the spaces in `…/Application Support/…`
    /// and any other metacharacters; see `String.singleQuotedForShell`.
    public var homeShellQuoted: String { home.singleQuotedForShell }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        color = try c.decode(String.self, forKey: .color)
        provider = try c.decode(Provider.self, forKey: .provider)
        home = try c.decode(String.self, forKey: .home)
        sourceHome = try c.decodeIfPresent(String.self, forKey: .sourceHome)
        rank = try c.decodeIfPresent(Int.self, forKey: .rank)
        reservedHours = try c.decodeIfPresent(Double.self, forKey: .reservedHours)
        status = try c.decode(AccountStatus.self, forKey: .status)
        identityEmail = try c.decodeIfPresent(String.self, forKey: .identityEmail)
        keychainService = try c.decodeIfPresent(String.self, forKey: .keychainService)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? true
        excludedFromScheduling = try c.decodeIfPresent(Bool.self, forKey: .excludedFromScheduling) ?? false
        usageRefreshSeconds = try c.decodeIfPresent(Int.self, forKey: .usageRefreshSeconds)
        // Forgiving: absent *or* unrecognized (a value from a newer build) reads
        // as `.managed`, never as a failed inventory load.
        loginSource = (try? c.decodeIfPresent(AccountLoginSource.self, forKey: .loginSource)) ?? .managed
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastVerifiedAt = try c.decodeIfPresent(Date.self, forKey: .lastVerifiedAt)
    }

    /// Spelled out because both coding directions are hand-written now (the
    /// compiler only synthesizes keys while one of them is synthesized).
    enum CodingKeys: String, CodingKey {
        case id, label, color, provider, home, sourceHome, rank, reservedHours, status
        case identityEmail, keychainService, pinned, excludedFromScheduling, usageRefreshSeconds
        case loginSource, createdAt, lastVerifiedAt
    }

    /// Mirrors what the synthesized encoder wrote before `loginSource` existed
    /// (optionals via `encodeIfPresent`), plus `loginSource` only when it isn't
    /// `.managed` — the byte-identical-inventory guarantee on that property.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encode(color, forKey: .color)
        try c.encode(provider, forKey: .provider)
        try c.encode(home, forKey: .home)
        try c.encodeIfPresent(sourceHome, forKey: .sourceHome)
        try c.encodeIfPresent(rank, forKey: .rank)
        try c.encodeIfPresent(reservedHours, forKey: .reservedHours)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(identityEmail, forKey: .identityEmail)
        try c.encodeIfPresent(keychainService, forKey: .keychainService)
        try c.encode(pinned, forKey: .pinned)
        try c.encode(excludedFromScheduling, forKey: .excludedFromScheduling)
        try c.encodeIfPresent(usageRefreshSeconds, forKey: .usageRefreshSeconds)
        if loginSource != .managed { try c.encode(loginSource, forKey: .loginSource) }
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(lastVerifiedAt, forKey: .lastVerifiedAt)
    }

    // MARK: Login source

    /// Whether this account uses the provider's default login as its home
    /// (see `AccountLoginSource.providerDefault`).
    public var tracksDefaultLogin: Bool { loginSource == .providerDefault }

    /// The Keychain service the official CLI keeps this account's Claude login
    /// in, and so the one usage reads (and the post-refresh re-read) use. A
    /// default-login account's is the provider's unsuffixed default item —
    /// what the CLI picks with `CLAUDE_CONFIG_DIR` unset; the stored
    /// `keychainService` (the managed home's item) is kept untouched so the
    /// account can be switched back.
    public var effectiveKeychainService: String? {
        tracksDefaultLogin ? provider.defaultKeychainService : keychainService
    }

    /// The config home the CLI actually uses for this account: the managed
    /// home, or the provider's default (`~/.claude` / `~/.codex`) for a
    /// default-login account. Credential *files* (Codex's `auth.json` and
    /// `config.toml`) are read from here, the app reveals it, and a custom
    /// ping's `AGENT_MANAGER_CONFIG_HOME` names it. Never pass it to anything
    /// that writes, deletes, or symlinks: for a default-login account it is the
    /// user's own folder, and only the official CLI may write there.
    public func configHomeURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL
    {
        tracksDefaultLogin ? provider.defaultSourceHome(homeDirectory: homeDirectory) : homeURL
    }

    /// The identity file this account's email / org UUID are read from.
    public func identityFileURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL
    {
        tracksDefaultLogin
            ? provider.defaultIdentityFile(homeDirectory: homeDirectory)
            : homeURL.appendingPathComponent(provider.identityFileName)
    }
}

public enum AccountIDError: Error, Equatable, CustomStringConvertible {
    case empty
    case invalid(String)

    public var description: String {
        switch self {
        case .empty: "account id must not be empty"
        case let .invalid(id): "account id '\(id)' is not a valid slug (use a-z, 0-9, '-' or '_')"
        }
    }
}

public enum AccountID {
    /// Validate that an id is a filesystem-safe slug (it doubles as a directory
    /// name under `homes/`, so we keep it conservative).
    public static func validate(_ id: String) throws {
        guard !id.isEmpty else { throw AccountIDError.empty }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard id.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw AccountIDError.invalid(id)
        }
    }
}

extension String {
    /// This string wrapped in single quotes for safe embedding in a single POSIX
    /// shell word. Embedded single quotes are closed, escaped, and reopened
    /// (`'\''`) — the standard idiom that makes the result robust to spaces and
    /// metacharacters. Used both for display/clipboard and to build the
    /// `TerminalLauncher` Terminal.app command; we still never assemble a
    /// `/bin/sh -c` string from interpolated values (see the "no shell string
    /// execution" rule in AGENTS.md).
    public var singleQuotedForShell: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
