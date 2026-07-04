import Foundation

/// Power-management support for *scheduled* pings.
///
/// A scheduled ping may fire while the Mac is asleep or in a brief maintenance
/// ("dark") wake. Two problems follow, and this file addresses both safely:
///
/// 1. **The wake can collapse mid-turn.** A dark wake has a short leash; without
///    an assertion the system can re-sleep before the ping's turn finishes, so the
///    window never anchors. `SystemPower.holdIdleAssertion` keeps the system awake
///    for exactly the ping's lifetime.
/// 2. **We must not strand the Mac awake — nor sleep one that's in use.** After the
///    ping we *may* return the Mac to sleep, but only when it is **provably
///    unattended**. `ReSleepPolicy` makes that call from a `PowerEnvironment`
///    sampled at both the start and end of the ping, so a user who was already
///    there — or who sits down mid-ping — is never slept on.
///
/// Everything here drives Apple's own tools (`pmset`, `caffeinate`, `ioreg`) via
/// `Process` + absolute paths + argument arrays (hard rule #5 — no shell strings),
/// and the decision logic is pure so it can be unit-tested without touching the
/// real machine.

// MARK: - Sampled environment

/// A presence snapshot used to decide whether a finished scheduled ping may put
/// the Mac back to sleep. Deliberately presence-focused: the only thing that
/// matters is whether we'd be sleeping a machine someone is using.
public struct PowerEnvironment: Equatable, Sendable {
    /// powerd's `UserIsActive` assertion — set whenever HID input tickles the
    /// system. The single most reliable "a human is here right now" signal, and
    /// architecture-agnostic (the legacy `IODisplayWrangler` node we'd otherwise
    /// read is absent on Apple Silicon).
    public var userActive: Bool
    /// `PreventUserIdleDisplaySleep` — the display is being kept awake. True while
    /// someone is at the machine (even idle/reading); false once the display
    /// sleeps or during a dark wake.
    public var displayAwake: Bool
    /// Seconds since the last HID event (`HIDIdleTime`). Large during sleep / dark
    /// wake, ~0 during active use.
    public var userIdleSeconds: Double
    /// AC vs battery. Clamshell Macs only honor a *scheduled wake* on AC, so this
    /// matters for the (privileged) wake-arming step, not for the sleep-back call.
    public var onACPower: Bool

    public init(userActive: Bool, displayAwake: Bool, userIdleSeconds: Double, onACPower: Bool) {
        self.userActive = userActive
        self.displayAwake = displayAwake
        self.userIdleSeconds = userIdleSeconds
        self.onACPower = onACPower
    }

    /// The fail-closed default: assume a human is present. Returned whenever we
    /// can't actually read the machine's state, so an unreadable probe can never
    /// lead to sleeping a Mac we know nothing about.
    public static let assumedPresent = PowerEnvironment(
        userActive: true, displayAwake: true, userIdleSeconds: 0, onACPower: false)
}

// MARK: - Pure parsers (unit-tested)

public enum PowerStateParser {
    /// `pmset -g assertions` prints a summary block of `<AssertionName>   <0|1>`
    /// lines, then a per-pid breakdown. We read only the summary flags — per-pid
    /// lines start with `pid …`, never the bare assertion name, so a `hasPrefix`
    /// on the trimmed line picks out exactly the summary row.
    public static func summaryFlag(_ key: String, inAssertions text: String) -> Bool {
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(key) else { continue }
            // The value is the trailing token (`split` drops the run of spaces).
            return line.split(separator: " ").last == "1"
        }
        return false
    }

    public static func userActive(inAssertions text: String) -> Bool {
        summaryFlag("UserIsActive", inAssertions: text)
    }

    public static func displayAwake(inAssertions text: String) -> Bool {
        summaryFlag("PreventUserIdleDisplaySleep", inAssertions: text)
    }

    /// First `"HIDIdleTime" = <nanoseconds>` from `ioreg -c IOHIDSystem`, in seconds.
    public static func idleSeconds(inIOReg text: String) -> Double? {
        guard let r = text.range(of: "\"HIDIdleTime\" = ") else { return nil }
        let digits = text[r.upperBound...].prefix { $0.isNumber }
        guard let ns = Double(digits) else { return nil }
        return ns / 1_000_000_000
    }

    /// `pmset -g batt` names the power source on its first line.
    public static func onACPower(inBatt text: String) -> Bool {
        text.contains("AC Power")
    }
}

