import Foundation

/// Detection of the Claude TUI's "input prompt is ready" state from raw PTY
/// output, kept pure so the markers stay testable against captured transcripts.
///
/// Claude Code ≤2.1.202 printed a "? for shortcuts" hint under the input box —
/// the marker the runners historically keyed on. 2.1.204 redesigned the start
/// screen and dropped that line (the box renders as `❯ ` plus a rotating
/// placeholder tip), which silently broke every ping and delegated refresh
/// ("prompt never became ready"). Readiness now accepts either signal: the
/// legacy hint, or the `❯` input caret.
///
/// The caret needs two guards, which the callers provide:
/// - `from:` — the trust-folder dialog draws `❯` as its selection caret too,
///   and the PTY buffer is append-only, so after dismissing that dialog the
///   caller passes the buffer length at dismissal time and only output that
///   arrived *after* it is searched.
/// - quiescence — callers only test a settled frame (no output growth for a
///   few hundred ms), so a half-drawn dialog can't expose its caret before
///   the "confirm" action bar that identifies it has rendered.
enum ClaudeTUI {
    /// "? for shortcuts" — the pre-2.1.204 ready hint.
    static let legacyReadyMarker = "shortcuts"
    /// The input box caret (U+276F), the one constant across TUI redesigns.
    static let inputCaret = "❯"

    /// Whether `text` (from character offset `start`) shows a ready input prompt.
    static func inputPromptVisible(in text: String, from start: Int = 0) -> Bool {
        let suffix = text.dropFirst(start)
        return suffix.contains(legacyReadyMarker) || suffix.contains(inputCaret)
    }

    /// "esc to interrupt" — the pre-2.1.204 generation-in-progress hint.
    static let legacyTurnMarker = "interrupt"
    /// The bullet that prefixes streamed assistant output (2.1.204 shows a
    /// spinner with no interrupt hint, so the reply itself is the signal).
    static let replyBullet = "⏺"

    /// Whether a turn provably began in output at/after character offset
    /// `start` — callers pass the buffer length from when they submitted the
    /// prompt, so a ⏺ in earlier screen content can't count.
    static func turnStarted(in text: String, from start: Int = 0) -> Bool {
        let suffix = text.dropFirst(start)
        return suffix.contains(legacyTurnMarker) || suffix.contains(replyBullet)
    }
}
