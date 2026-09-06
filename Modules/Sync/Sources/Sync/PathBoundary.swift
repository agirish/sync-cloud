import Foundation

/// Boundary-safe path prefix math — the ONE implementation of "is `path` inside `root`, and if
/// so, what is it relative to `root`?".
///
/// This exact logic has a bug history: a bare `hasPrefix(root)` strip claims sibling folders that
/// merely share a string prefix (root `/root/ab` also "contains" `/root/abc/x`), which round 3
/// fixed in `FilingEngine.destination(from:providerRoot:existingRelative:)` and which
/// `FileSyncManager.isNodeIgnored` re-fixed for pane roots. Several more hand-rolled copies of
/// the `== root || hasPrefix(root + "/")` check had grown around the Sync module; round 5 pulled
/// them onto this helper so the boundary rule can't drift copy by copy.
///
/// Semantics (mirroring the hardened `isNodeIgnored` math exactly):
/// - One trailing slash on `root` is ignored: `/a/b/` behaves as `/a/b`.
/// - `path == root` (after that normalization) relativizes to `""`.
/// - A child strips `root + "/"`: `relativize("/a/b/c", under: "/a/b") == "c"`.
/// - A sibling sharing only a string prefix is OUTSIDE: `relativize("/a/bc", under: "/a/b") == nil`.
/// - Root `"/"` normalizes to the empty base, so every absolute path is inside it:
///   `relativize("/x/y", under: "/") == "x/y"`.
/// - An EMPTY root claims nothing: `relativize(anything, under: "") == nil`. It is the absence of
///   a root, not the volume root — the two used to be indistinguishable here, because `""` and
///   `"/"` both reduce to an empty base, so an empty root prefix-matched every absolute path.
/// - Pure string math, no filesystem access: paths are compared exactly as given (no symlink or
///   case canonicalization, matching every call site this replaced) — **with one table of
///   exceptions, read once**: the folders macOS links INTO a root from outside it, see
///   ``linkedFolders(atRoot:in:)``. A path under such a folder's real location is inside the
///   root that links to it, and relativizes through the link's name.
public enum PathBoundary {

    // MARK: - Folders linked into a root

    /// Per root, the top-level names that are links to folders OUTSIDE that root, and where each
    /// one really lives: `[normalized root: [link name: absolute target]]`.
    ///
    /// **One root has any, and it is why this exists: iCloud Drive with Desktop & Documents
    /// syncing on.** macOS keeps the real trees at `~/Desktop` and `~/Documents` and leaves
    /// hidden symlinks named `Desktop` and `Documents` in the iCloud Drive container
    /// (``iCloudDriveContainer``). Finder shows them as two ordinary folders at the top of iCloud
    /// Drive, and this app does the same — but every absolute path the app stores for a file in
    /// them (a filing profile's root, an Organize scope, an automation's destination, every cache)
    /// is spelled the REAL way, `~/Documents/…`, and has been since before iCloud had a root above
    /// Documents at all. So a root-relative `Documents/Family` on the iCloud source composes to
    /// `~/Documents/Family` (``join(root:relative:links:)``), and `~/Documents/Family` relativizes
    /// back to `Documents/Family` (``relativize(_:under:links:)``): the two spellings meet here,
    /// and nowhere else has to know there are two.
    ///
    /// The link-side spelling, `…/com~apple~CloudDocs/Documents/Family`, relativizes the same way
    /// by plain prefix math, so a caller holding either spelling gets one answer — but the app
    /// never produces that spelling itself: the tree walk lists the two links as the real folders
    /// they point at (`FileSyncManager.buildTree`), and `FileManager`'s URL-based enumerators
    /// refuse to traverse a path whose last component IS a symlink (measured: `enumerator(at:)`
    /// on the link returns zero entries; on a real folder below it, the entries), which is the
    /// other reason the composed path is the real one.
    public typealias LinkedFolders = [String: [String: String]]

