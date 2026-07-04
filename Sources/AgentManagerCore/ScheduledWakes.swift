import Foundation
import IOKit.pwr_mgt

/// Read-only view of the system's scheduled-power-event table (what
/// `pmset -g sched` prints). Reading is unprivileged, so the app and CLI can
/// show ground truth about what the root wake helper actually armed — the
/// helper itself is observable without talking to it.
public enum ScheduledWakes {
    /// The identity the wake helper schedules under (`scheduledby` in the
    /// event table). Must match the literal in `am-wake-helper`.
    public static let helperID = "com.agent-manager.wake-helper"

    public struct Event: Equatable, Sendable {
        public var date: Date
        public var type: String
        public var scheduledBy: String
    }

    // Mirrors of IOPMLib.h's dictionary keys (kIOPMPowerEventTimeKey etc.).
    private static let keyTime = "time"
    private static let keyScheduledBy = "scheduledby"
    private static let keyType = "eventtype"

    public static func all() -> [Event] {
        guard let raw = IOPMCopyScheduledPowerEvents()?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return raw.compactMap { event in
            guard let date = event[keyTime] as? Date,
                  let type = event[keyType] as? String else { return nil }
            return Event(date: date, type: type, scheduledBy: event[keyScheduledBy] as? String ?? "")
        }
        .sorted { $0.date < $1.date }
    }

    /// The wakes our helper currently owns, earliest first.
    public static func ours() -> [Event] {
        all().filter { $0.scheduledBy == helperID && $0.type == "wake" }
    }
}
