import AgentManagerCore
import AppKit
import SwiftUI

/// Visual language: a blue/purple accent, a small per-account
/// color palette, and per-status colors/icons.
///
/// This enum is the single source of truth for the app's design tokens. Views must
/// reference semantic roles here — `Theme.success`, `Theme.Font.screenTitle`,
/// `Theme.Spacing.md` — rather than inline hex/point literals, so one meaning maps
/// to exactly one value across every screen and the menu bar.
enum Theme {
    static let accent = Color(hex: "#6c8cff")

    /// Default swatches offered when creating an account.
    /// Per-account identity colors — distinct from the semantic roles below.
    static let palette: [String] = ["#cc7450", "#259c8e", "#6c8cff", "#b970c6", "#a98731", "#509c50"]

    static let sidebarWidth: CGFloat = 210

    // MARK: Semantic colors
    //
    // One hex serves both appearances, so every value here must hold its WCAG
    // ratio against the light *and* dark window backgrounds —
    // `ThemeContrastTests` ratchets that. These sit at relative luminance
    // ≈0.26, the band where both ≥3:1 (light) and ≥4.5:1 (dark) hold.

    /// Positive / healthy / connected / succeeded.
    static let success = Color(hex: "#26a050")
    /// Caution — low headroom, expired, "ran but didn't anchor".
    static let warning = Color(hex: "#be7d43")
    /// Failure / destructive.
    static let danger = Color(hex: "#e0533f")
    /// In-progress — connecting, mid-flight.
    static let pending = Color(hex: "#a98731")
    /// Inactive / unknown / not-scheduled.
    static let neutral = Color(hex: "#878c91")
    /// The live "now" indicator drawn on the grids and the sidebar clock.
    static let nowLine = Color(hex: "#ff4444")

    // MARK: Spacing scale

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 22
        static let xxl: CGFloat = 32
    }

    // MARK: Corner radii

    enum Radius {
        static let sm: CGFloat = 7
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
    }

    // MARK: Type ramp

    /// A small, fixed type ramp. Specialized one-off styles (monospaced digits,
    /// the Canvas-drawn grid labels) stay inline; these cover the recurring roles.
    enum Font {
        /// Sidebar wordmark.
        static let brand = SwiftUI.Font.system(size: 19, weight: .heavy)
        /// Per-screen `H1` ("Agents", "Working hours", …).
        static let screenTitle = SwiftUI.Font.system(size: 18, weight: .bold)
        /// Prominent in-content heading.
        static let heading = SwiftUI.Font.system(size: 15, weight: .bold)
        /// Section label ("Daily consumption", "Scheduled jobs").
        static let sectionTitle = SwiftUI.Font.system(size: 13, weight: .semibold)
        /// Default body / descriptions.
        static let body = SwiftUI.Font.system(size: 13)
        static let callout = SwiftUI.Font.system(size: 12.5)
        static let caption = SwiftUI.Font.system(size: 11.5)
        static let caption2 = SwiftUI.Font.system(size: 11)
        static let footnote = SwiftUI.Font.system(size: 10.5)
        static let micro = SwiftUI.Font.system(size: 10)
    }
}

extension AppTheme {
    /// The AppKit appearance override this theme pins the app to;
    /// nil = no override, follow macOS.
    var nsAppearance: NSAppearance? {
        switch self {
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        case .system: nil
        }
    }
}

extension Color {
    /// Parse `#RRGGBB` (or `RRGGBB`). Falls back to the accent on bad input.
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else {
            self = Color(red: 0x6c / 255, green: 0x8c / 255, blue: 0xff / 255)
            return
        }
        self = Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }

    /// `#RRGGBB` for persisting back into the account model.
    func toHex() -> String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}

extension AccountStatus {
    var displayName: String {
        switch self {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .expired: "Expired"
        case .disconnected: "Disconnected"
        }
    }

    var tint: Color {
        switch self {
        case .connected: Theme.success
        case .connecting: Theme.pending
        case .expired: Theme.warning
        case .disconnected: Theme.neutral
        }
    }

    var systemImage: String {
        switch self {
        case .connected: "checkmark.circle.fill"
        case .connecting: "clock.fill"
        case .expired: "exclamationmark.triangle.fill"
        case .disconnected: "xmark.circle"
        }
    }
}

extension Provider {
    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}
