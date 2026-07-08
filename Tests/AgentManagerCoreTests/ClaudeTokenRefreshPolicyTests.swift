import XCTest
@testable import AgentManagerCore

/// The window-gate for the delegated `/status` refresh: `/status` anchors a
/// brand-new 5h window when none is live, so a *background* refresh may only run
/// while the last cached reading proves a window is already live. Anything
/// user-initiated is explicit and always allowed.
final class ClaudeTokenRefreshPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func reading(primaryResetsIn: TimeInterval?) -> UsageReading {
        UsageReading(
            primaryUsedPercent: 50,
            primaryResetsAt: primaryResetsIn.map { now.addingTimeInterval($0) },
            secondaryUsedPercent: nil,
            secondaryResetsAt: nil,
            fetchedAt: now)
    }

    func testUserInitiatedAlwaysAllowed() {
        // Explicit action wins regardless of what (if anything) we know.
        XCTAssertTrue(ClaudeTokenRefresher.mayRefresh(userInitiated: true, lastReading: nil, now: now))
        XCTAssertTrue(ClaudeTokenRefresher.mayRefresh(
            userInitiated: true, lastReading: reading(primaryResetsIn: -3600), now: now))
    }

    func testBackgroundAllowedWhileWindowLive() {
        // Window resets in 1h → live; `/status` just rides it.
        XCTAssertTrue(ClaudeTokenRefresher.mayRefresh(
            userInitiated: false, lastReading: reading(primaryResetsIn: 3600), now: now))
    }

    func testBackgroundDeferredAfterWindowReset() {
        // Window ended an hour ago — a refresh now would anchor a fresh one.
        XCTAssertFalse(ClaudeTokenRefresher.mayRefresh(
            userInitiated: false, lastReading: reading(primaryResetsIn: -3600), now: now))
    }

    func testBackgroundDeferredAtExactReset() {
        // Boundary: a reset at `now` means the window is over, not live.
        XCTAssertFalse(ClaudeTokenRefresher.mayRefresh(
            userInitiated: false, lastReading: reading(primaryResetsIn: 0), now: now))
    }

    func testBackgroundDeferredWithoutResetDate() {
        // A reading that never reported a reset can't prove a live window —
        // on doubt we defer (never anchor).
        XCTAssertFalse(ClaudeTokenRefresher.mayRefresh(
            userInitiated: false, lastReading: reading(primaryResetsIn: nil), now: now))
    }

    func testBackgroundDeferredWithoutAnyReading() {
        XCTAssertFalse(ClaudeTokenRefresher.mayRefresh(userInitiated: false, lastReading: nil, now: now))
    }
}
