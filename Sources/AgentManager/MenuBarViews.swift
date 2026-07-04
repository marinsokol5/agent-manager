import AgentManagerCore
import SwiftUI

// MARK: - Popover content

/// Merged dropdown: one line per agent — session usage left + when it resets.
struct MergedMenuView: View {
    let model: AppModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let accounts = model.menuBarAccounts
            if accounts.isEmpty {
                MenuEmptyState()
            } else {
                let recommendedID = model.recommendedAgent?.id
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(accounts) { account in
                        MergedAgentRow(
                            account: account,
                            reading: model.usageReadings[account.id],
                            isRecommended: account.id == recommendedID)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 4)
            }
            MenuActionFooter(model: model, close: close)
        }
        // 320, not 290: the recommended row's second line reads "Recommended ·
        // resets in 4h 20m" — ~4 chars wider than the plain "Session ·" rows —
        // and needs the extra width to stay on one line. `lineLimit(1)` in
        // `SessionSummary` is the backstop so it tail-truncates rather than
        // wrapping mid-word if a countdown ever runs long.
        .frame(width: 320)
        .menuBarPopoverBackground()
    }
}

/// One agent in the merged dropdown: glyph + label on top, session line below.
/// The cross-agent "run this now" recommendation is surfaced *inline* on the
/// recommended row's second line (see `SessionSummary`) rather than as a
/// separate header sentence — a fixed-width header truncates the agent name,
/// and the name is already on the row, so we tint the row instead.
private struct MergedAgentRow: View {
    let account: Account
    let reading: UsageReading?
    let isRecommended: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ProviderGlyph(provider: account.provider, size: 18)
                .foregroundStyle(Color(hex: account.color))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.label)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                SessionSummary(reading: reading,
                               isRecommended: isRecommended,
                               tint: Color(hex: account.color))
            }
            Spacer(minLength: 0)
            PercentBadge(remaining: reading?.effectivePrimaryRemainingPercent())
        }
    }
}

/// "Session · resets in …" one-liner used in the merged row. On the recommended
/// row the leading word becomes a tinted "Recommended" — that conveys the pick
/// without a separate header line, never collides with the trailing percent
/// badge, and never gets clipped by a long agent name (it lives on line two).
private struct SessionSummary: View {
    let reading: UsageReading?
    var isRecommended: Bool = false
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 5) {
            // The lead word (tinted "Recommended" on the pick, plain "Session"
            // otherwise) is fixed-size and high-priority so it's never the
            // element that truncates — the countdown gives up width first.
            Group {
                if isRecommended {
                    Text("Recommended")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint)
                } else {
                    Text("Session")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize()
            .layoutPriority(1)
            if let countdown = UsageReading.resetCountdown(to: reading?.primaryResetsAt) {
                Text("·").foregroundStyle(.tertiary)
                Text(countdown)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else if reading == nil {
                Text("· fetching…")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .lineLimit(1)
    }
}

/// Individual dropdown: the full picture for one agent — identity + both windows.
struct IndividualMenuView: View {
    let account: Account
    let model: AppModel
    let close: () -> Void

    private var reading: UsageReading? { model.usageReadings[account.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 13)

            VStack(alignment: .leading, spacing: 12) {
                UsageWindowRow(
                    title: "Session", subtitle: "5-hour window",
                    remaining: reading?.effectivePrimaryRemainingPercent(), resetsAt: reading?.primaryResetsAt)
                UsageWindowRow(
                    title: "Weekly", subtitle: "7-day window",
                    remaining: reading?.effectiveSecondaryRemainingPercent(), resetsAt: reading?.secondaryResetsAt)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 4)

            if let reading {
                Text("Updated \(reading.freshnessLabel())")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 2)
            }

            MenuActionFooter(model: model, close: close)
        }
        .frame(width: 300)
        .menuBarPopoverBackground()
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 11) {
            ProviderGlyph(provider: account.provider, size: 24)
                .foregroundStyle(Color(hex: account.color))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.label)
                    .font(.system(size: 15, weight: .bold))
                    .lineLimit(1)
                Text("\(account.provider.displayName) · \(account.id)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let email = account.identityEmail, !email.isEmpty {
                    Text(email)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Shared pieces

/// A labeled usage window: title + % left + a slim bar + reset countdown.
private struct UsageWindowRow: View {
    let title: String
    let subtitle: String
    let remaining: Int?
    let resetsAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                Spacer()
                if let remaining {
                    HStack(spacing: 4) {
                        if remaining <= 20 {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.warning)
                        }
                        Text("\(remaining)% left")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(remaining > 20 ? .primary : Theme.warning)
                    }
                } else {
                    Text("—").font(.system(size: 12.5)).foregroundStyle(.tertiary)
                }
            }
            UsageBar(fraction: remaining.map { Double($0) / 100 } ?? 0, warning: (remaining ?? 100) <= 20)
            if let countdown = UsageReading.resetCountdown(to: resetsAt) {
                Text(countdown)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Slim capsule progress bar showing remaining headroom.
private struct UsageBar: View {
    let fraction: Double
    let warning: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(warning ? Theme.warning : Theme.accent)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
                    .animation(.easeOut(duration: 0.45), value: fraction)
            }
        }
        .frame(height: 5)
    }
}

/// Pill showing remaining % at a glance, tinted for low headroom. Low headroom
/// also gets a warning glyph so the alert reads without color discrimination.
private struct PercentBadge: View {
    let remaining: Int?

    private var isLow: Bool { (remaining ?? 100) <= 20 }

    var body: some View {
        HStack(spacing: 3) {
            if isLow {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
            }
            Text(remaining.map { "\($0)%" } ?? "—")
                .font(.system(size: 12, weight: .bold, design: .rounded))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.14)))
    }

    private var color: Color {
        guard let remaining else { return .secondary }
        return remaining > 20 ? Theme.accent : Theme.warning
    }
}

private struct MenuEmptyState: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.2.slash")
                .foregroundStyle(.tertiary)
            Text("No connected agents")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }
}

/// The three actions present in every menu, regardless of mode.
struct MenuActionFooter: View {
    let model: AppModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider().padding(.top, 8)
            MenuActionButton(title: "Refresh usage", systemImage: "arrow.clockwise") {
                model.refreshUsage(force: true)
                close()
            }
            MenuActionButton(title: "Open Agent Manager", systemImage: "macwindow") {
                model.presentMainWindow?()
                close()
            }
            Divider().padding(.horizontal, 8)
            MenuActionButton(title: "Quit", systemImage: "power") {
                NSApp.terminate(nil)
            }
        }
        .padding(.bottom, 6)
    }
}

extension View {
    /// Opaque, light card background so the popover reads as solid white rather
    /// than the default translucent menu material.
    func menuBarPopoverBackground() -> some View {
        background(Color(nsColor: .textBackgroundColor), ignoresSafeAreaEdges: .all)
    }
}

/// A full-width, hover-highlighting menu row — the macOS menu look in SwiftUI.
private struct MenuActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering ? Theme.accent.opacity(0.16) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { hovering = $0 }
    }
}
