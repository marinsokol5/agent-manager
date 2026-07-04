import XCTest
@testable import AgentManagerCore

/// Locks in the "never tokens" invariant for `NetworkLog`: credential-bearing
/// headers must be redacted (on request *and* response), while ordinary headers
/// pass through so the log stays useful for debugging.
final class NetworkLogTests: XCTestCase {
    func testAuthorizationKeepsSchemeButMasksToken() {
        let out = NetworkLog.redactForTesting(["Authorization": "Bearer sk-ant-oat01-secret"])
        XCTAssertEqual(out["Authorization"], "Bearer ••••••")
        XCTAssertFalse(out["Authorization", default: ""].contains("secret"))
    }

    func testCookieAndSetCookieAreFullyMasked() {
        let out = NetworkLog.redactForTesting([
            "Cookie": "session=abc123; other=def",
            "Set-Cookie": "session=abc123; HttpOnly",
        ])
        XCTAssertEqual(out["Cookie"], "••••••")
        XCTAssertEqual(out["Set-Cookie"], "••••••")
    }

    func testApiKeyHeadersAreMasked() {
        let out = NetworkLog.redactForTesting([
            "x-api-key": "sk-secret",
            "anthropic-api-key": "sk-secret",
        ])
        XCTAssertEqual(out["x-api-key"], "••••••")
        XCTAssertEqual(out["anthropic-api-key"], "••••••")
    }

    func testRedactionIsCaseInsensitive() {
        let out = NetworkLog.redactForTesting(["AUTHORIZATION": "Bearer secret", "SET-COOKIE": "x=y"])
        XCTAssertEqual(out["AUTHORIZATION"], "Bearer ••••••")
        XCTAssertEqual(out["SET-COOKIE"], "••••••")
    }

    func testNonSensitiveHeadersPassThrough() {
        let headers = [
            "User-Agent": "claude-cli/1.2.3",
            "anthropic-beta": "oauth-2025-04-20",
            "Content-Type": "application/json",
        ]
        XCTAssertEqual(NetworkLog.redactForTesting(headers), headers)
    }
}
