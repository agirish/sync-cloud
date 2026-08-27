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
///   case canonicalization, matching every call site this replaced).
public enum PathBoundary {

    /// `path` relative to `root`, or nil when `path` is not `root` itself and not inside it.
    /// The exact match returns `""`.
    public static func relativize(_ path: String, under root: String) -> String? {
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
    public static func contains(_ path: String, under root: String) -> Bool {
        relativize(path, under: root) != nil
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
    /// The tilde is expanded on the ROOT only: roots are stored abbreviated (`~/Documents`,
    /// `FolderSource.abbreviated`), while a root-relative path never begins with one.
    public static func join(root: String, relative: String) -> String {
        let expandedRoot = (root as NSString).expandingTildeInPath
        guard !relative.isEmpty, !relative.hasPrefix("/") else { return expandedRoot }
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
