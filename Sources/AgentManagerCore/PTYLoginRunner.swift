import Foundation

/// Drives one provider CLI `/login` over a PTY: scrapes the OAuth URL, answers
/// the terminal's cursor-position query, taps Enter to step through first-run
/// onboarding / the trust-folder dialog, and stops when the CLI confirms login.
public enum PTYLoginRunner {
    public struct Options: Sendable {
        public var timeout: TimeInterval = 180
        public var extraArgs: [String] = ["/login"]
        public var environment: [String: String] = [:]
        public var stopOnSubstrings: [String] = LoginOutputParser.successMarkers
        /// Tap Enter this often until the auth URL appears. `nil` disables.
        public var sendEnterEvery: TimeInterval? = 1.0
        public var settleAfterStop: TimeInterval = 0.4

        public init() {}
    }

    public enum Outcome: Sendable, Equatable {
        case success
        case timedOut
        case exited(Int32)
        case binaryNotFound
        case launchFailed(String)
    }

    public struct Result: Sendable {
        public let outcome: Outcome
        public let text: String
        public let firstURL: String?
    }

    public static func run(
        binary: String,
        options: Options,
        onURLDetected: ((String) -> Void)? = nil)
        -> Result
    {
        let session: PTYSession
        do {
            session = try PTYSession(binary: binary, arguments: options.extraArgs, environment: options.environment)
        } catch PTYSession.SpawnError.binaryNotFound {
            return Result(outcome: .binaryNotFound, text: "", firstURL: nil)
        } catch let PTYSession.SpawnError.launchFailed(message) {
            return Result(outcome: .launchFailed(message), text: "", firstURL: nil)
        } catch {
            return Result(outcome: .launchFailed(error.localizedDescription), text: "", firstURL: nil)
        }

        var firstURL: String?
        var stoppedEarly = false
        var lastEnter = Date()
        let deadline = Date().addingTimeInterval(options.timeout)

        usleep(400_000) // let the TUI paint before the first Enter

        while Date() < deadline {
            session.drain()
            let captured = session.text

            if firstURL == nil, let url = LoginOutputParser.firstURL(in: captured) {
                firstURL = url
                onURLDetected?(url)
            }
            session.answerCursorQueryIfNeeded()

            if !options.stopOnSubstrings.isEmpty,
               options.stopOnSubstrings.contains(where: { captured.contains($0) })
            {
                stoppedEarly = true
                break
            }

            if firstURL == nil, let every = options.sendEnterEvery,
               Date().timeIntervalSince(lastEnter) >= every
            {
                session.send("\r")
                lastEnter = Date()
            }

            if !session.isRunning { break }
            usleep(60_000)
        }

        if stoppedEarly, options.settleAfterStop > 0 {
            let settleEnd = Date().addingTimeInterval(options.settleAfterStop)
            while Date() < settleEnd {
                session.drain()
                usleep(40_000)
            }
        }

        session.terminate()

        let captured = session.text
        let resolvedURL = firstURL ?? LoginOutputParser.firstURL(in: captured)
        let outcome: Outcome
        if stoppedEarly || LoginOutputParser.indicatesSuccess(captured) {
            outcome = .success
        } else if Date() >= deadline {
            outcome = .timedOut
        } else {
            outcome = .exited(session.terminationStatus)
        }
        return Result(outcome: outcome, text: captured, firstURL: resolvedURL)
    }
}
