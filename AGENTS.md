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
make build                  # assemble + codesign the DEV app at .build/AgentManager-dev.app
make run                    # build, kill any running instance, open the app bundle
.build/debug/am help        # CLI usage
```

The library and CLI build/run/test with no special signing. `make build`
assembles a real `.app` bundle (the app binary, `am`, and `am-wake-helper` in
`Contents/MacOS`, the wake-helper daemon plist in `Contents/Library/LaunchDaemons`
— that placement is what makes `SMAppService` registration possible) and
codesigns it with a local dev identity so Keychain grants survive rebuilds
(`CODESIGN_ID` overrides the identity).

**Build variants (dev vs prod).** So a locally built app can run *alongside* the
released one without colliding on bundle ID, launchd labels, workspace, or the
macOS background-item (BTM) records they feed, the build is variant-scoped:

- `make build` / `make run` produce the **dev** variant — bundle ID
  `com.agent-manager.app.dev`, name "Agent Manager (Dev)", launchd prefix
  `com.agent-manager.dev.`, workspace `~/Library/Application Support/AgentManager-dev`,
  bundle at `.build/AgentManager-dev.app`. This is the *only* variant to develop
  against.
- `make release` produces the **prod** variant — today's exact identifiers,
  bundle at `.build/AgentManager.app`. This is what brew ships; never release the
  dev variant.

The switch is the `AGENT_MANAGER_DEV` compile define (passed by `make build`,
absent for `make release`). Runtime code reads *all* identity from
`AppVariant` (Core) / `WakeVariant` (WakeHelperCore, the root binary that never
links Core); the Makefile keeps the assembled `Info.plist` + wake-helper plist in
sync via `Support/Info.plist.in` / `Support/wake-helper.plist.in`. To touch any
identifier, change `AppVariant`/`WakeVariant` and the two `.in` templates
together. Keep the *prod* bundle path (`.build/AgentManager.app`) stable:
launchd's Background-items approval binds to it.

Useful env overrides (also how the tests stay hermetic — nothing in Core
hard-codes a real path):

- `AGENT_MANAGER_ROOT` — workspace root (defaults to `~/Library/Application Support/AgentManager`, or `…/AgentManager-dev` for a dev build — see Build variants above).
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
   The one narrow carve-out is the `custom` ping method: it runs the user's
   *own* executable instead of driving the CLI ourselves. It gets exactly the
   environment the built-in drivers get (managed home, API keys stripped), we
   never inspect or relay any credential for it, and whether it anchored is
   still decided only from usage (`AnchorVerification`) — see
   `CustomPingRunner`.
3. **Isolated homes, never credential-swap.** Each account is its own managed
   `CLAUDE_CONFIG_DIR` / `CODEX_HOME`. We never mutate the user's global default
   login. The one identity file per provider (`.claude.json` / `auth.json`) stays
   real and per-account; everything else is symlinked from the shared source home.
4. **Local-only. No backend, no telemetry, no analytics.** Network calls go
   only to the *official* provider endpoints (`api.anthropic.com`,
   `chatgpt.com`), mirroring the real CLI's requests. Two kinds exist:
   read-only usage fetches, and — only while Claude's **`routine` ping method**
   is selected — first-party management of the user's own claude.ai anchor
   routines (`/v1/code/triggers` via `TriggerClient`), plus the disable call that
   stands a routine down when it isn't. Those trigger calls are the sole
   writes, they configure state in the *user's own* account,
   and they are always fail-soft (local scheduling never depends on them).
   Don't add phone-home, crash reporting, or third-party endpoints.
5. **No shell string execution.** Spawn subprocesses with `Process` +
   `executableURL` (absolute path) + an `arguments` array. Never build a
   `/bin/sh -c "…"` command string from interpolated values. (`TerminalLauncher`
   is the sole place that emits a shell/AppleScript string, and only from
   validated/managed inputs.) The `custom` ping method is consistent with this,
   not an exception to it: the user's command line is parsed once into argv
   (`CustomPingCommand`, an absolute executable + arguments) and only that argv
   ever reaches `Process`. Never re-join it into a string; a user who wants
   shell features points it at their own script or `/bin/zsh -lc '…'`
   explicitly.
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
- `schedule.json` — painted work hours + window length + planner knobs
  (parallel lanes, minimum budget-slice length, and the optional
  `firstPingOfDayOnly` mode — keep only each account's earliest ping per
  workday, filtered once in `LaunchAgentPlanner.weeklyPings` so every surface
  derives the same reduced plan; "workday" = the painted session a ping
  serves, keyed by the day that session started — see
  `firstAnchorPerWorkday`). At runtime the mode also caps deferral: a morning
  ping shifted past a hand-started window that would land inside the workday
  is skipped as covered rather than becoming an automatic mid-workday anchor
  (`RuntimeAnchorPolicy.adjust`, `firstPingOfDayOnly:`).
- `scheduler.json` — the resident scheduler's active flag (what the app's
  "Scheduler active" toggle actually writes).
- `wake.json` — the "Wake Mac for pings" opt-in (app toggle / `am wake
  enable`). Read by the root wake helper; flipping it is the helper's entire
  runtime control surface.
- `cloud-fallback-state.json` — which claude.ai anchor routine is armed per
  account and for when. Written **only** by the daemon's `CloudFallbackEngine`
  (single writer); the app/CLI just read it for display. (Whether to arm one is
  *not* here — it's Claude's `routine` ping method in `preferences.json`. The
  file name is historical: the routine began as a dead-man's fallback behind a
  local ping, and kept its name so an armed routine survived that redesign.)
- `scheduler-status.json` — the scheduler daemon's heartbeat + upcoming-queue
  snapshot, optional `inFlight` attempt checkpoint (kept separate from the
  handled watermark so a deferred child cannot lose its slot), per-account
  `windowStates` (the best-known real window expiry that runtime deferral
  schedules around), and `lastResolvedFire` (the latest fire whose cloud-routine
  run is accounted for, so it can't be reconciled twice), rewritten every tick
  (plus `scheduler.lock`, its flock file).
- `usage.json`, `usage-ratelimit.json` — cached readings / 429 backoff.
- `keychain-grants.json` — which Keychain services the `/usr/bin/security` read
  path is verified-granted for, shared app ↔ CLI ↔ daemon so background reads in
  any of them stay silent (see `KeychainGrantStore`).
- `preferences.json` — display preferences plus the provider-wide Claude and
  Codex ping methods, shared by app + CLI *and the scheduler daemon*. Four
  local drivers (`headless` / `terminal` / `sdk` / `custom`) plus, for Claude only,
  `routine`: the claude.ai cloud routine, which is a ping method rather than a
  separate feature because it answers the same question — what anchors this
  account. Picking it stops local Claude pings entirely. The file is written on
  first read if it's missing, because that read is also where "which default
  applies" is decided — see the ping-method gotcha. Optional
  `claudeCustomCommand` / `codexCustomCommand` (`{executable, arguments}`)
  hold what `custom` runs; they are omitted while unset, so older files stay
  byte-identical.
- `sdk-ping/` — the Node/Python helper scripts materialized by the installed
  binary when an SDK ping runs, plus the two dependency locations the user
  populates: `node_modules/` (Claude) and `.venv/` (Codex). The app never runs
  npm/pip or contacts a package registry — it only *resolves* what's there.
- `audit.log.jsonl`, `activity.jsonl`, `network.jsonl` — the three local logs
  shown in Monitoring.
- `homes/<id>/` — the managed config home per account (created `0o700`).
- The **single** scheduler LaunchAgent — a KeepAlive daemon (`am scheduler run`)
  that fires every account's pings from an in-process queue (`SchedulerDaemon`) —
  in one of two flavors (same launchd label, never both; `Scheduler` picks the
  first that applies): the **bundled** agent inside `AgentManager.app`
  (`Contents/Library/LaunchAgents/…scheduler.plist`) registered via
  `SMAppService` (`SchedulerAppService`), so it groups under the app's own Login
  Items row with a one-time approval; or the **classic** `~/Library/LaunchAgents/
  com.agent-manager.scheduler.plist` bootstrapped into `gui/<uid>` (the
  bare-binary/CLI fallback, and what the whole test suite exercises). The bundled
  plist is sealed and static — no per-user `AGENT_MANAGER_ROOT`/`PATH`/log paths
  (a variant-compiled `am` derives its own workspace; `am ping` children
  self-enrich PATH). Upgrading from classic → SMAppService, `Scheduler.activate`
  boots out + deletes the stale classic plist first (`migrateAwayFromClassicAgent`)
  so the same-label agents never fight.
- The optional root wake helper, in one of two flavors (same launchd label —
  never both): the **bundled** daemon inside `AgentManager.app` registered via
  `SMAppService` (the app's toggle; one-time System Settings approval, no
  sudo), or the **classic** install — root-owned copy in
  `/Library/PrivilegedHelperTools` + `/Library/LaunchDaemons` plist via the
  undocumented `sudo am wake install` (bare-binary/dev fallback).

Secrets are *not* among these: Claude's token stays in the login Keychain
(read-only, keyed by config-dir hash); Codex's tokens stay in the per-account
`auth.json` the CLI wrote inside the `0o700` home.

## Runbook: what happened last night?

Everything below lives in the workspace root above. The three logs are
append-only JSONL with ISO-8601 timestamps **in UTC** — convert before
correlating with wall-clock reports or `pmset` output, which are local time.
Parse defensively (`jq -cR 'fromjson? | select(type == "object") | …'`): the
in-app readers skip undecodable lines, and so should you. Monitoring shows a
rolling recent window of the same files — for forensics, read the files.

Work the chain in this order:

1. **Was the daemon alive?** `scheduler-status.json` is the heartbeat,
   rewritten every tick. `updatedAt` more than ~3 min stale at some point
   means the daemon was dead or unloaded then (unless `currentAccountID` /
   `inFlight` is set: a ping child is running, and a gap up to its 10-minute
   budget, `pingChildTimeout`, is expected); `startedAt`/`pid` reveal
   restarts; `lastHandled` is the per-account watermark of the last resolved
   fire (fired *or* deliberately dropped), while `inFlight` identifies a child
   whose outcome is not resolved yet; `upcoming` is what it planned next.
   `am scheduler status` pretty-prints it — and, on its `cloud:` lines, the
   armed one-shot per account from `cloud-fallback-state.json` (step 4's
   ground truth for what the routine was going to do).
2. **Did each fire happen, skip, or fail?** `audit.log.jsonl`, keyed by the
   dotted `action` field: `scheduler.start` marks a daemon (re)launch; each
   attempt is `ping.start` → `ping` (with `ok` and a one-line `detail`);
   deliberate drops are `ping.skip`, whose detail says why — `"stale ping
   (due 34m ago)"`, `"N stale pings (slept through…)"`, `"cloud routine
   covered this fire"`, `"cloud routine did not anchor this fire — <reason>"`
   (the armed one-shot's settle deadline passed and no evidence says it ran:
   that window is genuinely unanchored, and the reason names which witness said
   so), `"cloud routine method — no local ping"` (the slot came due with no
   routine armed for it at all: unanchored by design, never a flaky local
   turn), `"open window leaves no usable budget slice"`, or `"first ping only
   — an open window already covers the start of this workday"` (first-ping-only
   mode: deferring the morning ping past a hand-started window would have
   made it an automatic mid-workday anchor, so it was dropped instead).
   Note the ~5-minute lag on any cloud-routine resolution: a passed one-shot is
   held untouched until `CloudFallbackPlanner.dispatchSettle`, because moving it
   sooner would cancel the run — so a fire's `ping.skip` legitimately trails its
   minute, and the *absence* of any line within that window is the hold working.
   A fire that ran *minutes past its planned minute on purpose* logs
   `ping.defer` first (from the daemon when it shifts the queue past a
   known-open window, or from the child's preflight when it catches one at
   fire time) — deferral is the fix for phantom pings, not a malfunction: a
   turn fired into a still-open window anchors nothing. Cloud-routine arming
   appears as `routine.create` / `routine.adopt` / `routine.arm` /
   `routine.disable` (and `cloud.enable` / `cloud.disable` when the Claude ping
   method crossed into or out of `routine`) — and since
   `cloud-fallback-state.json` only holds the *current* arming, the last
   `routine.arm` with `ok: true` before the night is what tells you what was
   armed going in. Caveat: a
   plain "stale ping" skip does *not* rule out cloud coverage — the daemon
   can only log `"cloud routine covered…"` when it can reach the routines
   API at tick time (an expired token there means it reports a bare stale
   skip); cross-check with the anchor time in step 4. Audit timestamps are
   also a sleep proxy: on a closed-lid Mac the daemon only ticks during dark
   wakes, so gaps between entries mirror when the machine was actually up.
