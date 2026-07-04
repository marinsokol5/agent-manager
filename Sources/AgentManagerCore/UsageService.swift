import Foundation

/// One-shot usage fetch with the same safeguards the menu bar uses: rate-limit
/// gate, single Keychain read, and delegated token refresh on expiry/401. Used
/// by `am usage`. `allowInteraction` defaults to `true` because the CLI is always
/// user-initiated (it may prompt once for Keychain / refresh the token). Pass a
/// `log` to record each HTTP exchange to the shared `NetworkLog` (token masked),
/// so CLI usage calls are auditable alongside the app's.
public enum UsageService {
    public static func fetch(
        account: Account,
        gate: UsageRateLimitGate,
        allowInteraction: Bool = true,
        log: NetworkLog? = nil) async throws -> UsageReading
    {
        switch account.provider {
        case .codex:
            return try await CodexUsageFetcher.fetch(account: account, gate: gate, userInitiated: allowInteraction, log: log)

        case .claude:
            guard let service = account.keychainService else { throw UsageFetchError.keychainReadFailed }
            guard var creds = ClaudeCredentials.read(keychainService: service, allowInteraction: allowInteraction) else {
                throw UsageFetchError.tokenDecodeFailed
            }
            if ClaudeCredentials.needsRefresh(creds), let refreshed = refreshToken(account, allowInteraction) {
                creds = refreshed
            }
            do {
                return try await ClaudeUsageFetcher.fetch(
                    account: account, accessToken: creds.accessToken, gate: gate, userInitiated: allowInteraction, log: log)
            } catch UsageFetchError.unauthorized {
                guard let refreshed = refreshToken(account, allowInteraction),
                      !ClaudeCredentials.needsRefresh(refreshed) else { throw UsageFetchError.unauthorized }
                return try await ClaudeUsageFetcher.fetch(
                    account: account, accessToken: refreshed.accessToken, gate: gate, userInitiated: allowInteraction, log: log)
            }
        }
    }

    /// Delegated refresh: ask the Claude CLI to refresh via `/status` (no usage
    /// turn), then re-read. NOTE: this blocks (drives a PTY) — fine for the CLI's
    /// one-shot use; the menu bar runs its own refresh off the main actor.
    private static func refreshToken(_ account: Account, _ allowInteraction: Bool) -> ClaudeCredentials.Blob? {
        let home = ManagedHome(url: account.homeURL, provider: account.provider)
        let env = ChildEnvironment.make(for: home)
        let binary = ChildEnvironment.binary(for: account.provider, environment: env)
        _ = ClaudeTokenRefresher.run(binary: binary, environment: env)
        return account.keychainService.flatMap {
            ClaudeCredentials.read(keychainService: $0, allowInteraction: allowInteraction)
        }
    }
}
