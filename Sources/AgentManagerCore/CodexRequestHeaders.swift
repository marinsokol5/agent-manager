#if canImport(Darwin)
import Darwin
#endif
import Foundation

/// Extracts the `chatgpt_account_id` the ChatGPT backend wants in the
/// `ChatGPT-Account-Id` header. It lives in the access-token JWT under the
/// `https://api.openai.com/auth` claim — NOT the usage body's `account_id`,
/// which is the (different) user id. Captured real request confirmed this.
public enum CodexAuth {
    public static func chatgptAccountId(accessToken: String) -> String? {
        let segments = accessToken.split(separator: ".")
        guard segments.count >= 2,
              let payload = base64URLDecode(String(segments[1])),
              let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return nil }
        if let auth = root["https://api.openai.com/auth"] as? [String: Any],
           let id = auth["chatgpt_account_id"] as? String, !id.isEmpty
        {
            return id
        }
        return nil
    }

    private static func base64URLDecode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b.append("=") }
        return Data(base64Encoded: b)
    }
}

/// Produces a `codex-tui/<version>` User-Agent mirroring the real Codex CLI
/// (captured from the wire). Detected once via `codex --version`, cached, off the
/// calling actor; falls back to a constant when the CLI isn't reachable.
public actor CodexUserAgent {
    public static let shared = CodexUserAgent()
    public static let fallbackVersion = "0.142.0"

    private var cached: String?

    public func value() async -> String {
        if let cached { return cached }
        let version = await Task.detached(priority: .utility) {
            Self.detectVersion() ?? Self.fallbackVersion
        }.value
        let ua = "codex-tui/\(version)"
        cached = ua
        return ua
    }

    private static func detectVersion(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        guard let path = ExecutableResolver.resolve("codex", environment: environment) else {
            return nil
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["--version"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        proc.standardInput = nil

        let done = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in done.signal() }
        do { try proc.run() } catch { return nil }
        if done.wait(timeout: .now() + 5) != .success {
            if proc.isRunning { proc.terminate() }
            return nil
        }
        guard proc.terminationStatus == 0,
              let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        else { return nil }
        // `codex --version` prints e.g. "codex-cli 0.142.0" — take the first token
        // that starts with a digit (the version), tolerating any product prefix.
        for token in text.split(whereSeparator: { $0.isWhitespace }) {
            if token.first?.isNumber == true { return String(token) }
        }
        return nil
    }
}
