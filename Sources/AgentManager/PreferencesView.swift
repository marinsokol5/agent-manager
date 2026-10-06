import AgentManagerCore
import AppKit
import SwiftUI

/// The **Preferences** screen. Hosts the per-provider ping method (including
/// Claude's cloud routine — see `pingMethodSection`), the set-once "Wake Mac
/// for pings" opt-in (it lives here rather than next to the Scheduler toggle
/// because you flip it once and forget it — ongoing health shows on the
/// Monitoring screen), the menu-bar display mode, the theme, and the clock
/// style.
struct PreferencesView: View {
    @Bindable var model: AppModel
    @State private var pingMethodProvider: Provider = .claude

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                pingMethodSection
                wakeSection
                menuBarSection
                themeSection
                timeFormatSection
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Freshen helper/approval state whenever the user lands here, so the
        // wake card's caption reflects reality without a manual refresh.
        .onAppear { model.refreshMonitoring() }
    }

    private var header: some View {
        Text("Preferences").font(.system(size: 18, weight: .bold))
    }

    private var menuBarSection: some View {
        section(title: "Menu bar", subtitle: "How your agents appear in the system menu bar.") {
            ForEach(AppModel.MenuBarMode.allCases) { mode in
                PreferenceRadioCard(
                    systemImage: mode.systemImage,
                    title: mode.title,
                    subtitle: mode.subtitle,
                    isSelected: model.menuBarMode == mode,
                    action: { model.menuBarMode = mode })
            }
        }
    }

    private var themeSection: some View {
        section(title: "Theme", subtitle: "The app's color scheme — the window and the menu-bar dropdown.") {
            ForEach(AppTheme.allCases) { theme in
                PreferenceRadioCard(
                    systemImage: theme.displaySymbol,
                    title: theme.displayTitle,
                    subtitle: theme.displaySubtitle,
                    isSelected: model.theme == theme,
                    action: { model.theme = theme })
            }
        }
    }

    private var timeFormatSection: some View {
        section(title: "Time format", subtitle: "How every time is shown — usage resets, schedules, logs, and the `am` CLI.") {
            ForEach(ClockStyle.allCases) { style in
                PreferenceRadioCard(
                    systemImage: "clock",
                    title: style.displayTitle,
                    subtitle: style.displayExample,
                    isSelected: model.clockStyle == style,
                    action: { model.clockStyle = style })
            }
        }
    }

    private var wakeSection: some View {
        section(
            title: "Scheduled pings",
            subtitle: "Whether this Mac wakes itself for the pings it runs locally.")
        {
            WakeToggleCard(model: model)
        }
    }

    /// The one "what anchors this account?" question. The local drivers
    /// and Claude's cloud routine sit in the same list on purpose: they are
    /// alternatives, not a feature plus a mode — picking the routine means the
    /// scheduler stops running local Claude turns entirely.
    private var pingMethodSection: some View {
        section(
            title: "Ping method",
            subtitle: "How each provider's 5-hour window gets anchored. Scheduled runs always verify anchoring; Test ping always runs a local turn.")
        {
            Picker("Provider", selection: $pingMethodProvider) {
                Text("Claude").tag(Provider.claude)
                Text("Codex").tag(Provider.codex)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 220, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)

            pingMethodGroup(
                provider: pingMethodProvider,
                selection: pingMethodProvider == .claude
                    ? model.claudePingMethod
                    : model.codexPingMethod)
            { method in
                switch pingMethodProvider {
                case .claude: model.claudePingMethod = method
                case .codex: model.codexPingMethod = method
                }
            }
        }
    }

    private func pingMethodGroup(
        provider: Provider,
        selection: PingMethod,
        select: @escaping (PingMethod) -> Void)
        -> some View
    {
        VStack(alignment: .leading, spacing: 8) {
            // Only Claude offers `.routine` — `available(for:)` is what keeps
            // the Codex list from showing a method it has no routines for.
            ForEach(PingMethod.available(for: provider)) { method in
                let setupCommand = method == .sdk
                    ? SDKPingRunner.setupCommand(provider: provider, workspace: model.workspace)
                    : nil
                PreferenceRadioCard(
                    systemImage: method.displaySymbol,
                    title: method.displayTitle,
                    subtitle: method.displaySubtitle(
                        for: provider,
                        setupCommand: setupCommand),
                    copyCommand: setupCommand,
                    // Live routine state (armed for when, sync errors, why
                    // nothing will arm) reads as part of the choice, so it
                    // hangs off the selected card instead of a separate row.
                    statusCaption: method == .routine && selection == .routine
                        ? cloudRoutineCaption
                        : method == .custom && selection == .custom
                            ? customCommandCaption(provider: provider)
                            : nil,
                    isSelected: selection == method,
                    action: { select(method) })
                // The card is a Button, so the editable command lives under
                // it rather than inside it. Keyed by provider so switching the
                // segmented picker reloads the field from that provider's value.
                if method == .custom && selection == .custom {
                    CustomCommandField(model: model, provider: provider)
                        .id(provider)
                }
            }
        }
    }

    /// Selecting Custom without a usable command is allowed — you may pick the
    /// method first and the command second — but the card must say plainly
    /// that scheduled pings fail until one is set: never a silent dead method.
    private func customCommandCaption(provider: Provider) -> (text: String, tint: Color) {
        guard let command = model.customCommand(for: provider) else {
            return ("No command set — every ping fails until you save one below.", Theme.warning)
        }
        do {
            try command.validate()
        } catch {
            return ("Saved command can't run (\(error)) — pings fail until it's fixed.", Theme.warning)
        }
        return ("Runs your command (up to 8 minutes); usage decides whether it anchored.", Theme.success)
    }

    /// What the armed routine is actually doing, straight from the daemon's
    /// `cloud-fallback-state.json` — or the reason nothing will arm yet, in the
    /// order the daemon decides it (account → scheduler → plan).
    private var cloudRoutineCaption: (text: String, tint: Color) {
        guard model.accounts.contains(where: { $0.provider.supportsCloudAnchorRoutines && $0.status == .connected }) else {
            return ("No connected Claude account — nothing to anchor.", Theme.warning)
        }
        guard model.schedulerActive else {
            return ("Waiting for the Scheduler — turn it on to arm.", Theme.warning)
        }
        // Sorted by account id, not dictionary order: with two Claude accounts
        // erroring, an unordered pick would flip the caption between refreshes.
        let entries = (model.cloudFallbackState?.accounts ?? [:]).sorted(by: { $0.key < $1.key })
        if let bad = entries.compactMap({ $0.value.lastError }).first {
            return ("Sync problem: \(bad) — see Monitoring.", Theme.warning)
        }
        if let next = entries.compactMap({ $0.value.armedFor }).filter({ $0 > Date() }).sorted().first {
            return ("Armed — claude.ai anchors the next Claude slot at \(model.clockStyle.dayTimeString(next)).",
                    Theme.success)
        }
        return ("Arms a one-shot at each scheduled Claude slot on the daemon's next tick.", Theme.success)
    }

    /// Shared section chrome: a semibold title, a secondary subtitle, and a
    /// vertical stack of the section's radio cards.
    private func section<Content: View>(
        title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View
    {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) { content() }
                .padding(.top, 2)
        }
        .frame(maxWidth: 560, alignment: .leading)
    }
}

