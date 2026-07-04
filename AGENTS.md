# AGENTS.md

Guidance for AI coding agents and human contributors working in this repository.
Read this before making changes — it captures the architecture, the commands, and
the hard rules that the rest of the code assumes.

## What this is

Agent Manager is a local-first, macOS-native menu-bar app + CLI for running your
own paid Claude Code and Codex accounts as parallel, isolated, scheduled work
capacity. Each account gets its own managed config home (`CLAUDE_CONFIG_DIR` /
`CODEX_HOME`), so you can run several accounts concurrently without touching your
default login, see live usage per account, and (optionally) schedule pings that
anchor each account's rolling 5-hour window inside your workday.

It is a single Swift package targeting **macOS 14+**, built with **Swift 6** and
strict concurrency.

## Layout

```
Sources/
  AgentManagerCore/   Shared library — all logic lives here, no SwiftUI/AppKit.
  AgentManager/       SwiftUI menu-bar app target (thin UI over Core).
  am/                 The `am` CLI: run · list · usage · ping · scheduler · wake · cloud.
  WakeHelperCore/     Foundation-only planning/parsing for the wake helper.
  am-wake-helper/     The root LaunchDaemon that arms RTC wakes for scheduled
                      pings. Links WakeHelperCore ONLY — never AgentManagerCore
                      — so the one binary that runs as root contains no account,
                      keychain, network, or process-spawning code.
Tests/
  AgentManagerCoreTests/   XCTest suite over Core + WakeHelperCore (plus the
                           app's design tokens — see ThemeContrastTests).
Support/                   Templates the Makefile copies into the .app bundle
                           (Info.plist, the bundled wake-helper daemon plist).
```

