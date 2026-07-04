import XCTest
@testable import AgentManagerCore

final class PowerStateTests: XCTestCase {

    // MARK: - pmset -g assertions parsing (real-format fixtures)

    /// A human at the machine: powerd reports both flags set. The per-pid
    /// breakdown lines (which also contain the key words) must not be mistaken for
    /// the summary row.
    private let activeAssertions = """
       UserIsActive                   1
       PreventUserIdleDisplaySleep    1
       PreventUserIdleSystemSleep     1
       pid 391(WindowServer): [0x000ab79c0009a3bd] 00:00:01 UserIsActive named: "tickle"
       pid 327(powerd): [0x000ab8fd0001a492] 00:42:34 PreventUserIdleSystemSleep named: "display on"
    """

    /// Unattended / dark wake: display and user flags clear (a background
    /// `PreventUserIdleSystemSleep` may still be held — irrelevant to presence).
    private let idleAssertions = """
       UserIsActive                   0
       PreventUserIdleDisplaySleep    0
       PreventUserIdleSystemSleep     1
    """

    func testParsesUserActiveAndDisplayFlags() {
        XCTAssertTrue(PowerStateParser.userActive(inAssertions: activeAssertions))
        XCTAssertTrue(PowerStateParser.displayAwake(inAssertions: activeAssertions))

        XCTAssertFalse(PowerStateParser.userActive(inAssertions: idleAssertions))
        XCTAssertFalse(PowerStateParser.displayAwake(inAssertions: idleAssertions))
    }

    func testPerPidLinesDoNotForgePresence() {
        // Only the per-pid breakdown mentions the keys; the summary is absent →
        // both flags read false (the summary row is the sole source of truth).
        let perPidOnly = """
           pid 391(WindowServer): [0x0] 00:00:01 UserIsActive named: "tickle"
           pid 327(powerd): [0x0] 00:42:34 PreventUserIdleDisplaySleep named: "x"
        """
        XCTAssertFalse(PowerStateParser.userActive(inAssertions: perPidOnly))
        XCTAssertFalse(PowerStateParser.displayAwake(inAssertions: perPidOnly))
    }

    // MARK: - ioreg HIDIdleTime parsing

    func testParsesIdleSecondsFromIOReg() {
        let ioreg = #"    | | |   "HIDIdleTime" = 174782375"#
        let seconds = PowerStateParser.idleSeconds(inIOReg: ioreg)
        XCTAssertNotNil(seconds)
        XCTAssertEqual(seconds!, 0.174782375, accuracy: 1e-9)

        // An hours-long sleep reads as a large idle time.
        XCTAssertEqual(PowerStateParser.idleSeconds(inIOReg: #""HIDIdleTime" = 3600000000000"#)!,
                       3600, accuracy: 1e-6)
        XCTAssertNil(PowerStateParser.idleSeconds(inIOReg: "no idle key here"))
    }

    // MARK: - pmset -g batt parsing

    func testParsesPowerSource() {
        XCTAssertFalse(PowerStateParser.onACPower(inBatt:
            "Now drawing from 'Battery Power'\n -InternalBattery-0  92%; discharging"))
        XCTAssertTrue(PowerStateParser.onACPower(inBatt:
            "Now drawing from 'AC Power'\n -InternalBattery-0  100%; charged"))
    }

    // MARK: - Re-sleep policy

    private let present = PowerEnvironment(userActive: true, displayAwake: true, userIdleSeconds: 0, onACPower: true)
    private let unattended = PowerEnvironment(userActive: false, displayAwake: false, userIdleSeconds: 3600, onACPower: true)

    func testSleepsOnlyWhenUnattendedAtBothEdges() {
        XCTAssertTrue(ReSleepPolicy.shouldReturnToSleep(entry: unattended, exit: unattended))
    }

    func testNeverSleepsWhenUserPresentAtStart() {
        XCTAssertFalse(ReSleepPolicy.shouldReturnToSleep(entry: present, exit: unattended))
    }

    func testNeverSleepsWhenUserArrivesDuringPing() {
        // Unattended at entry, but a human shows up before we'd sleep.
        XCTAssertFalse(ReSleepPolicy.shouldReturnToSleep(entry: unattended, exit: present))
        let displayWokeMidPing = PowerEnvironment(
            userActive: false, displayAwake: true, userIdleSeconds: 3600, onACPower: true)
        XCTAssertFalse(ReSleepPolicy.shouldReturnToSleep(entry: unattended, exit: displayWokeMidPing))
    }

    func testNeverSleepsOnRecentInput() {
        let recentInput = PowerEnvironment(
            userActive: false, displayAwake: false, userIdleSeconds: 30, onACPower: true)
        XCTAssertFalse(ReSleepPolicy.shouldReturnToSleep(entry: unattended, exit: recentInput))
    }

    // MARK: - PowerProbe fail-closed behavior

    func testProbeAssumesPresentWhenAssertionsUnreadable() {
        struct EmptyRunner: CommandCapturing {
            func capture(_ executable: String, _ arguments: [String]) -> String { "" }
        }
        let env = PowerProbe(runner: EmptyRunner()).read()
        XCTAssertEqual(env, .assumedPresent)
        // …and that fail-closed state blocks sleep.
        XCTAssertFalse(ReSleepPolicy.shouldReturnToSleep(entry: env, exit: env))
    }

    func testProbeAssemblesEnvironmentFromCommands() {
        struct FakeRunner: CommandCapturing {
            func capture(_ executable: String, _ arguments: [String]) -> String {
                if arguments == ["-g", "assertions"] {
                    return "   UserIsActive                   0\n   PreventUserIdleDisplaySleep    0\n"
                }
                if arguments == ["-c", "IOHIDSystem"] { return #"  "HIDIdleTime" = 600000000000"# }
                if arguments == ["-g", "batt"] { return "Now drawing from 'AC Power'" }
                return ""
            }
        }
        let env = PowerProbe(runner: FakeRunner()).read()
        XCTAssertEqual(env, PowerEnvironment(
            userActive: false, displayAwake: false, userIdleSeconds: 600, onACPower: true))
    }
}
