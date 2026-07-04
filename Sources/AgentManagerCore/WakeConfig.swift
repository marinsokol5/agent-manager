import Foundation

/// `wake.json` — the "Wake Mac for pings" opt-in, sibling to `scheduler.json`.
///
/// Written by the app toggle / `am wake enable|disable`; read by the root
/// wake helper (via its own minimal decoder in `WakeHelperCore` — the helper
/// deliberately doesn't link this library). Flipping this file is the entire
/// runtime control surface for the helper: disabling doesn't uninstall
/// anything, it just makes the helper clear its RTC wakes on its next pass.
public struct WakeConfig: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var enabled: Bool

    public init(version: Int = WakeConfig.currentVersion, enabled: Bool = false) {
        self.version = version
        self.enabled = enabled
    }
}

/// Reads/writes `wake.json`. Forgiving load (missing/corrupt → disabled — a
/// root helper must never act on state it can't read), atomic save.
public struct WakeConfigStore {
    let fileURL: URL
    let fileManager: FileManager

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public init(workspace: Workspace, fileManager: FileManager = .default) {
        self.init(fileURL: workspace.wakeConfigFile, fileManager: fileManager)
    }

    public func load() -> WakeConfig {
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let config = try? JSONDecoder().decode(WakeConfig.self, from: data)
        else { return WakeConfig() }
        return config
    }

    public func save(_ config: WakeConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        let dir = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try data.write(to: fileURL, options: [.atomic])
    }
}
