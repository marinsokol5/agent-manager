import Foundation

/// One HTTP exchange — the request we sent and the response we got back — for the
/// Monitoring → Logs view ("if we did an http request, show both it and the
/// response").
///
/// Credential-bearing headers (`Authorization`, `Cookie` / `Set-Cookie`, API-key
/// headers) are redacted before anything reaches disk — on both the request and
/// the response (same "never tokens" rule as `AuditLog`). Bodies are captured in
/// full, but capped so a giant response can't bloat the log.
public struct NetworkLogEntry: Codable, Sendable, Equatable {
    public var time: Date
    public var accountID: String?
    public var method: String
    public var url: String
    public var requestHeaders: [String: String]
    public var requestBody: String?
    /// `nil` when the request never got a response (threw before completing).
    public var statusCode: Int?
    public var responseHeaders: [String: String]
    public var responseBody: String?
    public var durationMs: Int
    public var error: String?

    public init(
        time: Date = Date(),
        accountID: String?,
        method: String,
        url: String,
        requestHeaders: [String: String] = [:],
        requestBody: String? = nil,
        statusCode: Int? = nil,
        responseHeaders: [String: String] = [:],
        responseBody: String? = nil,
        durationMs: Int = 0,
        error: String? = nil)
    {
        self.time = time
        self.accountID = accountID
        self.method = method
        self.url = url
        self.requestHeaders = requestHeaders
        self.requestBody = requestBody
        self.statusCode = statusCode
        self.responseHeaders = responseHeaders
        self.responseBody = responseBody
        self.durationMs = durationMs
        self.error = error
    }
}

/// Append-only JSONL log of HTTP exchanges. Best-effort, like `AuditLog` /
/// `ActivityLog`: a logging failure never breaks the request it observes.
public struct NetworkLog: Sendable {
    let fileURL: URL

    /// Cap on each captured body so a pathological response can't bloat the log.
    static let maxBodyBytes = 16_000

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public init(workspace: Workspace) {
        self.init(fileURL: workspace.networkLogFile)
    }

    public func append(_ entry: NetworkLogEntry) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entry) else { return }
        JSONLAppend.appendLine(data, to: fileURL)
    }

    /// Most recent exchanges first, capped at `limit`; `since` drops anything
    /// older (Monitoring shows a rolling time window, not the whole file).
    public func readRecent(limit: Int = 100, since: Date? = nil) -> [NetworkLogEntry] {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var recs = content.split(separator: "\n").compactMap { line -> NetworkLogEntry? in
            guard let d = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(NetworkLogEntry.self, from: d)
        }
        if let since { recs.removeAll { $0.time < since } }
        recs.reverse()
        return Array(recs.prefix(limit))
    }

    // MARK: - Performing + recording a request

    /// Run `request` via `session`, recording the full exchange (token-redacted).
    /// Returns exactly what `URLSession.data(for:)` returns — logging never alters
    /// the result, and a failed request is logged with its error before rethrowing.
    public func perform(
        _ request: URLRequest,
        accountID: String?,
        session: URLSession = .shared) async throws -> (Data, URLResponse)
    {
        let start = Date()
        do {
            let (data, response) = try await session.data(for: request)
            append(Self.record(request, accountID: accountID, start: start, data: data, response: response, error: nil))
            return (data, response)
        } catch {
            append(Self.record(request, accountID: accountID, start: start, data: nil, response: nil, error: error))
            throw error
        }
    }

    private static func record(
        _ request: URLRequest,
        accountID: String?,
        start: Date,
        data: Data?,
        response: URLResponse?,
        error: Error?) -> NetworkLogEntry
    {
        let http = response as? HTTPURLResponse
        var responseHeaders: [String: String] = [:]
        if let http {
            for (key, value) in http.allHeaderFields { responseHeaders["\(key)"] = "\(value)" }
        }
        return NetworkLogEntry(
            time: start,
            accountID: accountID,
            method: request.httpMethod ?? "GET",
            url: request.url?.absoluteString ?? "",
            requestHeaders: redacted(request.allHTTPHeaderFields),
            requestBody: body(request.httpBody),
            statusCode: http?.statusCode,
            responseHeaders: redacted(responseHeaders),
            responseBody: body(data),
            durationMs: Int(Date().timeIntervalSince(start) * 1000),
            error: error.map { "\($0)" })
    }

    /// Header names whose values are credentials and must never reach disk
    /// (matched case-insensitively). `authorization` / `proxy-authorization` keep
    /// their scheme (`Bearer ••••••`) — the scheme is useful and not secret — while
    /// the rest are masked whole.
    private static let sensitiveHeaders: Set<String> = [
        "authorization", "proxy-authorization",
        "cookie", "set-cookie",
        "x-api-key", "api-key", "anthropic-api-key", "openai-api-key",
    ]

    /// Redact credential-bearing headers so they never land in the log; everything
    /// else passes through (header *names* and non-secret values aid debugging).
    /// Applied to request *and* response headers — a response `Set-Cookie` is as
    /// sensitive as a request `Authorization`.
    private static func redacted(_ headers: [String: String]?) -> [String: String] {
        guard let headers else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in headers {
            let name = key.lowercased()
            guard sensitiveHeaders.contains(name) else { out[key] = value; continue }
            if name == "authorization" || name == "proxy-authorization" {
                let scheme = value.split(separator: " ").first.map(String.init) ?? "Bearer"
                out[key] = "\(scheme) ••••••"
            } else {
                out[key] = "••••••"
            }
        }
        return out
    }

    /// Test hook for the (private) header redaction — the network path itself is
    /// not unit-tested, but this invariant is too important to leave uncovered.
    static func redactForTesting(_ headers: [String: String]) -> [String: String] {
        redacted(headers)
    }

    /// Decode a body as UTF-8 for display, capped at `maxBodyBytes`.
    private static func body(_ data: Data?) -> String? {
        guard let data, !data.isEmpty else { return nil }
        let capped = data.prefix(maxBodyBytes)
        var string = String(decoding: capped, as: UTF8.self)
        if data.count > maxBodyBytes {
            string += "\n… (truncated — \(data.count) bytes total)"
        }
        return string
    }
}
