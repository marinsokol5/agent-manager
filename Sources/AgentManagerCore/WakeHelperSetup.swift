import Foundation

/// Installs / removes / inspects the **classic** flavor of the root wake
/// helper (`am-wake-helper`) — the `sudo am wake install` path.
///
/// This is the fallback for bare-binary/dev setups; the supported path is the
/// bundled daemon registered via `WakeHelperAppService` (SMAppService, no
/// sudo) when running from the assembled `AgentManager.app`. Both use the same
/// launchd label, so only one may be installed at a time — the app checks for
/// this classic install first and leaves it alone.
///
/// What the classic path still does better: the binary is *copied* to a
/// **root-owned** location (`/Library/PrivilegedHelperTools`), so the root
/// daemon never executes from a user-writable path. That hygiene is why
/// updating this flavor of the helper needs sudo again, while everything else
/// in this repo never does.
///
/// The install is a one-time admin action: after it, the helper runs forever
/// (KeepAlive, system domain) and is controlled purely through `wake.json`.
/// macOS shows its one-time "background items added" notification at
/// bootstrap — same one-per-registration behavior the scheduler agent has.
///
/// Everything is injectable (dirs, launchd runner, source path, ownership
/// application) so install/uninstall/render are unit-testable without root.
public struct WakeHelperSetup {
    public static let label = ScheduledWakes.helperID           // com.agent-manager.wake-helper
    public static let plistFilename = label + ".plist"
    public static let helperFilename = "am-wake-helper"

    let workspace: Workspace
    let launchd: LaunchdController
    let helperInstallDir: URL
    let daemonsDir: URL
    let logsDir: URL
    let sourceBinary: String?
    let fileManager: FileManager
    /// Real installs chown the binary/plist to root:wheel; tests can't, so
    /// they run with this off. Never disable it on a real install path.
    let applyRootOwnership: Bool

