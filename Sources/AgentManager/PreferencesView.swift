import AgentManagerCore
import AppKit
import SwiftUI

/// The **Preferences** screen. Hosts the set-once "Wake Mac for pings" opt-in
/// (it lives here rather than next to the Scheduler toggle because you flip it
/// once and forget it — ongoing health shows on the Monitoring screen), the
/// menu-bar display mode, the theme, and the clock style.
struct PreferencesView: View {
    @Bindable var model: AppModel
    @State private var pingMethodProvider: Provider = .claude

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                wakeSection
                pingMethodSection
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
            subtitle: "Wake this Mac for local pings, or configure a Claude cloud routine for scheduled Claude windows.")
        {
            WakeToggleCard(model: model)
            ClaudeCloudRoutineCard(model: model)
        }
    }

    private var pingMethodSection: some View {
        section(
            title: "Local ping method",
            subtitle: "Used by Test ping and scheduled pings that run on this Mac. Choose separately per provider; scheduled runs still verify anchoring.")
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
            ForEach(PingMethod.allCases) { method in
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
                    isSelected: selection == method,
                    action: { select(method) })
            }
        }
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
        }
    }

    var displaySymbol: String {
        switch self {
        case .terminal: "terminal"
        case .headless: "chevron.left.forwardslash.chevron.right"
        case .sdk: "shippingbox"
        }
    }

    func displaySubtitle(for provider: Provider, setupCommand: String?) -> String {
        switch self {
        case .terminal:
            return "Drives the real interactive TUI — the verified-anchoring default."
        case .headless:
            return provider == .claude
                ? "claude -p — a lighter, non-interactive turn with structured output."
                : "codex exec — a lighter, non-interactive turn with structured output."
        case .sdk:
            let sdk = provider == .claude ? "Claude Agent SDK" : "Codex SDK"
            return "Install the \(sdk) once: \(setupCommand ?? "")"
        }
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

/// The experimental Claude cloud-routine switch, styled like `WakeToggleCard`
/// and kept with the other scheduled-ping controls. Its mode selector makes
/// the scheduling boundary explicit: fallback supplements local scheduled
/// turns, while Routines only replaces those turns without changing Test ping.
/// The caption reports what's armed (from `cloud-fallback-state.json`), the
/// last sync error, or why nothing will arm.
private struct ClaudeCloudRoutineCard: View {
    @Bindable var model: AppModel

    var body: some View {
        let caption = self.caption
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "cloud.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(model.cloudFallbackEnabled ? Color.white : Color.secondary)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(model.cloudFallbackEnabled ? Theme.accent : Color.primary.opacity(0.07)))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Claude cloud routine")
                            .font(.system(size: 13.5, weight: .semibold))
                        Text("CLAUDE")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.5)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Theme.accent.opacity(0.15)))
                            .foregroundStyle(Theme.accent)
                        Text("EXPERIMENTAL")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.5)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Theme.warning.opacity(0.15)))
                            .foregroundStyle(Theme.warning)
                    }
                    Text("Adds a one-shot claude.ai routine to scheduled Claude slots. Use it as a fallback for missed local pings, or let routines handle scheduled pings entirely.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(caption.text)
                        .font(.system(size: 12))
                        .foregroundStyle(caption.tint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("Claude cloud routine", isOn: Binding(
                    get: { model.cloudFallbackEnabled },
                    set: { model.setCloudFallbackEnabled($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            if model.cloudFallbackEnabled {
                Divider().padding(.leading, 38)
                VStack(alignment: .leading, spacing: 7) {
                    Text("Scheduled Claude mode")
                        .font(.system(size: 12.5, weight: .semibold))
                    Picker("Scheduled Claude mode", selection: Binding(
                        get: { model.cloudPrimaryEnabled },
                        set: { model.setCloudPrimaryEnabled($0) })) {
                        Text("Fallback").tag(false)
                        Text("Routines only").tag(true)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 260, alignment: .leading)
                    Text(modeDescription)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 38)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color.primary.opacity(0.02)))
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(model.cloudFallbackEnabled ? Theme.accent.opacity(0.6) : Color.primary.opacity(0.08),
                              lineWidth: model.cloudFallbackEnabled ? 1.5 : 1))
    }

    private var caption: (text: String, tint: Color) {
        guard model.cloudFallbackEnabled else {
            return ("Off — scheduled Claude pings use the local method only.", Color.secondary)
        }
        guard model.accounts.contains(where: { $0.provider.supportsCloudAnchorRoutines && $0.status == .connected }) else {
            return ("No connected Claude account — nothing to cover.", Theme.warning)
        }
        guard model.schedulerActive else {
            return ("Waiting for the Scheduler — turn it on to arm.", Theme.warning)
        }
        let entries = model.cloudFallbackState?.accounts ?? [:]
        if let bad = entries.values.compactMap(\.lastError).first {
            return ("Sync problem: \(bad) — see Monitoring.", Theme.warning)
        }
        let armed = entries.values.compactMap(\.armedFor).filter { $0 > Date() }.sorted()
        if model.cloudPrimaryEnabled {
            if let next = armed.first {
                return ("Routines only — cloud handles the next scheduled Claude slot at \(model.clockStyle.dayTimeString(next)); Test ping stays local.", Theme.success)
            }
            return ("Routines only — cloud handles scheduled Claude slots; Test ping stays local.", Theme.success)
        }
        if let next = armed.first {
            return ("Fallback — covers the local ping at \(model.clockStyle.dayTimeString(next.addingTimeInterval(-CloudFallbackPlanner.lead))); runs only if the Mac misses it.", Theme.success)
        }
        return ("Fallback — targets five minutes after each scheduled local Claude ping.", Theme.success)
    }

    private var modeDescription: String {
        if model.cloudPrimaryEnabled {
            return "Cloud handles scheduled Claude slots instead of local pings. Test ping still uses the selected local method."
        }
        return "Scheduled Claude pings use the selected local method. The cloud routine runs only when the Mac misses one."
    }
}

/// A selectable, radio-style card used across the Preferences sections.
private struct PreferenceRadioCard: View {
    let systemImage: String
    let title: String
    let subtitle: String
    let copyCommand: String?
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false
    @State private var copied = false

    init(
        systemImage: String,
        title: String,
        subtitle: String,
        copyCommand: String? = nil,
        isSelected: Bool,
        action: @escaping () -> Void)
    {
        self.systemImage = systemImage
        self.title = title
        self.subtitle = subtitle
        self.copyCommand = copyCommand
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
