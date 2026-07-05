import Foundation
import ServiceManagement

/// The SMAppService flavor of the resident scheduler agent — the no-sudo path
/// that groups the agent under the **app's own row** in System Settings → Login
/// Items & Extensions (via `AssociatedBundleIdentifiers`), instead of under the
/// developer name the way a plain `launchctl`-bootstrapped agent does.
///
/// A mirror of `WakeHelperAppService`, but for a **LaunchAgent** (per-user login
/// session — which is exactly why the scheduler can live here and the keychain
/// still reads: an SMAppService agent runs in the user's Aqua session, the same
/// `gui/<uid>` domain the classic bootstrap targeted).
///
/// When the app runs from the assembled `.app` (which carries the agent plist in
/// `Contents/Library/LaunchAgents`), `Scheduler.activate` registers here; the
/// user approves once. The classic `~/Library/LaunchAgents` bootstrap
/// (`Scheduler.ensureAgent`) remains for bare `swift build` binaries and the test
/// suite. Both use the **same launchd label**, so they must never coexist —
/// `Scheduler` picks the SMAppService path whenever `isAvailable`.
///
/// The bundled plist is sealed and static (no per-user paths): a variant-compiled
/// `am` derives its own workspace, and `am ping` children self-enrich `PATH`, so
/// nothing schedule- or user-shaped needs to live in the plist. See
/// `Support/scheduler.plist.in`.
public enum SchedulerAppService {
    /// Our summary of `SMAppService.Status`, plus the "not even possible" case,
    /// so UI/CLI code doesn't import ServiceManagement. Same shape as
    /// `WakeHelperAppService.Registration`.
    public enum Registration: Sendable, Equatable {
        /// Not running from a bundle that carries the agent plist (bare
        /// `swift build` binary) — only the classic bootstrap can work.
        case unavailable
        case notRegistered
        /// Registered; waiting for the one-time approval in System Settings →
        /// General → Login Items & Extensions.
        case requiresApproval
        /// Approved — launchd owns the agent.
        case enabled
        /// launchd can't find the registered service (e.g. the bundle moved);
        /// re-registering from the current location repairs it.
        case notFound
    }

    static var service: SMAppService {
        SMAppService.agent(plistName: LaunchAgentPlanner.schedulerFilename)
    }

    /// The running executable was launched from a bundle that actually ships the
    /// scheduler agent plist. When false, callers fall back to the classic
    /// `~/Library/LaunchAgents` bootstrap.
    public static var isAvailable: Bool {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return false }
        return FileManager.default.fileExists(
            atPath: bundle.appendingPathComponent("Contents/Library/LaunchAgents/\(LaunchAgentPlanner.schedulerFilename)").path)
    }

    public static func registration() -> Registration {
        guard isAvailable else { return .unavailable }
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        case .notRegistered: return .notRegistered
        @unknown default: return .notRegistered
        }
    }

    /// Ask launchd to adopt the bundled agent. On first use this trips the
    /// approval flow (macOS notifies and the service reads `requiresApproval`
    /// until the user allows it); `register()` may throw in that pending state,
    /// so callers should re-read `registration()` rather than treat the throw as
    /// fatal. Idempotent once enabled — re-registering an already-approved agent
    /// makes no change and posts no new notification.
    public static func register() throws {
        try service.register()
    }

    public static func unregister() throws {
        try service.unregister()
    }

    /// Deep-link to System Settings → Login Items so the user can approve.
    public static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