private extension AppTheme {
    var displayTitle: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .system: "System"
        }
    }

    var displaySubtitle: String {
        switch self {
        case .light: "Always light, whatever macOS is set to."
        case .dark: "Always dark, whatever macOS is set to."
        case .system: "Match the macOS appearance."
        }
    }

    var displaySymbol: String {
        switch self {
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        case .system: "circle.lefthalf.filled"
        }
    }
}

private extension ClockStyle {
    var displayTitle: String {
        switch self {
        case .twelveHour: "12-hour"
        case .twentyFourHour: "24-hour"
        }
    }

    var displayExample: String {
        switch self {
        case .twelveHour: "Shows times like 4:00pm."
        case .twentyFourHour: "Shows times like 16:00."
        }
    }
}

private extension PingMethod {
    var displayTitle: String {
        switch self {
        case .terminal: "Controlled terminal"
        case .headless: "Programmatic CLI"
        case .sdk: "SDK"
        case .custom: "Custom command"
        // The list is already scoped to a provider, so no "Claude" prefix.
        case .routine: "Cloud routine"
        }
    }

    var displaySymbol: String {
        switch self {
        case .terminal: "terminal"
        case .headless: "chevron.left.forwardslash.chevron.right"
        case .sdk: "shippingbox"
        case .custom: "wrench.and.screwdriver"
        case .routine: "cloud.fill"
        }
    }

