import Foundation

// MARK: - Error type

public enum TriggerAPIError: Error, LocalizedError, Sendable, Equatable {
    case invalidResponse
    case unauthorized
    /// The resource (trigger) is gone — e.g. the user deleted the routine on
    /// claude.ai. Distinct from `serverError` because the engine *recreates*
    /// on 404 instead of backing off.
    case notFound
    case rateLimited(retryAfter: Date?)
    case serverError(Int)
    /// A background read needed the Keychain prompt we won't show.
    case keychainAccessDeferred
    /// The account's `.claude.json` has no `oauthAccount.organizationUuid`.
    case missingOrganization

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "Invalid response from the routines API."
        case .unauthorized: "Routines API rejected the token (401/403)."
        case .notFound: "Routine not found (deleted on claude.ai?)."
        case .rateLimited: "Rate limited by the routines API — backing off."
        case let .serverError(code): "Routines API returned HTTP \(code)."
        case .keychainAccessDeferred: "Keychain access deferred (no background grant)."
        case .missingOrganization: "No organizationUuid in this account's .claude.json."
        }
    }
}

// MARK: - Wire types

/// The slice of a claude.ai trigger ("routine") the cloud fallback cares about.
public struct CloudTrigger: Sendable, Equatable {
    public var id: String
    public var name: String?
    public var enabled: Bool
    public var runOnceAt: Date?
    public var nextRunAt: Date?
    /// `"run_once_fired"` after a one-shot fired (the routine auto-disabled).
    public var endedReason: String?

    public init(
        id: String,
        name: String? = nil,
        enabled: Bool = false,
        runOnceAt: Date? = nil,
        nextRunAt: Date? = nil,
        endedReason: String? = nil)
    {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.runOnceAt = runOnceAt
        self.nextRunAt = nextRunAt
        self.endedReason = endedReason
    }
}

/// One entry from `GET /v1/environment_providers`.
public struct CloudEnvironment: Sendable, Equatable {
    public var id: String
    public var kind: String?
    public var name: String?
    public var state: String?

    public init(id: String, kind: String? = nil, name: String? = nil, state: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.state = state
    }

    /// Usable as a routine's execution environment.
    public var isActiveCloud: Bool { kind == "anthropic_cloud" && state == "active" }
}

/// Everything a create needs for the minimal anchor routine. The event UUID is
/// generated fresh per create inside the client.
public struct AnchorRoutineSpec: Sendable, Equatable {
    public var name: String
    public var runOnceAt: Date
    public var environmentID: String
    public var model: String
    public var prompt: String

    public init(name: String, runOnceAt: Date, environmentID: String, model: String, prompt: String) {
        self.name = name
        self.runOnceAt = runOnceAt
        self.environmentID = environmentID
        self.model = model
        self.prompt = prompt
    }
}

/// A partial trigger update (`POST /v1/code/triggers/{id}` is a partial merge).
public struct TriggerPatch: Sendable, Equatable {
    public var runOnceAt: Date?
    public var enabled: Bool?

    public init(runOnceAt: Date? = nil, enabled: Bool? = nil) {
        self.runOnceAt = runOnceAt
        self.enabled = enabled
    }
}

// MARK: - Client

/// Minimal client for the claude.ai routines API (`api.anthropic.com
/// /v1/code/triggers`) — the machinery behind claude.ai/code/routines, which
/// the cloud fallback uses to keep one anchor routine armed per account.
///
/// Wire contract captured live from the real clients (CLI + web, 2026-07-04):
/// OAuth bearer + `x-organization-uuid` (the CLI's "teleport-org" auth mode)
/// plus the `ccr-triggers-2026-01-30` beta. Deliberately *not* implemented:
/// DELETE — the API only exposes it to cookie-authenticated web/desktop
/// sessions, and we never touch cookie auth; "off" is `enabled: false`, and a
/// stray one-shot can fire at most once anyway.
///
/// Mirrors `ClaudeUsageFetcher`: token passed in (never read here), transport
/// through `NetworkLog.perform` (automatic credential redaction — and note the
/// bodies these endpoints carry are trigger config, never secrets), pure
/// decoders with `decodeForTesting` hooks, network path itself untested.
public enum TriggerClient {
    static let triggersURL = URL(string: "https://api.anthropic.com/v1/code/triggers")!
    static let environmentsURL = URL(string: "https://api.anthropic.com/v1/environment_providers")!
    static let environmentCreateURL = URL(string: "https://api.anthropic.com/v1/environment_providers/cloud/create")!
    /// Required by the triggers endpoints (missing → 404 "not found"). The
    /// environment endpoints need no beta at all.
    static let triggersBeta = "ccr-triggers-2026-01-30"

