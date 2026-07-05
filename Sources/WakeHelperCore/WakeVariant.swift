import Foundation

/// Build-variant identity for the root wake helper — a deliberate mirror of
/// `AgentManagerCore.AppVariant` (kept here because the root binary never links
/// `AgentManagerCore`; the same reason `WakeInputs`' decoders are duplicated).
///
/// Selected by the same `AGENT_MANAGER_DEV` compile define, so a **dev** build's
/// helper registers under a distinct launchd label, schedules its RTC wakes
/// under that label's `scheduledby` identity, and watches the dev workspace —
/// never touching the released prod helper's label, wakes, or workspace.
///
/// These must stay byte-for-byte in step with `AppVariant`'s counterparts.
public enum WakeVariant {
    #if AGENT_MANAGER_DEV
    public static let isDev = true
    #else
    public static let isDev = false
    #endif

    /// Must match `AgentManagerCore.AppVariant.labelPrefix`.
    public static let labelPrefix = isDev ? "com.agent-manager.dev." : "com.agent-manager."

    /// Must match `AgentManagerCore.AppVariant.workspaceDirName`.
    public static let workspaceDirName = isDev ? "AgentManager-dev" : "AgentManager"

    /// The wake helper's launchd Label and power-event `scheduledby` identity.
    /// Must match `AgentManagerCore.ScheduledWakes.helperID`.
    public static let helperID = labelPrefix + "wake-helper"
}
