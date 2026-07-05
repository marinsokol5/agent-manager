import Foundation
import IOKit.pwr_mgt
import WakeHelperCore
import os

/// `am-wake-helper` — the tiny root daemon behind the "Wake Mac for pings"
/// opt-in.
///
/// A lid-closed Mac never runs the resident scheduler, so scheduled pings are
/// dropped as stale. Arming an RTC wake fixes that — but the wake-scheduling
/// call (`IOPMSchedulePowerEvent`) is root-only, which is the *only* reason
/// this process exists. It is installed once, in one of two ways:
/// - **SMAppService (preferred, no sudo):** shipped inside `AgentManager.app`
///   and registered by the app's toggle; the user approves once in System
///   Settings → Login Items. No pinned workspace — the plist is sealed into
///   the signed bundle — so the helper discovers every standard workspace
///   under `/Users/*`, each gated by its own `wake.json`.
/// - **Classic (`sudo am wake install`):** root-owned copy in
///   `/Library/PrivilegedHelperTools` with one explicit workspace baked into
///   its `/Library/LaunchDaemons` plist as `AGENT_MANAGER_ROOT` (pre-env-var
///   installs used a `--root` argument, still honored until their next
///   install). Kept for bare-binary/dev setups.
///
/// Design constraints, in order:
/// - **Smallest possible root surface.** No XPC, no sockets, no subprocesses,
///   no writes. The helper *reads* two workspace files (`wake.json`,
///   `scheduler-status.json`) and reconciles the system's scheduled-power-event
///   table against them; the user-session side "talks" to it purely by writing
///   those files — the same no-IPC pattern the scheduler daemon itself uses.
/// - **Untrusted input.** The files it reads are user-writable. The worst a
///   forged file can achieve is bounded by `WakePlanner`: ≤ 12 wake events, ≤
///   48 h out. File contents are never logged or forwarded.
/// - **Fail quiet.** Anything unreadable plans zero wakes and clears ours from
///   the table. A machine can always be slept; we only ever *wake* it, and only
///   at moments the user's own painted schedule produced.
///
/// Hardware reality (why the app calls this "AC only"): firmware ignores RTC
/// wakes on a *closed* portable running on battery. Lid open, or lid closed on
/// AC, they fire.

private let helperID = WakeVariant.helperID
private let logger = Logger(subsystem: "com.agent-manager", category: "wake-helper")

// Mirrors of IOPMLib.h's scheduled-event constants, pinned here as literals so
// the reconcile logic below is greppable against `pmset -g sched` output.
private let eventTypeWake = "wake"            // kIOPMAutoWake
private let keyTime = "time"                  // kIOPMPowerEventTimeKey
private let keyScheduledBy = "scheduledby"    // kIOPMPowerEventAppNameKey
private let keyType = "eventtype"             // kIOPMPowerEventTypeKey

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    logger.error("\(message, privacy: .public)")
    exit(1)
}

// MARK: - the RTC event table

/// The wake events *we* own, as (whole-second epoch → exact CFDate in the
/// table). Keyed on rounded seconds so a Date that round-tripped through the
/// power-management daemon still compares equal to the one we planned.
private func ourScheduledWakes() -> [Int: Date] {
    guard let raw = IOPMCopyScheduledPowerEvents()?.takeRetainedValue() as? [[String: Any]] else { return [:] }
    var wakes: [Int: Date] = [:]
    for event in raw {
        guard event[keyScheduledBy] as? String == helperID,
              event[keyType] as? String == eventTypeWake,
              let date = event[keyTime] as? Date else { continue }
        wakes[Int(date.timeIntervalSince1970.rounded())] = date
    }
    return wakes
}

/// Make the table contain exactly `wanted` (for our id): cancel ours that are
/// no longer planned, add the missing. Idempotent; safe to run every pass.
private func reconcile(wanted: [Date]) -> (added: Int, cancelled: Int, failed: Int) {
    let current = ourScheduledWakes()
    let wantedByEpoch = Dictionary(uniqueKeysWithValues: wanted.map { (Int($0.timeIntervalSince1970.rounded()), $0) })

    var added = 0, cancelled = 0, failed = 0
    for (epoch, date) in current where wantedByEpoch[epoch] == nil {
        // Cancel with the table's own CFDate — the triple must match exactly.
        if IOPMCancelScheduledPowerEvent(date as CFDate, helperID as CFString, eventTypeWake as CFString) == kIOReturnSuccess {
            cancelled += 1
        } else {
            failed += 1
        }
    }
    for (epoch, date) in wantedByEpoch where current[epoch] == nil {
        if IOPMSchedulePowerEvent(date as CFDate, helperID as CFString, eventTypeWake as CFString) == kIOReturnSuccess {
            added += 1
        } else {
            failed += 1
        }
    }
    return (added, cancelled, failed)
}