    /// Per-account authentication: the OAuth access token (login Keychain) and
    /// the org UUID (`oauthAccount.organizationUuid` in the managed home's
    /// `.claude.json` — on disk already, no extra call).
    public struct Auth: Sendable, Equatable {
        public let accessToken: String
        public let organizationUUID: String

        public init(accessToken: String, organizationUUID: String) {
            self.accessToken = accessToken
            self.organizationUUID = organizationUUID
        }
    }

    // MARK: Requests

    public static func listTriggers(
        auth: Auth, accountID: String, log: NetworkLog? = nil) async throws -> [CloudTrigger]
    {
        let data = try await send("GET", url: triggersURL, auth: auth, beta: triggersBeta,
                                  body: nil, accountID: accountID, log: log)
        return try decodeTriggerList(data)
    }

    public static func getTrigger(
        id: String, auth: Auth, accountID: String, log: NetworkLog? = nil) async throws -> CloudTrigger
    {
        let data = try await send("GET", url: triggersURL.appendingPathComponent(id), auth: auth,
                                  beta: triggersBeta, body: nil, accountID: accountID, log: log)
        return try decodeTrigger(data)
    }

    /// Create the account's one-shot anchor routine. Always `run_once_at` —
    /// never a cron — so an orphaned routine fires at most once, ever.
    public static func createAnchorRoutine(
        _ spec: AnchorRoutineSpec, auth: Auth, accountID: String, log: NetworkLog? = nil)
        async throws -> CloudTrigger
    {
        let body: [String: Any] = [
            "name": spec.name,
            "run_once_at": rfc3339(spec.runOnceAt),
            "enabled": true,
            "job_config": [
                "ccr": [
                    "environment_id": spec.environmentID,
                    "session_context": [
                        "model": spec.model,
                        // The preset keeps the stored config minimal; omitting
                        // it makes the server expand the full default tool list.
                        "allowed_tools": ["preset:default"],
                    ],
                    "events": [[
                        "data": [
                            "uuid": UUID().uuidString.lowercased(),
                            "session_id": "",
                            "type": "user",
                            "parent_tool_use_id": NSNull(),
                            "message": ["content": spec.prompt, "role": "user"],
                        ],
                    ]],
                ],
            ],
        ]
        let data = try await send("POST", url: triggersURL, auth: auth, beta: triggersBeta,
                                  body: body, accountID: accountID, log: log)
        return try decodeTrigger(data)
    }

    /// Partial update: re-arm (`run_once_at`, which also re-enables a fired
    /// one-shot when paired with `enabled: true`) or pause (`enabled: false`).
    public static func updateTrigger(
        id: String, patch: TriggerPatch, auth: Auth, accountID: String, log: NetworkLog? = nil)
        async throws -> CloudTrigger
    {
        var body: [String: Any] = [:]
        if let runOnceAt = patch.runOnceAt { body["run_once_at"] = rfc3339(runOnceAt) }
        if let enabled = patch.enabled { body["enabled"] = enabled }
        let data = try await send("POST", url: triggersURL.appendingPathComponent(id), auth: auth,
                                  beta: triggersBeta, body: body, accountID: accountID, log: log)
        return try decodeTrigger(data)
    }

    public static func listEnvironments(
        auth: Auth, accountID: String, log: NetworkLog? = nil) async throws -> [CloudEnvironment]
    {
        let data = try await send("GET", url: environmentsURL, auth: auth, beta: nil,
                                  body: nil, accountID: accountID, log: log)
        return try decodeEnvironments(data)
    }

