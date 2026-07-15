import Foundation

/// Counts the `esc to interrupt` indicator in a captured Codex transcript.
///
/// Codex prints `esc to interrupt` in *two* unrelated phases: while the MCP
/// server **boots** (`Booting MCP server: … (0s • esc to interrupt)`) and while
/// the model **generates a reply**. The PTY buffer is append-only and the TUI
/// repaints the indicator on every spinner tick, so each phase leaves a *run* of
/// occurrences in the buffer.
///
/// This is exactly why a plain `transcript.contains("interrupt")` is a trap: once
/// the boot's indicator lands it stays in the buffer forever, so a turn that never
/// ran looks identical to one that did. We can't tell the phases apart by
/// *presence* — but we can by *count*. Snapshot the occurrence count once the boot
/// has quiesced; a real turn is then whatever makes the count climb past that
/// baseline. Counting (rather than byte-offset math) also stays correct across the
/// cursor-query bytes we splice out of the buffer mid-stream.
enum CodexTurnSignal {
    static let indicator = "interrupt"

    static func interruptCount(in transcript: String) -> Int {
        guard !transcript.isEmpty else { return 0 }
        var count = 0
        var search = transcript.startIndex
        while let r = transcript.range(of: indicator, range: search..<transcript.endIndex) {
            count += 1
            search = r.upperBound
        }
        return count
    }
}

/// The Codex "bump": drive the real interactive Codex TUI over a PTY for one tiny
/// turn so it anchors the rolling usage window — hardened against a false-success
/// bug:
///
/// The ChatGPT 5h window anchors only on a *completed, billed* turn. The earlier
/// flow waited a fixed 6s after the launch box, then typed the prompt and treated
/// the first `esc to interrupt` it saw as proof the turn ran. On a groggy wake the
/// MCP server is still booting at the 6s mark, so the prompt was typed into a
/// not-yet-ready composer (the Enter was swallowed and the text just sat there) —
/// and the boot's own `esc to interrupt` was then misread as the turn. Result: a
/// reported success with no turn and no anchored window.
///
/// So now we (1) submit only once the UI has gone **idle** (the boot's indicator is
/// already drained by then), (2) detect the turn by the interrupt *count climbing
/// past* its pre-submit baseline (never by mere presence), and (3) if the count
/// never climbs we re-send Enter once and otherwise report an honest failure rather
/// than a phantom success.
public enum CodexPingRunner {
    /// A friendly one-liner — the reply ("Good morning") is short, so the turn
    /// and its token cost stay tiny.
    public static let pingPrompt = "Good morning Codex"

