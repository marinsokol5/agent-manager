import Foundation

/// The user's own executable for the `custom` ping method, stored as an argv —
/// never as a shell string.
///
/// Why argv: hard rule 5 says we never hand an interpolated string to
/// `/bin/sh -c`. The Preferences field *looks* like a command line because
/// that's the natural way to type one, but it is parsed here, once, into an
/// absolute executable plus an argument array, and that array is what reaches
/// `Process`. Nothing about it is ever re-joined and re-interpreted. A user who
/// wants pipes, globs, or `&&` points the method at their own script — or says
/// so explicitly with `/bin/zsh -lc '…'` — and it still reaches us as argv.
///
/// The parse is deliberately a small, predictable subset of POSIX shell word
/// splitting so that whatever someone pastes from a terminal means the same
/// thing here:
/// - unquoted whitespace (space, tab, newline) separates words;
/// - `'…'` is literal, with no escapes at all;
/// - `"…"` honors `\"` and `\\` and keeps every other backslash verbatim;
/// - outside quotes, `\x` is a literal `x`;
/// - quoted and unquoted runs that touch concatenate into one word, so
///   `'it'\''s'` is `it's` — which is exactly what `commandLine` emits.
/// There is no variable, glob, or command expansion. The one convenience is a
/// leading `~` / `~/` on the *executable*, expanded once at parse time so the
/// stored path is always absolute.
public struct CustomPingCommand: Codable, Sendable, Equatable {
    /// Absolute path to the executable `Process` launches.
    public var executable: String
    /// Passed verbatim as `Process.arguments` — no shell ever sees them.
    public var arguments: [String]

    public init(executable: String, arguments: [String] = []) {
        self.executable = executable
        self.arguments = arguments
    }

    private enum CodingKeys: String, CodingKey { case executable, arguments }

    /// Forgiving like the rest of `preferences.json`: a hand-written entry
    /// with no `arguments` is a bare executable, not a decode failure.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        executable = try c.decode(String.self, forKey: .executable)
        arguments = (try? c.decodeIfPresent([String].self, forKey: .arguments)) ?? []
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case empty
        case unterminatedQuote(Character)
        case danglingBackslash
        case relativePath(String)
        case notFound(String)
        case notExecutable(String)

        public var description: String {
            switch self {
            case .empty:
                "Enter a command — an absolute path to an executable, then any arguments."
            case let .unterminatedQuote(q):
                "Unterminated \(q) quote."
            case .danglingBackslash:
                "Trailing backslash has nothing to escape."
            case let .relativePath(p):
                "\(p) is not an absolute path — start with / or ~/ (there is no PATH lookup)."
            case let .notFound(p):
                "\(p) does not exist."
            case let .notExecutable(p):
                "\(p) is not an executable file (chmod +x it, or run it via its interpreter)."
            }
        }
    }

    /// Parse one command line into a validated command.
    ///
    /// Validation happens here *and* again at run time (`validate`): the file
    /// can disappear or lose its `x` bit between the moment it was saved and
    /// the morning it fires, and a bad stored value must fail the ping loudly
    /// rather than launch something else.
    public static func parse(
        _ line: String,
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default)
        throws -> CustomPingCommand
    {
        var words = try tokenize(line)
        guard !words.isEmpty else { throw ParseError.empty }
        words[0] = expandTilde(words[0], homeDirectory: homeDirectory)
        let command = CustomPingCommand(executable: words[0], arguments: Array(words.dropFirst()))
        try command.validate(fileManager: fileManager)
        return command
    }

    /// Check the stored executable is still something `Process` can launch.
    /// No PATH search, on purpose: what runs at 6am must not depend on whose
    /// `PATH` the daemon happened to inherit.
    public func validate(fileManager: FileManager = .default) throws {
        guard executable.hasPrefix("/") else { throw ParseError.relativePath(executable) }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: executable, isDirectory: &isDirectory) else {
            throw ParseError.notFound(executable)
        }
        // `isExecutableFile` is also true for a searchable directory.
        guard !isDirectory.boolValue, fileManager.isExecutableFile(atPath: executable) else {
            throw ParseError.notExecutable(executable)
        }
    }

    /// Render the stored argv back as one editable line that `parse` reads
    /// back to the same argv. Words made only of shell-inert characters stay
    /// bare; anything else is single-quoted, with embedded `'` spelled `'\''`.
    public var commandLine: String {
        ([executable] + arguments).map(Self.quote).joined(separator: " ")
    }

    // MARK: - Pure pieces

    /// Split a command line into words (see the type doc for the rules).
    /// Public so the Preferences field can swap just the executable when the
    /// user picks one with "Choose…" and keep the arguments they typed.
    public static func tokenize(_ line: String) throws -> [String] {
        var words: [String] = []
        var current = ""
        // Distinguishes "no word yet" from an explicitly empty word (`''`).
        var inWord = false
        var it = Array(line)[...]

        while let c = it.popFirst() {
            switch c {
            case " ", "\t", "\n", "\r":
                if inWord { words.append(current); current = ""; inWord = false }
            case "'":
                inWord = true
                guard let end = it.firstIndex(of: "'") else { throw ParseError.unterminatedQuote("'") }
                current += String(it[it.startIndex..<end])
                it = it[(end + 1)...]
            case "\"":
                inWord = true
                var closed = false
                while let d = it.popFirst() {
                    if d == "\"" { closed = true; break }
                    if d == "\\", let next = it.first, next == "\"" || next == "\\" {
                        current.append(next)
                        it = it.dropFirst()
                    } else {
                        current.append(d)
                    }
                }
                guard closed else { throw ParseError.unterminatedQuote("\"") }
            case "\\":
                guard let next = it.popFirst() else { throw ParseError.danglingBackslash }
                inWord = true
                current.append(next)
            default:
                inWord = true
                current.append(c)
            }
        }
        if inWord { words.append(current) }
        return words
    }

    /// `~` → home, `~/x` → home/x. `~user` is left alone (no user lookup) and
    /// then fails the absolute-path check, which names the problem.
    static func expandTilde(_ word: String, homeDirectory: String) -> String {
        if word == "~" { return homeDirectory }
        if word.hasPrefix("~/") { return homeDirectory + word.dropFirst() }
        return word
    }

    private static let bareSafe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")

    static func quote(_ word: String) -> String {
        if !word.isEmpty, word.allSatisfy({ bareSafe.contains($0) }) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
