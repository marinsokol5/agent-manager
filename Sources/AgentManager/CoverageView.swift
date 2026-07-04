import AgentManagerCore
import SwiftUI

/// Which view of the day the consumption timeline shows.
enum CoverageMode: String, CaseIterable, Identifiable {
    case recommended = "Blocks"
    case windows = "Token windows"
    var id: String { rawValue }
}

/// The whole **Daily consumption** section body for one selected day: the day
/// picker (with the parallelism stepper on its trailing edge), the day's
/// plain-language ping schedule (whose color dots double as the legend), and a
/// compact **horizontal** 24-hour timeline (00 → 24 left-to-right) showing either
/// the recommended "use account X" rotation or each account's raw token windows
/// as colored time bars. Faint shading marks painted work hours; a live now-line
/// tracks today. Stacks under the week grid inside `PlannerView`, sharing the
/// selected `day`.
struct DayConsumptionTimeline: View {
    @Bindable var model: AppModel
    @Binding var day: Int
    @State private var mode: CoverageMode = .recommended

    private let laneHeight: CGFloat = 30
    private let axisHeight: CGFloat = 15

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if model.scheduledAccounts.isEmpty {
                note("Connect an account on the Agents screen to generate a ping schedule and see coverage.")
            } else {
                pingSchedule
                modePicker
                timeline
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Button { day = (day + 6) % 7 } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                Text(WorkSchedule.weekdayNames[day])
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(day == WeekTime.todayMon0 ? Theme.accent : .primary)
                    .frame(minWidth: 34)
                if hasWork(day) { Circle().fill(Theme.accent).frame(width: 5, height: 5) }
                Button { day = (day + 1) % 7 } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless)
            }

            Spacer(minLength: 0)

            parallelismStepper
        }
    }

    /// How many accounts run concurrently (parallel lanes). It sits in this
    /// section because it *shapes* the ping schedule below — fewer lanes rest
    /// spare accounts (they rotate in within a lane); the max keeps every account
    /// hot in parallel. Only meaningful with more than one connected account.
    @ViewBuilder
    private var parallelismStepper: some View {
        if model.parallelAccountCap > 1 {
            Stepper(
                value: Binding(get: { model.resolvedParallelism }, set: { model.setParallelism($0) }),
                in: 1...model.parallelAccountCap
            ) {
                Text("Run \(model.resolvedParallelism) of \(model.parallelAccountCap) in parallel")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .controlSize(.small)
            .fixedSize()
            .help("How many accounts run at the same time. Fewer lanes rest spare accounts (they rotate in within a lane); the max keeps every account hot in parallel.")
        }
    }

    /// The selected day's ping times per account — the "Claude — pings 05:00,
    /// 10:00" plain-language summary. Its color dots are the legend for the bars
    /// below. `fmtMin` keeps a pre-midnight anchor honest ("23:30 (-1d)").
    @ViewBuilder
    private var pingSchedule: some View {
        let plan = model.plan(forWeekday: day)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.scheduledAccounts) { account in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(Color(hex: account.color)).frame(width: 9, height: 9)
                    Text(account.label).font(.system(size: 12.5, weight: .semibold))
                    let times = (plan.accounts.first { $0.accountID == account.id }?.pings ?? [])
                        .map { fmtMin($0.atMin, clockStyle: model.clockStyle) }
                    Text(times.isEmpty ? "no pings" : "pings " + times.joined(separator: ", "))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var modePicker: some View {
        Picker("", selection: $mode) {
            ForEach(CoverageMode.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    // MARK: - timeline

    private var timeline: some View {
        // Bars don't depend on the clock, so compute them (and the lane count that
        // sets the row height) here; only the now-line ticks inside TimelineView.
        let bars = currentBars()
        let laneCount = max(bars.map(\.laneCount).max() ?? 1, 1)
        let blocks = model.schedule.blocks(forWeekday: day)
        let today = WeekTime.todayMon0
        let name = WorkSchedule.weekdayNames[day]
        let totalHeight = axisHeight + CGFloat(laneCount) * laneHeight

        return TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let nowMin = Self.minutes(from: timeline.date)
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, size in
                        drawBackground(ctx, size: size, blocks: blocks, laneCount: laneCount,
                                       isToday: today == day, nowMin: nowMin)
                    }
                    ForEach(bars) {
                        BarView(bar: $0, width: w, laneHeight: laneHeight, axisHeight: axisHeight)
                    }
                    if bars.isEmpty {
                        Text("No work hours for \(name) — paint some on the week grid above.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .position(x: w / 2, y: totalHeight / 2 + axisHeight / 2)
                    }
                }
            }
            .frame(height: totalHeight)
        }
        .frame(height: totalHeight)
    }

    /// One consumption bar plus its own instant hover tooltip.
    ///
    /// The tooltip is an *always-present* overlay toggled by `opacity`, and hover
    /// state is local to the bar. We deliberately do **not** insert/remove a view
    /// on hover: a view that appears under the cursor makes SwiftUI re-run
    /// hit-testing, which can flip the hover off-then-on forever and beachball the
    /// app. Opacity never changes the hit-test geometry, so this stays stable —
    /// and instant, unlike AppKit's ~1.5s `.help()` delay (the bars often can't
    /// fit their label, so hovering is the primary way to read them). The tooltip
    /// sits in the 6pt gap *outside* the bar so it never lands under the cursor.
    private struct BarView: View {
        let bar: ConsumptionBar
        let width: CGFloat
        let laneHeight: CGFloat
        let axisHeight: CGFloat
        @State private var showTip = false
        @State private var hoverTask: Task<Void, Never>?

        /// Hover dwell before the tooltip appears. Long enough that sweeping the
        /// pointer across bars doesn't flash labels; short enough to feel instant.
        private static let hoverDelay: Duration = .milliseconds(300)

        var body: some View {
            let x = DayConsumptionTimeline.xFor(bar.startMin, width: width)
            let barW = max(DayConsumptionTimeline.xFor(bar.endMin, width: width) - x - 2, 2)
            let h = laneHeight - 6
            let y = axisHeight + CGFloat(bar.lane) * laneHeight + laneHeight / 2

            return RoundedRectangle(cornerRadius: 5)
                .fill(bar.color.opacity(bar.laneCount > 1 ? 0.9 : 0.95))
                .frame(width: barW, height: h)
                .overlay(
                    // The legend maps color→account, so the bar just shows batch +
                    // span; hovering reveals the full account label.
                    VStack(spacing: 0) {
                        Text("Batch \(bar.batch)").font(.system(size: 9, weight: .bold))
                        Text(bar.timeLabel).font(.system(size: 8.5, weight: .medium)).opacity(0.9)
                    }
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .opacity(barW >= 58 ? 1 : 0))
                .overlay(alignment: .top) {
                    tooltip
                        .fixedSize()
                        .allowsHitTesting(false)
                        .opacity(showTip ? 1 : 0)
                        // Park the tooltip in the 6pt gap just above the bar — kept
                        // above (not flipped below) so it never covers the row under it.
                        .alignmentGuide(.top) { $0[.bottom] + 6 }
                }
                .contentShape(Rectangle())
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
                .position(x: x + barW / 2 + 1, y: y)
                // Float the hovered bar (and its tooltip) above neighboring bars.
                .zIndex(showTip ? 1 : 0)
        }

        private var tooltip: some View {
            Text(bar.fullLabel)
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.primary.opacity(0.12)))
                .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
        }
    }

    private func drawBackground(_ ctx: GraphicsContext, size: CGSize, blocks: [Block],
                                laneCount: Int, isToday: Bool, nowMin: Int) {
        let w = size.width
        let lanesTop = axisHeight
        let lanesH = CGFloat(laneCount) * laneHeight
        let trackRect = CGRect(x: 0.5, y: lanesTop, width: w - 1, height: lanesH)
        let outline = Path(roundedRect: trackRect, cornerRadius: 8)

        var inner = ctx
        inner.clip(to: outline)

        // Painted work hours, shaded faintly behind the bars (vertical bands).
        for b in blocks {
            let x0 = Self.xFor(b.start, width: w)
            let x1 = Self.xFor(b.end, width: w)
            inner.fill(Path(CGRect(x: x0, y: lanesTop, width: x1 - x0, height: lanesH)),
                       with: .color(Theme.accent.opacity(0.07)))
        }
        // Hour gridlines (vertical), every hour.
        for hh in 1..<24 {
            let x = Self.xFor(hh * 60, width: w)
            var line = Path()
            line.move(to: CGPoint(x: x, y: lanesTop))
            line.addLine(to: CGPoint(x: x, y: lanesTop + lanesH))
            inner.stroke(line, with: .color(.primary.opacity(hh % 6 == 0 ? 0.10 : 0.05)), lineWidth: 0.5)
        }
        // Now-line — a soft halo under a crisp 2pt line.
        if isToday {
            let x = Self.xFor(nowMin, width: w)
            var line = Path()
            line.move(to: CGPoint(x: x, y: lanesTop))
            line.addLine(to: CGPoint(x: x, y: lanesTop + lanesH))
            inner.stroke(line, with: .color(Theme.nowLine.opacity(0.22)), lineWidth: 5)
            inner.stroke(line, with: .color(Theme.nowLine), lineWidth: 2)
        }
        ctx.stroke(outline, with: .color(.primary.opacity(0.10)), lineWidth: 1)

        // Hour labels along the top axis, every 3 hours.
        for hh in stride(from: 0, through: 24, by: 2) {
            let x = Self.xFor(hh * 60, width: w)
            ctx.draw(
                Text(model.clockStyle.hourTick(hh)).font(.system(size: 9)).foregroundColor(.secondary.opacity(0.85)),
                at: CGPoint(x: min(max(x, 8), w - 8), y: axisHeight / 2))
        }
    }

    // MARK: - bar geometry

    /// A colored time block in one horizontal lane of the day (minute coordinates).
    private struct ConsumptionBar: Identifiable {
        let id = UUID()
        let color: Color
        let batch: Int
        let timeLabel: String   // "10:00–14:00", shown on the bar
        let fullLabel: String   // "Claude … · Batch 1 · 10:00–14:00", shown on hover
        let startMin: Int
        let endMin: Int
        let lane: Int       // 0 in Recommended (single row); account index in Windows
        let laneCount: Int
    }

    private func currentBars() -> [ConsumptionBar] {
        let plan = model.plan(forWeekday: day)
        let colors = model.scheduledAccountColors
        let labels = Dictionary(uniqueKeysWithValues: model.scheduledAccounts.map { ($0.id, $0.label) })

        switch mode {
        case .recommended:
            // One row per parallel lane (a serial rotation runs in each); with
            // parallelism 1 there's a single full-width row, as before.
            let laneCount = max((plan.usage.map(\.lane).max() ?? 0) + 1, 1)
            return plan.usage.compactMap { seg in
                makeBar(accountID: seg.accountID, batch: seg.batchIndex,
                        startMin: seg.startMin, endMin: seg.endMin,
                        lane: seg.lane, laneCount: laneCount, colors: colors, labels: labels)
            }
        case .windows:
            let window = model.schedule.windowMinutes
            let lanes = max(model.scheduledAccounts.count, 1)
            var bars: [ConsumptionBar] = []
            for (lane, account) in model.scheduledAccounts.enumerated() {
                let pings = plan.accounts.first { $0.accountID == account.id }?.pings ?? []
                for (i, ping) in pings.enumerated() {
                    if let made = makeBar(accountID: account.id, batch: i + 1,
                                          startMin: ping.atMin, endMin: ping.atMin + window,
                                          lane: lane, laneCount: lanes, colors: colors, labels: labels) {
                        bars.append(made)
                    }
                }
            }
            return bars
        }
    }

    /// Build a bar, clipping its geometry to the visible day while keeping the
    /// real (unclipped) times in the label.
    private func makeBar(accountID: String, batch: Int, startMin: Int, endMin: Int,
                         lane: Int, laneCount: Int,
                         colors: [String: Color], labels: [String: String]) -> ConsumptionBar? {
        let start = max(0, startMin)
        let end = min(1440, endMin)
        guard end > start else { return nil }
        let timeLabel = "\(fmtMin(startMin, clockStyle: model.clockStyle))–\(fmtMin(endMin, clockStyle: model.clockStyle))"
        let fullLabel = "\(labels[accountID] ?? accountID) · Batch \(batch) · \(timeLabel)"
        return ConsumptionBar(color: colors[accountID] ?? Theme.accent, batch: batch,
                              timeLabel: timeLabel, fullLabel: fullLabel,
                              startMin: start, endMin: end, lane: lane, laneCount: laneCount)
    }

    // MARK: - helpers

    private static func xFor(_ minute: Int, width: CGFloat) -> CGFloat {
        CGFloat(minute) / 1440 * width
    }

    private func hasWork(_ d: Int) -> Bool { !model.schedule.blocks(forWeekday: d).isEmpty }

    private static func minutes(from date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