3. **Did the window actually anchor?** `activity.jsonl` has one record per
   ping outcome, and `anchored` is the truth signal, not `ok`: a stale skip
   is `ok: true, anchored: false`, while a cloud-covered fire is
   `anchored: true` with no local ping. A successful turn whose postflight
   usage is unavailable is conservatively scheduled but remains
   `anchored: false`; likewise, a cloud routine that fired inside an existing
   window is logged as a phantom with `anchored: false`. A failed ping's
   `transcriptPath` points at the saved PTY transcript
   (`logs/<account>-<epoch>.transcript`) —
   read that to see what the official CLI actually printed.
4. **What went over the wire?** `network.jsonl` records every HTTP exchange
   (usage fetches, trigger calls) with request and response, credential
   headers redacted, bodies capped at 16 KB. A run of 429s here explains
   empty usage readings (see also `usage-ratelimit.json` for the backoff).
   The captured usage *response bodies* are also the ground truth for when a
   window anchored: `resets_at − 5 h` is the anchor time — an anchor while
   the Mac was provably asleep is the cloud routine's fingerprint. Read those
   boundaries as 10-minute buckets rather than exact instants: the provider
   floors a window's start to the previous 10-minute mark, so `resets_at − 5 h`
   is the bucket the anchoring turn fell in, up to 10 minutes before the turn
   itself. A trigger response's `last_fired_at` is the only exact record of when
   a cloud routine ran — and comparing it against the `run_once_at` in the same
   body is how you tell a run that happened from one that was cancelled.
