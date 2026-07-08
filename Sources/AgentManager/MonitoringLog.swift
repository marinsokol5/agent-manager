import AgentManagerCore
import Foundation

/// One row in Monitoring → Logs: a unified, time-ordered view of everything the
/// app did — every ping, every controlled run, and every HTTP request with its
/// full response. Built by merging the activity, audit, and network logs.
struct MonitoringLogEntry: Identifiable, Sendable {
    enum Kind: Sendable { case ping, http, action }

    /// Coarse usecase bucket for the Logs filter, assigned once at merge time
    /// (from the row's kind, dotted audit action, or HTTP host + path) so the
    /// view never classifies by string-matching display titles. Every row gets
    /// exactly one bucket — unknown future audit actions land in `.setup`
    /// (the account-lifecycle catch-all) rather than escaping the filter.
    enum Category: String, CaseIterable, Identifiable, Sendable {
        case pings = "Pings"
        case runs = "Runs"
        case usage = "Usage"
        case scheduler = "Scheduler"
        case setup = "Setup"
        var id: String { rawValue }
    }

    let id: String
    let time: Date
    let kind: Kind
    let ok: Bool
    let accountID: String?
    /// Short headline (the one-liner you scan).
    let title: String
    /// Secondary detail (outcome, host + timing, error).
    let detail: String
    /// Populated for `.http` rows so the row can expand to the full exchange.
    let http: NetworkLogEntry?
    /// Populated for `.ping` rows that saved a PTY transcript, so the row can
    /// expand to show what the agent actually replied (read lazily from disk).
    let transcriptPath: String?
    /// Usecase bucket the Logs filter toggles on (see `Category`).
    let category: Category
    /// Provider inferred from the HTTP host, for rows whose `accountID` can't
    /// be resolved against the current account inventory (removed accounts,
    /// account-less exchanges). The view prefers the account's real provider
    /// and falls back to this; rows with neither always pass a provider filter.
    let providerHint: Provider?

    /// Merge the three on-disk logs into a single newest-first feed. Ping rows
    /// come from the activity log (richest — they carry the anchor result), so
    /// the duplicate `ping` / `ping.start` audit lines are dropped to keep the
    /// timeline clear.
    static func merge(
        activity: [ActivityRecord],
        audit: [AuditEvent],
        network: [NetworkLogEntry]) -> [MonitoringLogEntry]
    {
        var out: [MonitoringLogEntry] = []

        for r in activity {
            let outcome = r.ok ? (r.anchored ? "anchored" : "ran · no anchor") : "failed"
            out.append(.init(
                id: "ping-\(r.time.timeIntervalSince1970)-\(r.accountID)",
                time: r.time, kind: .ping, ok: r.ok, accountID: r.accountID,
                title: "Ping \(r.accountID)",
                detail: "\(outcome) · \(r.detail)", http: nil, transcriptPath: r.transcriptPath,
                category: .pings, providerHint: nil))
        }

        for e in audit where e.action != "ping" && e.action != "ping.start" {
            out.append(.init(
                id: "audit-\(e.time.timeIntervalSince1970)-\(e.action)-\(e.accountID ?? "")",
                time: e.time, kind: .action, ok: e.ok, accountID: e.accountID,
                title: humanize(e.action),
                detail: e.detail, http: nil, transcriptPath: nil,
                category: classify(action: e.action), providerHint: nil))
        }

        for n in network {
            let status = n.statusCode.map(String.init) ?? "ERR"
            let parsed = URL(string: n.url)
            let path = parsed?.path.isEmpty == false ? parsed!.path : n.url
            let host = parsed?.host ?? ""
            out.append(.init(
                id: "http-\(n.time.timeIntervalSince1970)-\(n.url)",
                time: n.time, kind: .http,
                ok: n.error == nil && (n.statusCode.map { (200..<300).contains($0) } ?? false),
                accountID: n.accountID,
                title: "\(n.method) \(path) → \(status)",
                detail: n.error ?? "\(host) · \(n.durationMs) ms",
                http: n, transcriptPath: nil,
                category: classify(httpPath: path), providerHint: providerHint(host: host)))
        }

        return out.sorted { $0.time > $1.time }
    }

    /// Bucket a dotted audit action by its first segment. `token.refresh` sits
    /// with Usage (it's the delegated refresh the usage fetch rides on);
    /// `wake.*` and `routine.*` sit with Scheduler (the wake helper and cloud
    /// fallback exist only to serve scheduled pings). Everything else —
    /// `login.*`, `account.*`, `config.*`, `home.*`, `symlink.*`, `verify` —
    /// is account lifecycle, i.e. Setup.
    static func classify(action: String) -> Category {
        switch action.split(separator: ".").first.map(String.init) ?? action {
        case "ping": .pings
        case "run": .runs
        case "token": .usage
        case "scheduler", "wake", "routine": .scheduler
        default: .setup
        }
    }

    /// Bucket an HTTP row by its URL path: trigger/environment calls are the
    /// cloud fallback's routine management (Scheduler); every other exchange
    /// the app makes is a usage read.
    static func classify(httpPath path: String) -> Category {
        if path.contains("/code/triggers") || path.contains("/environment_providers") {
            return .scheduler
        }
        return .usage
    }

    /// Infer a provider from an HTTP host (see `providerHint`).
    static func providerHint(host: String) -> Provider? {
        if host == "anthropic.com" || host.hasSuffix(".anthropic.com") { return .claude }
        if host == "chatgpt.com" || host.hasSuffix(".chatgpt.com")
            || host == "chat.openai.com" { return .codex }
        return nil
    }

    /// Humanize a dotted audit key, e.g. `token.refresh` → "Token refresh".
    private static func humanize(_ action: String) -> String {
        let words = action.split(separator: ".").joined(separator: " ")
        guard let first = words.first else { return action }
        return first.uppercased() + words.dropFirst()
    }
}
