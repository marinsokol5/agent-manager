import Foundation

/// The build's marketing version (`CFBundleShortVersionString`, e.g. `0.1.2`) —
/// what `am --version` reports.
///
/// The single source of truth is `Support/Info.plist.in`; the Makefile copies it
/// into the assembled bundle's `Info.plist`, and `Scripts/release.sh` bumps it.
/// We resolve it two ways so both invocation shapes stay correct:
///
/// - **Shipped `am`** lives at `AgentManager.app/Contents/MacOS/am`, so
///   `Bundle.main` *is* the app bundle and `current` reads the real
///   `CFBundleShortVersionString` straight from it — programmatic, zero drift.
/// - **Bare SwiftPM binary** (`.build/debug/am` in dev) has no bundle, so the
///   info dictionary lacks the key and we fall back to the compiled `fallback`
///   constant. `Scripts/release.sh` rewrites that constant on every version bump,
///   so a fresh `swift build` right after a bump still prints the new number.
public enum AppVersion {
    /// Compiled-in version for the bare (unbundled) binary. Kept in lockstep with
    /// `Support/Info.plist.in` by `Scripts/release.sh` — edit both together, or
    /// just let a version bump via that script do it.
    public static let fallback = "0.3.1"

    /// Pull the version out of a bundle info dictionary, falling back to the
    /// compiled constant. Pure + injectable so it's testable without `Bundle.main`.
    public static func resolve(infoDictionary: [String: Any]?) -> String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? fallback
    }

    /// The running build's version — the app bundle's value when bundled, the
    /// compiled constant otherwise.
    public static var current: String { resolve(infoDictionary: Bundle.main.infoDictionary) }
}
