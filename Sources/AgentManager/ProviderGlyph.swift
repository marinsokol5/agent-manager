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

    /// The SwiftPM resource bundle carrying the brand SVGs, resolved ourselves
    /// rather than via `Bundle.module`.
    ///
    /// `Bundle.module`'s generated accessor looks for the bundle next to
    /// `Bundle.main.bundleURL` — the *app root* for a packaged `.app` — and
    /// otherwise falls back to a build-dir path baked in at compile time. In a
    /// shipped `.app` the bundle lives in `Contents/Resources` (a resource bundle
    /// can't sit at the app root — codesign rejects unsealed contents there), and
    /// the build path is absent on any machine but the builder's, so
    /// `Bundle.module` `fatalError`s at launch on a user's machine. We instead
    /// look under `resourceURL` (which is `Contents/Resources` for the `.app` and
    /// the executable's directory for a bare `swift build` binary — both correct),
    /// and degrade to the SF Symbol fallback if it's ever missing (never crash).
    private static let resourceBundle: Bundle? = {
        let name = "AgentManager_AgentManager.bundle"
        for base in [Bundle.main.resourceURL, Bundle.main.bundleURL] {
            if let url = base?.appendingPathComponent(name), let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return nil
    }()

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
        guard let url = resourceBundle?.url(forResource: resourceName(for: provider), withExtension: "svg"),
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
