import Foundation

/// Resolves a CLI binary name to an absolute executable path.
///
/// An explicit path (anything containing `/`) is taken as-is if executable;
/// otherwise we search `PATH` plus the usual install dirs. The `claude` on a
/// stripped `PATH` is often a session shim, so common real locations are
/// appended as a fallback. Shared by the PTY runners (ping/login) and the
/// `am run` launcher so every spawned CLI is found the same way.
public enum ExecutableResolver {
    public static func resolve(
        _ name: String,
        environment: [String: String],
        fileManager: FileManager = .default)
        -> String?
    {
        resolveAll(name, environment: environment, fileManager: fileManager, limit: 1).first
    }

    /// Every executable named `name` along that same search path, in order.
    ///
    /// Deduplicated by the file each entry ultimately points at: `python3`
    /// commonly appears two or three times as symlinks into one Cellar/version
    /// directory, and a caller that has to *ask each candidate a question* (see
    /// `SDKPingRunner.runtime`, which probes interpreters for an installed
    /// module) would otherwise pay for the same answer repeatedly. `limit` caps
    /// how many distinct executables a pathological `PATH` can produce.
    public static func resolveAll(
        _ name: String,
        environment: [String: String],
        fileManager: FileManager = .default,
        limit: Int = 8)
        -> [String]
    {
        guard limit > 0 else { return [] }
        if name.contains("/") {
            return fileManager.isExecutableFile(atPath: name) ? [name] : []
        }
        let home = environment["HOME"] ?? NSHomeDirectory()
        var dirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

        var seen = Set<String>()
        var found: [String] = []
        for dir in dirs where !dir.isEmpty {
            let candidate = (dir as NSString).appendingPathComponent(name)
            guard fileManager.isExecutableFile(atPath: candidate) else { continue }
            let identity = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
            guard seen.insert(identity).inserted else { continue }
            found.append(candidate)
            if found.count >= limit { break }
        }
        return found
    }
}
