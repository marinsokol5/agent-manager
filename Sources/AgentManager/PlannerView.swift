import AgentManagerCore
import SwiftUI

/// The **Planner** screen — two stacked sections sharing a selected day:
///   • **Working hours** — drag-paint the 7×24 week grid (full width).
///   • **Daily consumption** — the selected day's ping schedule plus a horizontal
///     timeline showing how fresh budgets tile that day, updating as you paint.
/// No apply step: while the Scheduler is on, the resident daemon picks up every
/// repaint on its next tick.
struct PlannerView: View {
    @Bindable var model: AppModel
    @State private var selectedDay: Int = WeekTime.todayMon0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section("Working hours", workingHoursSubtitle) {
                    WeekPaintGrid(model: model, selectedDay: $selectedDay)
                }

                Divider()

                section("Daily consumption",
                        "When each agent pings on the selected day and which fresh token batch covers each stretch — click a day above or use the arrows.") {
                    DayConsumptionTimeline(model: model, day: $selectedDay)
                }

            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
        }
    }

    /// The "Working hours" description. Under "first ping of the day only" the
    /// ping list below shows one ping per account per day, so the off-mode
    /// promise of re-pinging to tile the day would contradict it.
    private var workingHoursSubtitle: String {
        if model.firstPingOfDayOnly {
            return "Drag to paint the hours you actually work. The planner anchors a fresh budget just before each workday; later windows start when you first use the account."
        }
        return "Drag to paint the hours you actually work. The planner anchors a fresh budget just before each block and re-pings every \(model.schedule.windowMinutes / 60)h so capacity tiles your day."
    }

    /// A titled section: bold heading + one-line description, then the content.
    private func section(_ title: String, _ subtitle: String,
                         @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.Font.heading)
                Text(subtitle)
                    .font(Theme.Font.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
    }

}
