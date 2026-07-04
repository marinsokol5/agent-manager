import Foundation

/// Pure parsing of a login PTY transcript — factored out so it's unit-testable
/// without spawning a process.
public enum LoginOutputParser {
    /// Substrings the CLI prints once login completes (Claude and Codex).
    public static let successMarkers = [
        "Successfully logged in",
        "Login successful",
        "Logged in successfully",
        "Logged in to Codex",
        "Successfully logged in to",
    ]

    /// True if the transcript contains any success marker.
    public static func indicatesSuccess(_ text: String) -> Bool {
        successMarkers.contains { text.contains($0) }
    }

    /// The first `http(s)://…` URL in the transcript, with trailing punctuation
    /// (often introduced by line-wrapping / ANSI) stripped.
    public static func firstURL(in text: String) -> String? {
        let pattern = #"https?://[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let r = Range(match.range, in: text) else { return nil }
        var url = String(text[r])
        let trailing = CharacterSet(charactersIn: ".,;:)]}>\"'")
        while let last = url.unicodeScalars.last, trailing.contains(last) {
            url.unicodeScalars.removeLast()
        }
        return url
    }
}
