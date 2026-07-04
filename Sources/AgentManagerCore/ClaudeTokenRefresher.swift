import Foundation

/// Triggers the real Claude CLI to refresh this account's OAuth token — a
/// delegated refresh we never perform ourselves. We drive the interactive TUI and
/// run the `/status` slash command, which performs an authenticated check (and
/// refreshes the access token as a side effect) WITHOUT sending a model turn, so
/// it costs no usage. We never write the Keychain ourselves; the CLI remains the
/// single source of truth for the credential.
///
/// Mirrors `ClaudePingRunner`'s PTY choreography (wait for the input prompt,
/// dismissing the trust dialog if it appears) but sends `/status` instead of a
/// prompt and never dispatches a turn.
public enum ClaudeTokenRefresher {
    public struct Result: Sendable, Equatable {
        public let ok: Bool
        public let detail: String
    }

    public static func run(
        binary: String,
        environment: [String: String],
        timeout: TimeInterval = 30)
        -> Result
    {
        let session: PTYSession
        do {
            session = try PTYSession(binary: binary, arguments: [], environment: environment)
        } catch PTYSession.SpawnError.binaryNotFound {
            return Result(ok: false, detail: "claude binary not found on PATH")
        } catch let PTYSession.SpawnError.launchFailed(message) {
            return Result(ok: false, detail: "failed to launch claude: \(message)")
        } catch {
            return Result(ok: false, detail: "failed to launch claude: \(error.localizedDescription)")
        }

        var ready = false
        var trustDismissed = false
        var statusSent = false
        let deadline = Date().addingTimeInterval(timeout)

        usleep(400_000)

        while Date() < deadline {
            session.drain()
            session.answerCursorQueryIfNeeded()
            let captured = session.text

            if !ready {
                // The trust-folder dialog's action bar is the only place `confirm`
                // appears (Enter to confirm); dismiss it once.
                if !trustDismissed, captured.contains("confirm") {
                    session.send("\r")
                    trustDismissed = true
                }
                // `? for shortcuts` marks the input prompt as ready.
                if captured.contains("shortcuts") {
                    ready = true
                    session.send("/status")
                    session.send("\r")
                    statusSent = true
                }
            } else {
                // `/status` is running; the CLI's auth check refreshes the token in
                // the background. We don't parse output — just let it settle.
                break
            }

            if !session.isRunning { break }
            usleep(60_000)
        }

        // Give the auth check time to complete and write the refreshed credential.
        if statusSent {
            let settleEnd = Date().addingTimeInterval(2.5)
            while Date() < settleEnd { session.drain(); usleep(60_000) }
        }
        session.terminate()

        if statusSent {
            return Result(ok: true, detail: "ran /status (delegated token refresh)")
        }
        return Result(ok: false, detail: ready ? "status never sent" : "prompt never became ready")
    }
}
