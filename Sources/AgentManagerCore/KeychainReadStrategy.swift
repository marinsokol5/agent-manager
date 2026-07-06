import Foundation

// MARK: - Feature flag

/// How we read the Claude OAuth credential out of the macOS Keychain.
///
/// ## Background — why this exists
/// The Claude CLI stores its OAuth token as a Keychain generic-password item
/// that *it* owns. When our app reads that item, macOS shows the "AgentManager
/// wants to use your confidential information" dialog and records the granted
/// app in the item's ACL. The ACL match is keyed to the *reading app's code
/// identity*:
///   - An ad-hoc / untrusted signature is matched by **cdhash**, which changes
///     on **every build** → re-prompt on every `make run`.
///   - A signature from a **trusted, stable** identity is matched by the
///     designated requirement (cert leaf), which survives rebuilds — but only if
///     the dev cert is installed *and trusted*. Anyone running the app without
///     that exact cert (other machines, future distribution) is back to a
///     re-prompt on every update.
/// We hit exactly this: the menu-bar timer reads the token every ~5 min, so an
/// unstable/untrusted identity meant a Keychain prompt every 5 minutes. (The
/// fossil ACL entries from that era — dead cdhashes pointing at `.build/debug`
/// binaries — are still visible in `security dump-keychain -a`.)
///
/// ## The fix (`.securityCLIWithFrameworkFallback`, current default)
/// Read the token by shelling out to **`/usr/bin/security find-generic-password`**
/// instead of the in-process Security.framework API. The "Always Allow" grant
/// then attaches to **Apple's `security` binary** — a stable, system code
/// identity that never changes — so the grant persists across our rebuilds,
/// re-signings, and releases, regardless of our own signing setup. (This is the
/// same approach CodexBar uses behind its "Avoid Keychain prompts" toggle.)
///
/// It later turned out this is also **exactly how the Claude CLI itself uses
/// the item**: `claude` creates the credential via the `security` tool, so the
/// item is born with partition ID `apple-tool:` and `/usr/bin/security` as the
/// one trusted app in its decrypt ACL (verified with `security dump-keychain -a`
/// on a default `Claude Code-credentials` item this app had never touched).
/// Two consequences:
///   - **Reads are normally silent from the very first one** — no prompt at
///     all, because the item's creator already trusted `security`. The one-time
///     "Always Allow" flow below only matters if the ACL was altered.
///   - **This path adds no attack surface.** Any local process could already
///     read the token by shelling to `security`; that exposure is a property of
///     how the Claude CLI stores the credential, not of our read strategy.
///
/// We pair it with two rules so it never nags:
///   1. **Background reads never prompt.** The CLI has no "fail-instead-of-prompt"
///      flag, so a background read only uses the CLI once we *know* `security` is
///      already granted (a per-service flag set after the first successful read);
///      otherwise it falls back to a no-UI Security.framework read and, failing
///      that, defers (keeps cached usage). Only an explicit "Refresh usage"
///      (user-initiated) read is ever allowed to surface the one-time `security`
///      prompt.
///   2. **Self-heal.** If a CLI read that we believed was granted starts failing
///      (e.g. the CLI recreated its item and reset the ACL), we clear the flag so
///      we stop using the CLI and fall back to the no-UI path.
///
/// ## Trade-offs
///   - A grant to `security` is process-agnostic rather than app-scoped — but
///     per the above, the Claude CLI's own item setup already concedes exactly
///     that, so an app-scoped read would not actually narrow who can reach the
///     token.
///   - Each read spawns a short-lived process (tens of ms) — negligible at the
///     5-minute cadence.
///   - Known edge: if the item's ACL is reset *after* we recorded the grant, the
///     next **background** CLI read can prompt once (the CLI can't be told to
///     fail silently). After that one prompt it either re-grants (Allow) or
///     self-heals to the no-UI fallback (Deny). This is rare and far better than
///     the every-5-minutes prompting it replaces.
///
/// ## Why not go back to Security.framework now that signing is stable?
/// The app now ships Developer-ID-signed (stable designated requirement), so an
/// app-scoped grant *would* survive rebuilds. It still loses on every axis:
///   - Prompts return: one per keychain item per reading binary — the app and
///     `am` are distinct code identities, and the headless scheduler daemon can
///     never show its own prompt. The CLI path is zero-prompt (see above).
///   - App grants reset on every `claude /login`: the CLI deletes and recreates
///     the item, wiping the ACL — while the recreated item trusts `security`
///     from birth again.
///   - The recorded app grant pins the signing cert leaf, so a Developer ID
///     renewal re-prompts; `security`'s stored requirement
///     (`identifier "com.apple.security" and anchor apple`) never expires.
///   - And it buys no security — the token stays readable via `security`
///     regardless of how *we* read it.
///
/// ## Reverting
/// Flip `KeychainReadStrategy.current` to `.securityFrameworkOnly` to go back to
/// the in-process Security.framework reader (no subprocess, app-scoped grant).
/// That path still does no-UI background reads / UI-on-user-action, but its grant
/// only persists while the app's signing identity is stable **and** trusted.
enum KeychainReadStrategy {
    /// Read via `/usr/bin/security`; fall back to Security.framework. Default.
    case securityCLIWithFrameworkFallback
    /// Read in-process via Security.framework only (legacy app-scoped grant).
    case securityFrameworkOnly

