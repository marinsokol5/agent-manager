import AgentManagerCore
import SwiftUI

/// The drag-paint 7×24 work-hour grid (your timezone, live now-line), with hover
/// highlighting, live "from–until" labels, and a faint Anthropic peak-load heatmap.
/// Editing mutates `model.schedule` live. The selected day (driven by `selectedDay`,
/// shared with the coverage column beside it) is emphasized so paint→coverage reads
/// as cause→effect. Lives inside `PlannerView`.
struct WeekPaintGrid: View {
    @Bindable var model: AppModel
    /// The weekday (Mon = 0) mirrored in the coverage column; clicking a day header
    /// selects it.
    @Binding var selectedDay: Int

    // ── drag-paint state (Google-Calendar style range paint) ──────────────────
    /// While a drag is active the whole column is recomputed from `baseColumn`
    /// each pointer move, so dragging back toward the anchor shrinks the range.
    @State private var dragging = false
    /// `true` paints hours on, `false` erases — set from the cell the drag began on.
    @State private var paintOn = true
    /// The drag is locked to the column it started in (vertical movement only).
    @State private var paintDay = -1
    /// The hour the drag anchored on; the range runs anchor ↔ pointer.
    @State private var anchorHour = 0
    /// Snapshot of the painted column at drag start, so shrink-back is exact.
    @State private var baseColumn: Set<Int> = []
    /// The cell under the pointer, JS-tracked so hover survives fast drags.
    @State private var hover: GridCell?
    /// Session-only undo stack of whole-schedule snapshots (one per edit). Escape
    /// pops the last edit. Not persisted — it lives only for this app run.
    @State private var undoStack: [WorkSchedule] = []

