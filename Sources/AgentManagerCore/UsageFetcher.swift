import Foundation

// MARK: - Shared error type

public enum UsageFetchError: Error, LocalizedError, Sendable {
    case keychainReadFailed
    case tokenDecodeFailed
    case invalidResponse
    case unauthorized
    case rateLimited(retryAfter: Date?)
    case serverError(Int)
    /// A background read needs the Keychain prompt we won't show; keep cached
    /// usage and wait for an explicit "Refresh usage". Swallowed by the caller.
    case keychainAccessDeferred

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
        case .keychainAccessDeferred:
            "Click “Refresh usage” to allow Keychain access."
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
