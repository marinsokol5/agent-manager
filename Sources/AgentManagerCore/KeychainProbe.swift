import CryptoKit
#if canImport(Darwin)
import Darwin
#endif
import Foundation
import Security

/// Read-only probe of macOS Keychain generic-password **service names**.
///
/// Each Claude config-dir gets its own suffixed item:
/// `"Claude Code-credentials-<first8hexOfSHA256(path)>"`.
/// The derivation is confirmed reverse-engineered (SHA-256 of the path string,
/// lowercase hex, first 8 chars). We still snapshot-diff at login so the stored
/// `keychainService` is verified by observation, but derivation is used as a
/// reliable fallback for existing accounts that pre-date the field.
///
/// We request attributes only (`kSecReturnData: false`) in the scan, so that
/// path never triggers a keychain unlock/allow prompt.

public enum KeychainProbe {
    /// Service names of generic-password items whose service begins with `prefix`.
    public static func genericPasswordServices(prefix: String) -> Set<String> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: false,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return [] }

        var services = Set<String>()
        for item in items {
            if let service = item[kSecAttrService as String] as? String, service.hasPrefix(prefix) {
                services.insert(service)
            }
        }
        return services
    }

    /// Derives the Keychain service name Claude CLI uses for a given config-dir:
    /// `"Claude Code-credentials-<first 8 hex chars of SHA-256(path)>"`.
    ///
    /// Reverse-engineered derivation confirmed at:
    /// https://github.com/dody87/ccam/blob/bc0d0fc567e9c5499697c7909516f22674db50b9/lib/common.sh#L43
    /// If Anthropic ever changes the hash algorithm, this breaks for new accounts
    /// — but the baseline-diff in `IdentityVerifier` still works as a fallback,
    /// and existing accounts retain their stored `keychainService` in accounts.json.
    public static func claudeKeychainService(for configDir: URL) -> String {
        let digest = SHA256.hash(data: Data(configDir.path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-\(hex.prefix(8))"
    }

    /// Read the raw credential data blob for a specific generic-password item by
    /// service name. Returns `nil` if the item is absent or access isn't granted.
    ///
    /// `allowInteraction` defaults to `false`: a background read that isn't
    /// already authorized fails silently rather than popping the macOS "allow
    /// access" dialog (see `KeychainNoUIQuery`). Pass `true` only for an explicit
    /// user action (the "Refresh usage" button), which may prompt once so the
    /// user can click "Always Allow".
    public static func readGenericPasswordData(service: String, allowInteraction: Bool = false) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        #if os(macOS)
        if !allowInteraction { KeychainNoUIQuery.apply(to: &query) }
        #endif
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    /// Read the same generic-password data by shelling out to
    /// `/usr/bin/security find-generic-password -s <service> -w`.
    ///
    /// The point is *whose* code identity the Keychain "Always Allow" grant binds
    /// to: reading this way binds it to Apple's stable `security` binary instead
    /// of our app's (build-varying) signature, so the grant survives rebuilds and
    /// updates. See `KeychainReadStrategy` for the full rationale. Returns `nil`
    /// on non-zero exit, timeout, or if access is denied. NOTE: the CLI has no
    /// "fail-instead-of-prompt" mode, so this *can* show the system prompt if
    /// `security` isn't yet in the item's ACL — callers gate when they invoke it.
    public static func readGenericPasswordDataViaSecurityCLI(
        service: String,
        account: String? = nil,
        timeout: TimeInterval = 5) -> Data?
    {
        let securityPath = "/usr/bin/security"
        guard FileManager.default.isExecutableFile(atPath: securityPath) else { return nil }

        var arguments = ["find-generic-password", "-s", service]
        if let account, !account.isEmpty { arguments.append(contentsOf: ["-a", account]) }
        arguments.append("-w") // print only the password (the JSON blob) to stdout

        let process = Process()
        process.executableURL = URL(fileURLWithPath: securityPath)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        process.standardInput = nil

        do { try process.run() } catch { return nil }

        // Own the child's process group so a timeout kill takes the whole tree.
        let pid = process.processIdentifier
        var processGroup: pid_t?
        #if canImport(Darwin)
        if setpgid(pid, pid) == 0 { processGroup = pid }
        #endif

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            #if canImport(Darwin)
            if let processGroup { kill(-processGroup, SIGKILL) }
            #endif
            return nil
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else { return nil }

        // `-w` appends a trailing newline; strip CR/LF.
        var sanitized = data
        while let last = sanitized.last, last == 0x0A || last == 0x0D { sanitized.removeLast() }
        return sanitized.isEmpty ? nil : sanitized
    }
}