    private let labelWidth: CGFloat = 34
    private let rowHeight: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolbar
            grid
        }
        .background(undoShortcut)
    }

    /// A zero-size, transparent button that binds Escape to "undo last edit".
    /// Disabled (so Escape passes through) when there's nothing to undo.
    private var undoShortcut: some View {
        Button("Undo last edit", action: undoLast)
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .frame(width: 0, height: 0)
            .disabled(undoStack.isEmpty)
            .accessibilityHidden(true)
    }

    private func pushUndo() {
        undoStack.append(model.schedule)
        if undoStack.count > 200 { undoStack.removeFirst() }
    }

    /// Revert the most recent edit made this session (Escape). Also cancels an
    /// in-progress drag, since its pre-drag snapshot is on top of the stack.
    private func undoLast() {
        guard let previous = undoStack.popLast() else { return }
        dragging = false
        paintDay = -1
        hover = nil
        model.schedule = previous
        model.saveSchedule()
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { pushUndo(); model.copyMondayToWeekdays() } label: { Label("Copy Mon→Fri", systemImage: "arrow.right.doc.on.clipboard") }
            Button(role: .destructive) { pushUndo(); model.clearAllHours() } label: { Label("Clear all", systemImage: "trash") }
                .disabled(model.schedule.totalSelectedHours == 0)

            peakLegend

            Spacer()

            Text("\(model.schedule.totalSelectedHours) hrs/wk")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    /// Key for the peak-load heatmap shaded onto the grid. Each swatch uses the
    /// exact fill that lands on the calendar (red = peak, orange = busy), so the
    /// legend and the grid read as the same color.
    private var peakLegend: some View {
        HStack(spacing: 10) {
            legendChip(PeakHeat.orangeColor, PeakHeat.orangeFill, "busy")
            legendChip(PeakHeat.redColor, PeakHeat.redFill, "peak")
        }
        .help("Anthropic's shared capacity is busiest during US working hours (≈13:00–22:00 UTC). Red = peak (hottest core, 14:00–19:00 UTC); orange = busy (ramp-up/down). Expect slower responses and more 429/529 overloads then. Shaded in your local time; heuristic guidance, never blocks painting.")
    }

    private func legendChip(_ color: Color, _ opacity: Double, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color.opacity(opacity))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(color.opacity(0.45), lineWidth: 1))
                .frame(width: 13, height: 13)
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    // MARK: - the paint grid

    private var grid: some View {
        // Snapshot the selection in `body` so the Canvas redraws when it changes
        // (the draw closure runs after body, where observation isn't tracked).
        let selected = (0..<7).map { Set(model.schedule.hours(forWeekday: $0)) }
        let today = WeekTime.todayMon0
        let sel = selectedDay

        return GeometryReader { geo in
            let colW = max((geo.size.width - labelWidth) / 7, 1)
            VStack(spacing: 6) {
                headerRow(colW: colW, today: today, selected: selected)
                // TimelineView keeps the now-line ticking without a manual timer.
                TimelineView(.periodic(from: .now, by: 60)) { timeline in
                    let nowMin = Self.minutes(from: timeline.date)
                    ZStack(alignment: .topLeading) {
                        Canvas { ctx, size in
                            drawGrid(ctx, size: size, colW: colW, selected: selected,
                                     today: today, selectedDay: sel, nowMin: nowMin)
                        }
                        interaction(colW: colW)
                    }
                    .frame(height: rowHeight * 24)
                }
            }
        }
        .frame(height: rowHeight * 24 + 28)
    }

    private func headerRow(colW: CGFloat, today: Int, selected: [Set<Int>]) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: labelWidth)
            ForEach(0..<7, id: \.self) { d in
                HStack(spacing: 4) {
                    Button { selectedDay = d } label: {
                        Text(WorkSchedule.weekdayNames[d])
                            .font(.system(size: 11, weight: d == selectedDay || d == today ? .bold : .regular))
                            .foregroundStyle(d == selectedDay ? Theme.accent
                                : (d == today ? Theme.accent.opacity(0.7) : Color.secondary))
                    }
                    .buttonStyle(.plain)
                    .help("Show \(WorkSchedule.weekdayNames[d]) in the coverage column")
                    if !selected[d].isEmpty {
                        Button { pushUndo(); model.clearDay(d) } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 9))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                        .help("Clear \(WorkSchedule.weekdayNames[d])")
                    }
                }
                .frame(width: colW)
            }
        }
    }

    /// A transparent layer that owns hover tracking (so highlighting survives fast
    /// drags) and the range-paint drag gesture. We map pointer coordinates → cells
    /// ourselves rather than per-cell `onHover`, which skips cells on a fast drag.
    private func interaction(colW: CGFloat) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): if !dragging { hover = cell(at: p, colW: colW) }
                case .ended: if !dragging { hover = nil }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if dragging { extendPaint(at: v.location) }
                        else { beginPaint(at: v.location, colW: colW) }
                    }
                    .onEnded { _ in endPaint() })
    }

    // MARK: - paint mechanics

    private func beginPaint(at loc: CGPoint, colW: CGFloat) {
        guard let c = cell(at: loc, colW: colW) else { return }
        pushUndo()   // snapshot before this paint so Escape can revert the whole drag
        paintDay = c.d
        anchorHour = c.h
        baseColumn = Set(model.schedule.hours(forWeekday: c.d))
        paintOn = !baseColumn.contains(c.h)   // press on a filled cell ⇒ this drag erases
        dragging = true
        hover = c
        selectedDay = c.d                       // painting a day also focuses it in coverage
        applyRange(to: c.h)
    }

    private func extendPaint(at loc: CGPoint) {
        guard dragging, paintDay >= 0 else { return }
        let h = max(0, min(23, Int(loc.y / rowHeight)))
        hover = GridCell(d: paintDay, h: h)
        applyRange(to: h)
    }

    /// Rebuild the column from its start-of-drag snapshot and paint the inclusive
    /// anchor↔h range, so dragging back toward the anchor shrinks the selection.
    private func applyRange(to h: Int) {
        let lo = min(anchorHour, h), hi = max(anchorHour, h)
        var col = baseColumn
        for k in lo...hi { if paintOn { col.insert(k) } else { col.remove(k) } }
        model.setColumnHours(weekday: paintDay, hours: Array(col))
    }

    private func endPaint() {
        guard dragging else { return }
        dragging = false
        paintDay = -1
        model.saveSchedule()
    }

    private func cell(at loc: CGPoint, colW: CGFloat) -> GridCell? {
        guard loc.x >= labelWidth else { return nil }
        let d = Int((loc.x - labelWidth) / colW)
        let h = Int(loc.y / rowHeight)
        guard (0..<7).contains(d), (0..<24).contains(h) else { return nil }
        return GridCell(d: d, h: h)
    }

    // MARK: - drawing

    private func drawGrid(_ ctx: GraphicsContext, size: CGSize, colW: CGFloat,
                          selected: [Set<Int>], today: Int, selectedDay: Int, nowMin: Int) {
        let accent = Theme.accent
        let trackH = rowHeight * 24
        let heat = PeakHeat.grid

        for d in 0..<7 {
            let x = labelWidth + CGFloat(d) * colW
            let trackRect = CGRect(x: x + 1, y: 0, width: colW - 2, height: trackH)
            let outline = Path(roundedRect: trackRect, cornerRadius: 7)

            // Clip everything inside the track to its rounded rect, so a contiguous
            // run of painted hours reads as one solid bar with rounded ends.
            var col = ctx
            col.clip(to: outline)

            if d == today {
                col.fill(Path(trackRect), with: .color(accent.opacity(0.06)))
            }
            // The selected day (mirrored in the coverage column) gets a stronger wash.
            if d == selectedDay {
                col.fill(Path(trackRect), with: .color(accent.opacity(0.10)))
            }

            for h in 0..<24 {
                let y = CGFloat(h) * rowHeight
                let cellRect = CGRect(x: trackRect.minX, y: y, width: trackRect.width, height: rowHeight)
                let isOn = selected[d].contains(h)
                let isHover = hover?.d == d && hover?.h == h && !dragging

                if !isOn {
                    switch heat[d][h] {
                    case .orange: col.fill(Path(cellRect), with: .color(PeakHeat.orangeColor.opacity(PeakHeat.orangeFill)))
                    case .red:    col.fill(Path(cellRect), with: .color(PeakHeat.redColor.opacity(PeakHeat.redFill)))
                    case .none:   break
                    }
                }

                if isOn {
                    col.fill(Path(cellRect), with: .color(accent.opacity(isHover ? 1.0 : 0.9)))
                } else if isHover {
                    col.fill(Path(cellRect), with: .color(accent.opacity(0.22)))
                }

                if h > 0 {
                    var line = Path()
                    line.move(to: CGPoint(x: trackRect.minX, y: y))
                    line.addLine(to: CGPoint(x: trackRect.maxX, y: y))
                    col.stroke(line, with: .color(.primary.opacity(0.05)), lineWidth: 0.5)
                }
            }

            // Live "from–until" label centered over each contiguous painted block.
            for run in Self.runs(in: selected[d]) {
                let yMid = (CGFloat(run.lowerBound) + CGFloat(run.upperBound + 1)) / 2 * rowHeight
                col.draw(
                    Text(rangeLabel(run.lowerBound, run.upperBound + 1))
                        .font(.system(size: 9, weight: .bold)).foregroundColor(.white),
                    at: CGPoint(x: trackRect.midX, y: yMid))
            }

            // Faint preview of the single hovered hour (when not painting).
            if let hv = hover, hv.d == d, !dragging, !selected[d].contains(hv.h) {
                let yMid = (CGFloat(hv.h) + 0.5) * rowHeight
                col.draw(
                    Text(rangeLabel(hv.h, hv.h + 1))
                        .font(.system(size: 9, weight: .semibold)).foregroundColor(accent.opacity(0.8)),
                    at: CGPoint(x: trackRect.midX, y: yMid))
            }

            // Selected day's outline in accent so it ties to the coverage column.
            ctx.stroke(outline,
                       with: .color(d == selectedDay ? accent.opacity(0.9) : .primary.opacity(0.10)),
                       lineWidth: d == selectedDay ? 1.6 : 1)
        }

        // Hour labels down the gutter (00..23 / 12a..11p), every hour.
        for h in 0..<24 {
            let y = CGFloat(h) * rowHeight + rowHeight / 2
            ctx.draw(
                Text(model.clockStyle.hourTick(h)).font(.system(size: 9)).foregroundColor(.secondary.opacity(0.85)),
                at: CGPoint(x: labelWidth - 6, y: y), anchor: .trailing)
        }

        // Now-line across today's column, with a knob at the gutter edge.
        if (0..<7).contains(today) {
            let y = CGFloat(nowMin) / 60 * rowHeight
            let x0 = labelWidth + CGFloat(today) * colW
            let red = Theme.nowLine
            var line = Path()
            line.move(to: CGPoint(x: x0 + 1, y: y))
            line.addLine(to: CGPoint(x: x0 + colW - 1, y: y))
            ctx.stroke(line, with: .color(red.opacity(0.22)), lineWidth: 5)
            ctx.stroke(line, with: .color(red), lineWidth: 2)
            ctx.fill(Path(ellipseIn: CGRect(x: x0 - 2, y: y - 3, width: 6, height: 6)), with: .color(red))
        }
    }

    // MARK: - helpers

    private static func minutes(from date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// "09:00–17:00" / "9am–5pm"; hour 24 renders as "24:00" / "12am" so a
    /// block painted to the bottom of the grid still reads as end-of-day.
    private func rangeLabel(_ a: Int, _ b: Int) -> String {
        "\(model.clockStyle.minuteString(a * 60))–\(model.clockStyle.minuteString(b * 60))"
    }

    /// Contiguous closed runs of selected hours, ascending.
    private static func runs(in hours: Set<Int>) -> [ClosedRange<Int>] {
        var out: [ClosedRange<Int>] = []
        var start: Int?
        var prev: Int?
        for h in hours.sorted() {
            if let p = prev, h == p + 1 { prev = h }
            else {
                if let s = start, let p = prev { out.append(s...p) }
                start = h; prev = h
            }
        }
        if let s = start, let p = prev { out.append(s...p) }
        return out
    }
}

