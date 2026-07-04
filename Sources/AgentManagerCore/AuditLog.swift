import Foundation

/// One line in the local audit trail.
///
/// The audit log records every read, ping, launch, reset and failure — but
/// **never tokens**. Only pass non-secret material into `detail`.
public struct AuditEvent: Codable, Sendable {
    public var time: Date
    public var accountID: String?
    /// Dotted action key, e.g. `account.add.start`, `home.create`,
    /// `symlink.farm`, `login.url`, `login.result`, `verify`.
    public var action: String
    public var ok: Bool
    public var detail: String

    public init(time: Date = Date(), accountID: String?, action: String, ok: Bool, detail: String) {
        self.time = time
        self.accountID = accountID
        self.action = action
        self.ok = ok
        self.detail = detail
    }
}

/// Append-only JSONL audit log. Best-effort: failures to write are swallowed so
/// auditing never breaks the flow it observes.
public struct AuditLog {
    let fileURL: URL
    let fileManager: FileManager

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public init(workspace: Workspace, fileManager: FileManager = .default) {
        self.init(fileURL: workspace.auditLogFile, fileManager: fileManager)
    }

    public func append(_ event: AuditEvent) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var data = try? encoder.encode(event) else { return }
        data.append(0x0A) // newline-delimited JSON

        let dir = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL, options: [.atomic])
        }
    }

    public func append(accountID: String?, action: String, ok: Bool, detail: String) {
        append(AuditEvent(accountID: accountID, action: action, ok: ok, detail: detail))
    }

    /// Most recent events first, capped at `limit` (for Monitoring → Logs);
    /// `since` drops anything older (Monitoring shows a rolling time window,
    /// not the whole file).
    public func readRecent(limit: Int = 100, since: Date? = nil) -> [AuditEvent] {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var events = content.split(separator: "\n").compactMap { line -> AuditEvent? in
            guard let d = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(AuditEvent.self, from: d)
        }
        if let since { events.removeAll { $0.time < since } }
        events.reverse()
        return Array(events.prefix(limit))
    }
}
