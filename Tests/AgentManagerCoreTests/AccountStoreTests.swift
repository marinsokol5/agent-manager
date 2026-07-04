import XCTest
@testable import AgentManagerCore

final class AccountStoreTests: XCTestCase {
    var tmp: URL!
    var file: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("am-store-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        file = tmp.appendingPathComponent("accounts.json")
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: tmp)
    }

    func store() -> AccountStore { AccountStore(fileURL: file) }

    func makeAccount(_ id: String, status: AccountStatus = .connecting) -> Account {
        Account(id: id, label: id.capitalized, provider: .claude, home: "/tmp/\(id)", status: status)
    }

    func testLoadEmptyWhenMissing() throws {
        XCTAssertEqual(try store().load().count, 0)
    }

    func testInsertRejectsDuplicates() throws {
        let s = store()
        try s.insert(makeAccount("work"))
        XCTAssertThrowsError(try s.insert(makeAccount("work"))) { error in
            XCTAssertEqual(error as? AccountStoreError, .duplicateID("work"))
        }
    }

    func testUpsertReplacesByIDAndPreservesOrder() throws {
        let s = store()
        try s.insert(makeAccount("a"))
        try s.insert(makeAccount("b"))

        var a = makeAccount("a")
        a.status = .connected
        a.identityEmail = "a@example.com"
        try s.upsert(a)

        let loaded = try s.load()
        XCTAssertEqual(loaded.map(\.id), ["a", "b"], "order preserved")
        XCTAssertEqual(loaded[0].status, .connected)
        XCTAssertEqual(loaded[0].identityEmail, "a@example.com")
    }

    func testRoundTripsThroughJSON() throws {
        let s = store()
        // Whole-second date: persistence is ISO-8601 (no sub-second precision),
        // which is fine for our use — pin the date so equality isn't coupled to it.
        var original = makeAccount("work", status: .connected)
        original.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        original.identityEmail = "work@example.com"
        try s.insert(original)
        let back = try store().find("work")
        XCTAssertEqual(back, original)
    }

    func testSourceHomeRoundTripsThroughJSON() throws {
        let s = store()
        var a = makeAccount("work", status: .connected)
        a.sourceHome = "/Users/me/.claude"
        try s.insert(a)
        XCTAssertEqual(try store().find("work")?.sourceHome, "/Users/me/.claude")
    }

    func testEffectiveSourceHomeFallsBackToProviderDefault() {
        let home = URL(fileURLWithPath: "/Users/test")
        // Legacy account (no sourceHome) → resolves to the provider default.
        let legacy = makeAccount("legacy")
        XCTAssertNil(legacy.sourceHome)
        XCTAssertEqual(legacy.effectiveSourceHome(homeDirectory: home), "/Users/test/.claude")
        // An explicit (custom) source home is returned as-is.
        var custom = legacy
        custom.sourceHome = "/work/.claude"
        XCTAssertEqual(custom.effectiveSourceHome(homeDirectory: home), "/work/.claude")
    }

    func testProvisionerRecordsResolvedSourceHome() throws {
        let ws = Workspace(root: tmp)
        let custom = tmp.appendingPathComponent("work-src", isDirectory: true)
        try fm.createDirectory(at: custom, withIntermediateDirectories: true)
        _ = try AccountProvisioner(workspace: ws).create(
            .init(id: "work", label: "Work", provider: .claude, sourceHome: custom))
        XCTAssertEqual(try AccountStore(workspace: ws).find("work")?.sourceHome, custom.path)
    }
}
