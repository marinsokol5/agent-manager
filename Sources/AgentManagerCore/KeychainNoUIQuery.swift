import Foundation

#if os(macOS)
import Darwin
import LocalAuthentication
import Security

/// Turns a `SecItemCopyMatching` query into a *no-UI* read: if the calling app
/// isn't already authorized for the item, the read fails silently instead of
/// popping the macOS "allow access" dialog. We apply this to every background /
/// timer read so idle polling never prompts — only an explicit user action does.
enum KeychainNoUIQuery {
    private static let uiFailPolicy = KeychainNoUIQuery.resolveUIFailPolicy()

    static func apply(to query: inout [String: Any]) {
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context

        // Keep explicit UI-fail policy for legacy keychain behavior on macOS where
        // `interactionNotAllowed` alone can still surface Allow/Deny prompts.
        query[kSecUseAuthenticationUI as String] = self.uiFailPolicy as CFString
    }

    private static func resolveUIFailPolicy() -> String {
        // Resolve the Security symbol at runtime to preserve the true constant
        // value without referencing the deprecated API at compile time.
        let securityPath = "/System/Library/Frameworks/Security.framework/Security"
        guard let handle = dlopen(securityPath, RTLD_NOW) else { return "u_AuthUIF" }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "kSecUseAuthenticationUIFail") else { return "u_AuthUIF" }
        let valuePointer = symbol.assumingMemoryBound(to: CFString?.self)
        return (valuePointer.pointee as String?) ?? "u_AuthUIF"
    }
}
#endif