`Core` is the source of truth. The App and CLI are thin surfaces over the same
Core operations and the same on-disk config — neither owns state. Put logic in
Core (so it's testable and reusable); keep `AgentManager/` to presentation and
`am/` to argument parsing.

## Build, run, test

```bash
swift build                 # build everything
swift test                  # run the Core test suite (150+ tests, fast)
make build                  # assemble + codesign .build/AgentManager.app
make run                    # build, kill any running instance, open the app bundle
.build/debug/am help        # CLI usage
```

The library and CLI build/run/test with no special signing. `make build`
assembles a real `.app` bundle at `.build/AgentManager.app` (the app binary,
`am`, and `am-wake-helper` in `Contents/MacOS`, the wake-helper daemon plist in
`Contents/Library/LaunchDaemons` — that placement is what makes `SMAppService`
registration possible) and codesigns it with a local dev identity so Keychain
grants survive rebuilds (`CODESIGN_ID` overrides the identity). Keep the
bundle path stable: launchd's Background-items approval binds to it.

Useful env overrides (also how the tests stay hermetic — nothing in Core
hard-codes a real path):

- `AGENT_MANAGER_ROOT` — workspace root (defaults to `~/Library/Application Support/AgentManager`).
- `AGENT_MANAGER_LAUNCH_AGENTS_DIR` — where plists are written (defaults to `~/Library/LaunchAgents`).
- `AGENT_MANAGER_CLAUDE_BIN` / `AGENT_MANAGER_CODEX_BIN` — override the resolved CLI binary (tests inject stubs here).

## Hard rules (do not break these)

These are security and trust invariants, not preferences. Most of the code's
design follows from them.

1. **Never log or persist a secret.** Access/refresh tokens, OAuth blobs, and
   Keychain data must never land in any log (`AuditLog`, `ActivityLog`,
   `NetworkLog`) or any persisted file we write. `NetworkLog` redacts
   credential-bearing headers (`Authorization`, `Cookie`/`Set-Cookie`, API-key
   headers) on both request and response before writing; `AuditLog` only takes
   non-secret `detail`. Keep it that way.
2. **Never proxy OAuth.** We never route an OAuth token through our own harness.
   Logins, pings, and launches always drive the *official* `claude` / `codex`
   binary over a PTY (`GuidedLogin`, `*PingRunner`, `am run`). We only ever
   *read* credentials the official CLI wrote; we never write or relay them.
3. **Isolated homes, never credential-swap.** Each account is its own managed
   `CLAUDE_CONFIG_DIR` / `CODEX_HOME`. We never mutate the user's global default
   login. The one identity file per provider (`.claude.json` / `auth.json`) stays
   real and per-account; everything else is symlinked from the shared source home.
4. **Local-only. No backend, no telemetry, no analytics.** Network calls go
   only to the *official* provider endpoints (`api.anthropic.com`,
   `chatgpt.com`), mirroring the real CLI's requests. Two kinds exist:
   read-only usage fetches, and — only while the experimental **cloud
   fallback** toggle is on — first-party management of the user's own claude.ai
   anchor routines (`/v1/code/triggers` via `TriggerClient`). Those trigger
   calls are the sole writes, they configure state in the *user's own* account,
   and they are always fail-soft (local scheduling never depends on them).
   Don't add phone-home, crash reporting, or third-party endpoints.
5. **No shell string execution.** Spawn subprocesses with `Process` +
   `executableURL` (absolute path) + an `arguments` array. Never build a
   `/bin/sh -c "…"` command string from interpolated values. (`TerminalLauncher`
   is the sole place that emits a shell/AppleScript string, and only from
   validated/managed inputs.)
6. **Account IDs are filesystem-safe slugs.** Validate with `AccountID.validate`
   (`[A-Za-z0-9_-]`) before an ID is used as a directory name, launchd label, or
   plist path. This is what makes path/XML interpolation safe — keep new code
   paths going through it.
7. **Cadence restraint.** Scheduled pings bracket a real workday (minimal pings,
   never all-night batching, never disguised as human). Don't add anything that
   increases automated load or hides automation.

## Conventions

- **Swift 6, strict concurrency.** `Sendable` everywhere it matters; actors for
  shared mutable state (`UsageRateLimitGate`, `CodexUserAgent`, etc.).
- **Doc comments carry the "why."** The codebase favors rich `///` doc comments
  that explain rationale and edge cases (keychain ACL binding, anchoring, stale
  symlink healing). Match that density when you add or change behavior — explain
  *why*, not just *what*.
- **Pure core, injected I/O.** Logic is split into pure, testable pieces
  (`classify`, `toCalEntry`, `decodeResponse`) with `FileManager` / runners /
  environment injected so tests don't touch the real system. Follow this pattern.
- **Atomic writes, best-effort logs.** Config is written with `.atomic`; logs are
  append-only JSONL and best-effort (a logging failure never breaks the flow it
  observes).
- **Provider-agnostic Core.** Every provider-specific fact lives as a property on
  the `Provider` enum (`Provider.swift`). To add a provider, fill in those
  `switch` arms — the compiler will point at every one you owe.
- **Dark mode / theming.** The app honors the `theme` preference
  (`preferences.json`: light / dark / system) through one app-wide
  `NSApp.appearance` override (`AppModel.applyTheme`); `.system` clears it.
  Views must use adaptive colors (`Color.primary`, `.secondary`,
  `windowBackgroundColor`, …) so both appearances work; the fixed hex tokens
  in `Theme` are the deliberate exception. The menu-bar *status items* opt out
  of the override on purpose — `StatusBarController` pins them to the real
  system appearance (read from global defaults, re-pinned on the system
  theme-change notification) so template glyphs never render dark-on-dark or
  white-on-white against the actual menu bar.
- 4-space indentation; no trailing whitespace.

## Where state lives

`Workspace` resolves every on-disk path under one root
(`~/Library/Application Support/AgentManager` in production):

- `accounts.json` — account inventory (metadata + identity email + keychain
  service name; **no secrets**).
- `schedule.json` — painted work hours + window length.
- `scheduler.json` — the resident scheduler's active flag (what the app's
  "Scheduler active" toggle actually writes).
- `wake.json` — the "Wake Mac for pings" opt-in (app toggle / `am wake
  enable`). Read by the root wake helper; flipping it is the helper's entire
  runtime control surface.
- `cloud-fallback.json` — the experimental cloud-fallback opt-in (Preferences
  toggle / `am cloud enable`). Read by the scheduler daemon each tick.
