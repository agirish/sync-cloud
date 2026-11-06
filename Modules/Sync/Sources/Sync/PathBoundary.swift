import Foundation

/// Boundary-safe path prefix math: the one implementation of "is `path` inside `root`, and if so,
/// what is it relative to `root`?". A bare `hasPrefix(root)` claims siblings that merely share a
/// string prefix (root `/root/ab` "contains" `/root/abc/x`), so every such check goes through here
/// rather than being hand-rolled.
///
/// Semantics (matching `FileSyncManager.isNodeIgnored`):
/// - One trailing slash on `root` is ignored: `/a/b/` behaves as `/a/b`.
/// - `path == root` (after that normalization) relativizes to `""`.
/// - A child strips `root + "/"`: `relativize("/a/b/c", under: "/a/b") == "c"`.
/// - A sibling sharing only a string prefix is OUTSIDE: `relativize("/a/bc", under: "/a/b") == nil`.
/// - Root `"/"` normalizes to the empty base, so every absolute path is inside it:
///   `relativize("/x/y", under: "/") == "x/y"`.
/// - An empty root claims nothing: `relativize(anything, under: "") == nil`. It is the absence of
///   a root, not the volume root, though `""` and `"/"` both reduce to an empty base.
/// - Pure string math, no filesystem access: paths are compared exactly as given (no symlink or
///   case canonicalization), with one table of exceptions, read once: the folders macOS links into
///   a root from outside it (``linkedFolders(atRoot:in:)``). A path under such a folder's real
///   location is inside the root that links to it, and relativizes through the link's name.
public enum PathBoundary {

    // MARK: - Folders linked into a root

    /// Per root, the top-level names that are links to folders outside that root, and where each
    /// really lives: `[normalized root: [link name: absolute target]]`.
    ///
    /// Only one root has any: iCloud Drive with Desktop & Documents syncing on. macOS keeps the real
    /// trees at `~/Desktop` and `~/Documents` and leaves hidden symlinks to them in the iCloud Drive
    /// container (``iCloudDriveContainer``), which Finder and this app show as ordinary folders.
    /// Every absolute path the app stores for files in them (profile roots, Organize scopes,
    /// automation destinations, caches) uses the real spelling, `~/Documents/…`. So iCloud's
    /// root-relative `Documents/Family` composes to `~/Documents/Family`
    /// (``join(root:relative:links:)``) and relativizes back (``relativize(_:under:links:)``): the
    /// two spellings meet here, and nowhere else has to know.
    ///
    /// The link-side spelling, `…/com~apple~CloudDocs/Documents/Family`, relativizes the same way by
    /// plain prefix math, but the app never produces it: the tree walk lists the links as the real
    /// folders (`FileSyncManager.buildTree`), and `FileManager`'s URL enumerators return nothing
    /// for a path whose last component is a symlink.
    public typealias LinkedFolders = [String: [String: String]]

    /// Where iCloud Drive keeps what it syncs: the container whose top level Finder shows as
    /// "iCloud Drive".
    public static let iCloudDriveContainer: String =
        NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs"

    /// The two names macOS links into the iCloud Drive container when Desktop & Documents syncing
    /// is on. Read by name, two `readlink`s, rather than by listing an iCloud-backed directory,
    /// which can stall (see `contentsOfDirectory` in `FileSyncManager+Scanning`).
    static let iCloudSyncedFolderNames = ["Desktop", "Documents"]

    /// The table as this Mac has it: read once, on first use, and constant afterwards, so turning
    /// Desktop & Documents syncing on or off is noticed at the next launch.
    ///
    /// Empty without the links, leaving plain prefix math. Tests never read it: every function
    /// that consults the table takes it as a parameter defaulting to this, and fixtures pass their
    /// own.
    public static let discoveredLinkedFolders: LinkedFolders =
        discoverLinkedFolders(atRoot: iCloudDriveContainer, names: iCloudSyncedFolderNames)

