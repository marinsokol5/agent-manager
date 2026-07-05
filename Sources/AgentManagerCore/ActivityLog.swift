import Foundation

/// One ping outcome, for the Activity screen's "is it actually working?" view.
///
/// `anchored` is the make-or-break signal the design calls out: did a window
/// *actually* open, not just "did the command exit 0". For the `tui` ping that's
/// the same as `ok` (a dispatched interactive turn anchors the 5h window); we
/// keep it a separate field so a future headless/SDK path can record "ran but
/// didn't anchor". On failure, `transcriptPath` points at the saved PTY
/// transcript for debugging.
public struct ActivityRecord: Codable, Sendable, Equatable {
    public var time: Date
    public var accountID: String
    public var ok: Bool
    public var anchored: Bool
    public var detail: String
    public var transcriptPath: String?

    public init(time: Date = Date(), accountID: String, ok: Bool, anchored: Bool, detail: String, transcriptPath: String? = nil) {
        self.time = time
        self.accountID = accountID
        self.ok = ok
        self.anchored = anchored
        self.detail = detail
        self.transcriptPath = transcriptPath
    }
}

/// Append-only JSONL ping log. Best-effort — like `AuditLog`, a logging failure
/// never breaks the ping it observes. Both the launchd runner (`am bump`) and the
/// App's "Test ping" write here (through `AccountPinger`).
public struct ActivityLog {
    let fileURL: URL
    let logsDir: URL
    let fileManager: FileManager

    public init(fileURL: URL, logsDir: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.logsDir = logsDir
        self.fileManager = fileManager
    }

    public init(workspace: Workspace, fileManager: FileManager = .default) {
        self.init(fileURL: workspace.activityLogFile, logsDir: workspace.logsDir, fileManager: fileManager)
    }

    public func append(_ record: ActivityRecord) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else { return }
        JSONLAppend.appendLine(data, to: fileURL, fileManager: fileManager)
    }

    /// Persist a failed ping's PTY transcript so it can be inspected later;
    /// returns the file path written (or `nil` if it couldn't be saved).
    @discardableResult
    public func saveTranscript(_ transcript: String, accountID: String, at time: Date = Date()) -> String? {
        guard !transcript.isEmpty else { return nil }
        if !fileManager.fileExists(atPath: logsDir.path) {
            try? fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)
        }
        let stamp = Int(time.timeIntervalSince1970)
        let url = logsDir.appendingPathComponent("\(accountID)-\(stamp).transcript")
        guard (try? transcript.write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        return url.path
    }

    /// Most recent records first, capped at `limit`; `since` drops anything
    /// older (Monitoring shows a rolling time window, not the whole file).
    public func readRecent(limit: Int = 50, since: Date? = nil) -> [ActivityRecord] {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var recs = content.split(separator: "\n").compactMap { line -> ActivityRecord? in
            guard let d = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(ActivityRecord.self, from: d)
        }
        if let since { recs.removeAll { $0.time < since } }
        recs.reverse()
        return Array(recs.prefix(limit))
    }
}
