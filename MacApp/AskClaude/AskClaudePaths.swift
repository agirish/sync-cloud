import Foundation

/// The two spellings of one folder, made one.
///
/// iCloud Drive’s Desktop and Documents are links: `…/com~apple~CloudDocs/Documents` points at
/// `~/Documents`. The pane’s tree holds the real spelling (a listing below a link resolves it),
/// while a path built from the source’s root holds the link spelling. Mixing them makes lookups
/// miss, and a file opened in Edit by the link spelling reads as another source and opens a new tab.
///
/// So: look things up by the real path, navigate by the root’s spelling, tell Claude the path
/// relative to the source either way, and hand Edit the real path.
enum AskClaudePaths {

    /// Symlinks resolved: the spelling the pane’s tree and Spotlight use.
    nonisolated static func canonical(_ path: String) -> String {
        (path as NSString).resolvingSymlinksInPath
    }

    /// Links directly inside `root` to folders elsewhere: real target → the link’s own path.
    ///
    /// Read once a minute per root, not per call: a search can spell thousands of paths, each
    /// asking this, and relisting the root every time costs a hundred thousand file-system calls on
    /// the main thread for one question.
    nonisolated static func aliases(of root: String) -> [(real: String, spelled: String)] {
        if let cached = aliasCache.lookup(root) { return cached }
        let fm = FileManager.default
        // A root that can't be listed is remembered too, so it isn't asked again on every call.
        guard let names = try? fm.contentsOfDirectory(atPath: root) else {
            aliasCache.store([], for: root)
            return []
        }
        let found = names.compactMap { name -> (real: String, spelled: String)? in
            let link = (root as NSString).appendingPathComponent(name)
            guard (try? fm.destinationOfSymbolicLink(atPath: link)) != nil else { return nil }
            return (canonical(link), link)
        }
        aliasCache.store(found, for: root)
        return found
    }

    private static let aliasCache = AliasCache()

    private final class AliasCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (when: Date, aliases: [(real: String, spelled: String)])] = [:]

        func lookup(_ root: String) -> [(real: String, spelled: String)]? {
            lock.withLock {
                guard let entry = entries[root], Date().timeIntervalSince(entry.when) < 60 else { return nil }
                return entry.aliases
            }
        }

        func store(_ aliases: [(real: String, spelled: String)], for root: String) {
            lock.withLock { entries[root] = (Date(), aliases) }
        }
    }

    /// `path` spelled under `root`, for navigation, when it lives below one of the root’s links.
    nonisolated static func spelled(_ path: String, root: String) -> String {
        let standard = (path as NSString).standardizingPath
        if standard == root || standard.hasPrefix(root + "/") { return standard }
        for alias in aliases(of: root) where standard == alias.real || standard.hasPrefix(alias.real + "/") {
            return alias.spelled + String(standard.dropFirst(alias.real.count))
        }
        return standard
    }

    /// An existing `path` as the disk spells it (case corrected, links resolved), put back under
    /// `root`'s own spelling; nil when it doesn't exist, isn't under the root, or is already right.
    nonisolated static func trueSpelling(_ path: String, root: String) -> String? {
        guard let real = path.withCString({ realpath($0, nil) }) else { return nil }
        defer { free(real) }
        let spelledPath = spelled(String(cString: real), root: root)
        guard spelledPath != path, spelledPath.lowercased() == path.lowercased() else { return nil }
        return spelledPath
    }

    /// `path` relative to `root`, whichever spelling it arrives in. Something outside the root
    /// answers with its last component only, so a home-folder path is never spelled out to Claude.
    nonisolated static func relative(_ path: String, root: String) -> String {
        let root = (root as NSString).standardizingPath
        let spelledPath = spelled(path, root: root)
        guard spelledPath == root || spelledPath.hasPrefix(root + "/") else { return (path as NSString).lastPathComponent }
        return String(spelledPath.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Whether two paths name the same file, whatever their spelling.
    nonisolated static func same(_ a: String, _ b: String) -> Bool {
        a == b || canonical(a) == canonical(b)
    }
}
