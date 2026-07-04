import AgentManagerCore
import SwiftUI

/// The **Monitoring** screen, split into two tabs:
///   • **Status** — health of the scheduler agent and the wake helper, plus the
///     recent ping log with anchor verification. (Per-account ping times live on
///     the Planner's "Ping schedule" — this screen only shows the machinery.)
///   • **Logs** — a unified, time-ordered feed of *everything* the app did: every
///     ping, every controlled run, and every HTTP request with its full response.
///
/// The Schedule / Clear controls now live in the sidebar footer.
struct MonitoringView: View {
    @Bindable var model: AppModel

    enum Tab: String, CaseIterable, Identifiable {
        case status = "Status", logs = "Logs"
        var id: String { rawValue }
    }
    @State private var tab: Tab = .status

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(alignment: .center) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Spacer()

                refreshControl
            }

            Divider()

            switch tab {
            case .status:
                statusTab
            case .logs:
                logsTab
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // These logs go stale the moment launchd fires another ping in the
        // background, so refresh every time the user opens this screen — they
        // should never land on data that's already out of date.
        .onAppear { model.refreshMonitoring() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Monitoring").font(Theme.Font.screenTitle)
                Text("One resident background agent fires every scheduled ping, even while this app is closed. Schedule / Clear live in the sidebar; everything the app does is logged here.")
                    .font(Theme.Font.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    /// A deliberately prominent refresh affordance: a labelled button plus a live
    /// "Updated Xs ago" stamp that turns into a warning once the feed is stale, so
    /// the user always knows whether they're looking at current data.
    private var refreshControl: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Button { model.refreshMonitoring() } label: {
                HStack(spacing: 6) {
                    if model.monitoringRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text("Refresh")
                }
                .frame(minWidth: 78)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(model.monitoringRefreshing)
            .help("Reload launchd badges, the ping log, and the activity feed")

            freshnessStamp
        }
    }

    /// Self-ticking freshness label. Anything older than a minute is flagged as
    /// stale (amber + warning glyph) — a strong hint to hit Refresh.
    private var freshnessStamp: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let stamp = freshness(asOf: context.date)
            Label(stamp.text, systemImage: stamp.stale ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(Theme.Font.caption2)
                .foregroundStyle(stamp.stale ? Theme.warning : Color.secondary)
                .help(stamp.stale ? "This feed may be out of date — hit Refresh." : "These logs are up to date.")
        }
    }

    /// Build the "Updated Xs ago" text + staleness flag for the given clock tick.
    private func freshness(asOf now: Date) -> (text: String, stale: Bool) {
        guard let at = model.monitoringRefreshedAt else { return ("Not loaded yet", true) }
        let secs = max(0, Int(now.timeIntervalSince(at)))
        let text: String
        switch secs {
        case 0..<5:   text = "Updated just now"
        case 5..<60:  text = "Updated \(secs)s ago"
        default:      text = "Updated \(secs / 60)m ago"
        }
        return (text, secs >= 60)
    }

    // MARK: - Status tab

    private var statusTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            jobs
            Divider()
            pingLog
        }
    }

    private var jobs: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Background scheduler").font(Theme.Font.sectionTitle)
            schedulerCard
            wakeCard
            cloudRoutineCards
        }
    }

    /// One row per Claude account's cloud anchor routine (the experimental
    /// cloud fallback) — shown under the two daemons only while the feature is
    /// on or a routine still exists to report on. Clicking a row opens that
    /// routine on claude.ai (the authoritative info/run-history view — also
    /// the only place a routine can be deleted).
    @ViewBuilder
    private var cloudRoutineCards: some View {
        let entries = (model.cloudFallbackState?.accounts ?? [:]).sorted(by: { $0.key < $1.key })
        if model.cloudFallbackEnabled || !entries.isEmpty {
            if entries.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "circle.dashed")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.neutral)
                    Text("AgentManager Routine")
                        .font(.system(size: 13, weight: .medium))
                    Text("not armed yet")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.neutral)
                    Spacer()
                    Text("The scheduler daemon arms one per Claude account before its next ping.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 10)
                .amCard(radius: Theme.Radius.sm)
            } else {
                ForEach(entries, id: \.key) { id, state in
                    cloudRoutineCard(accountID: id, state: state)
                }
            }
        }
    }

    private func cloudRoutineCard(accountID: String, state: AccountCloudFallbackState) -> some View {
        let display = cloudRoutineDisplay(state, accountID: accountID)
        let routineURL = state.triggerID.flatMap { URL(string: "https://claude.ai/code/routines/\($0)") }
        return Button {
            if let routineURL { NSWorkspace.shared.open(routineURL) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: display.glyph)
                    .font(.system(size: 12))
                    .foregroundStyle(display.tint)
                Text("AgentManager Routine · \(accountID)")
                    .font(.system(size: 13, weight: .medium))
                Text(display.title)
                    .font(Theme.Font.caption)
                    .foregroundStyle(display.tint)
                Spacer()
                Text(display.detail)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if routineURL != nil {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .amCard(radius: Theme.Radius.sm)
        .help(state.triggerID.map {
            "Routine \($0) — a one-shot on claude.ai that anchors this account's 5h window if the Mac sleeps through a ping. Click to open it (run history, delete) on claude.ai."
        } ?? "No routine created yet for \(accountID).")
    }

    private func cloudRoutineDisplay(_ s: AccountCloudFallbackState, accountID: String)
        -> (glyph: String, tint: Color, title: String, detail: String)
    {
        if let err = s.lastError {
            return ("exclamationmark.triangle.fill", Theme.warning, "error", err)
        }
        if s.disabled {
            // The state file only records *that* the daemon disabled the
            // routine; the why is derivable right here — name the actual
            // cause instead of guessing "toggle off" (a routine is also
            // disabled when there is simply no upcoming ping to back up).
            return ("pause.circle.fill", Theme.neutral, "disabled", cloudRoutineDisabledReason(accountID: accountID))
        }
        if let at = s.armedFor {
            if at <= Date() {
                return ("checkmark.circle.fill", Theme.success, "fired",
                        "ran \(model.clockStyle.dayTimeString(at)) from Anthropic's cloud — re-arms on the daemon's next tick")
            }
            return ("checkmark.circle.fill", Theme.success, "armed",
                    "fires \(model.clockStyle.dayTimeString(at)) only if the Mac sleeps through the ping")
        }
        return ("circle.dashed", Theme.neutral, "not armed",
                "The daemon arms it before the next scheduled ping.")
    }

    /// Why a routine sits disabled, in the same priority order the daemon's
    /// sync signal is computed from (feature → scheduler → per-account plan).
    /// Kept terse and lowercase to read as one column with the daemon cards'
    /// "no pings planned this week" / "no wakes needed yet".
    private func cloudRoutineDisabledReason(accountID: String) -> String {
        if !model.cloudFallbackEnabled {
            return "fallback off in Preferences"
        }
        if model.schedulerStatus?.active != true {
            return "the Scheduler is off"
        }
        if model.schedulerStatus?.accounts.first(where: { $0.accountID == accountID })?.scheduled != true {
            return "no pings planned this week"
        }
        return "arms on the daemon's next tick"
    }

    /// The one launchd agent's health, distilled: installed → loaded →
    /// heartbeat → active. Shape + color (not color alone) keeps the states
    /// legible without relying on green-vs-grey discrimination.
    private var schedulerCard: some View {
        let state = schedulerState
        return HStack(spacing: 10) {
            Image(systemName: state.glyph)
                .font(.system(size: 12))
                .foregroundStyle(state.tint)
            Text("com.agent-manager.scheduler")
                .font(.system(size: 13, weight: .medium))
            Text(state.title)
                .font(Theme.Font.caption)
                .foregroundStyle(state.tint)
            Spacer()
            Text(state.detail)
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
        .amCard(radius: Theme.Radius.sm)
    }

    private var schedulerState: (glyph: String, tint: Color, title: String, detail: String) {
        guard let s = model.schedulerStatus else {
            return ("circle.dashed", Theme.neutral, "loading…", "")
        }
        if !s.agentInstalled {
            return ("circle.dashed", Theme.neutral, "not installed",
                    "Turn the Scheduler on to install the background agent (macOS notifies once).")
        }
        if !s.agentLoaded {
            return ("exclamationmark.triangle.fill", Theme.warning, "not loaded",
                    "The agent exists but launchd hasn't loaded it — flip the Scheduler off and on.")
        }
        if !(s.daemon?.isFresh(asOf: Date()) ?? false) {
            return ("exclamationmark.triangle.fill", Theme.warning, "no heartbeat",
                    "Loaded, but the daemon hasn't reported recently — see logs/scheduler.err.log.")
        }
        if !s.active {
            return ("pause.circle.fill", Theme.neutral, "running · off",
                    "Idle. Turn the Scheduler on to fire the painted plan.")
        }
        if let next = s.daemon?.upcoming.first {
            return ("checkmark.circle.fill", Theme.success, "running · active",
                    "next \(model.clockStyle.dayTimeString(next.fireAt)) · \(next.accountID)")
        }
        return ("checkmark.circle.fill", Theme.success, "running · active", "no pings planned this week")
    }

    /// The root wake helper's health: the optional privileged sidecar that
    /// wakes the Mac for pings. Reads pure ground truth — installed files plus
    /// the RTC table — so it can't disagree with `pmset -g sched`.
    private var wakeCard: some View {
        let state = wakeState
        return HStack(spacing: 10) {
            Image(systemName: state.glyph)
                .font(.system(size: 12))
                .foregroundStyle(state.tint)
            Text("com.agent-manager.wake-helper")
                .font(.system(size: 13, weight: .medium))
            Text(state.title)
                .font(Theme.Font.caption)
                .foregroundStyle(state.tint)
            Spacer()
            Text(state.detail)
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
        .amCard(radius: Theme.Radius.sm)
    }

    private var wakeState: (glyph: String, tint: Color, title: String, detail: String) {
        guard let s = model.wakeStatus else {
            return ("circle.dashed", Theme.neutral, "loading…", "")
        }
        // Classic root install (sudo am wake install) — report its health.
        if s.binaryInstalled && s.plistInstalled {
            if !s.rootMatches {
                return ("exclamationmark.triangle.fill", Theme.warning, "wrong workspace",
                        "Serving \(s.installedForRoot ?? "?") — re-run sudo am wake install.")
            }
            if s.needsUpdate {
                return ("exclamationmark.triangle.fill", Theme.warning, "outdated",
                        "Installed helper differs from this build — re-run sudo am wake install.")
            }
            return wakeHealth(s)
        }
        // Bundled SMAppService daemon — the normal path.
        switch model.wakeRegistration {
        case .enabled:
            return wakeHealth(s)
        case .requiresApproval:
            return ("exclamationmark.triangle.fill", Theme.warning, "waiting for approval",
                    "System Settings → Login Items → allow \u{201C}Agent Manager\u{201D}.")
        case .notFound:
            return ("exclamationmark.triangle.fill", Theme.warning, "not found",
                    "launchd lost the registration (app moved?) — flip the Wake toggle off and on.")
        case .notRegistered, .unavailable, nil:
            return ("circle.dashed", Theme.neutral, "not installed",
                    "Optional: wakes the Mac for pings — flip \u{201C}Wake Mac for pings\u{201D} to set it up.")
        }
    }

    private func wakeHealth(_ s: WakeHelperSetup.Status) -> (glyph: String, tint: Color, title: String, detail: String) {
        if !s.enabled {
            return ("pause.circle.fill", Theme.neutral, "installed · off",
                    "Flip \u{201C}Wake Mac for pings\u{201D} in Preferences to enable wakes.")
        }
        // Registration says enabled but launchd can't start the process (and
        // the automatic re-register didn't fix it) — never show that as
        // active. The remedy differs by flavor: a bundled daemon needs the
        // Login Items cycle that re-records macOS's code-requirement pin; a
        // classic install needs a reinstall.
        if case .spawnFailed = model.wakeProcessState {
            let classic = s.binaryInstalled && s.plistInstalled
            return ("exclamationmark.triangle.fill", Theme.warning, "not running",
                    classic
                        ? "launchd can't start the helper — re-run sudo am wake install."
                        : "launchd can't start the helper — toggle \u{201C}Agent Manager\u{201D} off/on in System Settings → Login Items.")
        }
        if let next = s.scheduledWakes.first {
            return ("checkmark.circle.fill", Theme.success, "active",
                    "next wake \(model.clockStyle.dayTimeString(next)) · closed lids wake on AC only")
        }
        return ("checkmark.circle.fill", Theme.success, "active", "no wakes needed yet")
    }

    private var pingLog: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent pings").font(Theme.Font.sectionTitle)
                Spacer()
                LogFileCaption(
                    text: "showing the last 48 hours — full history in activity.jsonl",
                    files: [model.workspace.activityLogFile])
            }
            if model.recentActivity.isEmpty {
                Text("No pings in the last 48 hours. They appear here as the scheduler fires them (or after a Test ping on the Agents screen).")
                    .font(Theme.Font.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(model.recentActivity.enumerated()), id: \.offset) { _, record in
                            pingRow(record)
                        }
                    }
                    .animation(.easeOut(duration: 0.25), value: model.recentActivity.count)
                }
            }
        }
    }

    private func pingRow(_ record: ActivityRecord) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: record.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(record.ok ? Theme.success : Theme.danger)
                .font(.system(size: 12))
            Text(model.clockStyle.stampString(record.time))
                .font(Theme.Font.caption).foregroundStyle(.secondary).monospacedDigit()
            Text(record.accountID).font(.system(size: 12.5, weight: .medium))
            Text(anchorText(record))
                .font(Theme.Font.caption)
                .foregroundStyle(record.ok ? (record.anchored ? Theme.success : Theme.warning) : .secondary)
            Text(record.detail).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    private func anchorText(_ r: ActivityRecord) -> String {
        guard r.ok else { return "failed" }
        return r.anchored ? "anchored" : "ran · no anchor"
    }

    // MARK: - Logs tab

    /// Frames the feed as what it is — a complete, local, secret-free audit trail.
    private var auditBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.success)
            Text("Your complete local audit trail — every read, ping, launch, and HTTP request. No tokens or secrets are ever recorded.")
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .amCard(radius: Theme.Radius.sm)
    }

    private var logsTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            auditBanner
            HStack(alignment: .firstTextBaseline) {
                Text("Activity log").font(Theme.Font.sectionTitle)
                Spacer()
                LogFileCaption(
                    text: "\(model.monitoringLogs.count) events · showing the last 48 hours — full history in the workspace's .jsonl files",
                    files: [model.workspace.auditLogFile,
                            model.workspace.activityLogFile,
                            model.workspace.networkLogFile])
            }
            if model.monitoringLogs.isEmpty {
                Text("Nothing logged in the last 48 hours. Pings, scheduling, token refreshes, and every HTTP request (with its response) show up here as they happen.")
                    .font(Theme.Font.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(model.monitoringLogs) { entry in
                            LogRowView(entry: entry, clockStyle: model.clockStyle)
                        }
                    }
                    .padding(.bottom, 6)
                    .animation(.easeOut(duration: 0.25), value: model.monitoringLogs.count)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// One row in the unified Logs feed. HTTP rows are clickable: tapping expands the
/// row to the full request (method, URL, headers, body) and response.
private struct LogRowView: View {
    let entry: MonitoringLogEntry
    let clockStyle: ClockStyle
    @State private var expanded = false
    @State private var transcript: String?
    @State private var transcriptLoaded = false

    private var isHTTP: Bool { entry.http != nil }
    /// Ping rows that saved a transcript can expand to show the agent's reply.
    private var hasTranscript: Bool { entry.transcriptPath != nil }
    private var canExpand: Bool { isHTTP || hasTranscript }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                guard canExpand else { return }
                expanded.toggle()
                if expanded, hasTranscript, !transcriptLoaded { loadTranscript() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: glyph)
                        .foregroundStyle(tint)
                        .font(.system(size: 11))
                        .frame(width: 14)
                    Text(clockStyle.stampString(entry.time))
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    Text(entry.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(entry.detail)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    if canExpand {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                if let http = entry.http {
                    httpDetail(http)
                } else if hasTranscript {
                    transcriptDetail
                }
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
        .amCard(radius: Theme.Radius.sm)
    }

    @ViewBuilder
    private func httpDetail(_ h: NetworkLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            exchangeBlock(
                "REQUEST",
                summary: "\(h.method) \(h.url)",
                headers: h.requestHeaders,
                body: h.requestBody)
            exchangeBlock(
                "RESPONSE",
                summary: h.statusCode.map { "HTTP \($0)" } ?? (h.error ?? "no response"),
                headers: h.responseHeaders,
                body: h.responseBody)
        }
        .padding(.top, 2)
        .padding(.leading, 22)
    }

    @ViewBuilder
    private var transcriptDetail: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("AGENT REPLY (PTY TRANSCRIPT)")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.tertiary)
                .tracking(0.6)
            let body = (transcript?.isEmpty == false) ? transcript! : "—  (no transcript captured)"
            ScrollView {
                Text(body)
                    .font(.system(size: 10.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        }
        .padding(.top, 2)
        .padding(.leading, 22)
    }

    /// Read the saved transcript off disk (once) and strip terminal control codes
    /// so the agent's reply is legible. Best-effort: a missing/unreadable file just
    /// leaves the placeholder.
    private func loadTranscript() {
        transcriptLoaded = true
        guard let path = entry.transcriptPath,
              let raw = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) else { return }
        transcript = Self.stripTerminalCodes(raw)
    }

    /// Strip ANSI/VT escape sequences and stray control bytes from a raw PTY dump,
    /// keeping newlines and tabs, so a captured TUI screen renders as plain text.
    static func stripTerminalCodes(_ s: String) -> String {
        var out = s
        // CSI (ESC [ … final), OSC (ESC ] … BEL/ST), and lone two-char ESC sequences.
        for pattern in [#"\u{001B}\[[0-9;?]*[ -/]*[@-~]"#,
                        #"\u{001B}\][^\u{0007}\u{001B}]*(?:\u{0007}|\u{001B}\\)"#,
                        #"\u{001B}[@-Z\\-_]"#] {
            out = out.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        // Drop remaining control chars except newline (\n) and tab (\t).
        out = String(out.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || $0.value >= 0x20 })
        // Collapse the runs of blank lines a redrawn TUI screen leaves behind.
        out = out.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func exchangeBlock(_ label: String, summary: String, headers: [String: String], body: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.tertiary)
                .tracking(0.6)
            Text(summary)
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
            ForEach(headers.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                Text("\(key): \(value)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
            if let body, !body.isEmpty {
                Text(body)
                    .font(.system(size: 10.5, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            }
        }
    }

    private var glyph: String {
        switch entry.kind {
        case .ping: entry.ok ? "checkmark.circle.fill" : "xmark.octagon.fill"
        case .http: "arrow.up.arrow.down.circle.fill"
        case .action: entry.ok ? "circle.fill" : "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        if !entry.ok { return Theme.danger }
        switch entry.kind {
        case .ping: return Theme.success
        case .http: return Theme.accent
        case .action: return Theme.neutral
        }
    }
}

/// The "showing the last 48 hours — full history in …" caption: hovering shows
/// the log files' full paths, clicking reveals them in Finder.
///
/// The tooltip borrows the consumption bars' technique (see
/// `DayConsumptionTimeline.BarView`): an *always-present* overlay toggled by
/// `opacity`, because a view inserted under the cursor re-runs hit-testing and
/// can flip hover off-then-on forever. Trailing-aligned so the wide path text
/// grows leftward instead of past the window edge.
private struct LogFileCaption: View {
    let text: String
    /// The files the tooltip lists and a click selects in Finder.
    let files: [URL]
    @State private var showTip = false
    @State private var hoverTask: Task<Void, Never>?

    /// Hover dwell before the tooltip appears — same feel as the planner bars.
    private static let hoverDelay: Duration = .milliseconds(300)

    var body: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting(files)
        } label: {
            Text(text)
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .underline(showTip)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            tooltip
                .fixedSize()
                .allowsHitTesting(false)
                .opacity(showTip ? 1 : 0)
                // Park the tooltip just above the caption, outside its bounds,
                // so it never lands under the cursor.
                .alignmentGuide(.top) { $0[.bottom] + 6 }
        }
        .onHover { inside in
            hoverTask?.cancel()
            if inside {
                hoverTask = Task { @MainActor in
                    try? await Task.sleep(for: Self.hoverDelay)
                    if !Task.isCancelled { showTip = true }
                }
            } else {
                showTip = false
            }
        }
        .zIndex(showTip ? 1 : 0)
    }

    private var tooltip: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(files, id: \.self) { file in
                Text(file.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
            }
            Text("Click to reveal in Finder")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
    }
}
