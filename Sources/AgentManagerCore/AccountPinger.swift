import Foundation

/// Delivers a tiny turn to a connected account, gated on `Connected` and
/// audited. Whether the turn actually anchored the rolling window is decided by
/// the caller's usage verification, never by this process result alone.
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
    let baseEnvironment: [String: String]

    public init(
        workspace: Workspace,
        fileManager: FileManager = .default,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment)
    {
        self.workspace = workspace
        self.fileManager = fileManager
        self.store = AccountStore(workspace: workspace, fileManager: fileManager)
        self.audit = AuditLog(workspace: workspace, fileManager: fileManager)
        self.activity = ActivityLog(workspace: workspace, fileManager: fileManager)
        self.baseEnvironment = baseEnvironment
    }

    public func ping(
        _ id: String,
        timeout: TimeInterval = 90,
        methodOverride: PingMethod? = nil)
        throws
        -> ClaudePingRunner.Result
    {
        let result = try runTurn(id, timeout: timeout, methodOverride: methodOverride)
        // A manual "test ping" does not read post-turn usage, so process
        // success cannot truthfully claim the rolling window moved. Record it
        // as unverified; the scheduled child uses `runTurn` + postflight and
        // records a verified anchor through `recordOutcome` itself.
        let detail = result.ok
            ? result.detail + " (anchor unverified — manual ping does not read usage)"
            : result.detail
        recordOutcome(id, result: result, anchored: false, detail: detail)
        return result
    }

    /// Run the gated, audited turn *without* writing the activity record.
    /// Callers that verify anchoring for real (the scheduled ping child, see
    /// `AnchorVerification`) decide `anchored` afterwards and record through
    /// `recordOutcome`.
    public func runTurn(
        _ id: String,
        timeout: TimeInterval = 90,
        methodOverride: PingMethod? = nil)
        throws
        -> ClaudePingRunner.Result
    {
        guard let account = try store.find(id) else { throw PingError.notFound(id) }
        guard account.status == .connected else { throw PingError.notConnected(account.status) }

        let home = ManagedHome(url: account.homeURL, provider: account.provider, fileManager: fileManager)
        var environment = ChildEnvironment.make(for: home, base: baseEnvironment)
        // A developer shell often exports direct-API keys. Letting those reach a
        // ping would test API billing instead of this managed subscription and,
        // for SDK/headless experiments, make the comparison meaningless.
        for key in account.provider.apiKeyEnvironmentKeys { environment.removeValue(forKey: key) }
        let binary = ChildEnvironment.binary(for: account.provider, environment: environment)
        let method = methodOverride
            ?? PreferencesStore(workspace: workspace, fileManager: fileManager).load()
                .pingMethod(for: account.provider)

        audit.append(accountID: id, action: "ping.start", ok: true, detail: method.rawValue)
        let rawResult: ClaudePingRunner.Result
        switch method {
        case .terminal:
            switch account.provider {
            case .claude:
                rawResult = ClaudePingRunner.run(
                    binary: binary, environment: environment,
                    workingDirectory: home.url, timeout: timeout)
            case .codex:
                rawResult = CodexPingRunner.run(
                    binary: binary, environment: environment,
                    workingDirectory: home.url, timeout: timeout)
            }
        case .headless:
            rawResult = HeadlessPingRunner.run(
                provider: account.provider,
                binary: binary,
                environment: environment,
                workingDirectory: home.url,
                timeout: timeout,
                fileManager: fileManager)
        case .sdk:
            rawResult = SDKPingRunner.run(
                provider: account.provider,
                binary: binary,
                environment: environment,
                workingDirectory: home.url,
                workspace: workspace,
                timeout: timeout,
                fileManager: fileManager)
        }
        let result = ClaudePingRunner.Result(
            ok: rawResult.ok,
            detail: rawResult.detail,
            transcript: rawResult.transcript,
            pingMethod: method)
        audit.append(accountID: id, action: "ping", ok: result.ok, detail: result.detail)
        return result
    }

    /// The Activity screen reads this: ✓/✗ + whether a window actually anchored.
    /// Save every transcript (not just failures) so Monitoring can show what the
    /// agent replied — and so a bad ping is still debuggable after the fact.
    public func recordOutcome(
        _ id: String,
        result: ClaudePingRunner.Result,
        anchored: Bool,
        detail: String? = nil)
    {
        let now = Date()
        let transcriptPath = activity.saveTranscript(result.transcript, accountID: id, at: now)
        activity.append(ActivityRecord(
            time: now, accountID: id, ok: result.ok, anchored: anchored,
            detail: detail ?? result.detail, transcriptPath: transcriptPath,
            pingMethod: result.pingMethod))
    }
}
