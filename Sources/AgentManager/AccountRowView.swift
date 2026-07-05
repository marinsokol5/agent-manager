import AgentManagerCore
import AppKit
import SwiftUI

/// One account in the Agents list. Collapsed, it shows the priority rank +
/// reorder arrows, the color dot, label/identity, and the status badge. Click
/// anywhere on the header (or the chevron on the right) to expand a drawer that
/// holds every action — Ping/Launch/Log in plus the management menu — and a
/// small metadata block. Ping/Launch are disabled unless the account is
/// `Connected` (matching the design's state machine).
struct AccountRowView: View {
    @Bindable var model: AppModel
    let account: Account
    /// 0-based position in the priority order, and the total count — drives the
    /// rank badge and enables/disables the reorder arrows.
    let index: Int
    let total: Int

    @State private var hovering = false
    @State private var copiedCommand = false
    @State private var copiedHome = false
    @State private var copiedTracking = false
    @State private var confirmingRemove = false
    @State private var showingLogin = false
    @State private var showingEdit = false

    private var isBusy: Bool { model.busyAccountIDs.contains(account.id) }
    private var isConnected: Bool { account.status == .connected }
    /// Single-open accordion driven by the model, so the sidebar (and other rows)
    /// can collapse this one and expand another.
    private var isExpanded: Bool { model.expandedAgentID == account.id }

