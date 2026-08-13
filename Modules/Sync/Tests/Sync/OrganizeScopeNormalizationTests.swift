import Testing
import Foundation
@testable import Sync

/// Organize's scope as it is **written**: the one normalization both writers now ask for.
///
/// ## What this suite is
///
/// A **characterization pin**. The rule used to be spelled twice — `ContentView.setOrganizeScope`
/// (`resolvedOrganizeScope(path)?.path ?? ""`, over a NON-optional provider root) and
/// `LensWorkspaceView.setScope` (a guard over an OPTIONAL root, clearing to `""` when it failed) —
/// each under a doc comment claiming to be the only write of a **persisted** key. The table below
/// was captured by running **both** pre-refactor spellings over every input in it, at `78b6ce8e`,
/// before ``OrganizeScope/normalizedPath(_:providerRoot:)`` existed; all fifteen inputs both
/// spellings could express agreed, and every value here is what they both produced. So this is not
/// a description of the new function — it is the old behaviour, and the new function has to keep
/// answering it.
///
/// ## The rows that are not obvious
///
/// - **A trailing slash is dropped from the stored path.** `…/Legal/` stores as `…/Legal`, because
///   `init?` runs the path through `expandingTildeInPath`, which normalizes it. Worth pinning: the
///   stored string is compared against pane paths, so a stray slash would have been a scope that
///   never matched itself.
/// - **A trailing slash on the ROOT is tolerated** — `PathBoundary` folds one — so the same subtree
///   under `…/Documents` and `…/Documents/` stores identically.
/// - **A sibling that merely shares a string prefix is outside.** `/Users/x/Documentsz/Legal` is
///   not in `/Users/x/Documents`, and storing it would have filtered every lens to nothing.
@Suite struct OrganizeScopeNormalizationTests {

    static let root = "/Users/x/Documents"
    static let home = NSHomeDirectory()

    /// Every interesting input, and the exact string that must land in
    /// ``OrganizeScopeDefaults/pathKey``.
    ///
    /// `""` is the global view. Eleven rows answer `""` and six answer a real path, which is what
    /// keeps the table from being a fixture whose expectation is the fallback: a `normalizedPath`
    /// that had degenerated to "always clear" fails six of these, and one that had lost the
    /// collapse entirely fails the other eleven.
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
        // Non-vacuity, twice over: the table must actually contain both answers, or a degenerate
        // implementation would pass it. Counted, not assumed — a row edited to `""` in a hurry is
        // exactly how a pin stops pinning.
        #expect(Self.table.filter { $0.stored.isEmpty }.count == 11)
        #expect(Self.table.filter { !$0.stored.isEmpty }.count == 6)
    }

    // MARK: The question the two spellings used to answer separately

    /// **A missing provider root and an empty one are one condition, and both clear the scope.**
    ///
    /// This is the only semantic the two writers stated differently: `ContentView` passes
    /// `lensProviderRootExpanded`, a non-optional `String` that is `""` when the pane's provider has
    /// no path in settings, and `LensWorkspaceView` passes a `String?` that is nil for the same
    /// condition. Neither could produce the other's spelling of "absent", so neither's behaviour for
    /// it was ever compared with the other's — they agree, and this is what says so.
    @Test func aMissingRootAndAnEmptyRootAnswerTheSame() {
        let subtree = Self.root + "/Legal"
        #expect(OrganizeScope.normalizedPath(subtree, providerRoot: nil) == "")
        #expect(OrganizeScope.normalizedPath(subtree, providerRoot: "") == "")
        // And the same path with a real root does NOT clear — otherwise the two above would be
        // passing for the wrong reason.
        #expect(OrganizeScope.normalizedPath(subtree, providerRoot: Self.root) == subtree)
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