    /// Where iCloud Drive keeps what it syncs: the container whose top level Finder shows as
    /// "iCloud Drive".
    public static let iCloudDriveContainer: String =
        NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs"

    /// The two names macOS links into the iCloud Drive container when Desktop & Documents syncing
    /// is on. Read by name rather than by listing the container: two `readlink`s, no enumeration
    /// of an iCloud-backed directory (see the note on `contentsOfDirectory` stalls in
    /// `FileSyncManager+Scanning`).
    static let iCloudSyncedFolderNames = ["Desktop", "Documents"]

    /// **The table, as this machine has it — read once, the first time any boundary call
    /// consults it, and constant afterwards.** Turning Desktop & Documents syncing on or off is a
    /// relaunch away from being noticed, which is also how long it takes macOS to move the trees.
    ///
    /// Empty on a Mac without the links, and then every call here is the plain prefix math the
    /// type doc describes. Tests never read it: every function that consults the table takes it
    /// as a parameter with this as the default, and a fixture passes its own.
    public static let discoveredLinkedFolders: LinkedFolders =
        discoverLinkedFolders(atRoot: iCloudDriveContainer, names: iCloudSyncedFolderNames)

    /// Builds the table for one root from the links it has, by name.
    ///
    /// - Parameter readLink: what the link points at, or nil when the name is not a link. The
    ///   production reader is `destinationOfSymbolicLink(atPath:)`; a relative target is taken
    ///   relative to the root, as the filesystem would, and `..` is collapsed.
    ///
    /// Two links are not recorded. One that resolves back INTO the root: the table is for folders
    /// kept outside it, and a link inside would only make one folder reachable by two relative
    /// paths. And one whose target is not itself named as the link is — `Documents → ~/Docs` —
    /// because the tree walk names a row after the folder it lists (`FileSyncManager.buildTree`
    /// substitutes the target for the link), and a row reading `Docs` under a crumb reading
    /// `Documents` is two names for one folder. macOS's two links both keep their name.
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

    /// `.` and `..` components folded away, lexically — not `NSString.standardizingPath`, which
    /// also strips `/private` from a path under it and resolves symlinks under `/var`, neither of
    /// which a table of link targets may do: the target must be spelled as the filesystem spells
    /// it, or the walk's substituted node and the composed pane path stop being one string.
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

    /// The links at `root`, keyed by name — `[:]` for a root that has none, which is every root
    /// but one.
    public static func linkedFolders(atRoot root: String,
                                     in links: LinkedFolders = discoveredLinkedFolders) -> [String: String] {
        guard !links.isEmpty else { return [:] }
        return links[normalizedRoot(root)] ?? [:]
    }

    /// `path` relative to `root`, or nil when `path` is not `root` itself and not inside it.
    /// The exact match returns `""`.
    public static func relativize(_ path: String, under root: String,
                                  links: LinkedFolders = discoveredLinkedFolders) -> String? {
        if let lexical = lexicalRelativize(path, under: root) { return lexical }
        // Not under the root by prefix: is it under a folder the root links to? `Documents/…`
        // through the link named `Documents`. Checked second so the link-side spelling of the
        // same folder, which IS a prefix match, never reaches here and never differs.
        for (name, target) in linkedFolders(atRoot: root, in: links) {
            if let below = lexicalRelativize(path, under: target) {
                return joinRelative(name, below)
            }
        }
        return nil
    }