    /// Builds the table for one root from the links it has, by name.
    ///
    /// - Parameter readLink: what the link points at, or nil when the name is not a link. The
    ///   production reader is `destinationOfSymbolicLink(atPath:)`; a relative target is taken
    ///   relative to the root, as the filesystem would, and `..` is collapsed.
    ///
    /// Two kinds of link are skipped. One that resolves back into the root, which would only make
    /// one folder reachable by two relative paths. And one whose target has a different name
    /// (`Documents → ~/Docs`): the tree walk names the row after the target
    /// (`FileSyncManager.buildTree`), so the row and the crumb would disagree. macOS's two links
    /// both keep their name.
    static func discoverLinkedFolders(
        atRoot root: String,
        names: [String],
        readLink: (String) -> String? = { try? FileManager.default.destinationOfSymbolicLink(atPath: $0) }
    ) -> LinkedFolders {
        let base = normalizedRoot(root)
        guard !base.isEmpty else { return [:] }
        var targets: [String: String] = [:]
        for name in names {
            guard let raw = readLink(base + "/" + name), !raw.isEmpty else { continue }
            let target = normalizedRoot(collapsingDots(raw.hasPrefix("/") ? raw : base + "/" + raw))
            guard lexicalRelativize(target, under: base) == nil,
                  (target as NSString).lastPathComponent == name else { continue }
            targets[name] = target
        }
        return targets.isEmpty ? [:] : [base: targets]
    }

