import XCTest
import WakeHelperCore

/// The wake helper's exit-for-relaunch decision: restart only on a *settled*
/// changed binary, never on a missing or still-warm one.
final class BinaryStampTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let fm = FileManager.default
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("am-stamp-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: tmp) }

    func stamp(mtimeOffset: TimeInterval, size: Int = 100) -> BinaryStamp {
        BinaryStamp(mtime: t0.addingTimeInterval(mtimeOffset), size: size)
    }

    func testReadReflectsTheFileAndNilForMissing() throws {
        let file = tmp.appendingPathComponent("am-wake-helper")
        try Data("binary".utf8).write(to: file)
        try fm.setAttributes([.modificationDate: t0], ofItemAtPath: file.path)

        let read = BinaryStamp.read(path: file.path)
        XCTAssertEqual(read?.size, 6)
        XCTAssertEqual(read?.mtime.timeIntervalSince1970 ?? 0, t0.timeIntervalSince1970, accuracy: 1)
        XCTAssertNil(BinaryStamp.read(path: tmp.appendingPathComponent("missing").path))
    }

    func testRestartDueOnlyForSettledChange() {
        let launch = stamp(mtimeOffset: -3600)

        // Unchanged binary: never due.
        XCTAssertFalse(BinaryStamp.restartDue(sinceLaunch: launch, current: launch, now: t0))
        // Missing binary (mid-reassembly of the bundle): wait, don't restart.
        XCTAssertFalse(BinaryStamp.restartDue(sinceLaunch: launch, current: nil, now: t0))
        // Changed but still warm from the build: wait for it to settle.
        XCTAssertFalse(BinaryStamp.restartDue(sinceLaunch: launch, current: stamp(mtimeOffset: -5, size: 200), now: t0))
        // Changed and settled: due.
        XCTAssertTrue(BinaryStamp.restartDue(sinceLaunch: launch, current: stamp(mtimeOffset: -60, size: 200), now: t0))
        // A same-size rebuild still counts — the mtime alone is the change.
        XCTAssertTrue(BinaryStamp.restartDue(sinceLaunch: launch, current: stamp(mtimeOffset: -60), now: t0))
    }

    func testUnreadableLaunchStampStillConvergesByRestarting() {
        // If the helper couldn't stat itself at launch (transient), one
        // restart re-reads a real stamp and the loop settles.
        XCTAssertTrue(BinaryStamp.restartDue(sinceLaunch: nil, current: stamp(mtimeOffset: -60), now: t0))
    }
}