    /// `relativize` with the table left out — the prefix math alone, which is what the type doc
    /// describes and what every call before the table existed got.
    static func lexicalRelativize(_ path: String, under root: String) -> String? {
        // An EMPTY root is the ABSENCE of a root, not the volume root — and it must never claim a
        // path. Without this the normalization below leaves an empty base, which prefixes every
        // absolute path, so `contains(_:under:)` answered true for everything and `relativize`
        // handed back a near-absolute "Users/…" as though it were root-relative.
        //
        // That is the same empty-root hazard `transferItems` and `createFolder` each guard
        // separately before they build a URL (an empty path resolves against the process working
        // directory), and it reaches here the same way: a provider dropped from settings while its
        // stale tree is still on screen. Those guards stay — this closes the helper that the
        // module's boundary math is supposed to be the single implementation of, so a future caller
        // cannot inherit the permissive answer by forgetting a check of its own.
        //
        // Root "/" is unaffected: it normalizes to an empty BASE by design (see the type doc), and
        // the guard tests the argument, not the base.
        guard !root.isEmpty else { return nil }
        let base = root.hasSuffix("/") ? String(root.dropLast()) : root
        if path == base { return "" }
        guard path.hasPrefix(base + "/") else { return nil }
        return String(path.dropFirst(base.count + 1))
    }

    /// Whether `path` is `root` itself or inside it — `relativize` as a containment test, for the
    /// scope filters that only need the boolean.
    public static func contains(_ path: String, under root: String,
                                links: LinkedFolders = discoveredLinkedFolders) -> Bool {
        relativize(path, under: root, links: links) != nil
    }

    /// `root` with `relative` appended — the ONE implementation of the composition `relativize`
    /// undoes, and the inverse it is paired with everywhere a source's root meets a root-relative
    /// path (a pane's focus, a tab's stored position, a source's `openAt`).
    ///
    /// A LEADING SLASH on `relative` yields the bare root, deliberately. An absolute path is not a
    /// relative one, and the two cannot be distinguished after `appendingPathComponent` has run
    /// them together — `/a/b` + `/c/d` is `/a/b/c/d`, which names a folder nobody asked for and
    /// which usually exists nowhere, so the failure surfaces as an empty pane rather than as a
    /// wrong one. Falling back to the root keeps a caller that built its relative half wrongly at a
    /// place it is entitled to be. This is the shape `PaneLogic.fullPath` shipped with; it is
    /// hoisted here so the rule holds for `CloudProvider.landingPath` too rather than being
    /// re-derived per call site.
    ///
    /// An EMPTY root yields the empty string, for the same reason `relativize` refuses one: `""` is
    /// the ABSENCE of a root, not the volume root. Left to `appendingPathComponent` it produces the
    /// relative half unchanged — `"" + "Documents/Family"` is `"Documents/Family"` — which is not a
    /// pane path at all but a path that resolves against the PROCESS WORKING DIRECTORY, and the
    /// empty root is a state this app reaches ordinarily: `SettingsManager.rootPath(for:)` answers
    /// `""` for a provider dropped from settings while its stale tree is still on screen. The
    /// several call sites that guard `!root.isEmpty` before composing — `FileActionHandler`,
    /// `transferItems`, `createFolder` — stay exactly as they are; this closes the composition
    /// itself, so a future caller cannot inherit the permissive answer by forgetting a check.
    ///
    /// The tilde is expanded on the ROOT only: roots are stored abbreviated (`~/Documents`,
    /// `FolderSource.abbreviated`), while a root-relative path never begins with one.
    ///
    /// **A first component that names a linked folder composes onto where that folder really
    /// is**: `join(root: <iCloud Drive>, relative: "Documents/Family")` is `~/Documents/Family`,
    /// not `<iCloud Drive>/Documents/Family`. The two name one folder on disk, and the first is
    /// the spelling every stored absolute path already uses — see ``LinkedFolders``.
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

    /// Two root-relative paths joined — `""` for either side short-circuits, so no empty component
    /// can produce a doubled or leading separator.
    ///
    /// The composition a rebase performs (`"Documents"` + `"Family/Photos"`), kept next to `join`
    /// because the invariant that matters is shared: what comes out is canonical root-relative
    /// form, never something `join` would then discard for having a leading slash.
    public static func joinRelative(_ prefix: String, _ relative: String) -> String {
        if prefix.isEmpty { return relative }
        if relative.isEmpty { return prefix }
        return prefix + "/" + relative
    }

