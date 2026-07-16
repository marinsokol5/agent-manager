import Foundation

/// The minimal "bump": drive the real interactive Claude TUI over a PTY for a
/// single tiny turn, so the request counts as ordinary interactive subscription
/// usage and anchors the rolling 5h window. The ping flow: wait for the input
/// prompt (dismissing the trust
/// dialog if it appears), send a one-character prompt, and confirm the turn was
/// dispatched by seeing `esc to interrupt`.
public enum ClaudePingRunner {
    /// A friendly one-liner — the reply ("Good morning") is short, so the turn
    /// and its token cost stay tiny.
    public static let pingPrompt = "Good morning Claude"

    public struct Result: Sendable, Equatable {
        public let ok: Bool
        public let detail: String
        public let transcript: String
        /// Delivery method selected by `AccountPinger`. Low-level runners leave
        /// this nil; the choke point stamps it before audit/activity logging.
        public let pingMethod: PingMethod?

        public init(ok: Bool, detail: String, transcript: String, pingMethod: PingMethod? = nil) {
            self.ok = ok
            self.detail = detail
            self.transcript = transcript
            self.pingMethod = pingMethod
        }
    }

    public static func run(
        binary: String,
        environment: [String: String],
        workingDirectory: URL? = nil,
        timeout: TimeInterval = 90)
        -> Result
    {
        let session: PTYSession
        do {
            // Interactive defaults to the main model, so pin haiku to stay cheap.
            // `workingDirectory` keeps Claude out of launchd's `/` (which otherwise
            // raises the trust dialog the loop below has to dismiss by hand).
            // The sandbox opt-out keeps Seatbelt init from sweeping TCC-protected
            // folders under our name — see `Provider.sandboxOptOutArguments`.
            session = try PTYSession(
                binary: binary,
                arguments: ["--model", "haiku"] + Provider.claude.sandboxOptOutArguments,
                environment: environment, workingDirectory: workingDirectory)
        } catch PTYSession.SpawnError.binaryNotFound {
            return Result(ok: false, detail: "claude binary not found on PATH", transcript: "")
        } catch let PTYSession.SpawnError.launchFailed(message) {
            return Result(ok: false, detail: "failed to launch claude: \(message)", transcript: "")
        } catch {
            return Result(ok: false, detail: "failed to launch claude: \(error.localizedDescription)", transcript: "")
        }

        var ready = false
        var trustDismissed = false
        var readySearchStart = 0
        var turnSearchStart = 0
        var promptSentAt: Date?
        var turnStarted = false   // saw `esc to interrupt` → generation began
        var turnSettled = false   // reply streamed and output went quiet → turn done
        let deadline = Date().addingTimeInterval(timeout)

        // Wait for the reply to actually stream back before quitting, rather than
        // bailing at dispatch. (Claude anchors the window on dispatch regardless, so
        // unlike Codex this is for transcript completeness, not anchoring.) The PTY
        // buffer is append-only — we can't watch `esc to interrupt` *clear* — so we
        // detect completion by quiescence: once generation started, the turn is done
        // when no new output has arrived for `quietWindow`.
        let quietWindow: TimeInterval = 2.0
        let maxTurn: TimeInterval = 45
        // Only trust a ready marker on a settled frame (no growth this long) —
        // a half-drawn trust dialog could otherwise expose its own ❯ caret
        // before the "confirm" bar that identifies it (see `ClaudeTUI`).
        let readyQuiet: TimeInterval = 0.5
        var lastLen = 0
        var lastGrowth = Date()

        usleep(400_000)

        while Date() < deadline {
            session.drain()
            session.answerCursorQueryIfNeeded()
            let captured = session.text
            if captured.count != lastLen { lastLen = captured.count; lastGrowth = Date() }

            if !ready {
                // The trust-folder dialog's action bar is the only place `confirm`
                // appears (Enter to confirm); dismiss it once, and from then on
                // only search output that arrived after the dismissal — the
                // buffer is append-only, so the dialog's own ❯ caret stays in it.
                if !trustDismissed, captured.contains("confirm") {
                    session.send("\r")
                    trustDismissed = true
                    readySearchStart = captured.count
                } else if Date().timeIntervalSince(lastGrowth) >= readyQuiet,
                          ClaudeTUI.inputPromptVisible(in: captured, from: readySearchStart)
                {
                    ready = true
                    session.send(pingPrompt)
                    session.send("\r")
                    promptSentAt = Date()
                    turnSearchStart = captured.count
                }
            } else {
                if ClaudeTUI.turnStarted(in: captured, from: turnSearchStart) { turnStarted = true }
                if turnStarted, Date().timeIntervalSince(lastGrowth) >= quietWindow {
                    turnSettled = true
                    break
                }
                if let sent = promptSentAt, Date().timeIntervalSince(sent) >= maxTurn {
                    turnSettled = turnStarted
                    break
                }
            }

            if !session.isRunning { break }
            usleep(60_000)
        }

        session.terminate()

        let transcript = session.text
        if turnStarted {
            let detail = turnSettled ? "interactive turn completed (tui)" : "turn streamed, not settled (tui)"
            return Result(ok: true, detail: detail, transcript: transcript)
        }
        let reason = ready ? "turn never started" : "prompt never became ready"
        return Result(ok: false, detail: "ping failed: \(reason)", transcript: transcript)
    }
}
