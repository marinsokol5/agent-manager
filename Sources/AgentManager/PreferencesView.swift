import AgentManagerCore
import AppKit
import SwiftUI

/// The **Preferences** screen. Hosts the ping method — a default per provider,
/// overridable per account (including Claude's cloud routine — see
/// `pingMethodSection`), the set-once "Wake Mac
/// for pings" opt-in (it lives here rather than next to the Scheduler toggle
/// because you flip it once and forget it — ongoing health shows on the
/// Monitoring screen), the menu-bar display mode, the theme, and the clock
/// style.
struct PreferencesView: View {
    @Bindable var model: AppModel
    /// Which ping-method setting the section is showing: a provider's default
    /// or one account's override of it.
    @State private var pingMethodScope: PingMethodScope = .provider(.claude)

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
    /// scheduler stops running local Claude turns for those accounts entirely.
    ///
    /// One compact scope menu picks *whose* answer is shown: a provider's
    /// default ("All Claude accounts"), or a single account's override of it.
    /// A menu rather than the old segmented control because it has to scale to
    /// however many accounts there are; everything below it is the same card
    /// list either way, so overriding one account costs no new screen.
    private var pingMethodSection: some View {
        let scope = resolvedScope
        return section(
            title: "Ping method",
            subtitle: "How each account's 5-hour window gets anchored — a default per provider, overridable per account. Scheduled runs always verify anchoring; Test ping always runs a local turn.")
        {
            Picker("Applies to", selection: Binding(
                get: { scope },
                set: { pingMethodScope = $0 }))
            {
                // One section per provider, its "All … accounts" default first
                // and selectable, then that provider's accounts — grouped by the
                // menu itself rather than by indenting titles with spaces (which
                // the collapsed popup button would show).
                ForEach(Provider.allCases, id: \.self) { provider in
                    Section(provider.displayName) {
                        Text("All \(provider.displayName) accounts").tag(PingMethodScope.provider(provider))
                        ForEach(model.accounts.filter { $0.provider == provider }) { account in
                            Text(scopeMenuTitle(for: account))
                                .tag(PingMethodScope.account(id: account.id, provider: provider))
                        }
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)

            // Inheriting is a choice in the same list, first: picking it
            // removes the override, so there is no separate "reset" control.
            if case .account = scope {
                let provider = scope.provider
                PreferenceRadioCard(
                    systemImage: "arrow.uturn.up",
                    title: "Same as all \(provider.displayName) accounts",
                    subtitle: "Currently \(prefs.pingMethod(for: provider).displayTitle). Follows that default when it changes.",
                    isSelected: prefs.pingMethod(in: scope) == nil,
                    action: { model.setPingMethod(nil, in: scope) })
            }
            pingMethodGroup(
                scope: scope,
                selection: prefs.pingMethod(in: scope),
                select: { model.setPingMethod($0, in: scope) })
            if case let .provider(provider) = scope, let line = overriddenLine(provider: provider) {
                Text(line)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var prefs: Preferences { model.pingPreferences }

    /// The scope actually shown: the picked one, unless it names an account
    /// that no longer exists (removed while this screen was open) — then that
    /// account's provider default.
    private var resolvedScope: PingMethodScope {
        if case let .account(id, provider) = pingMethodScope,
           !model.accounts.contains(where: { $0.id == id }) {
            return .provider(provider)
        }
        return pingMethodScope
    }

    /// An account's entry in the scope menu: its label, plus its own method
    /// when it overrides — so an override is visible
    /// from the menu itself, without opening each account.
    private func scopeMenuTitle(for account: Account) -> String {
        guard prefs.pingOverride(forAccount: account.id) != nil else { return account.label }
        return "\(account.label)  ·  \(prefs.pingMethod(forAccount: account.id, provider: account.provider).displayTitle)"
    }

    /// Under a provider's default: the accounts that don't follow it, so an
    /// override is never invisible from the scope it overrides.
    private func overriddenLine(provider: Provider) -> String? {
        let names = model.accounts
            .filter { $0.provider == provider && prefs.pingOverride(forAccount: $0.id) != nil }
            .map { "\($0.label) (\(prefs.pingMethod(forAccount: $0.id, provider: provider).displayTitle))" }
        guard !names.isEmpty else { return nil }
        return "Overridden for: \(names.joined(separator: ", "))"
    }

    private func pingMethodGroup(
        scope: PingMethodScope,
        selection: PingMethod?,
        select: @escaping (PingMethod) -> Void)
        -> some View
    {
        let provider = scope.provider
        return VStack(alignment: .leading, spacing: 8) {
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
                        ? cloudRoutineCaption(scope: scope)
                        : method == .custom && selection == .custom
                            ? customCommandCaption(scope: scope)
                            : nil,
                    isSelected: selection == method,
                    action: { select(method) })
                // The card is a Button, so the editable command lives under
                // it rather than inside it. Keyed by scope so switching the
                // scope menu reloads the field from that scope's own command.
                if method == .custom && selection == .custom {
                    CustomCommandField(model: model, scope: scope)
                        .id(scope)
                }
            }
        }
    }

    /// Selecting Custom without a usable command is allowed — you may pick the
    /// method first and the command second — but the card must say plainly
    /// that scheduled pings fail until one is set: never a silent dead method.
    /// The command is the scope's own: an overridden account never borrows
    /// its provider's.
    private func customCommandCaption(scope: PingMethodScope) -> (text: String, tint: Color) {
        guard let command = model.pingPreferences.customCommand(in: scope) else {
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
    /// order the daemon decides it (account → scheduler → plan). Scoped like
    /// the cards it hangs off: the provider default speaks for the Claude
    /// accounts that inherit it, an account scope for that one account.
    private func cloudRoutineCaption(scope: PingMethodScope) -> (text: String, tint: Color) {
        let inScope = model.accounts.filter { account in
            guard account.provider.supportsCloudAnchorRoutines else { return false }
            switch scope {
            case .provider: return prefs.pingOverride(forAccount: account.id) == nil
            case let .account(id, _): return account.id == id
            }
        }
        guard inScope.contains(where: { $0.status == .connected }) else {
            if case .account = scope {
                return ("This account isn't connected — nothing to anchor.", Theme.warning)
            }
            return ("No connected Claude account follows this default — nothing to anchor.", Theme.warning)
        }
        guard model.schedulerActive else {
            return ("Waiting for the Scheduler — turn it on to arm.", Theme.warning)
        }
        // Sorted by account id, not dictionary order: with two Claude accounts
        // erroring, an unordered pick would flip the caption between refreshes.
        let ids = Set(inScope.map(\.id))
        let entries = (model.cloudFallbackState?.accounts ?? [:])
            .filter { ids.contains($0.key) }
            .sorted(by: { $0.key < $1.key })
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
            return "Runs your own executable — say a daily eval — with \(home) set to the account's home, so real work anchors the window. Arguments only — or, if you tick it, run through your login shell."
        case .routine:
            return "A one-shot claude.ai routine anchors every scheduled slot from Anthropic's cloud. No local ping runs, so a sleeping Mac still anchors."
        }
    }
}

/// The `custom` method's command line, in either of `CustomPingCommand`'s
/// forms: by default one text field parsed into argv (`CustomPingCommand.parse`
/// — quote-aware, never a shell string) with a "Choose…" picker for the
/// executable; with "Run in my login shell" on, the same field takes a line in
/// the user's own shell's syntax, stored verbatim and run as `<shell> -l -c`
/// so their profile loads (see `LoginShell`).
///
/// Saving is explicit (Return, or picking a file) rather than per keystroke:
/// half-typed lines like `/bin/zsh -lc 'echo` would otherwise be saved as
/// whatever happened to parse along the way. Only a line that parses *and*
/// points at an executable file — or, in login-shell mode, a non-blank line
/// with a supported login shell — is ever written. Flipping the toggle only
/// converts the text in place; it never saves.
///
/// Scoped rather than per provider: the same field edits a provider's default
/// command or one overridden account's own — whichever the section shows.
private struct CustomCommandField: View {
    @Bindable var model: AppModel
    let scope: PingMethodScope
    @State private var text: String = ""
    @State private var useLoginShell = false
    @State private var loaded = false
    /// Read once per appearance: the user database doesn't change under an
    /// open Preferences window in any way worth polling for, and the runner
    /// re-reads it at every ping anyway.
    @State private var shell: Result<LoginShell, LoginShell.Problem> = LoginShell.resolve()

    var body: some View {
        let state = validation
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                TextField(
                    useLoginShell ? "cd ~/evals && npm run eval" : "/path/to/your-eval.sh --flag value",
                    text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit(save)
                if !useLoginShell {
                    Button("Choose…", action: choose)
                }
            }
            Toggle(isOn: Binding(get: { useLoginShell }, set: setLoginShell)) {
                Text("Run in my login shell (\(shellName))")
                    .font(.system(size: 12))
            }
            .toggleStyle(.checkbox)
            Text(state.text)
                .font(.system(size: 11.5))
                .foregroundStyle(state.tint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 51)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            shell = LoginShell.resolve()
            useLoginShell = saved?.isLoginShell ?? false
            text = saved?.commandLine ?? ""
        }
    }

    private var saved: CustomPingCommand? { model.pingPreferences.customCommand(in: scope) }

    /// The detected shell's name for the checkbox label — or, when it can't
    /// be used, the name of what was found, so the label never promises a
    /// shell the run would refuse.
    private var shellName: String {
        switch shell {
        case let .success(found): found.name
        case let .failure(.unsupported(name)): "\(name), unsupported"
        case .failure: "not found"
        }
    }

    private var validation: (text: String, tint: Color) {
        useLoginShell ? loginShellValidation : argvValidation
    }

    private var argvValidation: (text: String, tint: Color) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ("Absolute path first, then arguments. Quote with '…' or \"…\". For pipes or &&, point at a script or run it in your login shell. Scheduled runs don't load your shell profile.", Color.secondary)
        }
        do {
            let parsed = try CustomPingCommand.parse(text)
            if parsed == saved {
                let args = parsed.arguments.count
                return ("Saved — runs \(parsed.executable ?? "")\(args == 0 ? "" : " with \(args) argument\(args == 1 ? "" : "s")").",
                        Theme.success)
            }
            return ("Press Return to save.", Color.secondary)
        } catch {
            return ("\(error)", Theme.warning)
        }
    }

    private var loginShellValidation: (text: String, tint: Color) {
        let found: LoginShell
        switch shell {
        case let .success(s): found = s
        case let .failure(problem): return ("\(problem)", Theme.warning)
        }
        let how = "Runs as \(found.name) -l -c '…' from your home folder, so your shell config loads."
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ("Your shell's own syntax — pipes, &&, PATH lookups. \(how)", Color.secondary)
        }
        if saved == .loginShell(text) {
            return ("Saved. \(how)", Theme.success)
        }
        return ("Press Return to save. \(how)", Color.secondary)
    }

    private func save() {
        if useLoginShell {
            // Stored exactly as typed: it's in the user's shell's syntax, and
            // any normalization of ours could change what it means.
            guard case .success = shell,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            model.setCustomCommand(.loginShell(text), in: scope)
            return
        }
        guard let parsed = try? CustomPingCommand.parse(text) else { return }
        model.setCustomCommand(parsed, in: scope)
        text = parsed.commandLine
    }

    /// Convert the text in place where the other form can express it; never
    /// save. argv → line: rendered for the detected shell's family
    /// (`CustomPingCommand.loginShellLine(for:)`), which declines — leaving the
    /// text as typed — when fish would read the rendering as different words
    /// (a backslash inside fish single quotes is an escape). Line → argv:
    /// only if it parses as one (an absolute executable); otherwise the text
    /// stays and the validation line shows exactly why it isn't one.
    private func setLoginShell(_ on: Bool) {
        guard on != useLoginShell else { return }
        useLoginShell = on
        // Whatever parses as argv is rendered canonically; anything else is
        // left untouched.
        guard let parsed = try? CustomPingCommand.parse(text) else { return }
        if on, case let .success(found) = shell {
            if let line = parsed.loginShellLine(for: found.family) { text = line }
            return
        }
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
