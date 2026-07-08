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

/// `TranscriptCleaner` turns a raw PTY dump into legible plain text. The
/// regression these tests exist for: the original stripper wrote its
/// patterns as raw strings, so `\u{001B}` reached ICU as literal text it
/// can't parse and *nothing* was ever stripped — every assertion here uses a
/// real ESC character precisely because that's the case that silently broke.
final class TranscriptCleanerTests: XCTestCase {
    private let esc = "\u{001B}"

    func testStripsColorAndModeSequences() {
        let raw = "\(esc)[38;5;174mhello\(esc)[0m \(esc)[?25h\(esc)[?2004hworld"
        XCTAssertEqual(TranscriptCleaner.plainText(raw), "hello world")
    }

    func testColumnJumpsBecomeSingleSpaces() {
        // A TUI positions words with column jumps instead of spaces; deleting
        // them would fuse the words together.
        let raw = "Claude\(esc)[21GCode\(esc)[28Gv2.1.204"
        XCTAssertEqual(TranscriptCleaner.plainText(raw), "Claude Code v2.1.204")
    }

    func testStripsOrphanedBodiesWhoseEscapeWasLost() {
        // Sequence bodies with the ESC byte already stripped upstream.
        let raw = "[2G[38;5;174mdraws down usage[39m"
        XCTAssertEqual(TranscriptCleaner.plainText(raw), "draws down usage")
    }

    func testStripsOSCTitleAndTwoCharSequences() {
        let raw = "\(esc)]0;✳ Claude Code\u{0007}\(esc)7ready\(esc)8\(esc)[c"
        XCTAssertEqual(TranscriptCleaner.plainText(raw), "ready")
    }

    func testStripsPrivateParameterSequences() {
        // `ESC [ > 0 q` (terminal-version query) uses the `<=>` marker range
        // the original [0-9;?] parameter class missed.
        let raw = "\(esc)[>0qvisible\(esc)[>4;2m"
        XCTAssertEqual(TranscriptCleaner.plainText(raw), "visible")
    }

    func testCollapsesScreenWideRulesAndBlankLines() {
        let raw = "a\n\n\n\n" + String(repeating: "\u{2500}", count: 120) + "\nb"
        XCTAssertEqual(
            TranscriptCleaner.plainText(raw),
            "a\n\n" + String(repeating: "\u{2500}", count: 8) + "\nb")
    }

    func testKeepsNewlinesAndTabsDropsOtherControls() {
        let raw = "one\r\r\ntwo\tthree\u{0007}"
        XCTAssertEqual(TranscriptCleaner.plainText(raw), "one\ntwo\tthree")
    }
}
