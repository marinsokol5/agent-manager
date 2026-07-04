import XCTest
@testable import AgentManagerCore

final class StalePingPolicyTests: XCTestCase {
    let scheduled = Date(timeIntervalSince1970: 1_800_000_000)

    func testOnTimeFireIsFresh() {
        XCTAssertFalse(StalePingPolicy.isStale(scheduledFire: scheduled, now: scheduled.addingTimeInterval(20)))
    }

    func testWithinGraceIsFresh() {
        XCTAssertFalse(StalePingPolicy.isStale(scheduledFire: scheduled, now: scheduled.addingTimeInterval(StalePingPolicy.defaultGrace)))
    }

    func testPastGraceIsStale() {
        // The Mac slept through the slot and the fire happens hours later.
        XCTAssertTrue(StalePingPolicy.isStale(scheduledFire: scheduled, now: scheduled.addingTimeInterval(4 * 3600)))
        XCTAssertTrue(StalePingPolicy.isStale(scheduledFire: scheduled, now: scheduled.addingTimeInterval(StalePingPolicy.defaultGrace + 1)))
    }

    func testNoPlannedTimeIsNeverStale() {
        // Fail-open: a ping without a --scheduled-for must never be suppressed.
        XCTAssertFalse(StalePingPolicy.isStale(scheduledFire: nil, now: scheduled))
    }
}