- `cloud-fallback-state.json` — which claude.ai anchor routine is armed per
  account and for when. Written **only** by the daemon's `CloudFallbackEngine`
  (single writer); the app/CLI just read it for display.
- `scheduler-status.json` — the scheduler daemon's heartbeat + upcoming-queue
  snapshot, rewritten every tick (plus `scheduler.lock`, its flock file).
- `usage.json`, `usage-ratelimit.json` — cached readings / 429 backoff.
- `preferences.json` — display preferences (e.g. clock style), shared by app + CLI.
- `audit.log.jsonl`, `activity.jsonl`, `network.jsonl` — the three local logs
  shown in Monitoring.
- `homes/<id>/` — the managed config home per account (created `0o700`).
- `~/Library/LaunchAgents/com.agent-manager.scheduler.plist` — the **single**
  launchd agent: a KeepAlive daemon (`am scheduler run`) that fires every
  account's pings from an in-process queue (`SchedulerDaemon`).
- The optional root wake helper, in one of two flavors (same launchd label —
  never both): the **bundled** daemon inside `AgentManager.app` registered via
  `SMAppService` (the app's toggle; one-time System Settings approval, no
  sudo), or the **classic** install — root-owned copy in
  `/Library/PrivilegedHelperTools` + `/Library/LaunchDaemons` plist via the
  undocumented `sudo am wake install` (bare-binary/dev fallback).

Secrets are *not* among these: Claude's token stays in the login Keychain
(read-only, keyed by config-dir hash); Codex's tokens stay in the per-account
`auth.json` the CLI wrote inside the `0o700` home.

## Testing

- `Tests/AgentManagerCoreTests` covers Core: scheduling engine, launchd plist
  planning, symlink farm, account store, parsing/decoders, recommender. Run
  `swift test` — it should stay green and fast.
- Network *transport* and the SwiftUI app are not unit-tested; response decoders
  are exercised via `decodeForTesting` hooks. If you change a decoder, add a case
  there.
- When you change Core behavior, add or update a test in the same style (temp
  workspace, injected `FileManager`/runner).
- The test target also links the `AgentManager` app executable so
  `ThemeContrastTests` can audit the real `Theme` design tokens (no copies).
  It computes each token's WCAG contrast against the light and dark window
  backgrounds and *ratchets* the measured floors: improving or keeping
  contrast passes; losing it fails until the floor in that file is lowered on
  purpose. If you touch a `Theme` color, run
  `swift test --filter ThemeContrast` — it prints the full measured table.
  Every token clears WCAG's 3:1 non-text minimum in *both* appearances — most
  sit at relative luminance ≈0.26, the band where light ≥3:1 and dark ≥4.5:1
  hold from a single hex. The remaining gap is the 4.5:1 *text* bar in light
  mode (tinted captions measure 3.0–3.4); closing it means per-appearance
  token colors, then raising the floors.

## Gotchas

- **Keychain prompts.** Background usage reads use a non-interactive query
  (`KeychainNoUIQuery`) so they fail silently instead of popping the macOS "allow"
  dialog. Only an explicit user action (the Refresh button) may prompt. The
  read-via-`/usr/bin/security` path exists so the "Always Allow" grant binds to
  Apple's stable binary and survives app rebuilds — see `KeychainReadStrategy`.
- **launchd GUI domain.** The scheduler agent is loaded in `gui/<uid>` (not a
  cron or system daemon) because Claude's creds live in the login keychain,
  reachable only from a GUI-session agent.
- **Never churn the scheduler agent.** macOS 13+ posts a "background items
  added" notification every time a LaunchAgent is (re)registered — the reason
  the old one-job-per-account design notified N times on every Schedule click.
  The single agent plist must stay byte-stable: `Scheduler.activate` rewrites
  and re-bootstraps it **only** when the rendered content differs from disk;
  the Scheduler toggle otherwise only writes `scheduler.json`. Don't add
  anything schedule-shaped to the plist; the daemon reads all of that from the
  workspace.
