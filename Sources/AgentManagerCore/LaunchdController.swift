import Foundation

/// Thin wrapper over `launchctl` for loading/unloading our launchd jobs and
/// reading which of ours are currently loaded (the Activity screen's
/// `loaded`/`not scheduled` badge).
///
/// Uses the modern `bootstrap`/`bootout` verbs. The scheduler agent lives in
/// the **GUI domain** (`gui/<uid>`) — the design's reason for launchd over
/// cron is that Claude's creds live in the login keychain, reachable only from
/// a GUI-session agent. The root wake helper is the one exception: it needs
/// `IOPMSchedulePowerEvent` (root-only), so it loads in the **system domain**
/// via `LaunchdController.system()` — and, having no keychain business, loses
/// nothing by living there.
public struct LaunchdController {
    public struct CommandResult: Sendable {
        public var ok: Bool
        public var output: String
    }

    /// Run a subprocess; `nil` runner means the real `/bin/launchctl`. Injectable
    /// so the orchestration above it stays testable without touching the system.
    public typealias Runner = @Sendable (_ arguments: [String]) -> CommandResult

    let runner: Runner
    public let domainTarget: String

    public init(uid: UInt32 = getuid(), runner: Runner? = nil) {
        self.domainTarget = "gui/\(uid)"
        self.runner = runner ?? LaunchdController.systemRunner
    }

    private init(domainTarget: String, runner: Runner?) {
        self.domainTarget = domainTarget
        self.runner = runner ?? LaunchdController.systemRunner
    }

    /// The system domain (root LaunchDaemons) — bootstrapping here requires
    /// the caller itself to be root.
    public static func system(runner: Runner? = nil) -> LaunchdController {
        LaunchdController(domainTarget: "system", runner: runner)
    }

    /// Load (or reload) an agent: `bootout` first so a changed plist takes effect,
    /// then `bootstrap`. A failing `bootout` (job wasn't loaded) is expected and
    /// ignored; only the `bootstrap` result is returned.
    @discardableResult
    public func bootstrap(plistPath: String, label: String) -> CommandResult {
        _ = runner(["bootout", "\(domainTarget)/\(label)"])
        return runner(["bootstrap", domainTarget, plistPath])
    }

    /// Unload an agent. A "not loaded" failure is fine — the caller is removing it.
    @discardableResult
    public func bootout(label: String) -> CommandResult {
        runner(["bootout", "\(domainTarget)/\(label)"])
    }

    /// Restart a loaded job's running process in place (`kickstart -k`).
    /// Unlike `bootout`/`bootstrap` this never (re)registers the job, so it
    /// cannot trigger macOS's "background items added" notification — the
    /// right verb for bouncing a daemon that is running a stale binary.
    @discardableResult
    public func kickstart(label: String) -> CommandResult {
        runner(["kickstart", "-k", "\(domainTarget)/\(label)"])
    }

    /// One job's runtime state (`launchctl print domain/label`). Reading is
    /// allowed unprivileged even in the system domain — how "registered" gets
    /// told apart from "actually running" without root.
    public func printJob(label: String) -> CommandResult {
        runner(["print", "\(domainTarget)/\(label)"])
    }

    /// Labels currently loaded that belong to us (parsed from `launchctl list`).
    public func loadedLabels() -> Set<String> {
        let result = runner(["list"])
        guard result.ok else { return [] }
        var labels: Set<String> = []
        for line in result.output.split(separator: "\n") {
            // Format: "<PID|->\t<status>\t<label>"
            guard let label = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).last else { continue }
            let l = String(label)
            if l.hasPrefix(LaunchAgentPlanner.labelPrefix) { labels.insert(l) }
        }
        return labels
    }

    /// The real launchctl runner.
    static let systemRunner: Runner = { arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return CommandResult(ok: process.terminationStatus == 0, output: String(decoding: data, as: UTF8.self))
        } catch {
            return CommandResult(ok: false, output: "failed to run launchctl: \(error.localizedDescription)")
        }
    }
}
