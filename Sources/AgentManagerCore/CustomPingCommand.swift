import Foundation

/// What the `custom` ping method runs, in one of two explicit forms.
///
/// **argv** (`.argv`) — the user's own executable plus arguments, never a
/// shell string. Hard rule 5 says we never hand an interpolated string to
/// `/bin/sh -c`. The Preferences field *looks* like a command line because
/// that's the natural way to type one, but it is parsed here, once, into an
/// absolute executable plus an argument array, and that array is what reaches
/// `Process`. Nothing about it is ever re-joined and re-interpreted.
///
/// **login shell** (`.loginShell`) — a line in the user's *own* shell's syntax,
/// stored exactly as typed and run as `<their login shell> -l -c '<line>'`
/// (see `LoginShell`). It exists because a scheduled run inherits the daemon's
/// minimal launchd environment, not the user's profile; this form loads the
/// profile on purpose. It is rule 5's one narrow carve-out: the string the
/// shell sees is the user's own line plus a constant prologue whose values
/// travel only through env vars — nothing of ours is interpolated into it.
///
/// One type for both because it *is* the command: provider defaults and
/// per-account overrides store it the same way, and every reader resolves it
/// once (`Preferences.customCommand(forAccount:provider:)`) and hands it to
/// `CustomPingRunner`, which switches on the form.
///
/// Storage: the argv form encodes exactly as it always has —
/// `{"arguments":[…],"executable":"…"}` — so existing `preferences.json` files
/// stay byte-identical; the login-shell form is `{"loginShell":"<line>"}`.
///
/// The argv parse is deliberately a small, predictable subset of POSIX shell
/// word splitting so that whatever someone pastes from a terminal means the
/// same thing here:
/// - unquoted whitespace (space, tab, newline) separates words;
/// - `'…'` is literal, with no escapes at all;
/// - `"…"` honors `\"` and `\\` and keeps every other backslash verbatim;
/// - outside quotes, `\x` is a literal `x`;
/// - quoted and unquoted runs that touch concatenate into one word, so
///   `'it'\''s'` is `it's` — which is exactly what `commandLine` emits.
/// There is no variable, glob, or command expansion. The one convenience is a
/// leading `~` / `~/` on the *executable*, expanded once at parse time so the
/// stored path is always absolute.
public enum CustomPingCommand: Codable, Sendable, Equatable {
    /// Absolute executable + arguments passed verbatim as `Process.arguments`.
    case argv(executable: String, arguments: [String])
    /// One line in the user's login shell's syntax, exactly as typed.
    case loginShell(String)

    /// The argv form — the shape every pre-login-shell call site builds.
    public init(executable: String, arguments: [String] = []) {
        self = .argv(executable: executable, arguments: arguments)
    }

    /// The argv form's executable; `nil` for a login-shell line.
    public var executable: String? {
        if case let .argv(executable, _) = self { return executable }
        return nil
    }

    /// The argv form's arguments; empty for a login-shell line.
    public var arguments: [String] {
        if case let .argv(_, arguments) = self { return arguments }
        return []
    }

    public var isLoginShell: Bool {
        if case .loginShell = self { return true }
        return false
    }

    private enum CodingKeys: String, CodingKey { case executable, arguments, loginShell }

    /// Forgiving like the rest of `preferences.json`: a hand-written argv entry
    /// with no `arguments` is a bare executable, not a decode failure. A
    /// `loginShell` key selects the login-shell form; if it isn't a non-blank
    /// string the entry is malformed and throws, which the `Preferences`
    /// decoder turns into "unset" without losing the rest of the file.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.loginShell) {
            let line = try c.decode(String.self, forKey: .loginShell)
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .loginShell, in: c, debugDescription: "empty login-shell command")
            }
            self = .loginShell(line)
            return
        }
        let executable = try c.decode(String.self, forKey: .executable)
        let arguments = (try? c.decodeIfPresent([String].self, forKey: .arguments)) ?? []
        self = .argv(executable: executable, arguments: arguments)
    }

    /// The argv form writes the same two keys the synthesized encoding always
    /// did (an empty `arguments` included), so a file written before the
    /// login-shell form existed re-encodes byte-identically.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .argv(executable, arguments):
            try c.encode(executable, forKey: .executable)
            try c.encode(arguments, forKey: .arguments)
        case let .loginShell(line):
            try c.encode(line, forKey: .loginShell)
        }
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case empty
        case emptyShellLine
        case unterminatedQuote(Character)
        case danglingBackslash
        case relativePath(String)
        case notFound(String)
        case notExecutable(String)

        public var description: String {
            switch self {
            case .empty:
                "Enter a command — an absolute path to an executable, then any arguments."
            case .emptyShellLine:
                "Enter a command line for your login shell."
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

    /// Parse one command line into a validated **argv** command.
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

    /// Check the stored command can still run.
    ///
    /// argv: the executable is still something `Process` can launch. No PATH
    /// search, on purpose: what runs at 6am must not depend on whose `PATH`
    /// the daemon happened to inherit.
    ///
    /// login shell: the line isn't blank and the user's login shell (read now,
    /// via `loginShell`) is one we support. The line itself is never checked —
    /// it's in the user's shell's syntax, which only their shell can judge.
    /// Throws `ParseError` or `LoginShell.Problem`; both describe themselves.
    public func validate(
        fileManager: FileManager = .default,
        loginShell lookup: LoginShell.Lookup = LoginShell.systemLookup)
        throws
    {
        switch self {
        case let .argv(executable, _):
            guard executable.hasPrefix("/") else { throw ParseError.relativePath(executable) }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: executable, isDirectory: &isDirectory) else {
                throw ParseError.notFound(executable)
            }
            // `isExecutableFile` is also true for a searchable directory.
            guard !isDirectory.boolValue, fileManager.isExecutableFile(atPath: executable) else {
                throw ParseError.notExecutable(executable)
            }
        case let .loginShell(line):
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ParseError.emptyShellLine
            }
            if case let .failure(problem) = LoginShell.resolve(lookup: lookup, fileManager: fileManager) {
                throw problem
            }
        }
    }

    /// The command as one editable line. argv: rendered so that `parse` reads
    /// it back to the same argv — words made only of shell-inert characters
    /// stay bare; anything else is single-quoted, with embedded `'` spelled
    /// `'\''`. Login shell: the stored line itself, verbatim.
    public var commandLine: String {
        switch self {
        case let .argv(executable, arguments):
            ([executable] + arguments).map(Self.quote).joined(separator: " ")
        case let .loginShell(line):
            line
        }
    }

    /// The argv form as a line for a login shell of `family` — what the
    /// Preferences field converts to when the login-shell toggle is ticked —
    /// or `nil` when no faithful rendering exists; a login-shell line is
    /// returned as is.
    ///
    /// `commandLine`'s rendering (bare words, or `'…'` with `'\''` for an
    /// embedded quote) means the same words in every POSIX shell. In fish it
    /// does too, *except* for backslashes: inside fish single quotes `\\` and
    /// `\'` are escapes, so `'a\\b'` is `a\b` in fish but `a\\b` in sh, and a
    /// word ending in `\` leaves the quote unterminated. Rather than invent a
    /// second quoting scheme for one shell, any backslash in a fish rendering
    /// declines, and the caller keeps the text as the user typed it.
    public func loginShellLine(for family: LoginShell.Family) -> String? {
        switch self {
        case .loginShell:
            return commandLine
        case let .argv(executable, arguments):
            if family == .fish, ([executable] + arguments).contains(where: { $0.contains("\\") }) {
                return nil
            }
            return commandLine
        }
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
