import Foundation

// MARK: - Shared error type

public enum UsageFetchError: Error, LocalizedError, Sendable {
    case keychainReadFailed
    case tokenDecodeFailed
    case invalidResponse
    case unauthorized
    /// Codex only: the usage API answered 401 with OpenAI's `token_expired`
    /// code (see `CodexUsageFetcher.classifyRejection`). Split out of
    /// `.unauthorized` because "re-login this account" was not enough to act
    /// on. In the incident that motivated it the access token's JWT `exp` was
    /// still a week out — OpenAI had revoked it server-side (most likely after
    /// a ChatGPT plan change), so waiting or retrying never helps — and the
    /// user's re-login went through the Codex app / a plain `codex login`,
    /// which writes the *default* `~/.codex/auth.json`, never this account's
    /// managed `CODEX_HOME`, so the error never cleared. The message therefore
    /// names the one command that logs in *this* home (`am run <id> login`
    /// runs `codex login` with the account's `CODEX_HOME`; the app's Log in
    /// button is only offered while an account isn't connected, and a revoked
    /// `auth.json` still reads as connected). `lastRefresh` is the managed
    /// `auth.json`'s own `last_refresh` stamp — a timestamp, not a secret — so
    /// a re-login that landed elsewhere shows up as a file that kept aging.
    case tokenRevoked(accountID: String, lastRefresh: Date?)
    case rateLimited(retryAfter: Date?)
    case serverError(Int)
    /// A background read needs the Keychain prompt we won't show; keep cached
    /// usage and wait for an explicit "Refresh usage". Swallowed by the caller.
    case keychainAccessDeferred
    /// The token is expired but the delegated `/status` refresh was withheld:
    /// no 5h window is live, so running it would anchor a brand-new window (see
    /// `ClaudeTokenRefresher.mayRefresh`). Keep cached usage; an explicit
    /// refresh or the next scheduled ping delivers a fresh token.
    case refreshDeferred

    public var errorDescription: String? {
        switch self {
        case .keychainReadFailed:
            "Could not read OAuth token from Keychain."
        case .tokenDecodeFailed:
            "Could not decode token from the credential store."
        case .invalidResponse:
            "Invalid response from usage API."
        case .unauthorized:
            "Usage API rejected the token (401/403) — re-login this account."
        case let .tokenRevoked(accountID, lastRefresh):
            Self.tokenRevokedMessage(accountID: accountID, lastRefresh: lastRefresh)
        case .keychainAccessDeferred:
            "Click “Refresh usage” to allow Keychain access."
        case .refreshDeferred:
            "Token expired; refresh deferred so it can't start a 5h window — refresh manually to update."
        case let .rateLimited(retryAfter):
            if let retryAfter {
                "Rate limited by the usage API — retrying after \(Self.shortTime(retryAfter))."
            } else {
                "Rate limited by the usage API — backing off."
            }
        case let .serverError(code):
            "Usage API returned HTTP \(code)."
        }
    }

    /// `.tokenRevoked`'s text, with `now` injected so tests can pin the age.
    /// The `~/.codex` mention is the whole point: it's where the wrong re-login
    /// lands. We only *name* that folder — nothing here reads it.
    static func tokenRevokedMessage(accountID: String, lastRefresh: Date?, now: Date = Date()) -> String {
        var message = "OpenAI revoked this account's token (token_expired). Log in again as this account "
            + "with “am run \(accountID) login” — the Codex app or a plain “codex login” signs in "
            + "your default ~/.codex instead."
        if let lastRefresh {
            message += " Its auth.json was last refreshed \(ageLabel(since: lastRefresh, now: now))."
        }
        return message
    }

    /// "Xs ago" / "Xm ago" / "Xh ago" / "Xd ago" (a future stamp from clock
    /// skew reads as "0s ago" rather than a negative age).
    private static func ageLabel(since date: Date, now: Date) -> String {
        let age = max(0, Int(now.timeIntervalSince(date)))
        if age < 60 { return "\(age)s ago" }
        if age < 3600 { return "\(age / 60)m ago" }
        if age < 86400 { return "\(age / 3600)h ago" }
        return "\(age / 86400)d ago"
    }

    private static func shortTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }
}

// MARK: - Retry-After parsing

enum RetryAfter {
    /// Parse an HTTP `Retry-After` header (delta-seconds or HTTP-date) into an
    /// absolute date, or `nil` if absent/unparseable.
    static func date(from response: HTTPURLResponse, now: Date = Date()) -> Date? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else { return nil }
        if let seconds = TimeInterval(raw), seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return f.date(from: raw)
    }
}