    var body: some View {
        VStack(spacing: 0) {
            header

            if isExpanded {
                Divider().opacity(0.6)
                expandedDrawer
                    .transition(.opacity)
            }
        }
        .amCard(hovering: hovering)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .alert("Remove \(account.label)?", isPresented: $confirmingRemove) {
            Button("Remove (keep home)") { model.remove(account, purge: false) }
            Button("Remove & delete home", role: .destructive) { model.remove(account, purge: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The managed home is at \(account.home).")
        }
        .sheet(isPresented: $showingLogin) {
            LoginSheet(model: model, account: account)
        }
        .sheet(isPresented: $showingEdit) {
            EditAgentSheet(model: model, account: account)
        }
    }

    // MARK: Collapsed header

    /// Always-visible summary. Tapping anywhere that isn't a control toggles the
    /// drawer; the chevron on the right is an explicit affordance for the same.
    private var header: some View {
        HStack(spacing: 12) {
            reorderControl

            ProviderGlyph(provider: account.provider, size: 18)
                .foregroundStyle(Color(hex: account.color))
                .frame(width: 22)
                .help("\(account.provider.displayName) · tinted with this agent's color")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(account.label).font(.system(size: 14, weight: .semibold))
                    Text(account.provider.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Capsule())
                }
                HStack(spacing: 6) {
                    Text(account.id)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if let email = account.identityEmail {
                        Text("·").foregroundStyle(.tertiary)
                        Text(email)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            Spacer(minLength: 8)

            statusBadge

            expandToggle
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { toggleExpanded() }
    }

    /// Priority rank number + up/down arrows to re-prioritize this agent. Plain
    /// side-by-side bordered buttons, matching the rest of the row's controls.
    private var reorderControl: some View {
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.system(size: 15, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(Color(hex: account.color))
                .frame(minWidth: 16, alignment: .trailing)
            HStack(spacing: 4) {
                Button { model.moveAccount(account, by: -1) } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(index == 0)
                Button { model.moveAccount(account, by: 1) } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(index == total - 1)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Reorder priority — #1's token windows are filled first")
        }
    }

    private var statusBadge: some View {
        AMBadge(
            text: account.status.displayName,
            systemImage: account.status.systemImage,
            tint: account.status.tint,
            loading: isBusy)
    }

    /// Explicit expand/collapse affordance on the right edge of the header.
    private var expandToggle: some View {
        Button { toggleExpanded() } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.primary.opacity(hovering || isExpanded ? 0.06 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Collapse" : "Expand")
    }

    private func toggleExpanded() {
        withAnimation(.snappy(duration: 0.2)) {
            model.expandedAgentID = isExpanded ? nil : account.id
        }
    }

    // MARK: Expanded drawer

    @ViewBuilder
    private var expandedDrawer: some View {
        VStack(alignment: .leading, spacing: 14) {
            FlowLayout(hSpacing: 8, vSpacing: 8) {
                if isConnected {
                    Button { copyRunCommand() } label: {
                        Label(copiedCommand ? "Copied" : "Copy run command",
                              systemImage: copiedCommand ? "checkmark" : "doc.on.doc")
                    }
                    .help("Copy the CLI command to run this agent (\(account.runCommand))")

                    Button { model.ping(account) } label: {
                        Label("Ping", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .disabled(isBusy)
                    .help("Anchor this account's 5h window with a tiny interactive turn")
                } else {
                    Button { showingLogin = true } label: {
                        Label("Log in", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Log this account in")
                }

                Button { showingEdit = true } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .help("Edit this agent's label, color, and refresh settings")
                Button { model.togglePinned(account) } label: {
                    Label(account.pinned ? "Unpin from menu bar" : "Pin to menu bar",
                          systemImage: account.pinned ? "pin.slash" : "pin")
                }
                .help(account.pinned
                    ? "Hide this account from the menu-bar compact display"
                    : "Show this account in the menu-bar compact display")
                Button { model.verify(account) } label: {
                    Label("Verify identity", systemImage: "checkmark.shield")
                }
                .help("Check the logged-in identity still matches this account")
                Button { model.revealHome(account) } label: {
                    Label("Reveal home in Finder", systemImage: "folder")
                }
                .help("Open this agent's managed config home (\(account.home)) in Finder")
                Button(role: .destructive) { confirmingRemove = true } label: {
                    Label("Remove", systemImage: "trash")
                }
                .help("Remove this agent (optionally deleting its managed home)")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            usageSection

            metadata

            trustPanel
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    // MARK: What this touches

    /// Makes this agent's footprint legible: the exact, isolated places it reads
    /// and writes, with the safety boundary spelled out. The trust story lives in
    /// the UI, not just the docs.
    private var trustPanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("What this touches")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            touchRow("house", "Config home", abbreviatingHome(account.home))
            touchRow("key.horizontal", credentialLabel, credentialValue)

            Text("All local. Tokens never leave this Mac, and your default \(account.provider.displayName) login is never modified or swapped.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .amCard(radius: Theme.Radius.sm)
    }

    private func touchRow(_ icon: String, _ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 16)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    /// Credential location differs by provider: Claude's token lives in the login
    /// Keychain (keyed to this home); Codex's lives in a file inside the home.
    private var credentialLabel: String {
        account.provider == .claude ? "Keychain" : "Credential"
    }

    private var credentialValue: String {
        switch account.provider {
        case .claude:
            return account.keychainService ?? "Claude Code-credentials (this home)"
        case .codex:
            return "\(account.provider.identityFileName) (in home)"
        }
    }

    // MARK: Usage

    @ViewBuilder
    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Usage")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                usageFreshness
                Button { model.refreshUsage(for: account) } label: {
                    if model.isRefreshingUsage(account) {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(!isConnected || model.isRefreshingUsage(account))
                .help("Refresh this agent's usage now")
            }

            if !isConnected {
                Text("Connect this agent to see token-window usage.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            } else if let reading = model.usageReadings[account.id] {
                HStack(alignment: .top, spacing: 16) {
                    usageBar(title: "Session · 5h",
                             remainingPercent: reading.effectivePrimaryRemainingPercent(),
                             resetsAt: reading.primaryResetsAt)
                    usageBar(title: "Weekly · 7d",
                             remainingPercent: reading.effectiveSecondaryRemainingPercent(),
                             resetsAt: reading.secondaryResetsAt)
                }
            } else {
                Text(model.usageErrors[account.id] ?? "Fetching usage…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(model.usageErrors[account.id] != nil
                        ? Theme.warning : Color.secondary)
            }
        }
    }

    /// "Updated Xm ago · auto every 5m" / "· manual" footer for the usage block.
    @ViewBuilder
    private var usageFreshness: some View {
        if isConnected, let reading = model.usageReadings[account.id] {
            let cadence = account.usageAutoRefreshEnabled
                ? "auto every \(Self.cadenceLabel(account.usageRefreshInterval))"
                : "manual"
            Text("Updated \(reading.freshnessLabel()) · \(cadence)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
    }

    private func usageBar(title: String, remainingPercent: Int?, resetsAt: Date?) -> some View {
        let fraction = Double(remainingPercent ?? 0) / 100
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if let left = remainingPercent {
                    Text("\(left)% left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .monospacedDigit()
                } else {
                    Text("—").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(Theme.accent)
                        .frame(width: max(0, min(1, fraction)) * geo.size.width)
                        .animation(.easeOut(duration: 0.45), value: fraction)
                }
            }
            .frame(height: 6)
            Text(Self.resetText(resetsAt, clockStyle: model.clockStyle))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Resets 4:32pm (in 2h 14m)" — absolute reset clock time plus the relative
    /// countdown. Shows a weekday for resets that aren't today (weekly window).
    /// `clockStyle` selects 12- vs 24-hour, shared with the `am` CLI's report.
    private static func resetText(_ date: Date?, clockStyle: ClockStyle) -> String {
        guard let date, date > Date(),
              let countdown = UsageReading.resetCountdown(to: date) else { return "No reset reported" }
        let time = clockStyle.timeString(date)
        let absolute = Calendar.current.isDateInToday(date)
            ? time
            : "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time)"
        let diff = countdown.replacingOccurrences(of: "resets ", with: "")
        return "Resets \(absolute) (\(diff))"
    }

    /// "Jun 25, 2026 4:20pm" — created/verified stamps in the details grid.
    /// The date part keeps the locale's spelling (it's a calendar date, not a
    /// clock time); only the time-of-day follows the 12/24-hour preference.
    private static func metaDateText(_ date: Date, clockStyle: ClockStyle) -> String {
        "\(date.formatted(date: .abbreviated, time: .omitted)) \(clockStyle.timeString(date))"
    }

    /// Compact cadence like "5m" / "90s" / "2h" for the refresh-interval note.
    private static func cadenceLabel(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s % 3600 == 0 { return "\(s / 3600)h" }
        if s % 60 == 0 { return "\(s / 60)m" }
        return "\(s)s"
    }

    private var metadata: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
            GridRow {
                metaLabel("Account")
                Text(account.identityEmail ?? "Not signed in")
                    .font(.system(size: 11))
                    .foregroundStyle(account.identityEmail != nil ? Color.secondary : Color(white: 0.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            GridRow {
                metaLabel("Home")
                HStack(spacing: 6) {
                    Text(abbreviatingHome(account.home))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button { copyHomePath() } label: {
                        Image(systemName: copiedHome ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundStyle(copiedHome ? Theme.success : Color.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Copy this agent's home path, shell-escaped to cd into")
                }
            }
            GridRow {
                metaLabel("Tracking")
                HStack(spacing: 6) {
                    Text(abbreviatingHome(account.effectiveSourceHome()))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help("Static config and session history are symlinked from here")
                    Button { copyTrackingPath() } label: {
                        Image(systemName: copiedTracking ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundStyle(copiedTracking ? Theme.success : Color.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Copy the source home path, shell-escaped to cd into")
                }
            }
            GridRow {
                metaLabel("Run")
                HStack(spacing: 6) {
                    Text(account.runCommand)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button { copyRunCommand() } label: {
                        Image(systemName: copiedCommand ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundStyle(copiedCommand ? Theme.success : Color.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Copy the command to run this agent")
                }
            }
            GridRow {
                metaLabel("Created")
                Text(Self.metaDateText(account.createdAt, clockStyle: model.clockStyle))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            GridRow {
                metaLabel("Last verified")
                Text(account.lastVerifiedAt.map { Self.metaDateText($0, clockStyle: model.clockStyle) } ?? "Never")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func metaLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.tertiary)
            .gridColumnAlignment(.leading)
    }

    /// Copy the `am run <id>` command to the clipboard and flash a checkmark.
    private func copyRunCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(account.runCommand, forType: .string)
        copiedCommand = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            copiedCommand = false
        }
    }

    /// Copy the managed home path (shell-escaped, so the `Application Support`
    /// space and any metacharacters paste cleanly to cd into) and flash a check.
    private func copyHomePath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(account.homeShellQuoted, forType: .string)
        copiedHome = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            copiedHome = false
        }
    }

    /// Copy the source ("Tracking") home path, shell-escaped so it pastes cleanly
    /// to cd into, and flash a check.
    private func copyTrackingPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(account.effectiveSourceHome().singleQuotedForShell, forType: .string)
        copiedTracking = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            copiedTracking = false
        }
    }

    /// Collapse a leading home-directory prefix to `~`, so the Home and Tracking
    /// paths read consistently (and shorter) in the row. The copy button still
    /// yields the full absolute path to `cd` into.
    private func abbreviatingHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// A minimal flow layout: lays subviews left-to-right and wraps to a new line
/// when the next subview would overflow the proposed width. Used for the
/// expanded row's action buttons so they reflow when the window is narrow.
struct FlowLayout: Layout {
    var hSpacing: CGFloat = 8
    var vSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var maxRowWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let needed = rowWidth == 0 ? size.width : rowWidth + hSpacing + size.width
            if needed > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + vSpacing
                maxRowWidth = max(maxRowWidth, rowWidth)
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth = needed
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        maxRowWidth = max(maxRowWidth, rowWidth)
        return CGSize(width: maxWidth == .infinity ? maxRowWidth : maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + vSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + hSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
