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

/// A managed, isolated agent account.
///
/// `home` is the account's `CLAUDE_CONFIG_DIR` (a directory under the app's
/// managed `homes/`). `id` is a filesystem-safe slug used both as the account
/// key and as the managed-home directory name.
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
    /// Whether this account is pinned to the menu-bar compact display.
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
        pinned: Bool = false,
        excludedFromScheduling: Bool = false,
        usageRefreshSeconds: Int? = nil,
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
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        excludedFromScheduling = try c.decodeIfPresent(Bool.self, forKey: .excludedFromScheduling) ?? false
        usageRefreshSeconds = try c.decodeIfPresent(Int.self, forKey: .usageRefreshSeconds)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastVerifiedAt = try c.decodeIfPresent(Date.self, forKey: .lastVerifiedAt)
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
