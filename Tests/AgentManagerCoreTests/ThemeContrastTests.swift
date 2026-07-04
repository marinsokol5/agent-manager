import AppKit
import SwiftUI
import XCTest
@testable import AgentManager

/// WCAG 2.x contrast audit over the app's fixed design tokens (`Theme`).
///
/// The app supports light, dark, and system appearance (the `theme`
/// preference), but the `Theme` tokens are single hex values serving *both*
/// appearances — so every token change silently shifts legibility in two
/// places. This test measures each token against the window background of
/// each appearance and **ratchets** the result: the floors in `tokens` are
/// the measured ratios (rounded down a notch), so a color edit that keeps or
/// improves contrast passes untouched, while one that loses contrast fails
/// until the floor is *consciously* lowered here.
///
/// Current reality the floors encode (see the table this test prints): every
/// token clears WCAG 2.x's 3:1 non-text minimum in *both* appearances — most
/// tokens were re-derived at relative luminance ≈0.26, the band where ≥3:1 on
/// white and ≥4.5:1 on the dark background hold simultaneously. The remaining
/// gap to the 4.5:1 *text* bar in light mode (tinted captions sit at 3.0–3.4)
/// would need per-appearance token colors.
///
/// Ratios are computed against `windowBackgroundColor` as it resolves in a
/// windowless test process (pure white / #1e1e1e). Real windows are slightly
/// different (#ececec-ish in light), which shifts ratios a little in the
/// lenient direction — fine for a ratchet, which only compares against itself.
@MainActor
final class ThemeContrastTests: XCTestCase {

    /// A design token plus the ratcheted floor it must keep in each appearance.
    private struct Token {
        let name: String
        let color: Color
        let floorLight: Double
        let floorDark: Double
    }

    /// Every fixed color the UI paints on the window background: the semantic
    /// roles and the account-identity palette (which also tints text/glyphs in
    /// rows and grids, not just swatches).
    private var tokens: [Token] {
        [
            Token(name: "accent", color: Theme.accent, floorLight: 3.0, floorDark: 5.3),
            Token(name: "success", color: Theme.success, floorLight: 3.3, floorDark: 4.8),
            Token(name: "warning", color: Theme.warning, floorLight: 3.3, floorDark: 4.8),
            Token(name: "danger", color: Theme.danger, floorLight: 3.8, floorDark: 4.3),
            Token(name: "pending", color: Theme.pending, floorLight: 3.3, floorDark: 4.8),
            Token(name: "neutral", color: Theme.neutral, floorLight: 3.3, floorDark: 4.8),
            Token(name: "nowLine", color: Theme.nowLine, floorLight: 3.4, floorDark: 4.8),
        ] + Theme.palette.map {
            // The swatches are user-picked identity colors, not text — hold them
            // to the palette's current worst case (the accent blue, ~3.1 light /
            // ~5.4 dark) rather than per-swatch floors, so adding a swatch only
            // has to beat the existing bar.
            Token(name: "palette \($0)", color: Color(hex: $0), floorLight: 3.0, floorDark: 4.8)
        }
    }

    func testThemeTokensKeepTheirContrastFloors() {
        let lightBG = Self.resolve(.windowBackgroundColor, in: .aqua)
        let darkBG = Self.resolve(.windowBackgroundColor, in: .darkAqua)

        let pad: (String) -> String = { $0.padding(toLength: 22, withPad: " ", startingAt: 0) }
        var table = ["", pad("token") + "   light    dark"]
        for token in tokens {
            let light = Self.wcagRatio(NSColor(token.color), over: lightBG)
            let dark = Self.wcagRatio(NSColor(token.color), over: darkBG)
            table.append(pad(token.name) + String(format: "%8.2f %7.2f", light, dark))

            XCTAssertGreaterThanOrEqual(
                light, token.floorLight,
                "\(token.name) lost contrast on the light window background — " +
                "restore it, or consciously lower its floor in this file")
            XCTAssertGreaterThanOrEqual(
                dark, token.floorDark,
                "\(token.name) lost contrast on the dark window background — " +
                "restore it, or consciously lower its floor in this file")
        }
        print(table.joined(separator: "\n"))
    }

    /// Every token clears WCAG 2.x's 3:1 non-text minimum in both appearances —
    /// keep it that way (this is an absolute bar, not a ratchet).
    func testBothAppearancesMeetWCAGComponentContrastEverywhere() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let background = Self.resolve(.windowBackgroundColor, in: appearance)
            for token in tokens {
                XCTAssertGreaterThanOrEqual(
                    Self.wcagRatio(NSColor(token.color), over: background), 3.0,
                    "\(token.name) fell below WCAG 3:1 on the \(appearance.rawValue) window background")
            }
        }
    }

    // MARK: WCAG math

    /// WCAG 2.x contrast ratio, 1…21. Both colors are flattened to opaque sRGB
    /// first (the tokens are opaque; alpha-composited variants like the 0.02–0.07
    /// card washes only nudge the background, so auditing the base is enough).
    private static func wcagRatio(_ color: NSColor, over background: NSColor) -> Double {
        (max(luminance(color), luminance(background)) + 0.05)
            / (min(luminance(color), luminance(background)) + 0.05)
    }

    /// WCAG relative luminance of an sRGB color.
    private static func luminance(_ color: NSColor) -> Double {
        guard let c = color.usingColorSpace(.sRGB) else {
            XCTFail("color \(color) not convertible to sRGB")
            return 0
        }
        func linear(_ u: Double) -> Double {
            u <= 0.04045 ? u / 12.92 : pow((u + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.redComponent)
            + 0.7152 * linear(c.greenComponent)
            + 0.0722 * linear(c.blueComponent)
    }

    /// Pin a dynamic (catalog) color to what it renders as under `appearance`.
    private static func resolve(_ color: NSColor, in appearance: NSAppearance.Name) -> NSColor {
        var resolved = color
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return resolved
    }
}
