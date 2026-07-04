import XCTest
@testable import AgentManagerCore

/// The wake helper installer — plist rendering, root-gating, idempotence, and
/// drift detection — against a fake `launchctl` and temp directories (real
/// root ownership can't be applied in tests, so it's constructed off).
final class WakeHelperSetupTests: XCTestCase {
    var tmp: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("am-wakesetup-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: tmp) }

    func workspace(_ name: String = "ws") -> Workspace {
        Workspace(root: tmp.appendingPathComponent(name, isDirectory: true))
    }

    /// A stand-in helper binary (content is what install compares/copies).
    func makeSource(_ content: String = "helper-v1") throws -> URL {
        let url = tmp.appendingPathComponent("am-wake-helper")
        try Data(content.utf8).write(to: url)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func makeSetup(_ ws: Workspace, _ fake: SchedulerTests.FakeLaunchctl, source: URL) -> WakeHelperSetup {
        WakeHelperSetup(
            workspace: ws,
            launchd: .system(runner: fake.runner()),
            helperInstallDir: tmp.appendingPathComponent("PrivilegedHelperTools", isDirectory: true),
            daemonsDir: tmp.appendingPathComponent("LaunchDaemons", isDirectory: true),
            logsDir: tmp.appendingPathComponent("Logs", isDirectory: true),
            sourceBinary: source.path,
            fileManager: fm,
            applyRootOwnership: false)
    }

    func testInstallCopiesBinaryWritesPlistAndBootstraps() throws {
        let ws = workspace()
        let fake = SchedulerTests.FakeLaunchctl()
        let setup = makeSetup(ws, fake, source: try makeSource())

        let report = try setup.install(euid: 0)
        XCTAssertTrue(report.binaryUpdated)
        XCTAssertTrue(report.plistUpdated)
        XCTAssertTrue(report.loaded)

        XCTAssertEqual(try Data(contentsOf: setup.installedBinary), Data("helper-v1".utf8))
        let plist = try String(contentsOf: setup.installedPlist, encoding: .utf8)
        XCTAssertTrue(plist.contains("<string>\(WakeHelperSetup.label)</string>"))
        XCTAssertTrue(plist.contains("<string>--root</string>"))
        XCTAssertTrue(plist.contains("<string>\(ws.root.path)</string>"))
        XCTAssertTrue(plist.contains("<key>KeepAlive</key><true/>"))
        // Bootstrapped into the *system* domain — the whole point of the helper.
        XCTAssertTrue(fake.calls.contains { $0 == ["bootstrap", "system", setup.installedPlist.path] })
    }

    func testRepeatInstallIsQuietWhenNothingChanged() throws {
        let ws = workspace()
        let fake = SchedulerTests.FakeLaunchctl()
        let source = try makeSource()
        _ = try makeSetup(ws, fake, source: source).install(euid: 0)
        fake.loaded = [WakeHelperSetup.label]
        fake.calls = []

        let report = try makeSetup(ws, fake, source: source).install(euid: 0)
        XCTAssertFalse(report.binaryUpdated)
        XCTAssertFalse(report.plistUpdated)
        XCTAssertTrue(report.loaded)
        XCTAssertTrue(fake.calls.allSatisfy { $0.first == "list" },
                      "unexpected launchctl mutations: \(fake.calls)")
    }

    func testInstallRequiresRootAndASourceBinary() throws {
        let ws = workspace()
        let fake = SchedulerTests.FakeLaunchctl()
        XCTAssertThrowsError(try makeSetup(ws, fake, source: try makeSource()).install(euid: 501)) { error in
            XCTAssertEqual("\(error)", "must run as root — try: sudo am wake install")
        }
        let missing = tmp.appendingPathComponent("nope")
        XCTAssertThrowsError(try makeSetup(ws, fake, source: missing).install(euid: 0))
        // Nothing was half-installed by the failures.
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testUninstallRemovesArtifactsAndBootsOut() throws {
        let ws = workspace()
        let fake = SchedulerTests.FakeLaunchctl()
        let setup = makeSetup(ws, fake, source: try makeSource())
        _ = try setup.install(euid: 0)

        let report = try setup.uninstall(euid: 0)
        XCTAssertEqual(report.removed.count, 2)
        XCTAssertFalse(fm.fileExists(atPath: setup.installedBinary.path))
        XCTAssertFalse(fm.fileExists(atPath: setup.installedPlist.path))
        XCTAssertTrue(fake.calls.contains { $0 == ["bootout", "system/\(WakeHelperSetup.label)"] })
        XCTAssertThrowsError(try setup.uninstall(euid: 501))
    }

    func testStatusReportsDriftAndWorkspaceMismatch() throws {
        let ws = workspace()
        let fake = SchedulerTests.FakeLaunchctl()
        let source = try makeSource()
        let setup = makeSetup(ws, fake, source: source)
        _ = try setup.install(euid: 0)

        var status = setup.status()
        XCTAssertTrue(status.binaryInstalled)
        XCTAssertTrue(status.plistInstalled)
        XCTAssertTrue(status.rootMatches)
        XCTAssertFalse(status.needsUpdate)
        XCTAssertFalse(status.enabled)

        // A rebuilt helper differs from the installed copy → needsUpdate.
        try Data("helper-v2".utf8).write(to: source)
        status = setup.status()
        XCTAssertTrue(status.needsUpdate)

        // A different workspace asking sees the mismatch.
        let other = makeSetup(workspace("other"), fake, source: source)
        status = other.status()
        XCTAssertFalse(status.rootMatches)
        XCTAssertEqual(status.installedForRoot, ws.root.path)

        // The opt-in flag flows through from wake.json.
        try WakeConfigStore(workspace: ws).save(WakeConfig(enabled: true))
        XCTAssertTrue(setup.status().enabled)
    }

    func testParseRootArgumentRoundTripsEscapedPaths() {
        let nasty = tmp.appendingPathComponent("A & B <C>", isDirectory: true)
        let ws = Workspace(root: nasty)
        let setup = WakeHelperSetup(workspace: ws, sourceBinary: "/dev/null", fileManager: fm, applyRootOwnership: false)
        let plist = setup.renderPlist()
        XCTAssertFalse(plist.contains("A & B <C>")) // must be escaped in the XML…
        XCTAssertEqual(WakeHelperSetup.parseRootArgument(inPlist: plist), nasty.path) // …and parse back exactly
    }

    func testWakeConfigStoreRoundTripAndForgivingLoad() throws {
        let ws = workspace()
        let store = WakeConfigStore(workspace: ws)
        XCTAssertFalse(store.load().enabled) // missing file → disabled

        try store.save(WakeConfig(enabled: true))
        XCTAssertTrue(store.load().enabled)

        try Data("garbage".utf8).write(to: ws.wakeConfigFile)
        XCTAssertFalse(store.load().enabled) // corrupt → disabled, never throws
    }

    /// The `launchctl print` classifier behind "is the daemon *process*
    /// alive" — the registration can read enabled while every spawn fails.
    func testClassifyProcessState() {
        let running = """
        system/com.agent-manager.wake-helper = {
        \tactive count = 1
        \tstate = running
        \tpid = 4242
        \tprogram identifier = Contents/MacOS/am-wake-helper (mode: 2)
        }
        """
        XCTAssertEqual(
            WakeHelperSetup.classifyProcessState(output: running, ok: true),
            .running(pid: 4242))

        // The real shape observed after dev re-signing broke the BTM binding.
        let failing = """
        system/com.agent-manager.wake-helper = {
        \tactive count = 0
        \tstate = spawn scheduled
        \truns = 4237
        \tlast exit code = 78: EX_CONFIG
        \tjob state = spawn failed
        }
        """
        XCTAssertEqual(
            WakeHelperSetup.classifyProcessState(output: failing, ok: true),
            .spawnFailed(detail: "last exit code = 78: EX_CONFIG"))

        // A running job may carry a historical exit code — that's not failure.
        let restarted = running.replacingOccurrences(
            of: "\tpid = 4242", with: "\tpid = 4242\n\tlast exit code = 0")
        XCTAssertEqual(
            WakeHelperSetup.classifyProcessState(output: restarted, ok: true),
            .running(pid: 4242))

        XCTAssertEqual(
            WakeHelperSetup.classifyProcessState(
                output: "Could not find service \u{201C}com.agent-manager.wake-helper\u{201D} in domain for system", ok: false),
            .notLoaded)

        // Loaded, no pid yet, no failure marker: a spawn in flight.
        let scheduled = "system/com.agent-manager.wake-helper = {\n\tstate = spawn scheduled\n}"
        XCTAssertEqual(
            WakeHelperSetup.classifyProcessState(output: scheduled, ok: true),
            .starting)
    }
}
