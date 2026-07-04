import Foundation
import ServiceManagement

/// The SMAppService flavor of wake-helper management — the no-sudo path.
///
/// When the app runs from the assembled `AgentManager.app` (which carries the
/// helper and its daemon plist in `Contents/Library/LaunchDaemons`), the "Wake
/// Mac for pings" toggle registers the daemon here and the user approves it
/// once in System Settings → Login Items & Extensions. launchd then runs the
/// bundled helper as root with no arguments — that helper variant discovers
/// every standard workspace under `/Users/*` on its own (the sealed bundle
/// plist can't carry a per-user path).
///
/// The classic `WakeHelperSetup` install (`sudo am wake install`, root-owned
/// copy) remains for bare-binary/dev setups. Both use the **same launchd
/// label**, so they must never coexist: callers check for a classic install
/// first and leave it alone.
public enum WakeHelperAppService {
    /// Our summary of `SMAppService.Status`, plus the "not even possible"
    /// case, so UI code doesn't import ServiceManagement.
    public enum Registration: Sendable, Equatable {
        /// Not running from a bundle that carries the daemon plist (bare
        /// `swift build` binary) — only the classic sudo install can work.
        case unavailable
        case notRegistered
        /// Registered; waiting for the one-time approval in System Settings →
        /// General → Login Items & Extensions.
        case requiresApproval
        /// Approved — launchd owns the daemon.
        case enabled
        /// launchd can't find the registered service (e.g. the bundle moved);
        /// re-registering from the current location repairs it.
        case notFound
    }

    static var service: SMAppService { SMAppService.daemon(plistName: WakeHelperSetup.plistFilename) }

    /// The running executable was launched from a bundle that actually ships
    /// the daemon plist.
    public static var isAvailable: Bool {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return false }
        return FileManager.default.fileExists(
            atPath: bundle.appendingPathComponent("Contents/Library/LaunchDaemons/\(WakeHelperSetup.plistFilename)").path)
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

    /// Ask launchd to adopt the bundled daemon. On first use this trips the
    /// approval flow (macOS notifies and the service reads `requiresApproval`
    /// until the user allows it); `register()` may throw in that pending state,
    /// so callers should re-read `registration()` afterwards rather than treat
    /// the throw as fatal.
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
