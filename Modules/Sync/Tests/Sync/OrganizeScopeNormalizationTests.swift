import Testing
import Foundation
@testable import Sync

/// Organize's scope as it is written: the one normalization both writers (`ContentView` and
/// `LensWorkspaceView`) use, ``OrganizeScope/normalizedPath(_:providerRoot:)``. A characterization
/// pin: every stored value below is what the writers produce, and must keep producing.
///
/// - A trailing slash is dropped (`…/Legal/` stores as `…/Legal`), since the stored string is
///   compared against pane paths and a stray slash would never match itself.
/// - A trailing slash on the root is tolerated (`PathBoundary` folds it).
/// - A sibling sharing a string prefix (`/Users/x/Documentsz`) is outside, or storing it would
///   filter every lens to nothing.
@Suite struct OrganizeScopeNormalizationTests {

    static let root = "/Users/x/Documents"
    static let home = NSHomeDirectory()

    /// Every interesting input, and the exact string that must land in
    /// ``OrganizeScopeDefaults/pathKey``. `""` is the global view. Eleven rows clear and six keep a
    /// path, so an "always clear" or a "never clear" `normalizedPath` both fail.
    static let table: [(label: String, path: String?, root: String?, stored: String)] = [
        ("nil path",                nil,                          root,          ""),
        ("empty path",              "",                           root,          ""),
        ("the provider root",       root,                         root,          ""),
        ("provider root + slash",   root + "/",                   root,          ""),
        ("a subtree",               root + "/Legal",              root,          root + "/Legal"),
        ("a deep subtree",          root + "/Legal/US/2024",      root,          root + "/Legal/US/2024"),
        ("a subtree + slash",       root + "/Legal/",             root,          root + "/Legal"),
        ("outside the root",        "/Users/x/Photos",            root,          ""),
        ("sibling string prefix",   "/Users/x/Documentsz/Legal",  root,          ""),
        ("another provider's tree", "/Users/x/Dropbox/Legal",     root,          ""),
        ("a tilde path",            "~/Documents/Legal",          home + "/Documents", home + "/Documents/Legal"),
        ("a tilde path and root",   "~/Documents/Legal",          "~/Documents", home + "/Documents/Legal"),
        ("the tilde root itself",   "~",                          home,          ""),
        ("root spelled with slash", root + "/Legal",              root + "/",    root + "/Legal"),
        ("an EMPTY root",           root + "/Legal",              "",            ""),
        ("a NIL root",              root + "/Legal",              nil,           ""),
        ("nil path AND nil root",   nil,                          nil,           ""),
    ]

    @Test func theStoredFormIsPinnedAcrossEveryInterestingInput() {
        for row in Self.table {
            #expect(OrganizeScope.normalizedPath(row.path, providerRoot: row.root) == row.stored,
                    "\(row.label): expected \"\(row.stored)\"")
        }
        // Non-vacuity: the table must hold both answers, or a degenerate implementation would pass.
        #expect(Self.table.filter { $0.stored.isEmpty }.count == 11)
        #expect(Self.table.filter { !$0.stored.isEmpty }.count == 6)
    }

    // MARK: Write and read are one rule

    /// What the writer stores is exactly what the reader resolves back — the round trip that stops
    /// the chip and the lens filters disagreeing about one string.
    @Test func theWriteStoresExactlyWhatTheReadResolves() {
        for row in Self.table {
            let stored = OrganizeScope.normalizedPath(row.path, providerRoot: row.root)
            let reread = OrganizeScopeDefaults.scope(fromStored: stored, providerRoot: row.root)
            #expect(reread?.path ?? "" == stored, "\(row.label) does not survive a re-read")
        }
    }

    /// Storing an already-stored value changes nothing, for every row — so a re-write on launch, or
    /// a second click on the folder already scoped to, cannot walk the value.
    @Test func normalizingIsIdempotent() {
        for row in Self.table {
            let once = OrganizeScope.normalizedPath(row.path, providerRoot: row.root)
            let twice = OrganizeScope.normalizedPath(once, providerRoot: row.root)
            #expect(once == twice, "\(row.label) is not idempotent: \"\(once)\" → \"\(twice)\"")
        }
    }
}
