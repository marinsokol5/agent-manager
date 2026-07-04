import Foundation

/// On-disk persistence for the last-known usage reading per account.
///
/// Loaded on launch so the menu bar can show numbers immediately, and so the
/// app does *not* fire an eager network fetch just to repopulate state it
/// already had. Saved (whole-file, atomic) after each successful fetch. Holds no
/// secrets — only the normalized percentages and timestamps from `UsageReading`.
public struct UsageCache {
    public static let currentVersion = 1

    struct Stored: Codable {
        var version: Int
        var readings: [String: UsageReading]
    }

    let fileURL: URL
    let fileManager: FileManager

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public init(workspace: Workspace, fileManager: FileManager = .default) {
        self.init(fileURL: workspace.usageCacheFile, fileManager: fileManager)
    }

    /// Best-effort load; a missing/corrupt file yields an empty cache rather than
    /// throwing — stale-or-absent usage is never worth failing launch over.
    public func load() -> [String: UsageReading] {
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL)
        else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stored = try? decoder.decode(Stored.self, from: data),
              stored.version == Self.currentVersion
        else { return [:] }
        return stored.readings
    }

    public func save(_ readings: [String: UsageReading]) {
        let stored = Stored(version: Self.currentVersion, readings: readings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(stored) else { return }
        let dir = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try? data.write(to: fileURL, options: [.atomic])
    }
}
