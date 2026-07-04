import Foundation

/// Confirms a managed home is genuinely logged in as an account.
///
/// Authoritative signal: the `oauthAccount` record in `<home>/.claude.json`
/// (Claude's identity boundary — email / accountUuid / orgUuid, no token).
/// Confirming signal: the per-config-dir Keychain item exists (Claude) or
/// `auth.json` has credentials (Codex). The keychain check is confidence, not
/// a gate — `oauthAccount` presence is the requirement.
public enum IdentityVerifier {
    public struct Result: Sendable {
        public let connected: Bool
        public let oauthAccountPresent: Bool
        public let keychainItemPresent: Bool
        public let identityEmail: String?
        public let detail: String
    }

    public static func verify(
        provider: Provider,
        home: ManagedHome,
        keychainBaseline: Set<String>?)
        -> Result
    {
        switch provider {
        case .claude:
            return verifyClaude(home: home, keychainBaseline: keychainBaseline)
        case .codex:
            return verifyCodex(home: home)
        }
    }

    private static func verifyCodex(home: ManagedHome) -> Result {
        guard let data = try? Data(contentsOf: home.identityFileURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return Result(
                connected: false, oauthAccountPresent: false, keychainItemPresent: false,
                identityEmail: nil, detail: "auth.json: absent or unreadable")
        }

        let tokens = root["tokens"] as? [String: Any]
        let hasCredentials = (tokens?["access_token"] as? String)?.isEmpty == false
            || (root["OPENAI_API_KEY"] as? String)?.isEmpty == false
        let email = (tokens?["id_token"] as? String).flatMap(emailFromJWT)

        return Result(
            connected: hasCredentials,
            oauthAccountPresent: hasCredentials,
            keychainItemPresent: false,
            identityEmail: email,
            detail: hasCredentials ? "auth.json: \(email ?? "credentials present")" : "auth.json: no credentials")
    }

    /// Best-effort `email` claim from a JWT payload (the middle, base64url segment).
    static func emailFromJWT(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64.append("=") }
        guard let data = Data(base64Encoded: b64),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let email = claims["email"] as? String { return email }
        if let auth = claims["https://api.openai.com/auth"] as? [String: Any],
           let email = auth["email"] as? String { return email }
        return nil
    }

    private static func verifyClaude(home: ManagedHome, keychainBaseline: Set<String>?) -> Result {
        let (oauthPresent, email) = readOAuthAccount(at: home.identityFileURL)

        var keychainPresent = false
        var keychainNote = "keychain: not checked"
        if let prefix = home.provider.keychainServicePrefix {
            let derived = KeychainProbe.claudeKeychainService(for: home.url)
            let current = KeychainProbe.genericPasswordServices(prefix: prefix)
            keychainPresent = current.contains(derived)
            if let baseline = keychainBaseline {
                let appeared = current.subtracting(baseline)
                keychainNote = !appeared.isEmpty
                    ? "keychain: new item \(appeared.sorted().joined(separator: ","))"
                    : "keychain: no new item since baseline"
            } else {
                keychainNote = keychainPresent ? "keychain: \(derived)" : "keychain: none present"
            }
        }

        let detail = "oauthAccount: \(oauthPresent ? (email ?? "present") : "absent"); \(keychainNote)"
        return Result(
            connected: oauthPresent,
            oauthAccountPresent: oauthPresent,
            keychainItemPresent: keychainPresent,
            identityEmail: email,
            detail: detail)
    }

    static func readOAuthAccount(at url: URL) -> (present: Bool, email: String?) {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["oauthAccount"] as? [String: Any]
        else {
            return (false, nil)
        }
        return (true, oauth["emailAddress"] as? String)
    }

    /// The account's claude.ai org UUID from the same `oauthAccount` record —
    /// required as `x-organization-uuid` on every routines-API call (see
    /// `TriggerClient`). Read from disk on demand: the login rewrites
    /// `.claude.json`, so caching a copy elsewhere would just be a second
    /// source of truth to keep honest.
    public static func readOrganizationUuid(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["oauthAccount"] as? [String: Any],
              let org = oauth["organizationUuid"] as? String, !org.isEmpty
        else { return nil }
        return org
    }
}