    /// The active strategy. Code-only flag (intentionally no UI toggle).
    static let current: KeychainReadStrategy = .securityCLIWithFrameworkFallback
}

// MARK: - Grant memory

/// Remembers, per Keychain service, that a `/usr/bin/security` read has succeeded
/// — i.e. the (usually pre-existing) grant for `security` on that item is known to
/// work. This lets background reads use the (silent) CLI path without risking a
/// prompt: the CLI has no fail-instead-of-prompt mode, so an *unverified*
/// background read could pop the dialog if the item's ACL had been altered.
///
/// Persisted as `keychain-grants.json` in the workspace — NOT `UserDefaults` —
/// because three different processes take background reads (the app's usage
/// timer, `am usage`, the scheduler daemon's cloud-fallback engine) and
/// `UserDefaults.standard` is a *per-process* domain for an unbundled binary
/// (`am.plist` vs the app's bundle-ID domain). With per-process flags, a daemon
/// whose user never ran `am usage` interactively would defer keychain reads
/// forever even though the app was long since verified. The workspace file is
/// the same shared-state channel every other cross-process flag uses. Flags
/// recorded by older builds in `UserDefaults` are migrated in on first load;
/// a flag is cleared automatically when its previously-verified CLI read fails.
struct KeychainGrantStore {
    /// On-disk shape of `keychain-grants.json` (service names only — no secrets).
    private struct Grants: Codable {
        var version: Int = 1
        var services: [String] = []
    }

    private static let legacyDefaultsKey = "keychainSecurityCLIGrantedServices"

    let fileURL: URL
    let legacyDefaults: UserDefaults

    init(
        fileURL: URL = Workspace.standard().keychainGrantsFile,
        legacyDefaults: UserDefaults = .standard)
    {
        self.fileURL = fileURL
        self.legacyDefaults = legacyDefaults
    }

    func isGranted(_ service: String) -> Bool {
        load().contains(service)
    }

    func markGranted(_ service: String) {
        var set = load()
        guard set.insert(service).inserted else { return }
        save(set)
    }

    func clearGranted(_ service: String) {
        var set = load()
        guard set.remove(service) != nil else { return }
        save(set)
    }

    // MARK: Persistence — atomic write, forgiving load, best-effort throughout
    // (losing this file never breaks a read; the flags just get re-verified by
    // the next user-initiated refresh).

    private func load() -> Set<String> {
        if let data = try? Data(contentsOf: fileURL),
           let grants = try? JSONDecoder().decode(Grants.self, from: data)
        {
            return Set(grants.services)
        }
        // No (readable) file yet: one-time migration of the flags older builds
        // kept in this process's UserDefaults domain, so upgrades stay silent.
        let legacy = Set(legacyDefaults.stringArray(forKey: Self.legacyDefaultsKey) ?? [])
        if !legacy.isEmpty {
            save(legacy)
            legacyDefaults.removeObject(forKey: Self.legacyDefaultsKey)
        }
        return legacy
    }

    private func save(_ services: Set<String>) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Grants(services: services.sorted())) else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic])
    }
}