// MARK: - Claude

/// Fetches Claude OAuth usage from `https://api.anthropic.com/api/oauth/usage`.
/// Requires `account.keychainService` to be set (populated at login time).
public enum ClaudeUsageFetcher {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let betaHeader = "oauth-2025-04-20"

    /// `accessToken` is read once by the caller (`AppModel.loadUsage`) and passed
    /// in — reading the Keychain blob inside here would re-trigger the macOS
    /// access prompt on every fetch/refresh hop.
    public static func fetch(
        account: Account,
        accessToken: String,
        gate: UsageRateLimitGate,
        userInitiated: Bool = false,
        log: NetworkLog? = nil) async throws -> UsageReading
    {
        if !userInitiated, let until = await gate.blockedUntil(accountID: account.id) {
            throw UsageFetchError.rateLimited(retryAfter: until)
        }

        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        // Mirror the real `claude` CLI request byte-for-byte (captured from the
        // wire) so this client-gated endpoint sees nothing anomalous.
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue(await ClaudeCodeUserAgent.shared.value(), forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, URLResponse)
        if let log {
            (data, response) = try await log.perform(request, accountID: account.id)
        } else {
            (data, response) = try await URLSession.shared.data(for: request)
        }
        guard let http = response as? HTTPURLResponse else {
            throw UsageFetchError.invalidResponse
        }
        switch http.statusCode {
        case 200:
            await gate.recordSuccess(accountID: account.id)
            return try decodeResponse(data)
        case 401, 403:
            throw UsageFetchError.unauthorized
        case 429:
            // Report the *effective* block, not the raw `Retry-After` — the server
            // sends `Retry-After: 0`, so the header would read "retry now" while the
            // gate actually backs off for `defaultCooldown`.
            let until = await gate.recordRateLimit(
                accountID: account.id, retryAfter: RetryAfter.date(from: http))
            throw UsageFetchError.rateLimited(retryAfter: until)
        default:
            throw UsageFetchError.serverError(http.statusCode)
        }
    }

    /// Test hook for the response decoder (the network path is not unit-tested).
    static func decodeForTesting(_ data: Data) throws -> UsageReading { try decodeResponse(data) }

    private static func decodeResponse(_ data: Data) throws -> UsageReading {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageFetchError.invalidResponse
        }
        // `utilization` is already a 0–100 percent (e.g. 3.0 == 3%), matching the
        // integer `limits[].percent`. The `limits` array is the authoritative,
        // unambiguous source; the `five_hour`/`seven_day` objects are fallbacks.
        let limits = root["limits"] as? [[String: Any]] ?? []
        let session = limits.first { ($0["kind"] as? String) == "session" || ($0["group"] as? String) == "session" }
        let weekly = limits.first { ($0["group"] as? String) == "weekly" || ($0["kind"] as? String) == "weekly_all" }
        let fiveHour = root["five_hour"] as? [String: Any]
        let sevenDay = root["seven_day"] as? [String: Any]

