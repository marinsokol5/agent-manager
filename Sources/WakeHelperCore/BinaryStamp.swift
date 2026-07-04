import Foundation

/// An mtime+size fingerprint of the helper's own executable, used to notice a
/// rebuilt/upgraded binary from inside the long-lived daemon process.
///
/// Both of our resident daemons are `KeepAlive` launchd jobs, which makes
/// "restart on upgrade" one line: when the file on disk no longer matches the
/// stamp taken at launch, the process exits and launchd relaunches it on the
/// new code — no re-registration, no notification, no manual restart. The
/// scheduler daemon carries its own copy of this logic in `AgentManagerCore`;
/// this one is deliberately separate so the root helper keeps linking
/// WakeHelperCore only.
public struct BinaryStamp: Equatable, Sendable {
    public var mtime: Date
    public var size: Int

    public init(mtime: Date, size: Int) {
        self.mtime = mtime
        self.size = size
    }

    public static func read(path: String, fileManager: FileManager = .default) -> BinaryStamp? {
        guard let attrs = try? fileManager.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        return BinaryStamp(mtime: mtime, size: (attrs[.size] as? Int) ?? 0)
    }

    /// Whether the process should exit for a relaunch: the binary on disk
    /// differs from the one we launched from *and* has settled — a build may
    /// still be writing/codesigning a file younger than `settle`, and a
    /// missing file (mid-reassembly of the .app bundle) is the same
    /// wait-don't-restart situation.
    public static func restartDue(
        sinceLaunch launch: BinaryStamp?,
        current: BinaryStamp?,
        now: Date,
        settle: TimeInterval = 30) -> Bool
    {
        guard let current, current != launch else { return false }
        return now.timeIntervalSince(current.mtime) >= settle
    }
}