    /// Create the org's cloud environment when it has none (an account that
    /// never opened claude.ai/code). All three fields are required — probed
    /// live: the API 400s naming each missing one.
    public static func createCloudEnvironment(
        name: String, description: String, auth: Auth, accountID: String, log: NetworkLog? = nil)
        async throws -> CloudEnvironment
    {
        let body: [String: Any] = ["name": name, "kind": "anthropic_cloud", "description": description]
        let data = try await send("POST", url: environmentCreateURL, auth: auth, beta: nil,
                                  body: body, accountID: accountID, log: log)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = decodeEnvironment(root)
        else { throw TriggerAPIError.invalidResponse }
        return env
    }

    // MARK: Transport

    private static func send(
        _ method: String,
        url: URL,
        auth: Auth,
        beta: String?,
        body: [String: Any]?,
        accountID: String,
        log: NetworkLog?) async throws -> Data
    {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        // Mirror the real `claude` CLI's trigger requests (captured from the
        // wire) so this beta-gated endpoint sees nothing anomalous.
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("claude_code_cli", forHTTPHeaderField: "anthropic-client-platform")
        request.setValue(auth.organizationUUID, forHTTPHeaderField: "x-organization-uuid")
        if let beta { request.setValue(beta, forHTTPHeaderField: "anthropic-beta") }
        request.setValue(await ClaudeCodeUserAgent.shared.value(), forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        let (data, response): (Data, URLResponse)
        if let log {
            (data, response) = try await log.perform(request, accountID: accountID)
        } else {
            (data, response) = try await URLSession.shared.data(for: request)
        }
        guard let http = response as? HTTPURLResponse else {
            throw TriggerAPIError.invalidResponse
        }
        switch http.statusCode {
        case 200...299:
            return data
        case 401, 403:
            throw TriggerAPIError.unauthorized
        case 404:
            throw TriggerAPIError.notFound
        case 429:
            throw TriggerAPIError.rateLimited(retryAfter: RetryAfter.date(from: http))
        default:
            throw TriggerAPIError.serverError(http.statusCode)
        }
    }

    // MARK: Decoding (pure; test hooks below)

    private static func decodeTrigger(_ data: Data) throws -> CloudTrigger {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let trigger = root["trigger"] as? [String: Any],
              let parsed = parseTrigger(trigger)
        else { throw TriggerAPIError.invalidResponse }
        return parsed
    }

    private static func decodeTriggerList(_ data: Data) throws -> [CloudTrigger] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["data"] as? [[String: Any]]
        else { throw TriggerAPIError.invalidResponse }
        return list.compactMap(parseTrigger)
    }

    private static func decodeEnvironments(_ data: Data) throws -> [CloudEnvironment] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["environments"] as? [[String: Any]]
        else { throw TriggerAPIError.invalidResponse }
        return list.compactMap(decodeEnvironment)
    }

    private static func parseTrigger(_ dict: [String: Any]) -> CloudTrigger? {
        guard let id = dict["id"] as? String, !id.isEmpty else { return nil }
        return CloudTrigger(
            id: id,
            name: dict["name"] as? String,
            enabled: dict["enabled"] as? Bool ?? false,
            runOnceAt: (dict["run_once_at"] as? String).flatMap(parseISO8601),
            nextRunAt: (dict["next_run_at"] as? String).flatMap(parseISO8601),
            endedReason: (dict["ended_reason"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    private static func decodeEnvironment(_ dict: [String: Any]) -> CloudEnvironment? {
        guard let id = dict["environment_id"] as? String, !id.isEmpty else { return nil }
        return CloudEnvironment(
            id: id,
            kind: dict["kind"] as? String,
            name: dict["name"] as? String,
            state: dict["state"] as? String)
    }

    static func decodeTriggerForTesting(_ data: Data) throws -> CloudTrigger { try decodeTrigger(data) }
    static func decodeTriggerListForTesting(_ data: Data) throws -> [CloudTrigger] { try decodeTriggerList(data) }
    static func decodeEnvironmentsForTesting(_ data: Data) throws -> [CloudEnvironment] { try decodeEnvironments(data) }

    // MARK: Dates

    /// `run_once_at` wants RFC3339 UTC with whole seconds (`2026-07-05T05:00:00Z`).
    static func rfc3339(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.string(from: date)
    }

    private static func parseISO8601(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
