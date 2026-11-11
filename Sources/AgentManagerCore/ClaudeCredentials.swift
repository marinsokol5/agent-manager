import Foundation

/// Reads the Claude OAuth credential blob (`claudeAiOauth`) from the Keychain and
/// exposes the access token + its expiry. We only ever *read* this — the `claude`
/// CLI stays the single writer/refresher of the credential (see
/// `ClaudeTokenRefresher`); duplicating the OAuth refresh here would make us a
/// second writer that has to mirror refresh-token rotation atomically.
public enum ClaudeCredentials {
    public struct Blob: Sendable, Equatable {
        public let accessToken: String
        public let expiresAt: Date?
    }

    /// What the credential item says about this account's login.
    ///
    /// `.signedOut` exists because "the item is readable but holds no token" is
    /// a different fact from "we couldn't read the item", and conflating them
    /// hid a real outage: Claude Code gives a login a hard lifetime
    /// (`refreshTokenExpiresAt`), and when it runs out the CLI keeps the item
    /// but blanks it — `accessToken: ""`, `expiresAt: 0`, and
    /// `loginEnded: "time_limit"`. Read as "undecodable", a background poll
    /// took that for a deferred Keychain grant and kept showing day-old cached
    /// usage forever. No refresh can revive such a login (the refresh token is
    /// gone too), so callers must surface it — even on a background read — and
    /// never answer it with a delegated `/status`.
    public enum Status: Sendable, Equatable {
        case valid(Blob)
        /// The CLI's own `loginEnded` reason when it left one (`"time_limit"`),
        /// else `nil` (e.g. a plain `/logout`). A label, never a secret.
        case signedOut(reason: String?)
    }

    public static func read(keychainService service: String, allowInteraction: Bool = false) -> Blob? {
        guard case let .valid(blob) = status(keychainService: service, allowInteraction: allowInteraction)
        else { return nil }
        return blob
    }

    /// One Keychain read, classified. `nil` = the item couldn't be read (absent,
    /// not granted, or not JSON) — the only case a background caller may treat
    /// as "deferred, keep cached usage".
    public static func status(keychainService service: String, allowInteraction: Bool = false) -> Status? {
        guard let data = readData(service: service, allowInteraction: allowInteraction) else { return nil }
        return classify(data)
    }

    /// Strategy-aware raw read. See `KeychainReadStrategy` for the full rationale.
    static func readData(service: String, allowInteraction: Bool) -> Data? {
        switch KeychainReadStrategy.current {
        case .securityFrameworkOnly:
            return KeychainProbe.readGenericPasswordData(service: service, allowInteraction: allowInteraction)

        case .securityCLIWithFrameworkFallback:
            let grants = KeychainGrantStore()
            if allowInteraction {
                // User action. Go straight to the CLI — normally silent, since
                // the claude CLI trusts `security` from item creation; if the
                // ACL was altered, its one-time prompt says "security" and
                // "Always Allow" binds to that stable identity.
                // IMPORTANT: do NOT try an in-process framework read first — that
                // prompts as "AgentManager" and binds a non-durable app grant.
                if let data = KeychainProbe.readGenericPasswordDataViaSecurityCLI(service: service) {
                    grants.markGranted(service)
                    return data
                }
                grants.clearGranted(service)
                // Last resort only if `/usr/bin/security` is unavailable.
                return KeychainProbe.readGenericPasswordData(service: service, allowInteraction: true)
            } else {
                // Background. Silent CLI read only once `security` is known-granted;
                // otherwise DEFER. We never do a framework read here: the legacy ACL
                // "allow access" dialog isn't reliably suppressed, so a background
                // framework read can still prompt ("AgentManager wants to access…").
                guard grants.isGranted(service) else { return nil }
                if let data = KeychainProbe.readGenericPasswordDataViaSecurityCLI(service: service) {
                    return data
                }
                grants.clearGranted(service) // ACL changed → self-heal
                return nil
            }
        }
    }

    static func parse(_ data: Data) -> Blob? {
        guard case let .valid(blob) = classify(data) else { return nil }
        return blob
    }

    /// Pure classifier for the credential JSON. Any well-formed blob without a
    /// usable access token is `.signedOut` — that covers the blanked
    /// `claudeAiOauth` the CLI leaves when a login ends, and an item that only
    /// still holds `mcpOAuth` entries after a logout. Only non-JSON is `nil`.
    static func classify(_ data: Data) -> Status? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let oauth = root["claudeAiOauth"] as? [String: Any]
        guard let token = oauth?["accessToken"] as? String, !token.isEmpty else {
            return .signedOut(reason: oauth?["loginEnded"] as? String)
        }
        return .valid(Blob(accessToken: token, expiresAt: parseExpiry(oauth?["expiresAt"])))
    }

    /// True when the token is missing, already expired, or within `margin` of
    /// expiring — i.e. we should refresh before (or instead of) calling the API.
    /// An unknown expiry returns `false` so we let the request try rather than
    /// spawn the CLI blindly.
    public static func needsRefresh(_ blob: Blob?, now: Date = Date(), margin: TimeInterval = 60) -> Bool {
        guard let blob else { return true }
        guard let expiresAt = blob.expiresAt else { return false }
        return now.addingTimeInterval(margin) >= expiresAt
    }

    // MARK: - Expiry parsing

    /// Claude stores `expiresAt` as epoch milliseconds; tolerate seconds and ISO
    /// strings defensively.
    static func parseExpiry(_ value: Any?) -> Date? {
        switch value {
        case let n as Double: return dateFromEpoch(n)
        case let n as Int: return dateFromEpoch(Double(n))
        case let s as String:
            if let n = Double(s) { return dateFromEpoch(n) }
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) { return d }
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: s)
        default: return nil
        }
    }

    private static func dateFromEpoch(_ value: Double) -> Date {
        // Distinguish ms (~1.7e12) from seconds (~1.7e9).
        let seconds = value > 1e11 ? value / 1000 : value
        return Date(timeIntervalSince1970: seconds)
    }
}
