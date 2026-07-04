import XCTest
@testable import AgentManagerCore

/// The Monitoring feeds show a rolling time window, not the whole file: the
/// `since` cutoff on the log readers must drop entries older than the window
/// while keeping newest-first order and the `limit` safety cap intact.
final class LogWindowTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testActivityLogSinceDropsOlderRecords() {
        let log = ActivityLog(fileURL: dir.appendingPathComponent("activity.jsonl"), logsDir: dir)
        let now = Date()
        log.append(ActivityRecord(time: now.addingTimeInterval(-3 * 86_400), accountID: "old", ok: true, anchored: true, detail: ""))
        log.append(ActivityRecord(time: now, accountID: "new", ok: true, anchored: true, detail: ""))

        XCTAssertEqual(log.readRecent().map(\.accountID), ["new", "old"])
        XCTAssertEqual(log.readRecent(since: now.addingTimeInterval(-48 * 3_600)).map(\.accountID), ["new"])
    }

    func testAuditLogSinceDropsOlderEvents() {
        let log = AuditLog(fileURL: dir.appendingPathComponent("audit.log.jsonl"))
        let now = Date()
        log.append(AuditEvent(time: now.addingTimeInterval(-3 * 86_400), accountID: nil, action: "old.action", ok: true, detail: ""))
        log.append(AuditEvent(time: now, accountID: nil, action: "new.action", ok: true, detail: ""))

        XCTAssertEqual(log.readRecent().map(\.action), ["new.action", "old.action"])
        XCTAssertEqual(log.readRecent(since: now.addingTimeInterval(-48 * 3_600)).map(\.action), ["new.action"])
    }

    func testNetworkLogSinceDropsOlderEntries() {
        let log = NetworkLog(fileURL: dir.appendingPathComponent("network.jsonl"))
        let now = Date()
        log.append(NetworkLogEntry(time: now.addingTimeInterval(-3 * 86_400), accountID: nil, method: "GET", url: "https://example.com/old"))
        log.append(NetworkLogEntry(time: now, accountID: nil, method: "GET", url: "https://example.com/new"))

        XCTAssertEqual(log.readRecent().map(\.url), ["https://example.com/new", "https://example.com/old"])
        XCTAssertEqual(log.readRecent(since: now.addingTimeInterval(-48 * 3_600)).map(\.url), ["https://example.com/new"])
    }
}