5. **Sleep/wake questions.** The root wake helper never writes to the
   workspace; it logs via os.log — `log show --last 12h --predicate
   'subsystem == "com.agent-manager"'`. For ground truth on the machine
   itself, `pmset -g log | grep -E "DarkWake|Entering Sleep| Wake "` gives
   just the transitions (unfiltered output is dominated by driver-ack noise;
   timestamps are local, not UTC), and `pmset -g sched` lists currently
   armed RTC wakes.

Exit codes, when reading daemon ↔ child traces: `am ping` exits 0 = anchored
(verified against post-turn usage for scheduled pings), 2 = failed, 3 =
stale-skip, 4 = deferred (preflight or postflight proved the window was already
open — the daemon re-fires just past its expiry), 5 = anchor unverified (a turn
ran but usage couldn't confirm the window moved; scheduled around
conservatively, never reported as an anchor) — see `PingOutcome`; the daemon
reads any unknown code as failed. The daemon's best-known window expiry per
account travels as `windowStates` in `scheduler-status.json`, fed by usage
readings (`resets_at` is exact) and observed/scheduled anchor events
(event-derived fallbacks).

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
  workspace. The bundled SMAppService flavor keeps the same invariant for free:
  the plist is sealed and never changes, and `ensureAgentViaAppService` skips
  `register()` entirely once the registration reads `.enabled` (re-registering an
  approved agent is what would re-notify).
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
  One upgrade path *does* need a re-register: a cask/brew upgrade deletes the
  bundle before replacing it, and macOS tears down the SMAppService/BTM
  registration with it (the daemon may keep running as a leftover job, but
  nothing would relaunch it after logout/reboot). The app self-heals on
  monitoring refresh: active + registration reading `.notRegistered`/
  `.notFound` → one `register()` per app run (`scheduler.reregister` in the
  audit log) — a real state change, so it can't re-notify an approved agent.
