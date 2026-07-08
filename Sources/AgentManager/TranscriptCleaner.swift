import Foundation

/// Renders a raw PTY transcript as legible plain text, for the Monitoring
/// log's expanded ping rows.
///
/// A saved transcript is a byte-for-byte terminal session: ANSI/VT control
/// sequences for color, cursor motion, and screen redraws interleaved with
/// the text the agent actually printed. Two non-obvious rules make the
/// cleaned output readable — both learned the hard way:
///
/// - **Patterns embed a real ESC character, never the raw-string literal
///   `#"\u{001B}"#`.** Inside a raw string that escape reaches ICU as the
///   literal text `\u{001B}` — a form ICU's regex engine does not parse — so
///   the pattern silently matches nothing. The stripper shipped that way for
///   a while: only the control-char filter ran, deleting the ESC byte itself
///   and stranding every sequence body ("[2G", "[38;5;174m", "[?25h") as the
///   visible garbage it was meant to remove.
/// - **Cursor positioning becomes a space, not nothing.** A TUI lays words
///   out with column jumps (`ESC [ 21 G`) instead of literal spaces, so
///   deleting those sequences fuses "Claude Code v2.1.204" into
///   "ClaudeCodev2.1.204". They are the screen's whitespace — render them as
///   such.
enum TranscriptCleaner {
    private static let esc = "\u{001B}"

    /// Strip ANSI/VT escape sequences and stray control bytes from a raw PTY
    /// dump, keeping newlines and tabs, so a captured TUI screen reads as
    /// plain text.
    static func plainText(_ s: String) -> String {
        var out = s
        // Cursor positioning (CHA `G`, CUF `C`, CUP `H`) first, as spaces —
        // see the type comment. The second pattern catches orphaned bodies
        // whose ESC byte is already gone.
        for spacer in ["\(esc)\\[[0-9;]*[GCH]", "\\[[0-9;]{1,8}[GCH]"] {
            out = out.replacingOccurrences(of: spacer, with: " ", options: .regularExpression)
        }
        let patterns = [
            // CSI: ESC [ params intermediates final. Params include the
            // private-marker range (`<=>?` and `:`) so sequences like
            // `ESC [ > 0 q` and `ESC [ ? 25 h` are covered.
            "\(esc)\\[[0-9;:?<=>!]*[ -/]*[@-~]",
            // OSC (window title, colors): ESC ] … BEL/ST.
            "\(esc)\\][^\u{0007}\(esc)]*(?:\u{0007}|\(esc)\\\\)",
            // Two-char ESC sequences: C1 shorthands plus ESC-digit
            // (DECSC/DECRC cursor save/restore, `ESC 7` / `ESC 8`).
            "\(esc)[@-Z\\\\-_0-9]",
            // Orphaned CSI bodies whose ESC was already lost upstream
            // (lossy copies, transcripts filtered by other tools). A
            // deliberate tradeoff: rare legitimate text like "[3m" is
            // eaten too — acceptable in a terminal dump, where a stranded
            // sequence body is overwhelmingly more likely.
            "\\[[0-9;:?<=>]{1,16}[ -/]*[A-Za-z]",
        ]
        for pattern in patterns {
            out = out.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        // Drop remaining control chars except newline (\n) and tab (\t).
        out = String(out.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || $0.value >= 0x20 })
        // A full-width TUI border redraw leaves screen-wide ─ runs that wrap
        // over several display lines; collapse them to a short rule.
        out = out.replacingOccurrences(
            of: "\u{2500}{8,}", with: String(repeating: "\u{2500}", count: 8),
            options: .regularExpression)
        // Collapse the runs of blank lines a redrawn TUI screen leaves behind.
        out = out.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
