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
/// - Pure string math, no filesystem access: paths are compared exactly as given (no symlink or
///   case canonicalization, matching every call site this replaced).
public enum PathBoundary {

    /// `path` relative to `root`, or nil when `path` is not `root` itself and not inside it.
    /// The exact match returns `""`.
    public static func relativize(_ path: String, under root: String) -> String? {
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
}
