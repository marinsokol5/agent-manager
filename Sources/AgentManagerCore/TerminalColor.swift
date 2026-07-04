import Foundation

/// Small terminal-color helpers shared by the CLI's `am list` and the `am usage`
/// report: a filled identity dot in an account's `#RRGGBB` color, drawn with a
/// 24-bit ("truecolor") ANSI escape. Kept in Core so both surfaces render the
/// account's identity dot identically.
public enum TerminalColor {
    /// Parse `#RRGGBB` (or `RRGGBB`) into 0–255 components; nil if malformed.
    public static func rgb(fromHex hex: String) -> (r: Int, g: Int, b: Int)? {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        return ((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
    }

    /// A filled dot `●` in `hex`. When `color` is false (piped / `--no-color`) or
    /// the hex won't parse, the dot is left uncolored — never emits an escape — so
    /// plain output stays escape-free and column widths are unchanged.
    public static func dot(hex: String, color: Bool) -> String {
        guard color, let c = rgb(fromHex: hex) else { return "●" }
        return "\u{1B}[38;2;\(c.r);\(c.g);\(c.b)m●\u{1B}[0m"
    }
}
