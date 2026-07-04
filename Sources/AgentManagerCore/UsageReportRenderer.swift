import Foundation

/// Renders a pretty terminal usage report (ANSI progress bars) for one account,
/// in the style of the `claude` CLI's `/status` panel: a bold window title, a
/// two-tone bar (filled = remaining) with "N% left", and a dim "Resets …" line.
/// Percentages are *remaining* everywhere for consistency with the menu bar.
///
/// Pure and deterministic (inject `now`/`timeZone`); the `am usage` command does
/// the I/O. Pass `color: false` (non-TTY / `--no-color`) for plain `[██░░]` bars.
public enum UsageReportRenderer {
    /// Bar width in cells.
    static let barWidth = 32

    public static func render(
        account: Account,
        reading: UsageReading,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        clockStyle: ClockStyle = .twelveHour,
        color: Bool = true) -> String
    {
        var lines: [String] = []
        lines.append(
            TerminalColor.dot(hex: account.color, color: color) + " "
                + style(account.id, .bold, color)
                + dim(" (\(account.provider.rawValue.capitalized)) · updated \(reading.freshnessLabel(now: now))", color))
        lines.append("")
        lines.append(section(
            "Current session",
            remainingPercent: reading.primaryRemainingPercent,
            resetsAt: reading.primaryResetsAt, now: now, timeZone: timeZone, clockStyle: clockStyle, color: color))
        lines.append("")
        lines.append(section(
            "Current week (all models)",
            remainingPercent: reading.secondaryRemainingPercent,
            resetsAt: reading.secondaryResetsAt, now: now, timeZone: timeZone, clockStyle: clockStyle, color: color))
        return lines.joined(separator: "\n")
    }

    /// Which window the compact table shows.
    public enum Window: Sendable { case session, week }

    /// One agent's result for the compact table.
    public struct Row: Sendable {
        public let account: Account
        public let reading: UsageReading?
        public let error: String?
        public init(account: Account, reading: UsageReading?, error: String? = nil) {
            self.account = account
            self.reading = reading
            self.error = error
        }
    }

    /// Compact one-row-per-agent table. Rows are shown in the order the caller
    /// passes them — the canonical agent **priority order** — so the table matches
    /// the app list and `am list`. Each row leads with the account's identity dot
    /// and id (the same handle `am run`/`am ping` take). Built for scanning many
    /// agents at a glance.
    public static func renderCompact(
        _ rows: [Row],
        window: Window,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        clockStyle: ClockStyle = .twelveHour,
        color: Bool = true) -> String
    {
        func remaining(_ r: Row) -> Int? {
            window == .session ? r.reading?.primaryRemainingPercent : r.reading?.secondaryRemainingPercent
        }
        func reset(_ r: Row) -> Date? { window == .session ? r.reading?.primaryResetsAt : r.reading?.secondaryResetsAt }

        let labelWidth = min(28, max(8, rows.map(\.account.id.count).max() ?? 8))

        var lines = [style(window == .session ? "Current session" : "Current week (all models)", .bold, color)]
        for r in rows {
            // Lead with the identity dot + id so the row keys to the same handle as
            // `am list` / `am run`; the bar keeps its capacity coloring.
            let head = "\(TerminalColor.dot(hex: r.account.color, color: color)) \(pad(r.account.id, labelWidth))"
            if let error = r.error {
                lines.append("\(head)  " + style("! \(error)", .warn, color))
            } else if let rem = remaining(r) {
                var line = "\(head)  \(barString(filledPercent: rem, width: 20, color: color)) \(remainingText(rem, color: color, width: 3))"
                if let resetStr = formatReset(reset(r), now: now, timeZone: timeZone, clockStyle: clockStyle, includeZone: false) {
                    line += "  " + dim("· \(resetStr)", color)
                }
                lines.append(line)
            } else {
                lines.append("\(head)  " + dim("—  no data", color))
            }
        }
        return lines.joined(separator: "\n")
    }

    public static func renderError(account: Account, message: String, color: Bool = true) -> String {
        TerminalColor.dot(hex: account.color, color: color) + " "
            + style(account.id, .bold, color)
            + dim(" (\(account.provider.rawValue.capitalized))", color)
            + "\n  " + style(message, .warn, color)
    }

