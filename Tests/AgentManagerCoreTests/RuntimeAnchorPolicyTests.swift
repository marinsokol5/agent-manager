import XCTest
@testable import AgentManagerCore

/// The pure deferral policy: merging window evidence and bending the nominal
/// queue around known-open windows. Times are built from a fixed epoch so the
/// expectations read as offsets.
final class RuntimeAnchorPolicyTests: XCTestCase {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    let window: TimeInterval = 300 * 60
    func t(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }

    func usage(_ expiresMin: Double, observedMin: Double) -> AccountWindowState {
        AccountWindowState(expiresAt: t(expiresMin), evidence: .usage, observedAt: t(observedMin))
    }

    func conservative(_ expiresMin: Double, observedMin: Double) -> AccountWindowState {
        AccountWindowState(expiresAt: t(expiresMin), evidence: .conservative, observedAt: t(observedMin))
    }

    // MARK: - merge

    func testNewerObservationWinsEitherDirection() {
        // A fresh usage reading must be able to *shorten* a conservative bound…
        let tightened = RuntimeAnchorPolicy.merged(conservative(310, observedMin: 10), usage(302, observedMin: 12))
        XCTAssertEqual(tightened, usage(302, observedMin: 12))
        // …and a later anchor event must supersede an older reading.
        let extended = RuntimeAnchorPolicy.merged(usage(302, observedMin: 12), conservative(320, observedMin: 20))
        XCTAssertEqual(extended, conservative(320, observedMin: 20))
        // An older candidate never overrides.
        let kept = RuntimeAnchorPolicy.merged(conservative(320, observedMin: 20), usage(302, observedMin: 12))
        XCTAssertEqual(kept, conservative(320, observedMin: 20))
    }

    func testTiesPreferExactUsageThenLaterExpiry() {
        XCTAssertEqual(
            RuntimeAnchorPolicy.merged(conservative(310, observedMin: 10), usage(302, observedMin: 10)),
            usage(302, observedMin: 10))
        XCTAssertEqual(
            RuntimeAnchorPolicy.merged(usage(302, observedMin: 10), conservative(310, observedMin: 10)),
            usage(302, observedMin: 10))
        XCTAssertEqual(
            RuntimeAnchorPolicy.merged(usage(302, observedMin: 10), usage(305, observedMin: 10)),
            usage(305, observedMin: 10))
    }

    func testMergeFromNothingAdopts() {
        XCTAssertEqual(RuntimeAnchorPolicy.merged(nil, usage(302, observedMin: 10)), usage(302, observedMin: 10))
    }

    // MARK: - adjust

    func adjust(
        _ queue: [QueueEntry],
        states: [String: AccountWindowState],
        nowMin: Double,
        painted: Bool = true)
        -> RuntimeAnchorPolicy.AdjustedQueue
    {
        RuntimeAnchorPolicy.adjust(
            queue, windowStates: states, window: window, now: t(nowMin),
            hasPaintedWork: { _, _ in painted })
    }

    func testNoEvidenceLeavesQueueUntouched() {
        let queue = [QueueEntry(fireAt: t(0), accountID: "a"), QueueEntry(fireAt: t(300), accountID: "a")]
        let adjusted = adjust(queue, states: [:], nowMin: -5)
        XCTAssertEqual(adjusted.entries, queue)
        XCTAssertTrue(adjusted.covered.isEmpty)
    }

    func testCollidingEntryDefersJustPastExpiryWithNominalIdentity() {
        // Window open until +7m: the 0m fire runs at +8m (expiry + margin).
        let queue = [QueueEntry(fireAt: t(0), accountID: "a"), QueueEntry(fireAt: t(300), accountID: "a")]
        let adjusted = adjust(queue, states: ["a": usage(7, observedMin: -10)], nowMin: -1)
        XCTAssertEqual(adjusted.entries[0].fireAt, t(8))
        XCTAssertEqual(adjusted.entries[0].plannedAt, t(0))
        XCTAssertEqual(adjusted.entries[0].nominalFireAt, t(0))
        // The successor sits past the expiry: untouched.
        XCTAssertEqual(adjusted.entries[1], QueueEntry(fireAt: t(300), accountID: "a"))
    }

    func testExpiryMoreThanMarginBeforePlannedDoesNotShift() {
        let queue = [QueueEntry(fireAt: t(0), accountID: "a")]
        let adjusted = adjust(queue, states: ["a": usage(-2, observedMin: -10)], nowMin: -1)
        XCTAssertEqual(adjusted.entries, queue)
    }

    func testExactOrNearResetBoundaryStillGetsSafetyMargin() {
        let queue = [QueueEntry(fireAt: t(0), accountID: "a")]
        let exact = adjust(queue, states: ["a": usage(0, observedMin: -10)], nowMin: -1)
        XCTAssertEqual(exact.entries, [QueueEntry(fireAt: t(1), accountID: "a", plannedAt: t(0))])

        let thirtySecondsBefore = adjust(
            queue, states: ["a": usage(-0.5, observedMin: -10)], nowMin: -1)
        XCTAssertEqual(
            thirtySecondsBefore.entries,
            [QueueEntry(fireAt: t(0.5), accountID: "a", plannedAt: t(0))])
    }