- **`headless` is the default; `terminal` is the verified one — and which you
  get is decided once, per install.** New installs anchor with the programmatic
  CLI (`claude -p` / `codex exec`): it completes a real billed turn with nothing
  to install beyond the provider's own binary, and it reads a structured result
  instead of a TUI's screen output, so it's the method least likely to break
  under us. Controlled-terminal pings over a PTY are the *first* method verified
  to anchor a rolling window, and remain what every install predating that
  default keeps — an upgrade never moves a working install onto a different
  anchoring method. That split lives in exactly one place, `PreferencesStore.load`:
  no `preferences.json` + no `accounts.json` ⇒ `Preferences.default`
  (programmatic); no `preferences.json` + an inventory ⇒ `Preferences.legacyDefault`
  (terminal). It **seeds the answer to disk on that first read** — the marker
  appears when the user adds their first account, so an unseeded new install
  would silently flip to the legacy default the moment it became real. (The app
  loads preferences at launch, long before any account exists. The one read that
  doesn't seed is a root one, under `sudo am wake …`: a root-owned
  `preferences.json` would make every later save silently fail.) Everywhere a
  *stored* choice can't be honored still lands on `terminal`, not on the default
  — `PingMethod.sanitized` (`routine` named for Codex) and `PingMethod.localDriver`
  (anything that must run a turn here under `routine`: Test ping, a hand-run `am
  ping`) — because an unhonorable value says nothing about what this install
  wants, and those paths are exactly where someone is checking that a turn
  works. `am ping <id> --method headless|terminal|sdk|custom` supplies a one-off
  override; `routine` is deliberately rejected there, because it schedules a
  future cloud run rather than delivering a turn now. Never equate
  method/process success with anchoring: scheduled children still bracket
  every method with usage reads, and only `AnchorVerification` may report a moved
  window. SDK helpers are materialized in `<workspace>/sdk-ping`; users install
  `@anthropic-ai/claude-agent-sdk` / `openai-codex` themselves, and Agent Manager
  must never auto-install them or contact a package registry. Both dependencies
  live *in the workspace*, because the two runtimes resolve them from opposite
  ends: Node walks up from the helper script, so any `node` finds
  `sdk-ping/node_modules`, while Python imports from the running interpreter's
  own site-packages — making the interpreter itself the dependency location, and
  a bare `python3` the one thing `SDKPingRunner.runtime` may not settle for
  (`ChildEnvironment.enriched` prepends `/opt/homebrew/bin` ahead of the caller's
  PATH, and the daemon's sealed plist carries no user PATH at all, so the
  `python3` that runs the helper is routinely not the one the user pip-installed
  into). Hence `sdk-ping/.venv`, resolved identically by app, CLI, and daemon:
  `AGENT_MANAGER_PYTHON_BIN` > that venv (on existence alone — the documented
  location stays deterministic) > the first PATH `python3` that can `find_spec`
  the module. Keep `setupCommand` installing into that exact interpreter by
  absolute path; an instruction that says `python3 -m pip install` is an
  instruction about a different interpreter than the one that will run.

  `custom` runs the user's own command (say a daily eval) as the anchoring
  turn, under the account's managed home, with `AGENT_MANAGER_ACCOUNT_ID`,
  `AGENT_MANAGER_PROVIDER`, and the resolved provider binary
  (`AGENT_MANAGER_CLAUDE_BIN` / `AGENT_MANAGER_CODEX_BIN`, its directory first
  on `PATH`) added; cwd is the executable's directory, stdin `/dev/null`. It
  always uses its own 8-minute timeout (`CustomPingRunner.timeout`) — never the
  90 s turn budget, Test ping included — and on timeout kills the whole
  process group. That timeout is pinned below the daemon's 600 s hard kill
  (`SchedulerDaemon.pingChildTimeout`) with room for the postflight read, and
  must stay well inside the 15-min stale grace because the daemon drains due
  pings sequentially. Outcome: never launched ⇒ failed, no verification; exited
  on its own (any status) ⇒ `ok`, status in the detail; timed out ⇒ `ok: false`
  but `mayHaveRunTurns`, so the scheduled child still verifies it (and reports
  `anchorUnknown` if usage can't tell). That is the one case where
  `anchored: true` can sit next to `ok: false`, which is why Monitoring reads
  `ActivityRecord.outcomeLabel` (anchored wins) rather than `ok` first.
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
  System Settings approval; no pinned workspace — it discovers `/Users/*`
  workspaces itself) with the classic root-owned-copy install (workspace
  pinned via `AGENT_MANAGER_ROOT` in its plist) as the bare-binary fallback. Firmware rule: a
  closed lid honors RTC wakes on **AC power only**; open lids wake on battery
  too. The RTC wake is a *dark* wake with a ~30 s leash — `SchedulerDaemon`
  bridges it with a timed `caffeinate -i -t` whenever the next fire is ≤90 s
  out, until the ping child's own PID-bound assertion takes over. Don't widen
  the helper's lead past the bridge window or the Mac re-sleeps in the gap.
