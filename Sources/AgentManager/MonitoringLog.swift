import AgentManagerCore
import Foundation

/// One row in Monitoring → Logs: a unified, time-ordered view of everything the
/// app did — every ping, every controlled run, and every HTTP request with its
/// full response. Built by merging the activity, audit, and network logs.
struct MonitoringLogEntry: Identifiable, Sendable {
    enum Kind: Sendable { case ping, http, action }

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
                detail: "\(outcome) · \(r.detail)", http: nil, transcriptPath: r.transcriptPath))
        }

        for e in audit where e.action != "ping" && e.action != "ping.start" {
            out.append(.init(
                id: "audit-\(e.time.timeIntervalSince1970)-\(e.action)-\(e.accountID ?? "")",
                time: e.time, kind: .action, ok: e.ok, accountID: e.accountID,
                title: humanize(e.action),
                detail: e.detail, http: nil, transcriptPath: nil))
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
                http: n, transcriptPath: nil))
        }

        return out.sorted { $0.time > $1.time }
    }

    /// Humanize a dotted audit key, e.g. `token.refresh` → "Token refresh".
    private static func humanize(_ action: String) -> String {
        let words = action.split(separator: ".").joined(separator: " ")
        guard let first = words.first else { return action }
        return first.uppercased() + words.dropFirst()
    }
}
