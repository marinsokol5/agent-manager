import AgentManagerCore
import SwiftUI

/// The **Preferences** screen. Hosts the set-once "Wake Mac for pings" opt-in
/// (it lives here rather than next to the Scheduler toggle because you flip it
/// once and forget it — ongoing health shows on the Monitoring screen), the
/// menu-bar display mode, the theme, and the clock style.
struct PreferencesView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
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
            subtitle: "Safety nets for pings that land while the Mac is asleep — which one applies depends on whether it's plugged in.")
        {
            WakeToggleCard(model: model)
            ClaudeRoutineFallbackCard(model: model)
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

/// The experimental "Claude Routine fallback" switch, styled like
/// `WakeToggleCard` and living right under it — the two cards split the
/// sleeping-Mac problem by power source (charging → wake helper; battery →
/// this). The second caption line is live state: what's armed (from
/// `cloud-fallback-state.json`), the last sync error, or why nothing will arm.
private struct ClaudeRoutineFallbackCard: View {
    @Bindable var model: AppModel

    var body: some View {
        let caption = self.caption
        return HStack(spacing: 12) {
            Image(systemName: "cloud.fill")
                .font(.system(size: 16))
                .foregroundStyle(model.cloudFallbackEnabled ? Color.white : Color.secondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(model.cloudFallbackEnabled ? Theme.accent : Color.primary.opacity(0.07)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Claude Routine fallback")
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
                Text("Asleep on **battery**: no wake is possible, so your claude.ai account runs the ping in the cloud instead.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(caption.text)
                    .font(.system(size: 12))
                    .foregroundStyle(caption.tint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("Claude Routine fallback", isOn: Binding(
                get: { model.cloudFallbackEnabled },
                set: { model.setCloudFallbackEnabled($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
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
            return ("Off — pings missed on battery stay skipped.", Color.secondary)
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
        if let next = armed.first {
            return ("Active — covers the next ping at \(model.clockStyle.dayTimeString(next.addingTimeInterval(-CloudFallbackPlanner.lead))); runs only if the Mac misses it.", Theme.success)
        }
        return ("Active — arms before each scheduled Claude ping.", Theme.success)
    }
}

/// A selectable, radio-style card used across the Preferences sections.
private struct PreferenceRadioCard: View {
    let systemImage: String
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
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
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .fill(hovering ? Color.primary.opacity(0.05) : Color.primary.opacity(0.02)))
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(isSelected ? Theme.accent.opacity(0.6) : Color.primary.opacity(0.08),
                                  lineWidth: isSelected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