- **The cloud routine is a ping method, not a safety net.** The case the wake
  helper can't cover — closed lid on battery, where the firmware suppresses RTC
  wakes, or any Mac with chronic sleep races — is handled by picking `routine`
  as Claude's ping method (Claude only). The daemon then keeps a
  claude.ai routine ("AgentManager Routine") armed at the **exact planned
  fire** and **never spawns a local Claude ping**; Codex is untouched (no
  routines → it keeps pinging locally). `reconcilePassedCloudFire` resolves
  each fire the routine covered (real anchor vs. phantom still decided by usage
  evidence), and a drain-loop guard consumes any Claude entry the routine
  hasn't confirmed yet — that one window goes **unanchored by design** (logged
  `skipped: cloud routine method …`) rather than falling back to the flaky
  local turn the method exists to avoid. Its invariants: **nothing about a
  passed one-shot may move until its run is accounted for** — claude.ai
  dispatches `run_once_at` 35–45 s *late*, and that field is also the server's
  only handle on the pending run, so patching it forward inside the gap deletes
  the run; `CloudFallbackPlanner.dispatchSettle` holds the arming, the queue
  entry, *and* the covered-fire bookkeeping until the fire resolves (see the
  next bullet); **a fire is only ever resolved from evidence** — an exact
  `resets_at` attributable to it, or the routines API's `last_fired_at` — never
  from the armed minute having passed, and an unconfirmed fire resolves
  `anchored: false` with no window state invented for it; **always
  `run_once_at`, never cron** (an orphaned routine fires at most once, then
  auto-disables server-side); **the daemon is the only API writer** (the app
  only writes the preference; the CLI doesn't write it at all — `am scheduler
  status` just reports what's armed); **create is adopt-first** — the routine
  list is the customer's, and `triggerID` lives only in local state (losable to an
  uninstall/reinstall, a dev-variant workspace, a re-added account slug), so
  whenever no routine is pinned the engine re-adopts an existing "AgentManager
  Routine" by name (list → patch), pauses any enabled strays, and creates only
  when the account has zero of ours — this instance never grows the list past
  one; **delete is web-only** — the API exposes DELETE solely to
  cookie-authenticated web sessions, which we never touch, so "off" means
  `enabled: false`; and **never trigger the delegated token refresh from the
  engine** — a `/status` refresh anchors a window, the very thing pings
  schedule (the token is fresh right after a ping anyway, because the real CLI
  just ran). Everything is fail-soft: any API error just logs, backs off, and
  leaves local scheduling untouched.

  There used to be a second, *fallback* mode: the routine armed at
  `fire + 5 min` as a dead-man's switch behind a local ping. It is retired —
  two anchors for one slot made "what anchors this account?" a question with
  two answers. Retiring it removed that reason for holding an armed one-shot
  until its fire resolved, and removing the *hold* was a bug: the five-minute
  lead had also been what gave the cloud time to actually dispatch. Armed *at*
  the fire, an evidence-free "the minute passed, so it ran" resolution re-armed
  the routine ~5 s after it came due and cancelled every run on an awake Mac —
  while logging each one as an anchor. The hold is back (`dispatchSettle`), so
  the planner is convergence *plus* that one rule; don't remove either half.
- **The provider quantizes anchors to 10 minutes.** A rolling window's *start* is
  floored to the previous 10-minute mark, so every `resets_at` lands on
  :00/:10/:20/:30/:40/:50 (~120 distinct boundaries over three weeks of
  `network.jsonl`, no exception) — a turn at 05:35 anchors 05:30–10:30. Observed,
  not documented, so `RuntimeAnchorPolicy.anchorQuantum` is the single place it
  lives and everything treats it as "*at most* this much quantization", degrading
  to a no-op if it changes. Three consequences worth knowing before touching
  anchor math: the refire `margin` is **free** anywhere below one quantum (an
  expiry sits on the grid, and a fire in `[expiry, expiry + quantum)` floors back
  to exactly `expiry`), which is also why lateness inside a bucket costs nothing;
  a *conservative* bound must be grid-floored, or each deferral overstates the
  expiry, the next fire is pushed past that, and the error compounds hop after
  hop until it eats a slot; and anchor attribution must compare floored values
  (`SchedulerDaemon.exactWindowPredates`), never allow a clock tolerance —
  flooring can put an implied anchor a full quantum before the turn that caused
  it, and a tolerance compare reads those real anchors as phantoms.
- **Missing menu-bar item after running a dev *and* a packaged build.** If the
  status item doesn't appear even though the app is running and `menuBarMode`
  isn't `.hidden`, suspect a stale ControlCenter record, not the code. Running a
  locally-built `.app` and the notarized/brew copy of the same
  `com.agent-manager.app` bundle side by side registers two menu-bar entries in
  macOS's *Allow in the Menu Bar* list (BTM-backed); the leftover one can
  suppress the real item. Deleting the app files doesn't clear it — the fix is
  to regenerate ControlCenter's state: `rm "$HOME/Library/Group
  Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist"
  && killall ControlCenter` (needs Full Disk Access on the terminal; a shutdown
  instead of `killall` also works). This is a dev-machine artifact of the
  self-signed→Developer-ID transition — a clean install (only the brew copy)
  never registers the duplicate, so users don't hit it.

## Scope & responsible use

This tool manages **your own** paid subscriptions. It deliberately stays on the
documented side of provider terms: it drives the official CLI, never proxies
OAuth, keeps everything local, and keeps scheduled pings minimal. Keep
contributions within that posture — see the Hard rules above.