    func testPlausibleLiveExpiryRejectsCorruptFutureValue() {
        XCTAssertTrue(RuntimeAnchorPolicy.isPlausibleLiveExpiry(t(299), at: t(0), window: window))
        // The same one-minute tolerance used at the reset boundary also
        // absorbs provider/client clock skew at the physical upper bound.
        XCTAssertTrue(RuntimeAnchorPolicy.isPlausibleLiveExpiry(t(300.5), at: t(0), window: window))
        XCTAssertFalse(RuntimeAnchorPolicy.isPlausibleLiveExpiry(t(302), at: t(0), window: window))
        XCTAssertFalse(RuntimeAnchorPolicy.isPlausibleLiveExpiry(t(0), at: t(0), window: window))
    }

    func testPhysicallyImpossibleEvidenceIsDistrusted() {
        // A rolling window's expiry can never exceed now + window; corrupt
        // state must degrade to fixed-time behavior, not eat the schedule.
        let queue = [QueueEntry(fireAt: t(0), accountID: "a")]
        let adjusted = adjust(queue, states: ["a": usage(400, observedMin: -10)], nowMin: 0)
        XCTAssertEqual(adjusted.entries, queue)
        XCTAssertTrue(adjusted.covered.isEmpty)
    }

    func testShiftReachingSuccessorResolvesAsCoveredOnceDue() {
        // The user anchored at -1m, so the window runs to +299m — past the
        // successor's 250m slot. Once the 0m slot is nominally due it resolves
        // as covered, while the successor (whose planned minute the same
        // window also swallows) fires just past the expiry at +300m.
        let queue = [QueueEntry(fireAt: t(0), accountID: "a"), QueueEntry(fireAt: t(250), accountID: "a")]
        let due = adjust(queue, states: ["a": usage(299, observedMin: -1)], nowMin: 1)
        XCTAssertEqual(
            due.covered,
            [QueueEntry(fireAt: t(300), accountID: "a", plannedAt: t(0))])
        XCTAssertEqual(due.entries, [QueueEntry(fireAt: t(300), accountID: "a", plannedAt: t(250))])

        // Before its nominal minute the covered entry just sits out this
        // rebuild — evidence may still be corrected, and the planner re-emits
        // it every tick.
        let early = adjust(queue, states: ["a": usage(299, observedMin: -1)], nowMin: -0.5)
        XCTAssertTrue(early.covered.isEmpty)
        XCTAssertEqual(early.entries, [QueueEntry(fireAt: t(300), accountID: "a", plannedAt: t(250))])
    }

    func testShiftIntoOffHoursResolvesAsCoveredOnceDue() {
        // No painted work remains between the shifted fire and the next
        // opportunity: deferring would anchor a window nobody uses.
        let queue = [QueueEntry(fireAt: t(0), accountID: "a")]
        let adjusted = adjust(queue, states: ["a": usage(30, observedMin: -1)], nowMin: 1, painted: false)
        XCTAssertEqual(
            adjusted.covered,
            [QueueEntry(fireAt: t(31), accountID: "a", plannedAt: t(0))])
        XCTAssertTrue(adjusted.entries.isEmpty)
    }

    func testDeferralResortsAcrossAccounts() {
        // b's on-time fire at +3m overtakes a's fire deferred to +8m.
        let queue = [QueueEntry(fireAt: t(0), accountID: "a"), QueueEntry(fireAt: t(3), accountID: "b")]
        let adjusted = adjust(queue, states: ["a": usage(7, observedMin: -10)], nowMin: -1)
        XCTAssertEqual(adjusted.entries.map(\.accountID), ["b", "a"])
        XCTAssertEqual(adjusted.entries.map(\.fireAt), [t(3), t(8)])
    }

    func testShiftReachingCyclicSuccessorResolvesAtQueueSeam() {
        // The concrete queue contains one weekly occurrence per trigger. Its
        // final entry still has a successor just after the week wraps; runtime
        // deferral must not create two physical anchors across that seam.
        let entry = QueueEntry(fireAt: t(0), accountID: "a")
        let adjusted = RuntimeAnchorPolicy.adjust(
            [entry],
            windowStates: ["a": usage(100, observedMin: -1)],
            window: window,
            now: t(1),
            nextNominalFire: { _ in self.t(90) },
            hasPaintedWork: { _, _ in true })
        XCTAssertEqual(
            adjusted.covered,
            [QueueEntry(fireAt: t(101), accountID: "a", plannedAt: t(0))])
        XCTAssertTrue(adjusted.entries.isEmpty)
    }
}

