import Foundation

/// Mirrors the depth-1 children of a provider's source home (`~/.claude`) into an
/// account's managed home, so the new isolated account **shares your static
/// config** without colliding on identity.
///
/// Per the design's sharing caveats:
/// - the **identity file** (`.claude.json`) is never linked — it stays real and
///   per-account (login writes it);
/// - the shared config files each CLI rewrites (Claude's `settings.json`,
///   Codex's `config.toml`) are **symlinked** — they're edited in place, so a
///   plugin/hook/permission enabled in the source home stays live across the
///   whole source-home group instead of freezing at account-creation. (A file
///   rewritten via atomic temp-and-rename would instead need copying, so
///   `rewrittenConfigFiles` stays the escape hatch — it's just empty today.)
/// - everything else is symlinked. New files *inside* an already-linked dir
///   resolve through the dir symlink automatically; only new *top-level* entries
///   need reconciling, which `apply()` does (it's re-runnable).
///
/// `apply()` only ever **adds** missing entries. It never converts an existing
/// real entry into a symlink, so a runtime dir the CLI created locally inside the
/// account home (e.g. `projects/`) is left untouched.
public struct SymlinkFarm {
    public let provider: Provider
    public let sourceHome: URL
    public let managedHome: URL
    let fileManager: FileManager

    public init(provider: Provider, sourceHome: URL, managedHome: URL, fileManager: FileManager = .default) {
        self.provider = provider
        self.sourceHome = sourceHome
        self.managedHome = managedHome
        self.fileManager = fileManager
    }

    /// What to do with a single depth-1 child of the source home.
    public enum Action: String, Equatable, Sendable {
        /// Static / shareable / blendable-runtime → symlink to the source child.
        case symlink
        /// CLI rewrites it in place → copy on create (don't link).
        case copy
        /// The identity file → never link or copy; stays real and per-account.
        case skipIdentity
        /// Per-account local entry (e.g. `backups/`) → never link or copy.
        case skipLocal
    }

    public struct PlanItem: Equatable, Sendable {
        public let name: String
        public let action: Action
    }

    /// What actually happened to one child when the plan was applied.
    public enum Result: String, Equatable, Sendable {
        case linked
        case copied
        case skippedIdentity
        case skippedLocal
        case removedStaleLink
        case alreadyPresent
        case failed
    }

    public struct ApplyItem: Equatable, Sendable {
        public let name: String
        public let result: Result
        public let detail: String?
    }

    public struct ApplyReport: Equatable, Sendable {
        public var items: [ApplyItem]
        public var linked: Int { items.filter { $0.result == .linked }.count }
        public var copied: Int { items.filter { $0.result == .copied }.count }
        public var alreadyPresent: Int { items.filter { $0.result == .alreadyPresent }.count }
        public var skippedIdentity: Int { items.filter { $0.result == .skippedIdentity }.count }
        public var skippedLocal: Int { items.filter { $0.result == .skippedLocal }.count }
        public var failures: [ApplyItem] { items.filter { $0.result == .failed } }

        /// One-line summary for the audit log.
        public var summary: String {
            "linked=\(linked) copied=\(copied) kept=\(alreadyPresent) "
                + "identity=\(skippedIdentity) local=\(skippedLocal) failed=\(failures.count)"
        }
    }

    /// Classify a depth-1 child by name only. Pure — no I/O.
    public func classify(_ name: String) -> Action {
        if name == provider.identityFileName { return .skipIdentity }
        if provider.localOnlyEntries.contains(name) { return .skipLocal }
        if provider.rewrittenConfigFiles.contains(name) { return .copy }
        return .symlink
    }

    /// The depth-1 plan from the current source-home contents.
    public func plan() throws -> [PlanItem] {
        let children = try fileManager.contentsOfDirectory(atPath: sourceHome.path)
        return children
            .sorted()
            .map { PlanItem(name: $0, action: classify($0)) }
    }

    /// Apply (and re-apply / reconcile) the plan: ensure the managed home exists,
    /// then for each source child create the link/copy *only if it's missing*.
    @discardableResult
    public func apply() throws -> ApplyReport {
        if !fileManager.fileExists(atPath: managedHome.path) {
            try fileManager.createDirectory(
                at: managedHome,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }

        var items: [ApplyItem] = []
        for item in try plan() {
            let dest = managedHome.appendingPathComponent(item.name)
            let src = sourceHome.appendingPathComponent(item.name)

            switch item.action {
            case .skipIdentity, .skipLocal:
                // Heal a stale link from an older run: if this name is a symlink
                // (pointing into the shared source) we remove it — it should be
                // real/per-account. Never touch a real file/dir living here.
                if isSymlink(dest) {
                    try? fileManager.removeItem(at: dest)
                    items.append(ApplyItem(name: item.name, result: .removedStaleLink, detail: "was a symlink into the source"))
                } else {
                    let result: Result = item.action == .skipIdentity ? .skippedIdentity : .skippedLocal
                    items.append(ApplyItem(name: item.name, result: result, detail: nil))
                }

            case .symlink:
                if entryExists(dest) {
                    items.append(ApplyItem(name: item.name, result: .alreadyPresent, detail: nil))
                    continue
                }
                do {
                    try fileManager.createSymbolicLink(at: dest, withDestinationURL: src)
                    items.append(ApplyItem(name: item.name, result: .linked, detail: nil))
                } catch {
                    items.append(ApplyItem(name: item.name, result: .failed, detail: error.localizedDescription))
                }

            case .copy:
                if entryExists(dest) {
                    items.append(ApplyItem(name: item.name, result: .alreadyPresent, detail: nil))
                    continue
                }
                do {
                    try fileManager.copyItem(at: src, to: dest)
                    items.append(ApplyItem(name: item.name, result: .copied, detail: nil))
                } catch {
                    items.append(ApplyItem(name: item.name, result: .failed, detail: error.localizedDescription))
                }
            }
        }
        return ApplyReport(items: items)
    }

    /// True if anything exists at `url` — including a **dangling** symlink, which
    /// `FileManager.fileExists` (which follows links) would miss.
    private func entryExists(_ url: URL) -> Bool {
        if fileManager.fileExists(atPath: url.path) { return true }
        return (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    /// True only if `url` is itself a symbolic link (lstat semantics).
    private func isSymlink(_ url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}