/// One cell of the 7×24 grid: weekday `d` (0 = Mon) × hour `h` (0…23).
private struct GridCell: Equatable {
    let d: Int
    let h: Int
}

/// Faint advisory shading that warns when Anthropic's shared capacity is busiest,
/// so heavy sessions can steer around the crunch — peak hours bring higher
/// latency and more 429/529 overloads. Bands are hard-coded in **UTC** (demand
/// tracks US working hours regardless of where the user sits) and converted to
/// the user's local time below; weekdays only. Advisory only — never blocks
/// painting. Heuristic, not measured.
///
///   13:00–14:00 UTC → orange (ramp-up) · 14:00–19:00 UTC → red (hottest core)
///   19:00–22:00 UTC → orange (ramp-down)
enum PeakHeat {
    case none, orange, red

    static let orangeColor = Color(hex: "#f5a623")
    static let redColor = Color(hex: "#e5484d")

    /// Fill opacity used on the grid — shared with the toolbar legend so the
    /// swatches read as the exact same tint that lands on the calendar cells.
    static let redFill = 0.20
    static let orangeFill = 0.18

    private static func utc(_ utcHour: Int) -> PeakHeat {
        if utcHour >= 14 && utcHour < 19 { return .red }
        if utcHour == 13 || (utcHour >= 19 && utcHour < 22) { return .orange }
        return .none
    }

    /// Precomputed 7×24 heat keyed by LOCAL [day Mon0][hour]: each cell's midpoint
    /// is mapped to its UTC weekday/hour, then looked up against the band.
    static let grid: [[PeakHeat]] = {
        let weekMin = 7 * 1440
        // JS getTimezoneOffset() convention: UTC = local + offset.
        let tzOffsetMin = -TimeZone.current.secondsFromGMT() / 60
        return (0..<7).map { d in
            (0..<24).map { h -> PeakHeat in
                let utcMin = d * 1440 + h * 60 + 30 + tzOffsetMin   // cell midpoint → UTC
                let m = ((utcMin % weekMin) + weekMin) % weekMin
                if m / 1440 > 4 { return .none }                    // Sat/Sun in UTC
                return utc((m % 1440) / 60)
            }
        }
    }()
}
