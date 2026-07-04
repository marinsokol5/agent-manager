import XCTest
@testable import AgentManagerCore

final class UsageReadingExpiryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func reading(primaryUsed: Int?, primaryResetsIn: TimeInterval?,
                         secondaryUsed: Int? = nil, secondaryResetsIn: TimeInterval? = nil) -> UsageReading {
        UsageReading(
            primaryUsedPercent: primaryUsed,
            primaryResetsAt: primaryResetsIn.map { now.addingTimeInterval($0) },
            secondaryUsedPercent: secondaryUsed,
            secondaryResetsAt: secondaryResetsIn.map { now.addingTimeInterval($0) },
            fetchedAt: now)
    }

    func testLiveWindowReportsActualUsage() {
        let r = reading(primaryUsed: 8, primaryResetsIn: 3600) // resets in 1h → live
        XCTAssertFalse(r.primaryWindowExpired(now: now))
        XCTAssertEqual(r.effectivePrimaryUsedPercent(now: now), 8)
        XCTAssertEqual(r.effectivePrimaryRemainingPercent(now: now), 92)
    }

    func testExpiredWindowReportsFullHeadroom() {
        // The exact bug: 8% left (92% used) but the window reset an hour ago.
        let r = reading(primaryUsed: 92, primaryResetsIn: -3600)
        XCTAssertTrue(r.primaryWindowExpired(now: now))
        XCTAssertEqual(r.effectivePrimaryUsedPercent(now: now), 0)
        XCTAssertEqual(r.effectivePrimaryRemainingPercent(now: now), 100)
    }

    func testResetExactlyNowCountsAsExpired() {
        let r = reading(primaryUsed: 50, primaryResetsIn: 0)
        XCTAssertTrue(r.primaryWindowExpired(now: now))
        XCTAssertEqual(r.effectivePrimaryRemainingPercent(now: now), 100)
    }

    func testMissingResetKeepsRawValue() {
        // No reset reported → we can't claim expiry, so the raw figure stands.
        let r = reading(primaryUsed: 30, primaryResetsIn: nil)
        XCTAssertFalse(r.primaryWindowExpired(now: now))
        XCTAssertEqual(r.effectivePrimaryRemainingPercent(now: now), 70)
    }

    func testNoDataStaysNil() {
        let r = reading(primaryUsed: nil, primaryResetsIn: -3600)
        XCTAssertNil(r.effectivePrimaryUsedPercent(now: now))
        XCTAssertNil(r.effectivePrimaryRemainingPercent(now: now))
    }

    func testSecondaryExpiryIsIndependent() {
        // Primary live, weekly expired.
        let r = reading(primaryUsed: 40, primaryResetsIn: 3600,
                        secondaryUsed: 75, secondaryResetsIn: -60)
        XCTAssertEqual(r.effectivePrimaryRemainingPercent(now: now), 60)
        XCTAssertEqual(r.effectiveSecondaryRemainingPercent(now: now), 100)
    }
}
