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