- **Upgrades restart the daemons by themselves.** Both resident daemons are
  KeepAlive jobs, so "restart on upgrade" is just an exit: each stamps its own
  binary at launch and exits once the on-disk file has *changed and settled*
  (≥30 s old — never a half-written build; never mid-ping or inside the
  bridge window of an imminent fire) and launchd relaunches the new build.
  Belt-and-braces for daemons built before this trick existed:
  `Scheduler.restartDaemonIfOutdated` (run on app monitoring refresh and on
  activate) bounces a heartbeat-fresh, idle daemon whose `startedAt` predates
  the plist program's mtime — via `launchctl kickstart -k`, an in-place
  restart that never (re)registers, so it can't trigger the background-items
  notification. Restarts are double-fire safe (watermarks persist in the
  status file); don't add restart paths that bootout/bootstrap instead.
- **Anchoring needs a real TUI turn.** Only a `tui`-style ping over a PTY anchors
  a window; headless `claude -p` / `codex exec` burn tokens without opening the
  window. Don't "optimize" pings into headless calls.
- **Sleep & stale pings.** The daemon spawns each scheduled ping as
  `am ping <id> --manage-sleep --scheduled-for <epoch>`: the child holds the Mac
  awake for the turn (a `caffeinate` idle assertion bound to the ping's PID) and
  returns it to sleep only if the machine was provably unattended. A queue entry
  the Mac slept through is *dropped* (logged as `ping.skip`, grouped per
  account) rather than anchored at the wrong time — see `PowerManager` /
  `SchedulerDaemon` / `StalePingPolicy`.
- **The wake helper (lid-closed pings) is the one root component.** Waking a
  sleeping Mac needs `IOPMSchedulePowerEvent`, which is root-only — so the
  opt-in `am-wake-helper` LaunchDaemon exists solely to arm an RTC wake ~45 s
  before each queued fire. Its invariants: it links **WakeHelperCore only**
  (keep it that way — no AgentManagerCore in the root binary); it has **no
  XPC/IPC** (it re-reads `wake.json` + `scheduler-status.json` every minute —
  the files are the control channel, same as the scheduler); its inputs are
  untrusted (bounded decode, ≤12 wakes ≤48 h out, no file content in logs); and
  it installs as the bundled `SMAppService` daemon (app toggle → one-time
  System Settings approval; no `--root` arg — it discovers `/Users/*`
  workspaces itself) with the classic root-owned-copy install as the
  bare-binary fallback. Firmware rule: a
  closed lid honors RTC wakes on **AC power only**; open lids wake on battery
  too. The RTC wake is a *dark* wake with a ~30 s leash — `SchedulerDaemon`
  bridges it with a timed `caffeinate -i -t` whenever the next fire is ≤90 s
  out, until the ping child's own PID-bound assertion takes over. Don't widen
  the helper's lead past the bridge window or the Mac re-sleeps in the gap.
- **Cloud fallback is a one-shot dead-man's switch.** The one case the wake
  helper can't cover — closed lid on battery, where the firmware suppresses RTC
  wakes — is handled by the experimental cloud fallback (Claude only): the
  daemon keeps a claude.ai routine ("AgentManager Routine") armed at
  `next fire + 5 min`; a locally-anchored ping re-arms it forward, so
  Anthropic's cloud runs it only when the Mac provably couldn't. Its
  invariants: **always `run_once_at`, never cron** (an orphaned routine fires
  at most once, then auto-disables server-side); **the daemon is the only API
  writer** (app/CLI only flip `cloud-fallback.json`); **delete is web-only** —
  the API exposes DELETE solely to cookie-authenticated web sessions, which we
  never touch, so "off" means `enabled: false`; **never trigger the delegated
  token refresh from the engine** — a `/status` refresh anchors a window, the
  very thing pings schedule (the token is fresh right after a ping anyway,
  because the real CLI just ran); and the anchor signal is `am ping`'s exit
  code (0 anchored / 2 failed / 3 stale-skip — a skip must never read as an
  anchor). Everything is fail-soft: any API error just logs, backs off, and
  leaves local scheduling untouched.

## Scope & responsible use

This tool manages **your own** paid subscriptions. It deliberately stays on the
documented side of provider terms: it drives the official CLI, never proxies
OAuth, keeps everything local, and keeps scheduled pings minimal. Keep
contributions within that posture — see the Hard rules above.