    func displaySubtitle(for provider: Provider, setupCommand: String?) -> String {
        switch self {
        case .terminal:
            return "Drives the real interactive TUI — the first method verified to anchor."
        case .headless:
            return provider == .claude
                ? "claude -p — the default: a lighter, non-interactive turn with structured output and nothing extra to install."
                : "codex exec — the default: a lighter, non-interactive turn with structured output and nothing extra to install."
        case .sdk:
            let sdk = provider == .claude ? "Claude Agent SDK" : "Codex SDK"
            return "Install the \(sdk) once: \(setupCommand ?? "")"
        case .custom:
            let home = provider == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME"
            return "Runs your own executable — say a daily eval — with \(home) set to the account's home, so real work anchors the window. Arguments only, no shell."
        case .routine:
            return "A one-shot claude.ai routine anchors every scheduled slot from Anthropic's cloud. No local ping runs, so a sleeping Mac still anchors."
        }
    }
}

/// The `custom` method's command line: one text field parsed into argv
/// (`CustomPingCommand.parse` — quote-aware, never a shell string), a
/// "Choose…" picker for the executable, and inline validation.
///
/// Saving is explicit (Return, or picking a file) rather than per keystroke:
/// half-typed lines like `/bin/zsh -lc 'echo` would otherwise be saved as
/// whatever happened to parse along the way. Only a line that parses *and*
/// points at an executable file is ever written.
private struct CustomCommandField: View {
    @Bindable var model: AppModel
    let provider: Provider
    @State private var text: String = ""
    @State private var loaded = false

    var body: some View {
        let state = validation
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                TextField("/path/to/your-eval.sh --flag value", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit(save)
                Button("Choose…", action: choose)
            }
            Text(state.text)
                .font(.system(size: 11.5))
                .foregroundStyle(state.tint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 51)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            text = model.customCommand(for: provider)?.commandLine ?? ""
        }
    }

    private var saved: CustomPingCommand? { model.customCommand(for: provider) }

    private var validation: (text: String, tint: Color) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ("Absolute path first, then arguments. Quote with '…' or \"…\". For pipes or &&, point at a script. Scheduled runs don't load your shell profile.", Color.secondary)
        }
        do {
            let parsed = try CustomPingCommand.parse(text)
            if parsed == saved {
                let args = parsed.arguments.count
                return ("Saved — runs \(parsed.executable)\(args == 0 ? "" : " with \(args) argument\(args == 1 ? "" : "s")").",
                        Theme.success)
            }
            return ("Press Return to save.", Color.secondary)
        } catch {
            return ("\(error)", Theme.warning)
        }
    }

    private func save() {
        guard let parsed = try? CustomPingCommand.parse(text) else { return }
        model.setCustomCommand(parsed, for: provider)
        text = parsed.commandLine
    }

    /// Swap in the picked executable, keeping any arguments already typed.
    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = "Choose"
        panel.message = "Pick the executable the custom ping runs."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let arguments = Array(((try? CustomPingCommand.tokenize(text)) ?? []).dropFirst())
        text = CustomPingCommand(executable: url.path, arguments: arguments).commandLine
        save()
    }
}

/// The "Wake Mac for pings" switch, styled like the radio cards around it. The
/// caption is live state, not static copy: it names exactly what (if anything)
/// stands between the user and a Mac that wakes — a pending System Settings
/// approval, a stale classic install, or nothing but the next armed wake.
private struct WakeToggleCard: View {
    @Bindable var model: AppModel