    /// `.` and `..` components folded away, lexically. Not `NSString.standardizingPath`, which also
    /// strips `/private` and resolves symlinks under `/var`: the target must be spelled as the
    /// filesystem spells it, or the walk's substituted node and the composed pane path differ.
    static func collapsingDots(_ path: String) -> String {
        var out: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": _ = out.popLast()
            default: out.append(String(component))
            }
        }
        return (path.hasPrefix("/") ? "/" : "") + out.joined(separator: "/")
    }

    /// The links at `root`, keyed by name: `[:]` for a root that has none, which is every root but
    /// one.
    public static func linkedFolders(atRoot root: String,
                                     in links: LinkedFolders = discoveredLinkedFolders) -> [String: String] {
        guard !links.isEmpty else { return [:] }
        // Looked up as given when there is nothing to normalize, which is nearly every call:
        // `relativize` lands here on every prefix miss, and normalizing each time cost several ms
        // per Duplicates or Restructure render. A root starting with `~`, ending in `/` or holding
        // a `//` still goes through `normalizedRoot`, the one spelling rule.
        if root.utf8.first != UInt8(ascii: "~"), root.utf8.last != UInt8(ascii: "/"), !root.contains("//") {
            return links[root] ?? [:]
        }
        return links[normalizedRoot(root)] ?? [:]
    }

    /// `path` relative to `root`, or nil when `path` is not `root` itself and not inside it.
    /// The exact match returns `""`.
    public static func relativize(_ path: String, under root: String,
                                  links: LinkedFolders = discoveredLinkedFolders) -> String? {
        if let lexical = lexicalRelativize(path, under: root) { return lexical }
        // Not under the root by prefix: is it under a folder the root links to (`Documents/…`
        // through the link named `Documents`)? Checked second, so the link-side spelling, a prefix
        // match, never reaches here.
        for (name, target) in linkedFolders(atRoot: root, in: links) {
            if let below = lexicalRelativize(path, under: target) {
                return joinRelative(name, below)
            }
        }
        return nil
    }

    /// `relativize` without the table: the prefix math alone.
    static func lexicalRelativize(_ path: String, under root: String) -> String? {
        // An empty root is the absence of a root and must never claim a path. Otherwise the empty
        // base below prefixes every absolute path, so `contains` is true for everything and
        // `relativize` returns "Users/…" as if root-relative. It happens when a provider is dropped
        // from settings while its stale tree is on screen; `transferItems` and `createFolder` guard
        // it too, and keep their guards. Root "/" is unaffected: the guard tests the argument, not
        // the base.
        guard !root.isEmpty else { return nil }
        let base = root.hasSuffix("/") ? String(root.dropLast()) : root
        if path == base { return "" }
        guard path.hasPrefix(base + "/") else { return nil }
        return String(path.dropFirst(base.count + 1))
    }

    /// Whether `path` is `root` itself or inside it: `relativize` as a containment test, for scope
    /// filters that only need the boolean.
    public static func contains(_ path: String, under root: String,
                                links: LinkedFolders = discoveredLinkedFolders) -> Bool {
        relativize(path, under: root, links: links) != nil
    }

    /// `root` with `relative` appended: the one implementation of the composition `relativize`
    /// undoes, wherever a source's root meets a root-relative path (a pane's focus, a tab's stored
    /// position, a source's `openAt`; also `PaneLogic.fullPath` and `CloudProvider.landingPath`).
    ///
    /// A leading slash on `relative` yields the bare root, deliberately: `/a/b` + `/c/d` would name
    /// a folder nobody asked for, usually showing as an empty pane. The root is a safe place to be.
    ///
    /// An empty root yields `""`, as `relativize` refuses one: otherwise the result is the relative
    /// half alone, which resolves against the process working directory. An empty root is
    /// ordinary: `SettingsManager.rootPath(for:)` answers `""` for a provider dropped from settings
    /// while its stale tree is on screen. Callers that guard `!root.isEmpty` themselves keep their
    /// guards.
    ///
    /// The tilde is expanded on the root only: roots are stored abbreviated (`~/Documents`,
    /// `FolderSource.abbreviated`), and a root-relative path never begins with one.
    ///
    /// A first component naming a linked folder composes onto where that folder really is:
    /// `join(root: <iCloud Drive>, relative: "Documents/Family")` is `~/Documents/Family`, the
    /// spelling stored paths use (``LinkedFolders``).
    public static func join(root: String, relative: String,
                            links: LinkedFolders = discoveredLinkedFolders) -> String {
        guard !root.isEmpty else { return "" }
        let expandedRoot = (root as NSString).expandingTildeInPath
        guard !relative.isEmpty, !relative.hasPrefix("/") else { return expandedRoot }
        let table = linkedFolders(atRoot: expandedRoot, in: links)
        if !table.isEmpty {
            let parts = relative.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            if let first = parts.first, let target = table[String(first)] {
                let rest = parts.count > 1 ? String(parts[1]) : ""
                return rest.isEmpty ? target : (target as NSString).appendingPathComponent(rest)
            }
        }
        return (expandedRoot as NSString).appendingPathComponent(relative)
    }

    /// Two root-relative paths joined; `""` on either side short-circuits, so no doubled or leading
    /// separator appears. The composition a rebase performs (`"Documents"` + `"Family/Photos"`):
    /// the result is canonical root-relative form, never something `join` would discard for a
    /// leading slash.
    public static func joinRelative(_ prefix: String, _ relative: String) -> String {
        if prefix.isEmpty { return relative }
        if relative.isEmpty { return prefix }
        return prefix + "/" + relative
    }

    /// The one spelling of a provider root used as a dictionary key: tilde expanded, trailing
    /// slashes trimmed, and deliberately nothing more.
    ///
    /// Case-folding would merge distinct roots on a case-sensitive volume, and symlink resolution
    /// would tie a key to disk state that can change under a persisted pin. The app carries both
    /// the stored `~/…` and the expanded spelling, so raw keys would never meet
    /// (`FolderJumpStore.key(forRoot:)` uses this).
    public static func normalizedRoot(_ root: String) -> String {
        var path = (root as NSString).expandingTildeInPath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// One pane's root-relative position, re-expressed for a pane whose source opens somewhere
    /// else: what linked navigation needs, since the panes' roots don't share an origin.
    ///
    /// Sources start at the account folder and land at `openAt` (`""` for iCloud, `Documents` for
    /// OneDrive and Dropbox, `My Drive/Documents` for Google Drive), so one relative string names
    /// folders up to two components apart. Passed raw, it can name a folder that doesn't exist or,
    /// worse, a different tree that does, so the comparison would diff the wrong pair and Sync
    /// would act on it.
    ///
    /// Anchor-relative, and it degrades rather than guessing: below the landing folder the
    /// position translates; at or above it there is no landing-relative reading, so the path is
    /// carried across unchanged.
    ///
    /// An empty source anchor is handled here, not through `relativize` (which refuses an empty
    /// root): an empty `openAt` means the landing folder is the root, iCloud's ordinary state, so
    /// everything is below it and passes through whole.
    public static func reanchor(_ relative: String, from source: String, to destination: String) -> String {
        guard source != destination else { return relative }
        let belowSource: String
        if source.isEmpty {
            belowSource = relative
        } else if let below = relativize(relative, under: source) {
            belowSource = below
        } else {
            return relative
        }
        return joinRelative(destination, belowSource)
    }

    /// Where a row a pane transfer carries lands in the other source, root-relative: `reanchor`
    /// below the landing folder, and its own translation at and above it. Nil when the other
    /// source has no place at that level.
    ///
    /// Linked navigation may carry a path across unchanged; a write may not. Unchanged, the landing
    /// folder itself would map to the other pane's root, so Replace would swap the whole root; and
    /// a row above the landing folder could land outside Google Drive's `My Drive`, which isn't
    /// synced.
    ///
    /// The landing folder itself goes where its contents go: onto the other landing folder (`""`
    /// when that is the root), offered as Merge only (`FileCollision.mergeOnly`), so the pane root
    /// is never replaced and nothing lands beside it.
    ///
    /// A sibling of the landing folder keeps its name and the same number of levels above the
    /// other landing folder: Dropbox `Photos/a.jpg` lands at Google Drive `My Drive/Photos/a.jpg`.
    /// A destination landing at its root takes every level there; any other not that deep: nil.
    public static func transferTarget(_ relative: String, from source: String, to destination: String) -> String? {
        guard source != destination else { return relative }
        if source.isEmpty { return joinRelative(destination, relative) }
        if let below = lexicalRelativize(relative, under: source) {
            return below.isEmpty ? destination : joinRelative(destination, below)
        }
        // At or above the landing folder: climb until the row is strictly below.
        var ancestor = source
        var levels = 0
        var below = relative
        repeat {
            ancestor = (ancestor as NSString).deletingLastPathComponent
            levels += 1
            if ancestor.isEmpty { below = relative; break }
            if let found = lexicalRelativize(relative, under: ancestor), !found.isEmpty { below = found; break }
        } while true
        let destinationParts = destination.split(separator: "/").map(String.init)
        if destinationParts.count >= levels {
            return joinRelative(destinationParts.dropLast(levels).joined(separator: "/"), below)
        }
        return destination.isEmpty ? below : nil
    }

    /// Whether two paths name the SAME directory, folding case when the volume does.
    ///
    /// The one implementation of filing's "the chosen folder is the file's current folder" test,
    /// which decides whether a file stays or moves. Exact `==` is wrong on a case-insensitive
    /// volume: a hand-typed `documents/inbox` naming `Documents/Inbox` would look like a different
    /// folder, the move would meet the file itself, and the file would be renamed in place to
    /// "name 2" under a banner saying it was filed.
    ///
    /// `caseSensitive` is the volume's answer (`volumeSupportsCaseSensitiveNames`), failing to
    /// false, the safe direction: two spellings taken as one folder at worst decline a move,
    /// while one folder taken as two renames a file. Not `standardizedFileURL` + `==` alone,
    /// which never folds case.
    public static func namesSameDirectory(_ a: String, _ b: String, caseSensitive: Bool) -> Bool {
        let sa = URL(fileURLWithPath: a).standardizedFileURL.path
        let sb = URL(fileURLWithPath: b).standardizedFileURL.path
        if caseSensitive { return sa == sb }
        return sa.caseInsensitiveCompare(sb) == .orderedSame
    }

    /// `namesSameDirectory`, and then the same test again on the paths the disk resolves them to.
    ///
    /// A folder link is a second spelling of the same folder: a destination reached through a
    /// symlink (`~/Filing` → `~/Documents/Inbox`) would otherwise read as a different folder, and
    /// the file would be renamed in place to "name 2", as in the case trap above.
    ///
    /// The string test goes first, so the common case touches no disk; only differing spellings
    /// are resolved (`resolvingSymlinksInPath`, one `lstat` per component). A folder filing would
    /// still create resolves only as far as its existing ancestors, so it never collapses onto the
    /// file's parent. Separate from the pure `namesSameDirectory`, which the engine runs per
    /// candidate; this is for the apply step and the automation preview that promises what it does.
    public static func resolvesToSameDirectory(_ a: String, _ b: String, caseSensitive: Bool) -> Bool {
        if namesSameDirectory(a, b, caseSensitive: caseSensitive) { return true }
        return namesSameDirectory(URL(fileURLWithPath: a).resolvingSymlinksInPath().path,
                                  URL(fileURLWithPath: b).resolvingSymlinksInPath().path,
                                  caseSensitive: caseSensitive)
    }
}
