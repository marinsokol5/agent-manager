import XCTest
@testable import AgentManagerCore

/// Exercises the "which agent should I run right now?" rule: soonest-to-expire
/// first, with a 10-minute tolerance inside which the most tokens wins.
final class AgentRecommenderTests: XCTestCase {
    /// Fixed clock so reset offsets are deterministic.
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func account(_ id: String, status: AccountStatus = .connected) -> Account {
        Account(id: id, label: id.capitalized, provider: .claude, home: "/tmp/\(id)", status: status)
    }

    /// `used` is used-percent (so remaining = 100 - used); `resetsIn` is seconds
    /// from `now` (negative = in the past), or `nil` for "no reset reported".
    private func reading(used: Int?, resetsIn: TimeInterval?) -> UsageReading {
        UsageReading(
            primaryUsedPercent: used,
            primaryResetsAt: resetsIn.map { now.addingTimeInterval($0) },
            secondaryUsedPercent: nil,
            secondaryResetsAt: nil)
    }

    private func recommend(_ accounts: [Account], _ readings: [String: UsageReading]) -> String? {
        AgentRecommender.recommendedAgentID(accounts: accounts, readings: readings, now: now)
    }

    // MARK: - Empty / excluded candidates

    func testNoAccountsReturnsNil() {
        XCTAssertNil(recommend([], [:]))
    }

    func testIgnoresDisconnectedAgents() {
        let a = account("a", status: .expired)
        XCTAssertNil(recommend([a], ["a": reading(used: 10, resetsIn: 3600)]))
    }

    func testIgnoresAgentsWithoutAReading() {
        XCTAssertNil(recommend([account("a")], [:]))
    }

    func testIgnoresZeroHeadroom() {
        // 100% used → 0% remaining → not usable.
        XCTAssertNil(recommend([account("a")], ["a": reading(used: 100, resetsIn: 3600)]))
    }

    // MARK: - The core rule

    func testSoonestExpiryWinsAcrossTheBuffer() {
        // a resets in 1h with little left; b resets in 3h with lots left. a's budget
        // is perishable now, so a wins despite fewer tokens.
        let r = ["a": reading(used: 70, resetsIn: 3600),   // 30% left, 1h
                 "b": reading(used: 10, resetsIn: 10800)]  // 90% left, 3h
        XCTAssertEqual(recommend([account("a"), account("b")], r), "a")
    }

    func testWithinBufferMostTokensWins() {
        // The 2:49 vs 2:50 case: resets 5 min apart (< 10-min buffer) → a wash on
        // expiry, so the one with more tokens wins.
        let r = ["a": reading(used: 70, resetsIn: 3600),   // 30% left
                 "b": reading(used: 10, resetsIn: 3900)]   // 90% left, +5 min
        XCTAssertEqual(recommend([account("a"), account("b")], r), "b")
    }

    func testTieOnTokensPrefersSoonerReset() {
        // Equal headroom inside the bucket → the more urgent (sooner) reset wins.
        let r = ["a": reading(used: 50, resetsIn: 3900),
                 "b": reading(used: 50, resetsIn: 3600)]
        XCTAssertEqual(recommend([account("a"), account("b")], r), "b")
    }

    func testNoLiveResetFallsBackToMostHeadroom() {
        let r = ["a": reading(used: 70, resetsIn: nil),    // 30% left
                 "b": reading(used: 10, resetsIn: nil)]    // 90% left
        XCTAssertEqual(recommend([account("a"), account("b")], r), "b")
    }

    func testPastResetIsStaleAndNotPerishable() {
        // a's reset already passed (stale reading) → not perishable, so the agent
        // with a live future window wins even though a has more tokens.
        let r = ["a": reading(used: 20, resetsIn: -3600),  // 80% left, reset in the past
                 "b": reading(used: 50, resetsIn: 7200)]   // 50% left, live 2h window
        XCTAssertEqual(recommend([account("a"), account("b")], r), "b")
    }

    func testBufferBoundaryIsInclusiveAndExcludesBeyond() {
        // b sits exactly at soonest + buffer → inside the bucket, so its larger
        // headroom wins.
        let inclusive = ["a": reading(used: 90, resetsIn: 3600),   // 10% left
                         "b": reading(used: 10, resetsIn: 4200)]   // 90% left, +600s
        XCTAssertEqual(recommend([account("a"), account("b")], inclusive), "b")

        // c sits one second beyond the buffer → out of the bucket, so the perishable
        // a wins despite far less headroom.
        let beyond = ["a": reading(used: 90, resetsIn: 3600),
                      "c": reading(used: 10, resetsIn: 4201)]
        XCTAssertEqual(recommend([account("a"), account("c")], beyond), "a")
    }
}
