import XCTest
@testable import AgentManagerCore

final class CodexTests: XCTestCase {
    let fm = FileManager.default

    // MARK: Provider facts

    func testCodexProviderFacts() {
        XCTAssertEqual(Provider.codex.configHomeEnvKey, "CODEX_HOME")
        XCTAssertEqual(Provider.codex.cliBinaryName, "codex")
        XCTAssertEqual(Provider.codex.identityFileName, "auth.json")
        XCTAssertEqual(Provider.codex.loginArguments, ["login"])
        XCTAssertNil(Provider.codex.keychainServicePrefix, "Codex is file-based, no keychain")
        XCTAssertTrue(Provider.allCases.contains(.codex))
    }

    // MARK: Symlink classification (auth.json = identity, config.toml = copy)

    func testCodexSymlinkClassification() {
        let farm = SymlinkFarm(
            provider: .codex,
            sourceHome: URL(fileURLWithPath: "/src"),
            managedHome: URL(fileURLWithPath: "/dst"))
        XCTAssertEqual(farm.classify("auth.json"), .skipIdentity)
        XCTAssertEqual(farm.classify("config.toml"), .copy)
        XCTAssertEqual(farm.classify("sessions"), .symlink)
    }

    // MARK: Identity verification

    func testVerifyCodexConnectedWhenTokensPresent() throws {
        let home = try makeCodexHome(authJSON: #"{"OPENAI_API_KEY":null,"tokens":{"access_token":"tok"}}"#)
        let result = IdentityVerifier.verify(provider: .codex, home: home, keychainBaseline: nil)
        XCTAssertTrue(result.connected)
    }

    func testVerifyCodexDisconnectedWhenAuthMissing() throws {
        let home = try makeCodexHome(authJSON: nil)
        let result = IdentityVerifier.verify(provider: .codex, home: home, keychainBaseline: nil)
        XCTAssertFalse(result.connected)
    }

    func testVerifyCodexExtractsEmailFromIDToken() throws {
        let idToken = makeJWT(payload: #"{"email":"codex@example.com"}"#)
        let home = try makeCodexHome(authJSON: #"{"tokens":{"access_token":"tok","id_token":"\#(idToken)"}}"#)
        let result = IdentityVerifier.verify(provider: .codex, home: home, keychainBaseline: nil)
        XCTAssertTrue(result.connected)
        XCTAssertEqual(result.identityEmail, "codex@example.com")
    }

    func testEmailFromJWTReturnsNilForGarbage() {
        XCTAssertNil(IdentityVerifier.emailFromJWT("not-a-jwt"))
    }

    // MARK: Ping turn-detection (interrupt count vs. mere presence)

    /// The boot indicator must be counted so it can form the pre-submit baseline.
    func testInterruptCountSeesBootIndicator() {
        let boot = "• Booting MCP server: codex_apps (0s • esc to interrupt)"
        XCTAssertEqual(CodexTurnSignal.interruptCount(in: boot), 1)
        XCTAssertEqual(CodexTurnSignal.interruptCount(in: ""), 0)
        XCTAssertEqual(CodexTurnSignal.interruptCount(in: "no indicator here"), 0)
        // The spinner repaints the indicator on each tick; every repaint counts.
        XCTAssertEqual(CodexTurnSignal.interruptCount(in: boot + "\n" + boot), 2)
    }

    /// Regression for the false-success bug: a transcript whose *only* `esc to
    /// interrupt` is the MCP boot line (prompt typed but never submitted) must not
    /// read as a started turn. The runner baselines the count at submit time, so a
    /// turn requires the count to climb *past* that baseline — which boot-only
    /// output never does.
    func testBootOnlyTranscriptDoesNotLookLikeAStartedTurn() {
        // Mirrors the captured transcript: launch box + banners + a single boot
        // indicator, with the prompt sitting unsubmitted in the composer.
        let bootOnly = """
        OpenAI Codex (v0.142.2)
        model: gpt-5.4-mini   directory: ~/.../homes/codex-work
        You have 3 usage limit resets available. Run /usage to use one.
        • Booting MCP server: codex_apps (0s • esc to interrupt)
        › Good morning Codex
        """
        let baselineAtSubmit = CodexTurnSignal.interruptCount(in: bootOnly)
        // No new generation arrives after submit → count never climbs past baseline.
        let afterSubmit = CodexTurnSignal.interruptCount(in: bootOnly)
        XCTAssertFalse(afterSubmit > baselineAtSubmit, "boot-only output must not register as a turn")
    }

    /// A real turn repaints `esc to interrupt` as the model streams, pushing the
    /// count above the pre-submit baseline.
    func testStreamingReplyClimbsPastBaseline() {
        let beforeSubmit = "• Booting MCP server: codex_apps (0s • esc to interrupt)"
        let baseline = CodexTurnSignal.interruptCount(in: beforeSubmit)
        let afterSubmit = beforeSubmit + """

        › Good morning Codex
        Working (1s • esc to interrupt)
        Working (2s • esc to interrupt)
        Good morning! How can I help?
        """
        XCTAssertTrue(CodexTurnSignal.interruptCount(in: afterSubmit) > baseline)
    }

    // MARK: helpers

    private func makeCodexHome(authJSON: String?) throws -> ManagedHome {
        let dir = fm.temporaryDirectory.appendingPathComponent("am-codex-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if let authJSON {
            try authJSON.data(using: .utf8)!.write(to: dir.appendingPathComponent("auth.json"))
        }
        return ManagedHome(url: dir, provider: .codex)
    }

    private func makeJWT(payload: String) -> String {
        func b64url(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(b64url(#"{"alg":"none"}"#)).\(b64url(payload)).sig"
    }
}
