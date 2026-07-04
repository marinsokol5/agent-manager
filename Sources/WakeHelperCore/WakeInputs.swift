import Foundation

/// Minimal, tolerant readers for the two workspace files the root helper
/// consumes: `wake.json` (the user's opt-in) and `scheduler-status.json` (the
/// resident daemon's heartbeat + upcoming queue).
///
/// These decoders are *deliberately duplicated* from `AgentManagerCore` rather
/// than shared: the helper binary runs as root, so it must not link the
/// library that contains keychain, network, and process-spawning code. It
/// reads exactly the fields it needs and treats both files as untrusted input
/// — any shape it doesn't recognize simply decodes to "schedule nothing", and
/// no file content is ever echoed anywhere (the helper logs counts and dates
/// only).
public enum WakeInputs {
    /// One workspace's wake-relevant state, as read off disk.
    public struct Snapshot: Equatable, Sendable {
        /// `wake.json` exists and says `"enabled": true`.
        public var enabled: Bool
        /// The daemon heartbeat's `updatedAt` (nil = no/unreadable status file).
        public var statusUpdatedAt: Date?
        /// The upcoming fire times, capped at `maxUpcoming`.
        public var fires: [Date]

        public init(enabled: Bool, statusUpdatedAt: Date? = nil, fires: [Date] = []) {
            self.enabled = enabled
            self.statusUpdatedAt = statusUpdatedAt
            self.fires = fires
        }
    }

    /// More entries than the daemon would ever publish (it caps at 50); a file
    /// larger than that is not ours — stop reading rather than obey it.
    public static let maxUpcoming = 64

    /// Every standard Agent Manager workspace on the machine — one per user
    /// home. Used by the SMAppService-registered helper, whose plist is sealed
    /// inside the signed app bundle and therefore can't carry a per-user
    /// workspace path; each discovered workspace is still individually gated by
    /// its own `wake.json`. (The classic `sudo am wake install` path instead
    /// bakes one explicit root into its plist.)
    public static func standardWorkspaceRoots(
        under usersDir: URL = URL(fileURLWithPath: "/Users", isDirectory: true),
        fileManager: FileManager = .default)
        -> [URL]
    {
        let homes = (try? fileManager.contentsOfDirectory(at: usersDir, includingPropertiesForKeys: nil)) ?? []
        return homes
            .map { $0.appendingPathComponent("Library/Application Support/AgentManager", isDirectory: true) }
            .filter { fileManager.fileExists(atPath: $0.path) }
            .sorted { $0.path < $1.path }
    }

    // Only the fields we need; unknown keys are ignored by Decodable.
    private struct StatusFile: Decodable {
        struct Entry: Decodable { var fireAt: Date }
        var updatedAt: Date
        var upcoming: [Entry]
    }

    private struct ConfigFile: Decodable { var enabled: Bool? }

    public static func read(root: URL, fileManager: FileManager = .default) -> Snapshot {
        var snapshot = Snapshot(enabled: false)

        if let data = fileManager.contents(atPath: root.appendingPathComponent("wake.json").path),
           data.count < 4096,
           let config = try? JSONDecoder().decode(ConfigFile.self, from: data) {
            snapshot.enabled = config.enabled ?? false
        }
        // Not enabled → don't even parse the queue; the answer is already "no wakes".
        guard snapshot.enabled else { return snapshot }

        guard let data = fileManager.contents(atPath: root.appendingPathComponent("scheduler-status.json").path),
              data.count < 1 << 20 else { return snapshot }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let status = try? decoder.decode(StatusFile.self, from: data) else { return snapshot }
        snapshot.statusUpdatedAt = status.updatedAt
        snapshot.fires = status.upcoming.prefix(maxUpcoming).map(\.fireAt)
        return snapshot
    }
}