        return UsageReading(
            primaryUsedPercent: percent(from: session) ?? percent(fromWindow: fiveHour),
            primaryResetsAt: resetsAt(from: session) ?? resetsAt(from: fiveHour),
            secondaryUsedPercent: percent(from: weekly) ?? percent(fromWindow: sevenDay),
            secondaryResetsAt: resetsAt(from: weekly) ?? resetsAt(from: sevenDay))
    }

    /// Integer `percent` from a `limits[]` entry.
    private static func percent(from limit: [String: Any]?) -> Int? {
        guard let value = limit?["percent"] else { return nil }
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d.rounded()) }
        return nil
    }

    /// `utilization` (already 0–100) from a `five_hour`/`seven_day` window.
    private static func percent(fromWindow window: [String: Any]?) -> Int? {
        (window?["utilization"] as? Double).map { Int($0.rounded()) }
    }

    private static func resetsAt(from object: [String: Any]?) -> Date? {
        (object?["resets_at"] as? String).flatMap(parseISO8601)
    }

    private static func parseISO8601(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

// MARK: - Codex

/// Fetches Codex usage from the ChatGPT backend (`/wham/usage` or `/api/codex/usage`).
/// Reads the access token from `auth.json` in the account's managed home.
public enum CodexUsageFetcher {
    private static let defaultBaseURL = "https://chatgpt.com/backend-api"
    private static let usagePath = "/wham/usage"

    public static func fetch(
        account: Account,
        gate: UsageRateLimitGate,
        userInitiated: Bool = false,
        log: NetworkLog? = nil) async throws -> UsageReading
    {
        if !userInitiated, let until = await gate.blockedUntil(accountID: account.id) {
            throw UsageFetchError.rateLimited(retryAfter: until)
        }
        let authURL = account.homeURL.appendingPathComponent("auth.json")
        guard
            let blob = try? Data(contentsOf: authURL),
            let root = try? JSONSerialization.jsonObject(with: blob) as? [String: Any],
            let tokens = root["tokens"] as? [String: Any],
            let token = tokens["access_token"] as? String, !token.isEmpty
        else {
            throw UsageFetchError.tokenDecodeFailed
        }
        // The header wants the JWT's chatgpt_account_id (the body's `account_id`
        // is a different, user-scoped id); fall back to auth.json fields.
        let accountId = CodexAuth.chatgptAccountId(accessToken: token)
            ?? (tokens["account_id"] as? String)
            ?? (root["account_id"] as? String)

        let url = resolveURL(homeURL: account.homeURL)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Mirror the real codex CLI request (captured from the wire).
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(await CodexUserAgent.shared.value(), forHTTPHeaderField: "User-Agent")
        if let accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response): (Data, URLResponse)
        if let log {
            (data, response) = try await log.perform(request, accountID: account.id)
        } else {
            (data, response) = try await URLSession.shared.data(for: request)
        }
        guard let http = response as? HTTPURLResponse else {
            throw UsageFetchError.invalidResponse
        }
        switch http.statusCode {
        case 200:
            await gate.recordSuccess(accountID: account.id)
            return try decodeResponse(data)
        case 401, 403:
            throw classifyRejection(
                statusCode: http.statusCode,
                errorCodeHeader: http.value(forHTTPHeaderField: errorCodeHeader),
                body: data,
                accountID: account.id,
                lastRefresh: (root["last_refresh"] as? String).flatMap(parseLastRefresh))
        case 429:
            // Report the *effective* block, not the raw `Retry-After` — the server
            // sends `Retry-After: 0`, so the header would read "retry now" while the
            // gate actually backs off for `defaultCooldown`.
            let until = await gate.recordRateLimit(
                accountID: account.id, retryAfter: RetryAfter.date(from: http))
            throw UsageFetchError.rateLimited(retryAfter: until)
        default:
            throw UsageFetchError.serverError(http.statusCode)
        }
    }

    /// Response header carrying OpenAI's machine-readable reason for a rejected
    /// token (captured on the wire: `x-openai-ide-error-code: token_expired`).
    private static let errorCodeHeader = "x-openai-ide-error-code"
    private static let tokenExpiredCode = "token_expired"

    /// Pure classifier for a 401/403 from the usage endpoint. A 401 whose
    /// reason is `token_expired` becomes `.tokenRevoked` (see that case for
    /// why it needs its own message); every other 401, and every 403, stays
    /// `.unauthorized` with the old text. 403 is deliberately excluded even
    /// with the code: it's an authorization refusal (Cloudflare, plan, policy)
    /// that a fresh login isn't known to fix.
    ///
    /// The reason is honored from any of the places OpenAI puts it — the
    /// response header, or the body's `error.code` / `detail.code` (the body is
    /// JSON despite a `text/plain` content type) — so a proxy stripping the
    /// header, or a body reshuffle, still classifies. `token_expired` is what
    /// the server says even when the JWT's own `exp` is days away: on this
    /// endpoint it means "no longer accepted", not "time ran out". Either way
    /// the fix is the same login, so no `exp` check is needed here; and we never
    /// refresh a Codex token ourselves (hard rule 2) — only the official CLI may.
    private static func classifyRejection(
        statusCode: Int,
        errorCodeHeader: String?,
        body: Data,
        accountID: String,
        lastRefresh: Date?) -> UsageFetchError
    {
        guard statusCode == 401,
              errorCodes(header: errorCodeHeader, body: body).contains(tokenExpiredCode)
        else { return .unauthorized }
        return .tokenRevoked(accountID: accountID, lastRefresh: lastRefresh)
    }

    /// Every reason code the rejection carries, lowercased: the header plus the
    /// body's `error.code` and `detail.code` (non-JSON bodies contribute none).
    private static func errorCodes(header: String?, body: Data) -> Set<String> {
        var codes: [String?] = [header]
        if let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            codes += ["error", "detail"].map { (root[$0] as? [String: Any])?["code"] as? String }
        }
        return Set(codes.compactMap {
            $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty })
    }

    /// `auth.json`'s `last_refresh`, which the Codex CLI writes as RFC 3339 with
    /// *microseconds* (`2026-10-07T08:49:28.060093Z`) — more fractional digits
    /// than `ISO8601DateFormatter` promises to accept, so on a miss the fraction
    /// is dropped (an age label doesn't need sub-second precision).
    private static func parseLastRefresh(_ raw: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: raw) { return date }
        f.formatOptions = [.withInternetDateTime]
        if let dot = raw.firstIndex(of: ".") {
            let fractionEnd = raw[raw.index(after: dot)...].firstIndex { !$0.isNumber } ?? raw.endIndex
            return f.date(from: String(raw[..<dot] + raw[fractionEnd...]))
        }
        return f.date(from: raw)
    }

    /// Test hook for the rejection classifier (the network path is not unit-tested).
    static func classifyRejectionForTesting(
        statusCode: Int, errorCodeHeader: String?, body: Data,
        accountID: String, lastRefresh: Date? = nil) -> UsageFetchError
    {
        classifyRejection(
            statusCode: statusCode, errorCodeHeader: errorCodeHeader, body: body,
            accountID: accountID, lastRefresh: lastRefresh)
    }

    /// Test hook for the `last_refresh` parser.
    static func parseLastRefreshForTesting(_ raw: String) -> Date? { parseLastRefresh(raw) }

    private static func resolveURL(homeURL: URL) -> URL {
        let configURL = homeURL.appendingPathComponent("config.toml")
        if let contents = try? String(contentsOf: configURL, encoding: .utf8),
           let base = parseChatGPTBaseURL(from: contents)
        {
            return URL(string: normalize(base) + usagePath) ?? defaultURL()
        }
        return defaultURL()
    }

    private static func defaultURL() -> URL {
        URL(string: defaultBaseURL + usagePath)!
    }

    private static func normalize(_ base: String) -> String {
        var s = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if (s.hasPrefix("https://chatgpt.com") || s.hasPrefix("https://chat.openai.com")),
           !s.contains("/backend-api")
        {
            s += "/backend-api"
        }
        return s
    }

    private static func parseChatGPTBaseURL(from contents: String) -> String? {
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let trimmed = rawLine
                .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: true)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == "chatgpt_base_url"
            else { continue }
            var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if (value.hasPrefix("\"") && value.hasSuffix("\""))
                || (value.hasPrefix("'") && value.hasSuffix("'"))
            {
                value = String(value.dropFirst().dropLast())
            }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// Test hook for the response decoder (the network path is not unit-tested).
    static func decodeForTesting(_ data: Data) throws -> UsageReading { try decodeResponse(data) }

    private static func decodeResponse(_ data: Data) throws -> UsageReading {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageFetchError.invalidResponse
        }
        let rateLimit = root["rate_limit"] as? [String: Any]
        let primary = rateLimit?["primary_window"] as? [String: Any]
        let secondary = rateLimit?["secondary_window"] as? [String: Any]
        return UsageReading(
            primaryUsedPercent: usedPercent(from: primary),
            primaryResetsAt: resetAt(from: primary),
            secondaryUsedPercent: usedPercent(from: secondary),
            secondaryResetsAt: resetAt(from: secondary))
    }

    /// `used_percent` tolerating Int, Double, or a numeric String. OpenAI
    /// documents it as an integer 0–100, but we round a fraction defensively
    /// (mirroring CodexBar's flexible decoding) so a `0.7` doesn't blank the
    /// window out instead of reading ~1% used.
    ///
    /// Heuristic: Codex reports `used_percent: 1` for an otherwise-fresh window
    /// (confirmed on the wire — a brand-new 5h window comes back as 1, not 0), so
    /// we floor 0–1 to 0. Seeing "99% left" first thing in the morning is just
    /// noise; 100% reads as the clean reset it actually is.
    private static func usedPercent(from window: [String: Any]?) -> Int? {
        let raw: Int?
        switch window?["used_percent"] {
        case let i as Int: raw = i
        case let d as Double: raw = Int(d.rounded())
        case let s as String:
            raw = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)).map { Int($0.rounded()) }
        default: raw = nil
        }
        return raw.map { $0 <= 1 ? 0 : $0 }
    }

    /// `reset_at` (epoch seconds) tolerating Int or Double.
    private static func resetAt(from window: [String: Any]?) -> Date? {
        switch window?["reset_at"] {
        case let i as Int: return Date(timeIntervalSince1970: TimeInterval(i))
        case let d as Double: return Date(timeIntervalSince1970: d)
        default: return nil
        }
    }
}
