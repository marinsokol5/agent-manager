import AppKit
import SwiftUI

/// The Agent Manager brand mark: three staggered, rounded capsules — parallel 5h
/// windows tiled across the day. One geometry, three render targets: the colored
/// Dock icon, the monochrome menu-bar glyph, and the in-app SwiftUI `LogoMark`.
enum AgentManagerLogo {
    // Geometry on a unit square (CoreGraphics y-up; orange top-left → blue bottom-right).
    static let barLength: CGFloat = 0.46
    static let barHeight: CGFloat = 0.135
    static let barStartsX: [CGFloat] = [0.14, 0.27, 0.40]
    static let barCentersY: [CGFloat] = [0.68, 0.50, 0.32]

    private static func srgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    /// The colored app/Dock icon — deep-indigo squircle with the cascading bars.
    static func iconImage(size: CGFloat = 1024) -> NSImage? {
        let barColors = [srgb(0xe8, 0x84, 0x5b), srgb(0x2b, 0xb3, 0xa3), srgb(0x6c, 0x8c, 0xff)]
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return nil }

        // Squircle, slightly inset from the canvas edge (the macOS icon grid).
        let inset = size * 0.06
        let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
        let radius = rect.width * 0.2237
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
        if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [srgb(0x28, 0x2f, 0x59).cgColor, srgb(0x12, 0x15, 0x2c).cgColor] as CFArray,
                                 locations: [0, 1]) {
            ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: size), end: .zero, options: [])
        }
        drawBars(ctx, size: size, colors: barColors, shadow: true,
                 length: barLength, height: barHeight, startsX: barStartsX, centersY: barCentersY)
        ctx.restoreGState()
        return image
    }

    /// The monochrome menu-bar glyph (a template image the status bar tints). Bars
    /// are a touch longer/thicker than the icon so they read at ~16pt.
    static func menuBarGlyph(pointSize: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize))
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            drawBars(ctx, size: pointSize, colors: nil, shadow: false,
                     length: 0.60, height: 0.17, startsX: [0.10, 0.22, 0.34], centersY: [0.70, 0.50, 0.30])
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    /// Shared bar drawing. `colors == nil` fills every bar black (the template).
    private static func drawBars(_ ctx: CGContext, size s: CGFloat, colors: [NSColor]?, shadow: Bool,
                                 length: CGFloat, height: CGFloat, startsX: [CGFloat], centersY: [CGFloat]) {
        for i in 0..<3 {
            let r = CGRect(x: startsX[i] * s, y: centersY[i] * s - height * s / 2,
                           width: length * s, height: height * s)
            let path = CGPath(roundedRect: r, cornerWidth: height * s / 2, cornerHeight: height * s / 2, transform: nil)
            ctx.saveGState()
            if shadow {
                ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.006), blur: s * 0.022,
                              color: NSColor.black.withAlphaComponent(0.4).cgColor)
            }
            ctx.addPath(path)
            ctx.setFillColor((colors?[i] ?? .black).cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }
    }
}

/// The brand mark as a crisp SwiftUI view — a miniature of the app icon, used in
/// the sidebar header. (SwiftUI is y-down, so the bar centers are flipped.)
struct AgentManagerLogoMark: View {
    var size: CGFloat = 28

    private let barColors = [Color(hex: "#e8845b"), Color(hex: "#2bb3a3"), Color(hex: "#6c8cff")]
    private let startsX: [CGFloat] = [0.14, 0.27, 0.40]
    private let centersY: [CGFloat] = [0.32, 0.50, 0.68]   // flipped from the CG y-up values

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(hex: "#282f59"), Color(hex: "#12152c")],
                    startPoint: .top, endPoint: .bottom))
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(barColors[i])
                    .frame(width: size * AgentManagerLogo.barLength,
                           height: size * AgentManagerLogo.barHeight)
                    .position(x: size * (startsX[i] + AgentManagerLogo.barLength / 2),
                              y: size * centersY[i])
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
