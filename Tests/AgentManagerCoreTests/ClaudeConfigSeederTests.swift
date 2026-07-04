import XCTest
@testable import AgentManagerCore

final class ClaudeConfigSeederTests: XCTestCase {
    var tmp: URL!
    var source: URL!
    var managed: URL!
    var home: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("am-seed-\(UUID().uuidString)", isDirectory: true)
        source = tmp.appendingPathComponent("source", isDirectory: true)
        managed = tmp.appendingPathComponent("managed", isDirectory: true)
        home = tmp.appendingPathComponent("home", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: managed, withIntermediateDirectories: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: tmp) }

    private func seededConfig() throws -> [String: Any] {
        let data = try Data(contentsOf: managed.appendingPathComponent(".claude.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testStripsIdentityMarksOnboardingTrustsManagedHome() throws {
        let src = #"""
        {"oauthAccount":{"emailAddress":"source@x.com"},"userID":"abc",
         "theme":"dark","hasCompletedOnboarding":false,"tipsHistory":{"a":1}}
        """#
        try src.data(using: .utf8)!.write(to: source.appendingPathComponent(".claude.json"))

        let didSeed = ClaudeConfigSeeder.seed(sourceHome: source, managedHome: managed)
        XCTAssertTrue(didSeed)

        let config = try seededConfig()
        XCTAssertNil(config["oauthAccount"], "identity must be stripped")
        XCTAssertNil(config["userID"], "anonymous id must be stripped")
        XCTAssertEqual(config["hasCompletedOnboarding"] as? Bool, true)
        XCTAssertEqual(config["theme"] as? String, "dark", "non-identity config carried over")

        let projects = try XCTUnwrap(config["projects"] as? [String: Any])
        // The managed home (login/ping cwd) is trusted — not $HOME, so real
        // project dirs still get their own trust prompt (claude-code#72547).
        let homeEntry = try XCTUnwrap(projects[managed.path] as? [String: Any])
        XCTAssertEqual(homeEntry["hasTrustDialogAccepted"] as? Bool, true)
        XCTAssertEqual(homeEntry["hasCompletedProjectOnboarding"] as? Bool, true)
        XCTAssertNil(projects[home.path], "$HOME must NOT be trusted")
    }

    func testWorksWithNoSourceConfig() throws {
        let didSeed = ClaudeConfigSeeder.seed(sourceHome: source, managedHome: managed)
        XCTAssertTrue(didSeed)
        let config = try seededConfig()
        XCTAssertEqual(config["hasCompletedOnboarding"] as? Bool, true)
        XCTAssertNotNil(config["projects"])
    }

    func testNeverClobbersExistingConfig() throws {
        let existing = #"{"oauthAccount":{"emailAddress":"real@x.com"}}"#
        try existing.data(using: .utf8)!.write(to: managed.appendingPathComponent(".claude.json"))

        let didSeed = ClaudeConfigSeeder.seed(sourceHome: source, managedHome: managed)
        XCTAssertFalse(didSeed, "must not overwrite a logged-in account's config")

        let config = try seededConfig()
        let oauth = try XCTUnwrap(config["oauthAccount"] as? [String: Any])
        XCTAssertEqual(oauth["emailAddress"] as? String, "real@x.com")
    }
}
