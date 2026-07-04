import AgentManagerCore
import SwiftUI

/// The fixed left sidebar: brand, route nav (Agents shows a live count), the
/// run-now recommendation, the schedule controls, and the workspace clock.
struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 9) {
                AgentManagerLogoMark(size: 28)
                Text("Agent Manager")
                    .font(Theme.Font.brand)
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)

            VStack(spacing: 4) {
                ForEach(AppModel.Route.allCases) { route in
                    NavButton(
                        title: route.title,
                        systemImage: route.systemImage,
                        count: route == .agents ? model.accounts.count : nil,
                        isActive: model.route == route,
                        action: { model.route = route })
                }
            }

            Spacer()

            scheduleControls

            recommendation

            VStack(alignment: .leading, spacing: 8) {
                clock
            }
            .padding(.horizontal, 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 16)
        .frame(width: Theme.sidebarWidth)
        .background(.regularMaterial)
    }

    /// The scheduler master switch, parked at the bottom-left. There is no
    /// apply step anymore: while the switch is on, the resident daemon picks up
    /// calendar repaints and account changes on its own — the switch only
    /// carries intent (fire the painted plan, or don't). Off keeps the painted
    /// calendar and leaves the background agent idling.
    private var scheduleControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                if model.scheduleBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(model.schedulerActive ? Theme.accent : Color.secondary)
                }
                Text("Scheduler active")
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 4)
                // The switch state is optimistic (`schedulerActive`); the
                // trailing refreshMonitoring() snaps it back if Core disagrees.
                Toggle("Scheduler active", isOn: Binding(
                    get: { model.schedulerActive },
                    set: { model.setSchedulerActive($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(model.scheduleBusy || (!model.schedulerActive && model.scheduledAccounts.isEmpty))
            }
            Text(schedulerCaption.text)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(schedulerCaption.tint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .amCard(radius: Theme.Radius.sm)
        .padding(.horizontal, 8)
        .help("On: the background agent pings each connected account inside your painted hours — calendar and account changes apply live, no re-apply needed. Off: pings stop; your painted calendar is kept.")
    }


    /// One line under the switch saying what the scheduler will actually do.
    /// Counts come from live in-memory state (not the last status snapshot) so
    /// the caption doesn't lag the optimistic switch flip.
    private var schedulerCaption: (text: String, tint: Color) {
        if model.scheduleBusy { return ("working…", Color.secondary) }
        if model.schedulerActive {
            if let s = model.schedulerStatus, s.agentInstalled, !s.agentLoaded {
                return ("agent not loaded — see Monitoring", Theme.warning)
            }
            guard model.schedule.totalSelectedHours > 0 else {
                return ("no hours painted — nothing will fire", Color.secondary)
            }
            let count = model.scheduledAccounts.count
            return (count == 1 ? "1 account scheduled" : "\(count) accounts scheduled", Theme.success)
        }
        return model.scheduledAccounts.isEmpty
            ? ("connect an account first", Color.secondary)
            : ("off — pings won't fire", Color.secondary)
    }

    /// Live wall clock + timezone, so the now-line on the grid has context. Ticks
    /// once a second via `TimelineView` — no manual timer. Rendered through
    /// `ClockStyle` so it follows the 12/24-hour preference like every other time.
    private var clock: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Circle().fill(Theme.nowLine).frame(width: 6, height: 6)
                    Text(model.clockStyle.preciseTimeString(timeline.date))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                Text(timeline.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Text(TimeZone.current.identifier)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// The app's one ambient answer: which agent to run right now. Persistent
    /// across every route since it lives in the sidebar; clicking it jumps to that
    /// agent on the Agents screen. Hidden when there's no usable recommendation.
    @ViewBuilder
    private var recommendation: some View {
        if let agent = model.recommendedAgent {
            RecommendationCard(agent: agent, reading: model.usageReadings[agent.id]) {
                model.revealAgent(agent.id)
            }
            .padding(.horizontal, 8)
            .transition(.opacity)
        }
    }
}

/// The clickable "run this now" card in the sidebar footer. Shows the agent's id
/// (the thing you pass to `am run`), headroom, and reset countdown.
private struct RecommendationCard: View {
    let agent: Account
    let reading: UsageReading?
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text("RECOMMENDED")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .opacity(hovering ? 1 : 0)
                }
                HStack(spacing: 7) {
                    Circle().fill(Color(hex: agent.color)).frame(width: 9, height: 9)
                    Text(agent.id)
                        .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let pct = reading?.effectivePrimaryRemainingPercent() {
                        Text("\(pct)%")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.accent)
                            .monospacedDigit()
                    }
                }
                if let countdown = UsageReading.resetCountdown(to: reading?.primaryResetsAt) {
                    Text(countdown)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .amCard(radius: Theme.Radius.sm, hovering: hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("Show \(agent.id) on the Agents screen")
    }
}

private struct NavButton: View {
    let title: String
    let systemImage: String
    var count: Int?
    let isActive: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 13))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                Spacer(minLength: 4)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(isActive ? Color.white.opacity(0.25) : Color.primary.opacity(0.1))
                        .clipShape(Capsule())
                }
            }
            .foregroundStyle(isActive ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(isActive ? Theme.accent : (hovering ? Color.primary.opacity(0.06) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