// MARK: - The re-sleep decision (pure, unit-tested)

public enum ReSleepPolicy {
    /// HID input within this many seconds of the decision counts as "someone's
    /// here" and blocks sleep. Generous so a user who just stepped away is safe.
    public static let defaultIdleThreshold: Double = 120

    /// Whether a just-finished *scheduled* ping may return the Mac to sleep.
    ///
    /// Conservative by construction: we only sleep a machine that looked unattended
    /// **both** when the ping started and right before we'd sleep it. So a user who
    /// was already present, or who arrives during the ping's ~tens-of-seconds, is
    /// never slept on — and neither is a machine the user is deliberately keeping
    /// awake (its `PreventUserIdleDisplaySleep` reads true).
    public static func shouldReturnToSleep(
        entry: PowerEnvironment,
        exit: PowerEnvironment,
        idleThreshold: Double = defaultIdleThreshold)
        -> Bool
    {
        if entry.userActive || entry.displayAwake { return false } // present at start
        if exit.userActive || exit.displayAwake { return false }   // arrived during ping
        if exit.userIdleSeconds < idleThreshold { return false }    // recent input
        return true
    }
}

// MARK: - Command capture (injected for tests)

/// Captures stdout of a child process. Injected so `PowerProbe` can be tested
/// against fixture strings without spawning anything.
public protocol CommandCapturing: Sendable {
    func capture(_ executable: String, _ arguments: [String]) -> String
}

/// Real implementation: run the tool, capture stdout, swallow failures (an empty
/// string flows through to the fail-closed `assumedPresent` default).
public struct ProcessCommandRunner: CommandCapturing {
    public init() {}

    public func capture(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        // Read before wait so a large `ioreg` dump can't deadlock the pipe.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Reading the live machine

public struct PowerProbe: Sendable {
    let runner: any CommandCapturing

    public init(runner: any CommandCapturing = ProcessCommandRunner()) {
        self.runner = runner
    }

    /// Sample the machine. If `pmset -g assertions` comes back empty (the read
    /// failed), return `.assumedPresent` so an unreadable machine is never slept.
    public func read() -> PowerEnvironment {
        let assertions = runner.capture("/usr/bin/pmset", ["-g", "assertions"])
        guard !assertions.isEmpty else { return .assumedPresent }
        let ioreg = runner.capture("/usr/sbin/ioreg", ["-c", "IOHIDSystem"])
        let batt = runner.capture("/usr/bin/pmset", ["-g", "batt"])
        return PowerEnvironment(
            userActive: PowerStateParser.userActive(inAssertions: assertions),
            displayAwake: PowerStateParser.displayAwake(inAssertions: assertions),
            // A missing idle reading defaults to 0 → "recent input" → don't sleep.
            userIdleSeconds: PowerStateParser.idleSeconds(inIOReg: ioreg) ?? 0,
            onACPower: PowerStateParser.onACPower(inBatt: batt))
    }
}

// MARK: - Actuation

public enum SystemPower {
    /// Hold a `PreventUserIdleSystemSleep` assertion until `pid` exits, so a ping
    /// that fires during a brief dark wake can finish its turn before the machine
    /// re-sleeps. `-w` ties the assertion to our process: it self-releases if we
    /// crash, so it can never orphan and pin the Mac awake. Returns the `caffeinate`
    /// process so the caller can also tear it down explicitly on the normal path.
    @discardableResult
    public static func holdIdleAssertion(untilPID pid: Int32) -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-i", "-w", String(pid)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        return process
    }

    /// Return the Mac to sleep. Best-effort: if it ever needs a privilege we don't
    /// have it simply no-ops and the machine drifts back to sleep on its own idle
    /// timer — never an error the caller must handle.
    public static func sleepNow() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["sleepnow"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
