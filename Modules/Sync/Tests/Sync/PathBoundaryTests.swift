import Testing
import Foundation
@testable import Sync

/// Pins `PathBoundary.relativize(_:under:)` — the one boundary-safe prefix strip the Sync module's
/// hand-rolled copies were consolidated onto. The boundary-collision cases pin the round-3 bug
/// class (a bare `hasPrefix(root)` strip claiming a sibling that merely shares a string prefix);
/// the exact-match, trailing-slash, and root-"/" cases pin the normalization every converted call
/// site now inherits.
struct PathBoundaryTests {

    // MARK: Containment and stripping

    @Test func childStripsRootAtComponentBoundary() {
        #expect(PathBoundary.relativize("/root/a/b.txt", under: "/root") == "a/b.txt")
        #expect(PathBoundary.relativize("/root/a", under: "/root") == "a")
    }

    @Test func exactMatchRelativizesToEmpty() {
        #expect(PathBoundary.relativize("/root/a", under: "/root/a") == "")
    }

    @Test func outsidePathIsNil() {
        #expect(PathBoundary.relativize("/elsewhere/x", under: "/root") == nil)
        #expect(PathBoundary.relativize("/root", under: "/root/a") == nil)   // parent, not child
    }

    // MARK: Boundary collision (the round-3 bug class)

    @Test func siblingSharingAStringPrefixIsOutside() {
        // "/root/abc" merely string-starts-with "/root/ab" — it is NOT inside it.
        #expect(PathBoundary.relativize("/root/abc", under: "/root/ab") == nil)
        #expect(PathBoundary.relativize("/root/abc/x", under: "/root/ab") == nil)
        #expect(PathBoundary.relativize("/Users/x/DocsArchive/Foo", under: "/Users/x/Docs") == nil)
        // The genuine child at the same depth still strips.
        #expect(PathBoundary.relativize("/root/ab/x", under: "/root/ab") == "x")
    }

    // MARK: Trailing slash on the root

    @Test func oneTrailingSlashOnRootIsIgnored() {
        #expect(PathBoundary.relativize("/root/a/b", under: "/root/a/") == "b")
        #expect(PathBoundary.relativize("/root/a", under: "/root/a/") == "")
        #expect(PathBoundary.relativize("/root/abc", under: "/root/ab/") == nil)
    }

    @Test func trailingSlashOnThePathIsNotNormalized() {
        // Pure string math: "/root/a/" is the child "" — one exact-string layer past the root —
        // not the root itself. (No call site produces trailing-slash paths; pinned so a future
        // caller knows relativize does not canonicalize its first argument.)
        #expect(PathBoundary.relativize("/root/a/", under: "/root/a") == "")
        #expect(PathBoundary.relativize("/root/a/", under: "/root/a/") == "")
    }

    // MARK: Root "/"

    @Test func filesystemRootContainsEveryAbsolutePath() {
        #expect(PathBoundary.relativize("/x/y", under: "/") == "x/y")
        #expect(PathBoundary.relativize("/x", under: "/") == "x")
        #expect(PathBoundary.relativize("/", under: "/") == "")
    }

    // MARK: Empty root

    /// An empty root is the ABSENCE of a root, not the volume root. Before the guard, `""`
    /// normalized to the same empty base that root "/" produces, so it prefix-matched every
    /// absolute path: `contains` answered true for everything and `relativize` handed back a
    /// near-absolute "Users/…" as though it were root-relative. That is the empty-root hazard the
    /// transfer and folder-creation paths each guard before building a URL (an empty path resolves
    /// against the process working directory); this keeps the shared helper from re-offering the
    /// permissive answer to a future caller that forgets its own check.
    @Test func emptyRootClaimsNothing() {
        #expect(PathBoundary.relativize("/Users/me/file.txt", under: "") == nil)
        #expect(PathBoundary.relativize("/", under: "") == nil)
        #expect(PathBoundary.relativize("", under: "") == nil)
        #expect(!PathBoundary.contains("/Users/me/file.txt", under: ""))
    }

    /// The guard tests the ARGUMENT, not the normalized base — root "/" also reduces to an empty
    /// base and must keep working. Pinned separately so a future simplification to `base.isEmpty`
    /// fails loudly instead of silently un-rooting the filesystem root.
    @Test func filesystemRootIsUnaffectedByTheEmptyRootGuard() {
        #expect(PathBoundary.relativize("/x/y", under: "/") == "x/y")
        #expect(PathBoundary.contains("/x/y", under: "/"))
    }

    // MARK: Unicode

    @Test func unicodeNamesCompareAsExactStrings() {
        #expect(PathBoundary.relativize("/root/résumé/août.txt", under: "/root/résumé") == "août.txt")
        #expect(PathBoundary.relativize("/root/日本語/ファイル", under: "/root/日本語") == "ファイル")
        // Same visible name in a different normalization form is a DIFFERENT string — no
        // canonicalization happens here (Swift String == compares canonical equivalence, so
        // precomposed vs decomposed é DO match; a genuinely different scalar sequence does not).
        let precomposed = "/root/caf\u{E9}"          // café, precomposed
        let decomposed = "/root/cafe\u{301}"         // café, combining accent
        #expect(PathBoundary.relativize(precomposed + "/x", under: decomposed) == "x")
    }

    @Test func containsMirrorsRelativize() {
        #expect(PathBoundary.contains("/root/a/b", under: "/root/a"))
        #expect(PathBoundary.contains("/root/a", under: "/root/a"))
        #expect(!PathBoundary.contains("/root/abc", under: "/root/ab"))
        #expect(!PathBoundary.contains("/elsewhere", under: "/root"))
    }
}