    public static func run(
        binary: String,
        environment: [String: String],
        workingDirectory: URL? = nil,
        timeout: TimeInterval = 90)
        -> ClaudePingRunner.Result
    {
        // The ping is a sealed, no-op turn that never proposes a command or touches
        // `apply_patch`, so the startup approval gates only ever stall it. Wave them
        // through for this one invocation (the flags persist no trust, so the user's
        // own sessions still prompt):
        //   --dangerously-bypass-hook-trust          → no "Hooks need review" modal
        //   --dangerously-bypass-approvals-and-sandbox → no command/trust prompts
        // `-C` pins a real working root so the box never lands on `/`.
        var arguments = [
            // Pin a cheap model so the ping stays tiny (mirrors Claude's `--model
            // haiku`); the turn only needs to anchor the window, not reason.
            "-m", "gpt-5.4-mini",
            // Pin the reasoning effort too — the ping only needs to anchor the
            // window, not reason. Leaving it to the account config lets an
            // arbitrary `model_reasoning_effort` leak in; a value the pinned
            // model rejects (e.g. `"max"`) 400s the turn so it never anchors.
            // Quoted so the override parses as a TOML string (no shell strips it).
            "-c", "model_reasoning_effort=\"low\"",
            // Suppress the on-startup update banner, which otherwise blocks the
            // launch box we wait for.
            "-c", "check_for_update_on_startup=false",
            "--dangerously-bypass-hook-trust",
            "--dangerously-bypass-approvals-and-sandbox",
        ]
        if let workingDirectory { arguments.append(contentsOf: ["-C", workingDirectory.path]) }

        let session: PTYSession
        do {
            session = try PTYSession(
                binary: binary,
                arguments: arguments,
                environment: environment,
                workingDirectory: workingDirectory)
        } catch PTYSession.SpawnError.binaryNotFound {
            return .init(ok: false, detail: "codex binary not found on PATH", transcript: "")
        } catch let PTYSession.SpawnError.launchFailed(message) {
            return .init(ok: false, detail: "failed to launch codex: \(message)", transcript: "")
        } catch {
            return .init(ok: false, detail: "failed to launch codex: \(error.localizedDescription)", transcript: "")
        }

        let deadline = Date().addingTimeInterval(timeout)
        var launched = false
        var launchedAt: Date?
        var promptSent = false
        var promptSentAt: Date?
        var resentEnter = false
        var interruptsBeforeSubmit = 0
        var turnStarted = false   // interrupt count climbed past baseline → generation began
        var turnSettled = false   // reply streamed and output went quiet → turn done

        // Submit only once the launch box has appeared AND the UI has gone idle:
        // the model finished resolving and the MCP server finished booting (so the
        // composer actually accepts the Enter, and the boot's stale `esc to
        // interrupt` is already in the buffer — i.e. part of the pre-submit
        // baseline, never mistaken for our turn).
        let minSettle: TimeInterval = 2.5    // floor after launch (boot may not have started yet)
        let bootQuiet: TimeInterval = 1.5    // no new output for this long → UI idle

        // After submit, confirm the turn actually started (interrupt count climbed).
        // If it hasn't by `submitGrace`, the Enter was likely swallowed — nudge it
        // once; if it still hasn't by `submitDeadline`, fail honestly instead of
        // burning the full timeout on a turn that never ran.
        let submitGrace: TimeInterval = 4.0
        let submitDeadline: TimeInterval = 14.0

        // Completion is detected by quiescence: once generation has started, treat
        // the turn as done when no new output has arrived for `quietWindow` (the
        // elapsed-timer/spinner keeps the buffer growing the whole time the model is
        // actually working). Cap with `maxTurn` — a reply this long has surely billed.
        let quietWindow: TimeInterval = 2.0
        let maxTurn: TimeInterval = 45
        var lastLen = 0
        var lastGrowth = Date()

        usleep(400_000)

        while Date() < deadline {
            session.drain()
            session.answerCursorQueryIfNeeded()
            let captured = session.text
            if captured.count != lastLen { lastLen = captured.count; lastGrowth = Date() }

            if !launched {
                // The launch box prints `directory:` with the cwd.
                if captured.contains("directory") {
                    launched = true
                    launchedAt = Date()
                }
            } else if !promptSent {
                // Wait for the UI to settle (boot done, composer ready) before typing.
                let settledLongEnough = Date().timeIntervalSince(lastGrowth) >= bootQuiet
                let pastFloor = launchedAt.map { Date().timeIntervalSince($0) >= minSettle } ?? false
                if settledLongEnough, pastFloor {
                    interruptsBeforeSubmit = CodexTurnSignal.interruptCount(in: captured)
                    session.send(pingPrompt)
                    usleep(800_000) // let the input become ready before submitting
                    session.send("\r")
                    promptSent = true
                    promptSentAt = Date()
                }
            } else {
                // A real turn is what makes the interrupt count climb past the
                // pre-submit baseline — never mere presence (the boot's indicator is
                // already counted into the baseline).
                if CodexTurnSignal.interruptCount(in: captured) > interruptsBeforeSubmit {
                    turnStarted = true
                }
                if turnStarted {
                    if Date().timeIntervalSince(lastGrowth) >= quietWindow {
                        turnSettled = true
                        break
                    }
                    if let sent = promptSentAt, Date().timeIntervalSince(sent) >= maxTurn {
                        turnSettled = true
                        break
                    }
                } else if let sent = promptSentAt {
                    let since = Date().timeIntervalSince(sent)
                    // Enter may have been swallowed (composer wasn't ready) — nudge once.
                    if since >= submitGrace, !resentEnter {
                        session.send("\r")
                        resentEnter = true
                    }
                    // Still nothing — stop and report honestly rather than time out.
                    if since >= submitDeadline { break }
                }
            }

            if !session.isRunning { break }
            usleep(60_000)
        }

        if turnStarted {
            // Codex quits on Ctrl-C twice.
            session.send("\u{03}")
            usleep(200_000)
            session.send("\u{03}")
        } else if promptSent {
            // Clear the composer so terminate()'s `/exit` can't accidentally submit
            // the text we typed as a (stray, billed) turn.
            session.send("\u{03}")
            usleep(150_000)
        }
        session.terminate()

        let transcript = session.text
        if turnStarted {
            let detail = turnSettled ? "interactive turn completed (tui)" : "turn streamed, not settled (tui)"
            return .init(ok: true, detail: detail, transcript: transcript)
        }
        let reason: String
        if !launched {
            reason = "codex did not launch"
        } else if !promptSent {
            reason = "ui never became ready to submit"
        } else {
            reason = "prompt submitted but turn never started"
        }
        return .init(ok: false, detail: "ping failed: \(reason)", transcript: transcript)
    }
}
