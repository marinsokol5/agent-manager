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
/// unstable/untrusted identity meant a Keychain prompt every 5 minutes.
///
/// ## The fix (`.securityCLIWithFrameworkFallback`, current default)
/// Read the token by shelling out to **`/usr/bin/security find-generic-password`**
/// instead of the in-process Security.framework API. The "Always Allow" grant
/// then attaches to **Apple's `security` binary** — a stable, system code
/// identity that never changes — so the grant persists across our rebuilds,
/// re-signings, and releases, regardless of our own signing setup. (This is the
/// same approach CodexBar uses behind its "Avoid Keychain prompts" toggle.)
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
///   - Granting `security` access to the item is **broader** than an app-scoped
///     grant: any process that shells to `/usr/bin/security` can then read it.
///     Acceptable for a local menu-bar/dev tool (the Claude CLI already holds the
///     token), but it is a real difference from Security.framework's per-app ACL.
///   - Each read spawns a short-lived process (tens of ms) — negligible at the
///     5-minute cadence.
///   - Known edge: if the item's ACL is reset *after* we recorded the grant, the
///     next **background** CLI read can prompt once (the CLI can't be told to
///     fail silently). After that one prompt it either re-grants (Allow) or
///     self-heals to the no-UI fallback (Deny). This is rare and far better than
///     the every-5-minutes prompting it replaces.
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
/// — i.e. the user has clicked "Always Allow" for `security` on that item. This
/// lets background reads use the (silent) CLI path without risking a prompt
/// before the one-time grant exists. Persisted in `UserDefaults` so it survives
/// relaunches; cleared automatically when a previously-granted CLI read fails.
enum KeychainGrantStore {
    private static let key = "keychainSecurityCLIGrantedServices"

    static func isGranted(_ service: String, defaults: UserDefaults = .standard) -> Bool {
        granted(defaults).contains(service)
    }

    static func markGranted(_ service: String, defaults: UserDefaults = .standard) {
        var set = granted(defaults)
        guard set.insert(service).inserted else { return }
        defaults.set(Array(set), forKey: key)
    }

    static func clearGranted(_ service: String, defaults: UserDefaults = .standard) {
        var set = granted(defaults)
        guard set.remove(service) != nil else { return }
        defaults.set(Array(set), forKey: key)
    }

    private static func granted(_ defaults: UserDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }
}
