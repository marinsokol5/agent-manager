import XCTest
@testable import AgentManagerCore

/// Guards `Provider.sandboxOptOutArguments` — the session-scoped `--settings`
/// override that keeps the CLI's Seatbelt-sandbox init from sweeping
/// TCC-protected folders under our name during automated sessions.
final class SandboxOptOutTests: XCTestCase {
    /// The claude override must be a `--settings` flag whose value is valid JSON
    /// that actually disables the sandbox — a typo here silently reverts every
    /// scheduled ping to whatever the user's shared settings.json says.
    func testClaudeOptOutDisablesSandboxViaSettingsFlag() throws {
        let args = Provider.claude.sandboxOptOutArguments
        XCTAssertEqual(args.count, 2)
        XCTAssertEqual(args.first, "--settings")

        struct Settings: Decodable {
            struct Sandbox: Decodable { let enabled: Bool }
            let sandbox: Sandbox
        }
        let payload = try XCTUnwrap(args.last?.data(using: .utf8))
        let decoded = try JSONDecoder().decode(Settings.self, from: payload)
        XCTAssertFalse(decoded.sandbox.enabled)
    }

    /// Codex deliberately gets no override: its sandbox is integral to its exec
    /// model, and no TCC sweep has been observed from Codex pings.
    func testCodexHasNoOptOut() {
        XCTAssertEqual(Provider.codex.sandboxOptOutArguments, [])
    }
}
