import XCTest
@testable import AgentManagerCore

final class SymlinkFarmTests: XCTestCase {
    var tmp: URL!
    var source: URL!
    var managed: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("am-symlink-\(UUID().uuidString)", isDirectory: true)
        source = tmp.appendingPathComponent("source-claude", isDirectory: true)
        managed = tmp.appendingPathComponent("managed", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        // A representative source home: a linkable dir, a linkable file, the
        // rewritten config file, and the identity file.
        try fm.createDirectory(at: source.appendingPathComponent("skills"), withIntermediateDirectories: true)
        try write("hello", to: source.appendingPathComponent("CLAUDE.md"))
        try write("{}", to: source.appendingPathComponent("settings.json"))
        try write("{\"oauthAccount\":{}}", to: source.appendingPathComponent(".claude.json"))
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: tmp)
    }

    func write(_ contents: String, to url: URL) throws {
        try contents.data(using: .utf8)!.write(to: url)
    }

    func isSymlink(_ url: URL) throws -> Bool {
        let attrs = try fm.attributesOfItem(atPath: url.path) // lstat — does not follow
        return (attrs[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    func farm() -> SymlinkFarm {
        SymlinkFarm(provider: .claude, sourceHome: source, managedHome: managed)
    }

    func testClassificationIsPure() {
        let f = farm()
        XCTAssertEqual(f.classify("skills"), .symlink)
        XCTAssertEqual(f.classify("CLAUDE.md"), .symlink)
        XCTAssertEqual(f.classify("settings.json"), .copy)
        XCTAssertEqual(f.classify(".claude.json"), .skipIdentity)
        XCTAssertEqual(f.classify("backups"), .skipLocal)
    }

    func testBackupsAreNotLinked() throws {
        // The source's backups/ holds .claude.json.backup (source identity); it
        // must never be linked into the new account.
        try fm.createDirectory(at: source.appendingPathComponent("backups"), withIntermediateDirectories: true)
        try write("source-identity", to: source.appendingPathComponent("backups/.claude.json.backup.123"))

        let report = try farm().apply()

        XCTAssertFalse(fm.fileExists(atPath: managed.appendingPathComponent("backups").path))
        XCTAssertEqual(report.items.first { $0.name == "backups" }?.result, .skippedLocal)
    }

    func testReconcileHealsAStaleBackupsLinkFromAnOlderRun() throws {
        // Simulate an account created before backups/ was skipped: a leftover
        // symlink into the source.
        try fm.createDirectory(at: managed, withIntermediateDirectories: true)
        try fm.createDirectory(at: source.appendingPathComponent("backups"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: managed.appendingPathComponent("backups"),
            withDestinationURL: source.appendingPathComponent("backups"))

        let report = try farm().apply()

        XCTAssertEqual(report.items.first { $0.name == "backups" }?.result, .removedStaleLink)
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: managed.appendingPathComponent("backups").path))
    }

    func testApplyLinksStaticCopiesRewrittenSkipsIdentity() throws {
        _ = try farm().apply()

        // Static dir + file are symlinks back to the source.
        XCTAssertTrue(try isSymlink(managed.appendingPathComponent("skills")))
        XCTAssertTrue(try isSymlink(managed.appendingPathComponent("CLAUDE.md")))
        XCTAssertEqual(
            try fm.destinationOfSymbolicLink(atPath: managed.appendingPathComponent("skills").path),
            source.appendingPathComponent("skills").path)

        // The rewritten config is a real copy, not a link (so edits don't bleed back).
        let settings = managed.appendingPathComponent("settings.json")
        XCTAssertTrue(fm.fileExists(atPath: settings.path))
        XCTAssertFalse(try isSymlink(settings))

        // The identity file is never created here (login writes it, per account).
        XCTAssertFalse(fm.fileExists(atPath: managed.appendingPathComponent(".claude.json").path))
    }

    func testReconcileAddsNewTopLevelEntryAndKeepsExisting() throws {
        _ = try farm().apply()

        // A new top-level entry appears in the source after the first run.
        try fm.createDirectory(at: source.appendingPathComponent("commands"), withIntermediateDirectories: true)
        let report = try farm().apply()

        XCTAssertTrue(try isSymlink(managed.appendingPathComponent("commands")))
        XCTAssertEqual(report.items.first { $0.name == "commands" }?.result, .linked)
        // Previously-linked entries are recognized as already present, not relinked.
        XCTAssertEqual(report.items.first { $0.name == "skills" }?.result, .alreadyPresent)
    }

    func testReconcileNeverClobbersAnAccountLocalRealDir() throws {
        // The CLI created `projects/` as a real, account-local dir inside the home…
        let localProjects = managed.appendingPathComponent("projects", isDirectory: true)
        try fm.createDirectory(at: localProjects, withIntermediateDirectories: true)
        try write("local", to: localProjects.appendingPathComponent("marker.txt"))
        // …and the source later grows a `projects/` of its own.
        try fm.createDirectory(at: source.appendingPathComponent("projects"), withIntermediateDirectories: true)

        let report = try farm().apply()

        // The real local dir is preserved (not replaced by a symlink).
        XCTAssertFalse(try isSymlink(localProjects))
        XCTAssertTrue(fm.fileExists(atPath: localProjects.appendingPathComponent("marker.txt").path))
        XCTAssertEqual(report.items.first { $0.name == "projects" }?.result, .alreadyPresent)
    }
}