// MARK: - entry

let arguments = Array(CommandLine.arguments.dropFirst())
let environmentRoot = ProcessInfo.processInfo.environment["AGENT_MANAGER_ROOT"]?
    .trimmingCharacters(in: .whitespacesAndNewlines)
let explicitRoot: URL?
switch arguments.count {
case 0:
    // Classic installs pin one workspace via AGENT_MANAGER_ROOT in the daemon
    // plist; the bundled SMAppService plist sets nothing, so discovery runs.
    explicitRoot = environmentRoot.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
case 2 where arguments[0] == "--root":
    // Pre-env-var classic plists — honored until their next `sudo am wake install`.
    explicitRoot = URL(fileURLWithPath: arguments[1], isDirectory: true)
default:
    fail("usage: am-wake-helper (workspace root via AGENT_MANAGER_ROOT, or none to discover /Users/*)")
}

// IOPMSchedulePowerEvent is root-only; running unprivileged would just log a
// failure per pass forever. Exit loudly instead — launchd (system domain) is
// the intended parent.
guard geteuid() == 0 else {
    fail("am-wake-helper must run as root (as the \(helperID) LaunchDaemon)")
}

logger.notice("wake helper started (pid \(ProcessInfo.processInfo.processIdentifier, privacy: .public)), watching \(explicitRoot?.path ?? "all standard workspaces under /Users", privacy: .public)")

/// Our own binary at launch. When the file on disk stops matching (an app
/// rebuild / upgrade replaced it), the pass below exits so launchd's KeepAlive
/// relaunches the new build — no manual restart after upgrades. Only armed
/// under launchd (parent pid 1); a hand-run copy has nothing to relaunch it.
let executablePath = Bundle.main.executablePath
let launchBinaryStamp = executablePath.flatMap { BinaryStamp.read(path: $0) }
let relaunchAvailable = getppid() == 1

/// Last plan actually applied, logged only on change so a quiet week is quiet
/// in Console too.
var lastApplied: [Int] = [-1]

while true {
    // Re-discover every pass (users/workspaces can appear); merge every
    // opted-in workspace's plan and re-cap globally — the RTC table is one
    // shared resource no matter how many workspaces feed it.
    let roots = explicitRoot.map { [$0] } ?? WakeInputs.standardWorkspaceRoots()
    let now = Date()
    var enabledCount = 0
    var merged: Set<Date> = []
    for root in roots {
        let snapshot = WakeInputs.read(root: root)
        if snapshot.enabled { enabledCount += 1 }
        merged.formUnion(WakePlanner.plan(snapshot, now: now))
    }
    let wanted = Array(merged.sorted().prefix(WakePlanner.defaultCap))
    let result = reconcile(wanted: wanted)

    let epochs = wanted.map { Int($0.timeIntervalSince1970.rounded()) }
    if epochs != lastApplied || result.failed > 0 {
        lastApplied = epochs
        let next = wanted.first.map { ISO8601DateFormatter().string(from: $0) } ?? "none"
        logger.notice("reconciled: \(wanted.count, privacy: .public) wake(s) scheduled (next \(next, privacy: .public)), +\(result.added, privacy: .public) −\(result.cancelled, privacy: .public) failed \(result.failed, privacy: .public), \(enabledCount, privacy: .public)/\(roots.count, privacy: .public) workspace(s) enabled")
    }

    // Exit-for-relaunch on a rebuilt binary, checked after the reconcile so
    // the RTC table is never left mid-update. The armed wakes themselves
    // outlive the process — they sit in the power-management daemon's table.
    if relaunchAvailable, let executablePath,
       BinaryStamp.restartDue(sinceLaunch: launchBinaryStamp, current: BinaryStamp.read(path: executablePath), now: Date())
    {
        logger.notice("binary updated on disk — exiting so launchd relaunches the new build")
        exit(0)
    }

    // Plain poll, like the scheduler daemon: the files *are* the IPC. Sleeping
    // through machine sleep is fine — we resume and reconcile on wake, and the
    // RTC table itself is what does the waking.
    Thread.sleep(forTimeInterval: 60)
}
