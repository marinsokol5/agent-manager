import XCTest
@testable import AgentManagerCore

final class UsageRateLimitGateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeGate() -> UsageRateLimitGate {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return UsageRateLimitGate(fileURL: dir.appendingPathComponent("usage-ratelimit.json"))
    }

    /// The server sends `Retry-After: 0`, so the raw header is at/before now. The
    /// gate must ignore it and back off for `defaultCooldown`, and must *return*
    /// that effective instant so the caller can report the real retry time.
    func testRetryAfterZeroReturnsDefaultCooldown() async {
        let gate = makeGate()
        let until = await gate.recordRateLimit(accountID: "a", retryAfter: now, now: now)
        XCTAssertEqual(until, now.addingTimeInterval(UsageRateLimitGate.defaultCooldown))
        // And the block it hands out on a subsequent read matches what it returned.
        let blocked = await gate.blockedUntil(accountID: "a", now: now)
        XCTAssertEqual(blocked, until)
    }

    /// A `Retry-After` genuinely in the future is honored verbatim and returned.
    func testFutureRetryAfterIsHonored() async {
        let gate = makeGate()
        let future = now.addingTimeInterval(90)
        let until = await gate.recordRateLimit(accountID: "a", retryAfter: future, now: now)
        XCTAssertEqual(until, future)
    }

    /// A missing header (`nil`) also falls back to the default cooldown.
    func testMissingRetryAfterUsesDefaultCooldown() async {
        let gate = makeGate()
        let until = await gate.recordRateLimit(accountID: "a", retryAfter: nil, now: now)
        XCTAssertEqual(until, now.addingTimeInterval(UsageRateLimitGate.defaultCooldown))
    }
}