    // MARK: - Sections

    private static func section(
        _ title: String, remainingPercent: Int?, resetsAt: Date?,
        now: Date, timeZone: TimeZone, clockStyle: ClockStyle, color: Bool) -> String
    {
        var out = style(title, .bold, color)
        if let rem = remainingPercent {
            out += "\n" + barString(filledPercent: rem, width: barWidth, color: color) + " " + remainingText(rem, color: color)
        } else {
            out += "\n" + dim("(no data)", color)
        }
        if let reset = formatReset(resetsAt, now: now, timeZone: timeZone, clockStyle: clockStyle) {
            out += "\n" + dim(reset, color)
        }
        return out
    }

    /// Bar whose filled portion represents `filledPercent` (= remaining).
    static func barString(filledPercent: Int, width: Int, color: Bool) -> String {
        let pct = max(0, min(100, filledPercent))
        let filled = Int((Double(pct) / 100.0 * Double(width)).rounded())
        let empty = max(0, width - filled)
        if color {
            return ansi(String(repeating: "█", count: filled), "38;5;147")
                + ansi(String(repeating: "█", count: empty), "38;5;239")
        }
        return "[" + String(repeating: "█", count: filled) + String(repeating: "░", count: empty) + "]"
    }

    /// "Resets 6:20pm (in 8h 20m) · Europe/Amsterdam" same-day, else
    /// "Resets Jun 26 at 4am (in 18h 5m) · Europe/Amsterdam". The clock style
    /// picks 12- vs 24-hour (12-hour round hours drop ":00"); the relative
    /// countdown mirrors the app and is omitted once the reset is in the past.
    static func formatReset(
        _ date: Date?, now: Date, timeZone: TimeZone = .current,
        clockStyle: ClockStyle = .twelveHour, includeZone: Bool = true) -> String?
    {
        guard let date else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone

        let time = clockStyle.timeString(date, timeZone: timeZone)
        let relative = UsageReading.resetCountdown(to: date, now: now)
            .map { " (\($0.replacingOccurrences(of: "resets ", with: "")))" } ?? ""
        let zone = includeZone ? " · \(timeZone.identifier)" : ""

        let clock = cal.isDate(date, inSameDayAs: now)
            ? "Resets \(time)"
            : "Resets \(dayString(date, timeZone: timeZone)) at \(time)"
        return clock + relative + zone
    }

    /// "MMM d" in the given zone (e.g. "Jun 26").
    private static func dayString(_ date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }

    /// Left-justify `s` to `width`, truncating overlong labels with an ellipsis.
    private static func pad(_ s: String, _ width: Int) -> String {
        let t = s.count > width ? String(s.prefix(width - 1)) + "…" : s
        return t.padding(toLength: width, withPad: " ", startingAt: 0)
    }

    /// "N% left", colored by how little remains (≤10 red, ≤30 amber, else blue).
    /// `width` right-aligns the number for the compact table (0 = no padding).
    private static func remainingText(_ remaining: Int, color: Bool, width: Int = 0) -> String {
        let clamped = max(0, min(100, remaining))
        let number = width > 0 ? String(format: "%\(width)d", clamped) : String(clamped)
        let text = "\(number)% left"
        guard color else { return text }
        let code = clamped <= 10 ? "38;5;196" : clamped <= 30 ? "38;5;179" : "38;5;147"
        return ansi(text, code)
    }

    // MARK: - ANSI

    private enum Style { case bold, dim, warn }

    private static func style(_ s: String, _ st: Style, _ color: Bool) -> String {
        guard color else { return s }
        switch st {
        case .bold: return "\u{1B}[1m\(s)\u{1B}[0m"
        case .dim: return ansi(s, "38;5;244")
        case .warn: return ansi(s, "38;5;179")
        }
    }

    private static func dim(_ s: String, _ color: Bool) -> String { style(s, .dim, color) }

    private static func ansi(_ s: String, _ code: String) -> String {
        s.isEmpty ? "" : "\u{1B}[\(code)m\(s)\u{1B}[0m"
    }
}
