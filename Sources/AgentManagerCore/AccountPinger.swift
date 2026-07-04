import Foundation

/// Pings (anchors the 5h window of) a connected account, gated on `Connected`
/// and audited. The provider switch keeps it ready for Codex later.
public struct AccountPinger {
    public enum PingError: Error, CustomStringConvertible {
        case notFound(String)
        case notConnected(AccountStatus)

        public var description: String {
            switch self {
            case let .notFound(id): "no account with id '\(id)'"
            case let .notConnected(status): "account is \(status.rawValue) — ping requires a connected account"
            }
        }
    }

    let workspace: Workspace
    let fileManager: FileManager
    let store: AccountStore
    let audit: AuditLog
    let activity: ActivityLog

    public init(workspace: Workspace, fileManager: FileManager = .default) {
        self.workspace = workspace
        self.fileManager = fileManager
        self.store = AccountStore(workspace: workspace, fileManager: fileManager)
        self.audit = AuditLog(workspace: workspace, fileManager: fileManager)
        self.activity = ActivityLog(workspace: workspace, fileManager: fileManager)
    }

    public func ping(_ id: String, timeout: TimeInterval = 90) throws -> ClaudePingRunner.Result {
        guard let account = try store.find(id) else { throw PingError.notFound(id) }
        guard account.status == .connected else { throw PingError.notConnected(account.status) }

        let home = ManagedHome(url: account.homeURL, provider: account.provider, fileManager: fileManager)
        let environment = ChildEnvironment.make(for: home)
        let binary = ChildEnvironment.binary(for: account.provider, environment: environment)

        audit.append(accountID: id, action: "ping.start", ok: true, detail: "tui")
        let result: ClaudePingRunner.Result
        switch account.provider {
        case .claude:
            result = ClaudePingRunner.run(
                binary: binary, environment: environment,
                workingDirectory: home.url, timeout: timeout)
        case .codex:
            result = CodexPingRunner.run(
                binary: binary, environment: environment,
                workingDirectory: home.url, timeout: timeout)
        }
        audit.append(accountID: id, action: "ping", ok: result.ok, detail: result.detail)

        // The Activity screen reads this: ✓/✗ + whether a window actually anchored
        // (for the `tui` ping, a dispatched turn == an anchored window). Save every
        // transcript (not just failures) so Monitoring can show what the agent
        // replied — and so a bad ping is still debuggable after the fact.
        let now = Date()
        let transcriptPath = activity.saveTranscript(result.transcript, accountID: id, at: now)
        activity.append(ActivityRecord(
            time: now, accountID: id, ok: result.ok, anchored: result.ok,
            detail: result.detail, transcriptPath: transcriptPath))
        return result
    }
}
