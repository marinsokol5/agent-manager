import XCTest
@testable import AgentManagerCore

/// Guards `ClaudeTUI.inputPromptVisible` — the ready detection the ping and
/// token-refresh runners key on. Claude Code 2.1.204 dropped the "? for
/// shortcuts" hint and broke the old substring check, so readiness now also
/// accepts the `❯` input caret; these cases pin both signals and the
/// trust-dialog guard.
final class ClaudeTUIReadinessTests: XCTestCase {
    /// Pre-2.1.204 TUI: the "? for shortcuts" hint under the input box.
    func testLegacyShortcutsHintIsReady() {
        XCTAssertTrue(ClaudeTUI.inputPromptVisible(in: "──────\n> \n? for shortcuts"))
    }

    /// 2.1.204 start screen, verbatim shape from a captured ping transcript:
    /// no shortcuts hint, input box is `❯ ` plus a dimmed placeholder tip.
    func testModernCaretFrameIsReady() {
        let frame = "\u{1B}[38;2;153;153;153mv2.1.204\u{1B}[39m\n"
            + "\u{1B}[38;2;136;136;136m──────\u{1B}[39m\n"
            + "❯ \u{1B}[2mTry \"edit <filepath> to...\"\u{1B}[22m\n"
            + "\u{1B}[38;2;136;136;136m──────\u{1B}[39m"
        XCTAssertTrue(ClaudeTUI.inputPromptVisible(in: frame))
    }

    /// A startup banner with no input box yet must not read as ready.
    func testBannerAloneIsNotReady() {
        XCTAssertFalse(ClaudeTUI.inputPromptVisible(in: "Claude Code v2.1.204\nHaiku 4.5 · Claude Pro"))
    }

    /// The trust-folder dialog draws `❯` as its selection caret, so it *does*
    /// read as ready from offset 0 — that's exactly why the runners dismiss it
    /// first and then search only output appended after the dismissal.
    func testTrustDialogCaretIsExcludedBySearchOffset() {
        let dialog = "Do you trust the files in this folder?\n"
            + "❯ 1. Yes, proceed\n  2. No, exit\nEnter to confirm · Esc to reject"
        XCTAssertTrue(ClaudeTUI.inputPromptVisible(in: dialog))

        // After dismissal: search from the dialog's end — nothing new yet…
        XCTAssertFalse(ClaudeTUI.inputPromptVisible(in: dialog, from: dialog.count))
        // …until the real input box renders in the appended output.
        let afterDismissal = dialog + "\n──────\n❯ \u{1B}[2mTry a prompt\u{1B}[22m"
        XCTAssertTrue(ClaudeTUI.inputPromptVisible(in: afterDismissal, from: dialog.count))
    }

    /// Pre-2.1.204 TUI: "esc to interrupt" while generating.
    func testLegacyInterruptHintMarksTurnStarted() {
        XCTAssertTrue(ClaudeTUI.turnStarted(in: "✢ Thinking… (esc to interrupt)"))
    }

    /// 2.1.204: no interrupt hint; the ⏺-bulleted streamed reply is the signal
    /// (verbatim shape from a captured ping transcript). The bare spinner
    /// before any output must not count.
    func testModernReplyBulletMarksTurnStarted() {
        XCTAssertFalse(ClaudeTUI.turnStarted(in: "✢ Spelunking… (3s · thinking)"))
        XCTAssertTrue(ClaudeTUI.turnStarted(in: "⏺ Good morning! I'm ready to help."))
    }

    /// A ⏺ that was already on screen before the prompt was submitted (restored
    /// history, release notes) must not count — only output after `from:` does.
    func testEarlierBulletExcludedBySearchOffset() {
        let beforePrompt = "⏺ old output from the screen\n❯ "
        XCTAssertFalse(ClaudeTUI.turnStarted(in: beforePrompt, from: beforePrompt.count))
        XCTAssertTrue(ClaudeTUI.turnStarted(in: beforePrompt + "⏺ fresh reply", from: beforePrompt.count))
    }
}
