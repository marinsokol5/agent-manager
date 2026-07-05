import Foundation

/// Build-variant identity — the single source of truth that lets a locally
/// built **dev** app run side by side with the released **prod** app without
/// colliding on bundle ID, launchd labels, workspace, or the macOS
/// background-item (BTM) records those feed.
///
/// The variant is chosen at **compile time** by the `AGENT_MANAGER_DEV` define:
/// `make build` / `make run` pass it (dev); `make release` — the build brew
/// ships — does not (prod). Everything identity-shaped derives from here, so the
/// two builds stay fully partitioned: separate BTM rows, keychain grants
/// (the token is keyed by config-dir hash, and the dev workspace is a different
/// dir), config, and on-disk state.
///
/// `WakeHelperCore` deliberately carries its own mirror (`WakeVariant`) rather
/// than importing this: the root wake-helper binary never links
/// `AgentManagerCore` (same reason its decoders are duplicated), and the shared
/// `AGENT_MANAGER_DEV` define keeps the two in lockstep.
public enum AppVariant {
    #if AGENT_MANAGER_DEV
    public static let isDev = true
    #else
    public static let isDev = false
    #endif

    /// The app bundle identifier — `com.agent-manager.app` (prod) /
    /// `com.agent-manager.app.dev` (dev). Set in `Info.plist` by the Makefile;
    /// this constant is the value that identity-derived code expects to match.
    public static let bundleID = isDev ? "com.agent-manager.app.dev" : "com.agent-manager.app"

    /// Prefix for every launchd Label / plist filename this build owns —
    /// `com.agent-manager.` (prod) / `com.agent-manager.dev.` (dev).
    public static let labelPrefix = isDev ? "com.agent-manager.dev." : "com.agent-manager."

    /// This build's workspace directory name under `~/Library/Application
    /// Support/` — `AgentManager` (prod) / `AgentManager-dev` (dev).
    public static let workspaceDirName = isDev ? "AgentManager-dev" : "AgentManager"

    /// Human-facing app name (also `CFBundleName`/`CFBundleDisplayName`).
    public static let displayName = isDev ? "Agent Manager (Dev)" : "Agent Manager"
}