    var body: some View {
        let caption = self.caption
        return HStack(spacing: 12) {
            Image(systemName: "powersleep")
                .font(.system(size: 16))
                .foregroundStyle(model.wakeEnabled ? Color.white : Color.secondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(model.wakeEnabled ? Theme.accent : Color.primary.opacity(0.07)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Wake Mac for pings")
                    .font(.system(size: 13.5, weight: .semibold))
                Text("Asleep and **charging**: wakes the Mac just before each ping, then lets it sleep again. One-time System Settings approval.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(caption.text)
                    .font(.system(size: 12))
                    .foregroundStyle(caption.tint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("Wake Mac for pings", isOn: Binding(
                get: { model.wakeEnabled },
                set: { model.setWakeEnabled($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color.primary.opacity(0.02)))
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(model.wakeEnabled ? Theme.accent.opacity(0.6) : Color.primary.opacity(0.08),
                              lineWidth: model.wakeEnabled ? 1.5 : 1))
    }

    private var caption: (text: String, tint: Color) {
        guard model.wakeEnabled else {
            return ("Off — pings the Mac sleeps through are skipped.", Color.secondary)
        }
        guard let status = model.wakeStatus else { return ("Checking helper…", Color.secondary) }

        // A classic root install (sudo am wake install) owns the helper.
        if status.binaryInstalled && status.plistInstalled {
            if !status.rootMatches { return ("Helper serves another workspace — re-run sudo am wake install.", Theme.warning) }
            if status.needsUpdate { return ("Helper outdated — re-run sudo am wake install.", Theme.warning) }
            return activeCaption(status)
        }

        // Otherwise the bundled SMAppService daemon is the helper.
        switch model.wakeRegistration {
        case .enabled:
            return activeCaption(status)
        case .requiresApproval:
            return ("Waiting for approval: System Settings → Login Items → allow \u{201C}Agent Manager\u{201D}.", Theme.warning)
        case .notRegistered, .notFound:
            return ("Not registered — flip the toggle off and on.", Theme.warning)
        case .unavailable, nil:
            return ("Run once in a terminal: sudo am wake install.", Theme.warning)
        }
    }

    private func activeCaption(_ status: WakeHelperSetup.Status) -> (text: String, tint: Color) {
        if let next = status.scheduledWakes.first {
            return ("Active — next wake \(model.clockStyle.dayTimeString(next)).", Theme.success)
        }
        return ("Active — no wakes needed yet.", Theme.success)
    }
}

/// A selectable, radio-style card used across the Preferences sections.
///
/// `statusCaption` exists for the one option that is more than a preference —
/// Claude's cloud routine, which has live state behind it. Keeping it on the
/// shared card is what lets that option sit in the same list as the local
/// drivers instead of needing a card of its own.
private struct PreferenceRadioCard: View {
    let systemImage: String
    let title: String
    let subtitle: String
    let copyCommand: String?
    /// Live state for this option, shown under the subtitle — what's armed, or
    /// what stands in the way. Callers pass nil when there's nothing to say.
    let statusCaption: (text: String, tint: Color)?
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false
    @State private var copied = false

    init(
        systemImage: String,
        title: String,
        subtitle: String,
        copyCommand: String? = nil,
        statusCaption: (text: String, tint: Color)? = nil,
        isSelected: Bool,
        action: @escaping () -> Void)
    {
        self.systemImage = systemImage
        self.title = title
        self.subtitle = subtitle
        self.copyCommand = copyCommand
        self.statusCaption = statusCaption
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: action) {
                HStack(spacing: 12) {
                    Image(systemName: systemImage)
                        .font(.system(size: 16))
                        .foregroundStyle(isSelected ? Color.white : Color.secondary)
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(isSelected ? Theme.accent : Color.primary.opacity(0.07)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 13.5, weight: .semibold))
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let statusCaption {
                            Text(statusCaption.text)
                                .font(.system(size: 12))
                                .foregroundStyle(statusCaption.tint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(isSelected ? Theme.accent : Color.secondary.opacity(0.5))
                }
                .padding(.leading, 13)
                .padding(.trailing, copyCommand == nil ? 13 : 4)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if copyCommand != nil {
                Button(action: copySetupCommand) {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(copied ? Theme.success : Theme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help("Copy the one-time SDK setup command")
                .padding(.trailing, 11)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(hovering ? Color.primary.opacity(0.05) : Color.primary.opacity(0.02)))
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(isSelected ? Theme.accent.opacity(0.6) : Color.primary.opacity(0.08),
                              lineWidth: isSelected ? 1.5 : 1))
        .onHover { hovering = $0 }
    }

    private func copySetupCommand() {
        guard let copyCommand else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyCommand, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}