/// Pure classification of "did this turn anchor a window" from the readings
/// the scheduled ping child fetches around its turn.
final class AnchorVerificationTests: XCTestCase {
    let turnStart = Date(timeIntervalSince1970: 1_800_000_000)
    func t(_ minutes: Double) -> Date { turnStart.addingTimeInterval(minutes * 60) }

    func reading(_ resetsAt: Date?, fetchedAt: Date) -> UsageReading {
        UsageReading(
            primaryUsedPercent: 1, primaryResetsAt: resetsAt,
            secondaryUsedPercent: nil, secondaryResetsAt: nil, fetchedAt: fetchedAt)
    }

    func testFreshWindowAfterNoPriorKnowledgeIsVerified() {
        let verdict = AnchorVerification.classify(
            pre: nil, post: reading(t(300), fetchedAt: t(1)),
            turnStartedAt: turnStart, turnFinishedAt: t(0.5), window: 300 * 60)
        XCTAssertEqual(verdict, .verified(expiresAt: t(300)))
    }

    func testMovedResetIsVerifiedEvenWithLivePreWindow() {
        // Pre showed a window ending just after the turn started; post shows a
        // *different* boundary — only a new anchor moves resets_at.
        let verdict = AnchorVerification.classify(
            pre: reading(t(0.5), fetchedAt: t(-3)),
            post: reading(t(300.5), fetchedAt: t(1)),
            turnStartedAt: turnStart, turnFinishedAt: t(1), window: 300 * 60)
        XCTAssertEqual(verdict, .verified(expiresAt: t(300.5)))
    }

    func testExpiredPreWindowIsVerified() {
        let verdict = AnchorVerification.classify(
            pre: reading(t(-10), fetchedAt: t(-200)),
            post: reading(t(299), fetchedAt: t(1)),
            turnStartedAt: turnStart, turnFinishedAt: t(1), window: 300 * 60)
        XCTAssertEqual(verdict, .verified(expiresAt: t(299)))
    }

    func testUnmovedLiveResetIsPhantom() {
        let resets = t(120)
        let verdict = AnchorVerification.classify(
            pre: reading(resets, fetchedAt: t(-3)),
            post: reading(resets, fetchedAt: t(1)),
            turnStartedAt: turnStart, turnFinishedAt: t(1), window: 300 * 60)
        XCTAssertEqual(verdict, .phantom(openUntil: resets))
    }

    func testMissingOrStalePostReadingIsUnknown() {
        XCTAssertEqual(
            AnchorVerification.classify(
                pre: nil, post: nil, turnStartedAt: turnStart,
                turnFinishedAt: t(1), window: 300 * 60),
            .unknown)
        XCTAssertEqual(
            AnchorVerification.classify(
                pre: nil, post: reading(nil, fetchedAt: t(1)), turnStartedAt: turnStart,
                turnFinishedAt: t(1), window: 300 * 60),
            .unknown)
        // A post reading whose window doesn't even reach the turn can't
        // confirm anything (API lag / stale snapshot).
        XCTAssertEqual(
            AnchorVerification.classify(
                pre: nil, post: reading(t(-1), fetchedAt: t(1)), turnStartedAt: turnStart,
                turnFinishedAt: t(1), window: 300 * 60),
            .unknown)
    }

    func testPreexistingWindowDiscoveredOnlyPostflightIsPhantom() {
        // Reset implies an anchor three hours before this attempt. Even with
        // no usable preflight, postflight can prove this turn was a phantom.
        XCTAssertEqual(
            AnchorVerification.classify(
                pre: nil, post: reading(t(120), fetchedAt: t(1)),
                turnStartedAt: turnStart, turnFinishedAt: t(1), window: 300 * 60),
            .phantom(openUntil: t(120)))
    }

    func testResponseFetchedBeforeAttemptIsNotPostflightEvidence() {
        XCTAssertEqual(
            AnchorVerification.classify(
                pre: nil, post: reading(t(300), fetchedAt: t(-2)),
                turnStartedAt: turnStart, turnFinishedAt: t(1),
                window: 300 * 60, clockTolerance: 0),
            .unknown)
    }
}

final class PingOutcomeTests: XCTestCase {
    func testDaemonChildExitCodeContract() {
        XCTAssertEqual(PingOutcome.fromExitCode(PingOutcome.anchoredExitCode), .anchored)
        XCTAssertEqual(PingOutcome.fromExitCode(PingOutcome.failedExitCode), .failed)
        XCTAssertEqual(PingOutcome.fromExitCode(PingOutcome.skippedStaleExitCode), .skippedStale)
        XCTAssertEqual(
            PingOutcome.fromExitCode(PingOutcome.deferredOpenWindowExitCode),
            .deferredOpenWindow)
        XCTAssertEqual(
            PingOutcome.fromExitCode(PingOutcome.anchorUnknownExitCode),
            .anchorUnknown)
        XCTAssertEqual(PingOutcome.fromExitCode(99), .failed)
    }
}
