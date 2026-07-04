import AppKit
import SwiftUI

/// Stand-in for the app's `Color(hex:)` (Theme.swift, which imports
/// AgentManagerCore and can't compile standalone). Only referenced by the
/// SwiftUI `AgentManagerLogoMark` view, which this tool never renders — it
/// exists purely to satisfy compilation of `AgentManagerLogo.swift`.
extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let value = UInt32(s, radix: 16) ?? 0
        self = Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }
}

/// Renders `Support/AgentManager.icns` from the code-defined brand mark
/// (`AgentManagerLogo.iconImage`), so the bundle icon can never drift from the
/// in-app/Dock rendering. Compiled by `make icon` together with the app's
/// `AgentManagerLogo.swift` + `Theme.swift` — no duplicated geometry here.
///
/// Each iconset slot is re-rendered from the vector geometry at its exact pixel
/// size (not downscaled from 1024), so small sizes stay crisp.
@main
struct RenderIcon {
    /// (pixels, iconset filename) — the ten slots `iconutil` expects.
    static let slots: [(Int, String)] = [
        (16, "icon_16x16"), (32, "icon_16x16@2x"),
        (32, "icon_32x32"), (64, "icon_32x32@2x"),
        (128, "icon_128x128"), (256, "icon_128x128@2x"),
        (256, "icon_256x256"), (512, "icon_256x256@2x"),
        (512, "icon_512x512"), (1024, "icon_512x512@2x"),
    ]

    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: render-icon <output.icns>\n".utf8))
            exit(2)
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let iconset = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentManager-\(ProcessInfo.processInfo.processIdentifier).iconset")
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: iconset) }

        for (pixels, name) in slots {
            guard let image = AgentManagerLogo.iconImage(size: CGFloat(pixels)) else {
                fatalError("iconImage(size: \(pixels)) returned nil")
            }
            try writePNG(image, pixels: pixels, to: iconset.appendingPathComponent("\(name).png"))
        }

        let iconutil = Process()
        iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
        try iconutil.run()
        iconutil.waitUntilExit()
        guard iconutil.terminationStatus == 0 else {
            fatalError("iconutil failed with status \(iconutil.terminationStatus)")
        }
        print("wrote \(output.path)")
    }

    /// Rasterize into an explicit bitmap of exactly `pixels`² so the output is
    /// pixel-exact regardless of the process's backing scale.
    static func writePNG(_ image: NSImage, pixels: Int, to url: URL) throws {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { fatalError("could not create bitmap rep (\(pixels)px)") }
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
                   from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else {
            fatalError("PNG encode failed (\(pixels)px)")
        }
        try png.write(to: url)
    }
}
