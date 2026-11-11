import Foundation

/// One-shot usage fetch with the same safeguards the menu bar uses: rate-limit
/// gate, single Keychain read, and delegated token refresh on expiry/401. Used
/// by `am usage`. `allowInteraction` defaults to `true` because the CLI is always
/// user-initiated (it may prompt once for Keychain / refresh the token). Pass a
/// `log` to record each HTTP exchange to the shared `NetworkLog` (token masked),
/// so CLI usage calls are auditable alongside the app's.
///
/// The delegated refresh is **window-gated** for background callers
/// (`ClaudeTokenRefresher.mayRefresh`): `/status` anchors a fresh 5h window when
/// none is live, so with `allowInteraction: false` it only runs while
/// `cachedReading` shows a live window — otherwise the fetch fails soft with
/// `.refreshDeferred` and the caller keeps its cached usage. Any future
/// background caller must pass the account's last cached reading to get
/// refreshes at all; omitting it means "never anchor".
///
/// A default-login account (`Account.tracksDefaultLogin`) goes through exactly
/// the same path against its own login: the credential is read from the
/// default item (`effectiveKeychainService` / `configHomeURL`), and the
/// delegated refresh runs `claude /status` with `CLAUDE_CONFIG_DIR` unset
/// (`ChildEnvironment.make(for:base:)`) under the same window gate.
public enum UsageService {
    public static func fetch(
        account: Account,
        gate: UsageRateLimitGate,
        allowInteraction: Bool = true,
        cachedReading: UsageReading? = nil,
        workspace: Workspace = .standard(),
        log: NetworkLog? = nil) async throws -> UsageReading
    {
        switch account.provider {
        case .codex:
            return try await CodexUsageFetcher.fetch(account: account, gate: gate, userInitiated: allowInteraction, log: log)

        case .claude:
            guard let service = account.effectiveKeychainService else { throw UsageFetchError.keychainReadFailed }
            var creds: ClaudeCredentials.Blob
            switch ClaudeCredentials.status(keychainService: service, allowInteraction: allowInteraction) {
            case let .valid(blob): creds = blob
            // A blanked login can't be refreshed — say so rather than spawn
            // `/status` (or report an unreadable store).
            case let .signedOut(reason):
                throw UsageFetchError.loginEnded(accountID: account.id, reason: reason).adapted(for: account)
            case nil: throw UsageFetchError.tokenDecodeFailed
            }
            let mayRefresh = ClaudeTokenRefresher.mayRefresh(
                userInitiated: allowInteraction, lastReading: cachedReading)
            if ClaudeCredentials.needsRefresh(creds) {
                // Expired token and no refresh allowed → don't fire the doomed
                // 401 poll either; fail soft and keep whatever the caller has.
                guard mayRefresh else { throw UsageFetchError.refreshDeferred }
                if let refreshed = refreshToken(account, workspace, allowInteraction) { creds = refreshed }
            }
            do {
                return try await ClaudeUsageFetcher.fetch(
                    account: account, accessToken: creds.accessToken, gate: gate, userInitiated: allowInteraction, log: log)
            } catch UsageFetchError.unauthorized {
                guard mayRefresh else { throw UsageFetchError.refreshDeferred }
                guard let refreshed = refreshToken(account, workspace, allowInteraction),
                      !ClaudeCredentials.needsRefresh(refreshed) else { throw UsageFetchError.unauthorized }
                return try await ClaudeUsageFetcher.fetch(
                    account: account, accessToken: refreshed.accessToken, gate: gate, userInitiated: allowInteraction, log: log)
            }
        }
    }

    /// Delegated refresh: ask the Claude CLI to refresh via `/status` (no usage
    /// turn), then re-read. NOTE: this blocks (drives a PTY) — fine for the CLI's
    /// one-shot use; the menu bar runs its own refresh off the main actor.
    private static func refreshToken(
        _ account: Account, _ workspace: Workspace, _ allowInteraction: Bool) -> ClaudeCredentials.Blob?
    {
        _ = ClaudeTokenRefresher.run(for: account, workspace: workspace)
        return account.effectiveKeychainService.flatMap {
            ClaudeCredentials.read(keychainService: $0, allowInteraction: allowInteraction)
        }
    }
}
