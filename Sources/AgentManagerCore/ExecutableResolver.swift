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
        if name.contains("/") {
            return fileManager.isExecutableFile(atPath: name) ? name : nil
        }
        let home = environment["HOME"] ?? NSHomeDirectory()
        var dirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        for dir in dirs where !dir.isEmpty {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
