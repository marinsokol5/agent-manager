import AgentManagerCore
import AppKit
import SwiftUI

/// Loads the bundled provider brand glyph (e.g. the Claude/Codex logo) as a
/// monochrome template `NSImage`, cached per provider. The SVGs are single-path,
/// white-fill marks, so flagging
/// them `isTemplate` lets the menu bar / SwiftUI tint them for light & dark.
@MainActor
enum ProviderBrandIcon {
    private static var cache: [Provider: NSImage] = [:]

    /// Resource basename for each provider's bundled SVG.
    private static func resourceName(for provider: Provider) -> String {
        switch provider {
        case .claude: "ProviderIcon-claude"
        case .codex: "ProviderIcon-codex"
        }
    }

    /// SF Symbol fallback used when the bundled SVG can't be loaded, so the UI
    /// never renders an empty box.
    static func fallbackSymbol(for provider: Provider) -> String {
        switch provider {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        }
    }

    static func image(for provider: Provider) -> NSImage? {
        if let cached = cache[provider] { return cached }
        guard let url = Bundle.module.url(forResource: resourceName(for: provider), withExtension: "svg"),
              let image = NSImage(contentsOf: url)
        else {
            return nil
        }
        image.isTemplate = true
        cache[provider] = image
        return image
    }
}

/// A square, tintable provider brand glyph. Falls back to an SF Symbol when the
/// bundled brand SVG is unavailable.
struct ProviderGlyph: View {
    let provider: Provider
    var size: CGFloat = 14

    var body: some View {
        Group {
            if let image = ProviderBrandIcon.image(for: provider) {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
            } else {
                Image(systemName: ProviderBrandIcon.fallbackSymbol(for: provider))
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
    }
}