    public init(
        workspace: Workspace,
        launchd: LaunchdController = .system(),
        helperInstallDir: URL = URL(fileURLWithPath: "/Library/PrivilegedHelperTools", isDirectory: true),
        daemonsDir: URL = URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true),
        logsDir: URL = URL(fileURLWithPath: "/Library/Logs", isDirectory: true),
        sourceBinary: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        applyRootOwnership: Bool = true)
    {
        self.workspace = workspace
        self.launchd = launchd
        self.helperInstallDir = helperInstallDir
        self.daemonsDir = daemonsDir
        self.logsDir = logsDir
        self.sourceBinary = sourceBinary ?? WakeHelperSetup.resolveSourceBinary(environment: environment, fileManager: fileManager)
        self.fileManager = fileManager
        self.applyRootOwnership = applyRootOwnership
    }

    public var installedBinary: URL { helperInstallDir.appendingPathComponent(WakeHelperSetup.helperFilename) }
    public var installedPlist: URL { daemonsDir.appendingPathComponent(WakeHelperSetup.plistFilename) }

    /// The freshly built helper to install: env override (tests/dev) → a
    /// sibling named `am-wake-helper` next to the current executable (covers
    /// `am` and the app — `swift build` puts all products side by side).
    static func resolveSourceBinary(environment: [String: String], fileManager: FileManager) -> String? {
        if let override = environment["AGENT_MANAGER_WAKE_HELPER_BIN"]?.trimmingCharacters(in: .whitespaces), !override.isEmpty {
            return override
        }
        if let exe = Bundle.main.executablePath {
            let sibling = (exe as NSString).deletingLastPathComponent + "/" + WakeHelperSetup.helperFilename
            if fileManager.isExecutableFile(atPath: sibling) { return sibling }
        }
        return nil
    }

    /// The LaunchDaemon plist. The workspace root is baked in as `--root` at
    /// install time — that path is the admin-approved scope of what the helper
    /// will ever read, and re-running install re-bakes it for a new workspace.
    func renderPlist() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(WakeHelperSetup.label)</string>
          <key>ProgramArguments</key>
          <array>
            <string>\(xmlEscape(installedBinary.path))</string>
            <string>--root</string>
            <string>\(xmlEscape(workspace.root.path))</string>
          </array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><true/>
          <key>ProcessType</key><string>Background</string>
          <key>StandardOutPath</key><string>\(xmlEscape(logsDir.appendingPathComponent(WakeHelperSetup.label + ".out.log").path))</string>
          <key>StandardErrorPath</key><string>\(xmlEscape(logsDir.appendingPathComponent(WakeHelperSetup.label + ".err.log").path))</string>
        </dict>
        </plist>
        """
    }

    // MARK: - install / uninstall (root)

    public struct InstallReport: Sendable {
        public var binaryUpdated: Bool
        public var plistUpdated: Bool
        public var loaded: Bool
        public var loadOutput: String
    }

    public enum SetupError: Error, CustomStringConvertible {
        case notRoot
        case helperBinaryNotFound
        public var description: String {
            switch self {
            case .notRoot:
                return "must run as root — try: sudo am wake install"
            case .helperBinaryNotFound:
                return "am-wake-helper binary not found next to am (build it with `swift build`)"
            }
        }
    }

    /// Copy the helper to its root-owned home, write the daemon plist, and
    /// bootstrap it. Idempotent: an unchanged install with the daemon loaded
    /// re-registers nothing. Requires root (the destination dirs and the
    /// system launchd domain both do).
    @discardableResult
    public func install(euid: uid_t = geteuid()) throws -> InstallReport {
        guard euid == 0 else { throw SetupError.notRoot }
        guard let source = sourceBinary, fileManager.isExecutableFile(atPath: source) else {
            throw SetupError.helperBinaryNotFound
        }

        try fileManager.createDirectory(at: helperInstallDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: daemonsDir, withIntermediateDirectories: true)

        // Binary: replace only when the bytes differ, so re-running install is
        // a cheap no-op health check.
        let sourceData = try Data(contentsOf: URL(fileURLWithPath: source))
        let installedData = try? Data(contentsOf: installedBinary)
        let binaryUpdated = installedData != sourceData
        if binaryUpdated {
            try? fileManager.removeItem(at: installedBinary)
            try sourceData.write(to: installedBinary)
            try applyPrivilegedAttributes(to: installedBinary, permissions: 0o755)
        }

        let rendered = renderPlist()
        let onDisk = try? String(contentsOf: installedPlist, encoding: .utf8)
        let plistUpdated = onDisk != rendered
        if plistUpdated {
            try rendered.write(to: installedPlist, atomically: true, encoding: .utf8)
            try applyPrivilegedAttributes(to: installedPlist, permissions: 0o644)
        }

        // (Re)bootstrap when anything changed or it simply isn't running yet;
        // otherwise leave launchd untouched (same no-churn manners as the
        // scheduler agent, though here re-installs are rare anyway).
        if !binaryUpdated && !plistUpdated && launchd.loadedLabels().contains(WakeHelperSetup.label) {
            return InstallReport(binaryUpdated: false, plistUpdated: false, loaded: true, loadOutput: "")
        }
        let result = launchd.bootstrap(plistPath: installedPlist.path, label: WakeHelperSetup.label)
        return InstallReport(binaryUpdated: binaryUpdated, plistUpdated: plistUpdated, loaded: result.ok, loadOutput: result.output)
    }

    /// launchd refuses (and security requires) daemons that aren't root-owned;
    /// tests can't chown, so they construct the setup with ownership off.
    private func applyPrivilegedAttributes(to url: URL, permissions: Int) throws {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: permissions]
        if applyRootOwnership {
            attributes[.ownerAccountID] = 0
            attributes[.groupOwnerAccountID] = 0
        }
        try fileManager.setAttributes(attributes, ofItemAtPath: url.path)
    }

    public struct UninstallReport: Sendable {
        public var removed: [String]
    }

    /// Boot the daemon out and delete both installed artifacts. Root required.
    @discardableResult
    public func uninstall(euid: uid_t = geteuid()) throws -> UninstallReport {
        guard euid == 0 else { throw SetupError.notRoot }
        var removed: [String] = []
        launchd.bootout(label: WakeHelperSetup.label)
        if fileManager.fileExists(atPath: installedPlist.path) {
            try? fileManager.removeItem(at: installedPlist)
            removed.append(installedPlist.path)
        }
        if fileManager.fileExists(atPath: installedBinary.path) {
            try? fileManager.removeItem(at: installedBinary)
            removed.append(installedBinary.path)
        }
        return UninstallReport(removed: removed)
    }

    // MARK: - status (unprivileged)

    public struct Status: Sendable {
        /// The user's opt-in flag in `wake.json`.
        public var enabled: Bool
        public var binaryInstalled: Bool
        public var plistInstalled: Bool
        /// The workspace root baked into the installed plist (nil = not parsed).
        public var installedForRoot: String?
        /// The installed plist serves *this* workspace.
        public var rootMatches: Bool
        /// The installed binary's bytes differ from the freshly built helper —
        /// re-run `sudo am wake install` to update it.
        public var needsUpdate: Bool
        /// Our wakes currently armed in the system's RTC table (ground truth,
        /// readable without privileges).
        public var scheduledWakes: [Date]
    }

    public func status() -> Status {
        let enabled = WakeConfigStore(workspace: workspace, fileManager: fileManager).load().enabled
        let plistText = try? String(contentsOf: installedPlist, encoding: .utf8)
        let installedRoot = plistText.flatMap(WakeHelperSetup.parseRootArgument)
        var needsUpdate = false
        if let source = sourceBinary,
           let sourceData = try? Data(contentsOf: URL(fileURLWithPath: source)),
           let installedData = try? Data(contentsOf: installedBinary) {
            needsUpdate = sourceData != installedData
        }
        return Status(
            enabled: enabled,
            binaryInstalled: fileManager.isExecutableFile(atPath: installedBinary.path),
            plistInstalled: plistText != nil,
            installedForRoot: installedRoot,
            rootMatches: installedRoot == workspace.root.path,
            needsUpdate: needsUpdate,
            scheduledWakes: ScheduledWakes.ours().map(\.date))
    }

    // MARK: - process state (unprivileged)

    /// Whether the daemon *process* is actually alive — a different question
    /// from "is it registered". SMAppService/BTM can report a registration as
    /// enabled while launchd fails every spawn (seen in practice after dev
    /// re-signing of the bundle invalidated the Background-items approval:
    /// `job state = spawn failed`, exit 78, thousands of retries — with the
    /// registration still reading `.enabled`). Parsed from `launchctl print`,
    /// which works unprivileged even for the system domain.
    public enum ProcessState: Sendable, Equatable {
        /// launchd has a live process for the label.
        case running(pid: Int32)
        /// Registered, but launchd cannot start it (the detail carries the
        /// `last exit code` line when present). Re-registering is the heal.
        case spawnFailed(detail: String)
        /// The label isn't loaded in the system domain at all.
        case notLoaded
        /// Loaded with no pid yet and no recorded failure (e.g. a spawn
        /// scheduled moments ago) — indeterminate, treat as neither.
        case starting

        public var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    public func processState() -> ProcessState {
        let result = launchd.printJob(label: WakeHelperSetup.label)
        return WakeHelperSetup.classifyProcessState(output: result.output, ok: result.ok)
    }

    /// The pure classifier over `launchctl print` output. Only top-level job
    /// facts are trusted: the first `pid = N` line (a running job prints one),
    /// the `job state = spawn failed` marker, and the `last exit code` line.
    static func classifyProcessState(output: String, ok: Bool) -> ProcessState {
        guard ok else { return .notLoaded }
        var pid: Int32?
        var lastExit: String?
        var spawnFailed = false
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if pid == nil, line.hasPrefix("pid = "), let value = Int32(line.dropFirst("pid = ".count)) {
                pid = value
            } else if line.hasPrefix("last exit code = ") {
                lastExit = line
            } else if line == "job state = spawn failed" {
                spawnFailed = true
            }
        }
        if let pid { return .running(pid: pid) }
        if spawnFailed { return .spawnFailed(detail: lastExit ?? "job state = spawn failed") }
        return .starting
    }

    /// Pull the `--root` value back out of an installed plist (the `<string>`
    /// right after `<string>--root</string>`), so status can tell when the
    /// helper is serving a different workspace than the one asking.
    static func parseRootArgument(inPlist text: String) -> String? {
        guard let flag = text.range(of: "<string>--root</string>") else { return nil }
        guard let open = text.range(of: "<string>", range: flag.upperBound..<text.endIndex),
              let close = text.range(of: "</string>", range: open.upperBound..<text.endIndex) else { return nil }
        let value = String(text[open.upperBound..<close.lowerBound])
        return value
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