    /// The ONE spelling of a provider root used as a dictionary key: tilde expanded, trailing
    /// slashes trimmed, and deliberately nothing more.
    ///
    /// Case-folding would merge two genuinely distinct roots on a case-sensitive volume, and
    /// symlink resolution would make a key depend on disk state that can change under a persisted
    /// pin. `FolderJumpStore.key(forRoot:)` is this rule — the app carries both spellings of a
    /// folder source's path (the panes hand over the stored `~/…` form, surfaces that touch the
    /// disk expand it first), and used raw as keys those two never met.
    public static func normalizedRoot(_ root: String) -> String {
        var path = (root as NSString).expandingTildeInPath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// One pane's root-relative position, re-expressed for a pane whose source opens somewhere
    /// else — the translation linked navigation needs now that two panes' roots no longer share an
    /// origin.
    ///
    /// **Why it is needed at all.** Linked panes drive both sides with ONE relative path, and that
    /// was exact while every source was rooted at its documents folder: `Family` meant the same
    /// place on both. Sources now start at the account folder and land at `openAt` — `""` for
    /// iCloud, `Documents` for OneDrive and Dropbox, `My Drive/Documents` for Google Drive — so the
    /// same string names folders up to two components apart. Left OneDrive at `Documents/Family`,
    /// linked to an iCloud right, sent the right pane to `~/Documents/Documents/Family`, which does
    /// not exist; the other direction was worse, because `<account>/Family` often DOES exist and is
    /// a different tree, so the comparison quietly diffed the wrong pair and Sync acted on it.
    ///
    /// **The translation is anchor-relative, and it degrades rather than guessing.** Below the
    /// landing folder, the shared position is what the two panes have in common. At or above it
    /// there is no landing-relative reading — a pane at the account root is somewhere its sibling's
    /// anchor cannot express — so the path is carried across unchanged, which is exactly what
    /// linked navigation did before this existed.
    /// An EMPTY source anchor is handled here rather than through `relativize`, which answers nil
    /// for an empty root by design (`""` is the ABSENCE of a root, not the volume root). An empty
    /// `openAt` is not an absent anchor — it is the landing folder being the root itself, which is
    /// iCloud's ordinary state and therefore the commonest half of every mixed pair. Everything is
    /// below it, so the position passes through whole.
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

    /// Whether two paths name the SAME directory, folding case when the volume does.
    ///
    /// The one implementation of filing's "the chosen folder IS the file's current folder" test,
    /// which decides whether a file is left alone or moved. It had been spelled as `==` at three
    /// separate sites, and exact comparison is wrong on the default (case-insensitive) macOS
    /// volume: an automation destination template is matched case-insensitively by design, so a
    /// hand-typed `documents/inbox` naming the on-disk `Documents/Inbox` is expected input. Read
    /// exactly, the destination looked like a DIFFERENT folder from the file's parent, so the
    /// move went ahead — `fileExists` then found the file itself (case collapsed on disk), the
    /// unique-name helper stepped around it, and the file was renamed in place to "name 2" under
    /// a banner claiming it had been filed.
    ///
    /// `caseSensitive` is the volume's own answer (`volumeSupportsCaseSensitiveNames`), which
    /// fails to false — and false is the safe direction here: treating two spellings as one
    /// folder at worst declines a move the user can repeat with the exact case, while treating
    /// one folder as two renames a file nobody asked to rename.
    ///
    /// Note this is deliberately NOT `standardizedFileURL` + `==`: standardization resolves `..`
    /// and trailing slashes but never case, which is exactly the part that was missing.
    public static func namesSameDirectory(_ a: String, _ b: String, caseSensitive: Bool) -> Bool {
        let sa = URL(fileURLWithPath: a).standardizedFileURL.path
        let sb = URL(fileURLWithPath: b).standardizedFileURL.path
        if caseSensitive { return sa == sb }
        return sa.caseInsensitiveCompare(sb) == .orderedSame
    }
}
