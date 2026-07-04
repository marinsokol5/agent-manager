import Foundation

/// Drives the provider CLI's one-time interactive login under an isolated home,
/// captures the OAuth URL, opens it in the browser, and waits for the CLI to
/// confirm. We never route the OAuth token through our own harness — the real
/// `claude` binary performs the login and writes its own credentials.
public struct GuidedLogin {
    public let provider: Provider
    public let home: ManagedHome

    public init(provider: Provider, home: ManagedHome) {
        self.provider = provider
        self.home = home
    }

    public enum Event: Sendable {
        case launching
        case authURLReady(String)
        case browserOpened(String)
    }

    public struct Outcome: Sendable {
        public let succeeded: Bool
        public let authURL: String?
        public let transcript: String
        public let detail: String
    }

    public func run(
        timeout: TimeInterval = 180,
        openBrowser: Bool = true,
        onEvent: @escaping (Event) -> Void)
        -> Outcome
    {
        onEvent(.launching)

        let environment = ChildEnvironment.make(for: home)
        var options = PTYLoginRunner.Options()
        options.timeout = timeout
        options.environment = environment
        options.extraArgs = provider.loginArguments

        let result = PTYLoginRunner.run(
            binary: ChildEnvironment.binary(for: provider, environment: environment),
            options: options,
            onURLDetected: { url in
                onEvent(.authURLReady(url))
                if openBrowser {
                    Self.openInBrowser(url)
                    onEvent(.browserOpened(url))
                }
            })

        switch result.outcome {
        case .success:
            return Outcome(succeeded: true, authURL: result.firstURL, transcript: result.text, detail: "logged in")
        case .timedOut:
            return Outcome(
                succeeded: false, authURL: result.firstURL, transcript: result.text,
                detail: "login timed out after \(Int(timeout))s")
        case let .exited(code):
            return Outcome(
                succeeded: false, authURL: result.firstURL, transcript: result.text,
                detail: "\(provider.cliBinaryName) exited (\(code)) before login completed")
        case .binaryNotFound:
            return Outcome(
                succeeded: false, authURL: nil, transcript: result.text,
                detail: "\(provider.cliBinaryName) binary not found on PATH")
        case let .launchFailed(message):
            return Outcome(
                succeeded: false, authURL: nil, transcript: result.text,
                detail: "failed to launch \(provider.cliBinaryName): \(message)")
        }
    }

    /// Open a URL in the user's default browser via `/usr/bin/open` (AppKit-free,
    /// works from a plain CLI process).
    public static func openInBrowser(_ url: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url]
        try? process.run()
    }
}
