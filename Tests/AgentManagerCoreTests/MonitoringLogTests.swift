import XCTest
import AgentManagerCore
@testable import AgentManager

/// The Logs-tab filter buckets every merged row exactly once, at merge time
/// (`MonitoringLogEntry.Category`). These tests pin the classification — the
/// audit-action → bucket map, the HTTP path split (usage read vs. trigger
/// call), and the host → provider hint — so a new audit action or endpoint
/// that lands in the wrong chip is a conscious change here, not a silent one.
final class MonitoringLogTests: XCTestCase {

    // MARK: - Audit action → category

    func testAuditActionClassification() {
        let expectations: [(String, MonitoringLogEntry.Category)] = [
            ("ping.skip", .pings),
            ("run.exec", .runs),
            ("token.refresh", .usage),
            ("scheduler.start", .scheduler),
            ("scheduler.reregister", .scheduler),
            ("wake.reregister", .scheduler),
            ("routine.arm", .scheduler),
            ("login.result", .setup),
            ("account.add.start", .setup),
            ("config.seed", .setup),
            ("home.create", .setup),
            ("symlink.reconcile", .setup),
            ("verify", .setup),
            // Unknown future actions must still land somewhere filterable.
            ("mystery.action", .setup),
        ]
        for (action, expected) in expectations {
            XCTAssertEqual(
                MonitoringLogEntry.classify(action: action), expected,
                "action '\(action)' should classify as \(expected)")
        }
    }

    // MARK: - HTTP path → category, host → provider hint

    func testHTTPClassification() {
        XCTAssertEqual(MonitoringLogEntry.classify(httpPath: "/api/oauth/usage"), .usage)
        XCTAssertEqual(MonitoringLogEntry.classify(httpPath: "/backend-api/wham/usage"), .usage)
        XCTAssertEqual(MonitoringLogEntry.classify(httpPath: "/v1/code/triggers"), .scheduler)
        XCTAssertEqual(MonitoringLogEntry.classify(httpPath: "/v1/code/triggers/tr_123"), .scheduler)
        XCTAssertEqual(MonitoringLogEntry.classify(httpPath: "/v1/environment_providers"), .scheduler)
    }

    func testProviderHintFromHost() {
        XCTAssertEqual(MonitoringLogEntry.providerHint(host: "api.anthropic.com"), .claude)
        XCTAssertEqual(MonitoringLogEntry.providerHint(host: "chatgpt.com"), .codex)
        XCTAssertEqual(MonitoringLogEntry.providerHint(host: "chat.openai.com"), .codex)
        XCTAssertNil(MonitoringLogEntry.providerHint(host: "example.com"))
        // Suffix match must not swallow look-alike registrable domains.
        XCTAssertNil(MonitoringLogEntry.providerHint(host: "notanthropic.com"))
    }

    // MARK: - Merge wires the buckets through

    func testMergeAssignsCategoriesAndHints() {
        let merged = MonitoringLogEntry.merge(
            activity: [ActivityRecord(accountID: "work", ok: true, anchored: true, detail: "anchored")],
            audit: [
                AuditEvent(accountID: "work", action: "run.exec", ok: true, detail: "claude: /bin/claude"),
                AuditEvent(accountID: nil, action: "scheduler.start", ok: true, detail: "pid 1"),
                // Dropped: activity already carries the richer ping row.
                AuditEvent(accountID: "work", action: "ping", ok: true, detail: "dup"),
            ],
            network: [
                NetworkLogEntry(accountID: "work", method: "GET",
                                url: "https://api.anthropic.com/api/oauth/usage", statusCode: 200),
                NetworkLogEntry(accountID: "work", method: "POST",
                                url: "https://api.anthropic.com/v1/code/triggers", statusCode: 200),
            ])

        XCTAssertEqual(merged.count, 5, "the duplicate 'ping' audit row should be dropped")

        let byKindAndTitle = { (title: String) in merged.first { $0.title == title } }
        let ping = merged.first { $0.kind == .ping }
        XCTAssertEqual(ping?.category, .pings)
        XCTAssertNil(ping?.providerHint)

        XCTAssertEqual(byKindAndTitle("Run exec")?.category, .runs)
        XCTAssertEqual(byKindAndTitle("Scheduler start")?.category, .scheduler)

        let usage = merged.first { $0.http != nil && $0.category == .usage }
        XCTAssertEqual(usage?.providerHint, .claude)
        let trigger = merged.first { $0.http != nil && $0.category == .scheduler }
        XCTAssertEqual(trigger?.providerHint, .claude)
    }
}
