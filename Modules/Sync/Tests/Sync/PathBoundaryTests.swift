import Testing
import Foundation
@testable import Sync

/// Pins `PathBoundary` — the module's one boundary-safe path arithmetic, which every hand-rolled
/// copy was consolidated onto.
///
/// `relativize` came first: the boundary-collision cases pin the round-3 bug class (a bare
/// `hasPrefix(root)` strip claiming a sibling that merely shares a string prefix); the exact-match,
/// trailing-slash, and root-"/" cases pin the normalization every converted call site inherits.
///
/// **The rest of the type was reached only transitively, and that was the gap.** `join`,
/// `joinRelative`, `normalizedRoot`, `reanchor` and `namesSameDirectory` were exercised solely
/// through `RootsMigration.rebased` and `CloudProvider.landingPath`, so each was pinned at whatever
/// inputs those two happen to produce — and three of them arrived with the root/landing split
/// carrying rules that are load-bearing and silent when wrong: a leading slash falling back to the
/// bare root, a tilde expanded on one side only, and a linked-navigation translation that must pass
/// a path through UNCHANGED rather than guess when it cannot express it.
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

    // MARK: Composition — the inverse of relativize

    /// **A leading slash yields the bare root, and that is the deliberate half.**
    ///
    /// An absolute path is not a relative one, and after `appendingPathComponent` has run them
    /// together the two cannot be told apart: `/a/b` + `/c/d` is `/a/b/c/d`, a folder nobody asked
    /// for that usually exists nowhere. Falling back to the root makes the failure an empty pane
    /// rather than a wrong one — a caller that built its relative half wrongly stays somewhere it
    /// is entitled to be.
    @Test func joinDiscardsAnAbsoluteRelativeHalfRatherThanRunningThemTogether() {
        #expect(PathBoundary.join(root: "/a/b", relative: "c") == "/a/b/c")
        #expect(PathBoundary.join(root: "/a/b", relative: "c/d") == "/a/b/c/d")
        // The rule: an absolute right-hand side is refused, not appended.
        #expect(PathBoundary.join(root: "/a/b", relative: "/c") == "/a/b")
        #expect(PathBoundary.join(root: "/a/b", relative: "/c/d") == "/a/b")
        // Empty means the root itself — a source with no `openAt` lands on its own root.
        #expect(PathBoundary.join(root: "/a/b", relative: "") == "/a/b")
        // A trailing slash on the root does not double the separator.
        #expect(PathBoundary.join(root: "/a/b/", relative: "c") == "/a/b/c")
    }

    /// The tilde is expanded on the ROOT only, because only roots are stored abbreviated.
    ///
    /// Roots arrive `~/Documents` (`FolderSource.abbreviated`); a root-relative path never begins
    /// with one. Expanding both would make a folder literally named `~` unreachable, and expanding
    /// neither leaves a path that no filesystem call can use.
    @Test func joinExpandsTheTildeOnTheRootAndNotTheRelativeHalf() {
        let home = NSHomeDirectory()
        #expect(PathBoundary.join(root: "~/Documents", relative: "Legal") == "\(home)/Documents/Legal")
        #expect(PathBoundary.join(root: "~/Documents", relative: "") == "\(home)/Documents")
        // Not expanded on the right: this names a folder called "~", not the home directory.
        #expect(PathBoundary.join(root: "/a", relative: "~") == "/a/~")
    }

    /// `joinRelative` short-circuits on either empty side, so no doubled or leading separator can
    /// be produced — which is what keeps its output something `join` will accept rather than
    /// discard for looking absolute.
    @Test func joinRelativeNeverProducesAnEmptyComponent() {
        #expect(PathBoundary.joinRelative("Documents", "Family/Photos") == "Documents/Family/Photos")
        #expect(PathBoundary.joinRelative("", "Family") == "Family")
        #expect(PathBoundary.joinRelative("Documents", "") == "Documents")
        #expect(PathBoundary.joinRelative("", "") == "")
        // The invariant that ties the two together: a rebase's output is canonical root-relative
        // form, so feeding it straight back to `join` reaches the folder it names.
        let rebased = PathBoundary.joinRelative("", "Family")
        #expect(PathBoundary.join(root: "/a", relative: rebased) == "/a/Family")
    }

    // MARK: The key spelling

    /// Tilde expanded, trailing slashes trimmed, and deliberately nothing more.
    ///
    /// Case-folding would merge two genuinely distinct roots on a case-sensitive volume, and
    /// symlink resolution would make a key depend on disk state that can change under a persisted
    /// pin — so both are absent on purpose, and asserted absent here rather than left to be
    /// rediscovered as a missing feature.
    @Test func normalizedRootTrimsAndExpandsAndDoesNothingElse() {
        let home = NSHomeDirectory()
        #expect(PathBoundary.normalizedRoot("~/Documents") == "\(home)/Documents")
        #expect(PathBoundary.normalizedRoot("/a/b/") == "/a/b")
        #expect(PathBoundary.normalizedRoot("/a/b///") == "/a/b")
        // "/" is one character and must survive: trimming it to "" would turn the volume root into
        // the absence of a root, which is what `relativize`'s empty-root guard refuses to claim.
        #expect(PathBoundary.normalizedRoot("/") == "/")
        // NOT case-folded, and NOT symlink-resolved.
        #expect(PathBoundary.normalizedRoot("/A/B") == "/A/B")
    }

    // MARK: Re-anchoring — linked panes whose sources land in different places

    /// A position below the source anchor is re-expressed below the destination's.
    ///
    /// This is the whole of what linked navigation needs now that two panes' roots no longer share
    /// an origin. Left OneDrive at `Documents/Family` linked to an iCloud right used to send that
    /// pane to `~/Documents/Documents/Family`, which does not exist — and the reverse was worse,
    /// because `<account>/Family` often DOES exist and is a different tree, so the comparison
    /// diffed the wrong pair and Sync acted on it.
    @Test func reanchorTranslatesAPositionBelowOneLandingFolderToAnother() {
        // OneDrive (lands at Documents) → iCloud (lands at its own root).
        #expect(PathBoundary.reanchor("Documents/Family", from: "Documents", to: "") == "Family")
        // ...and back.
        #expect(PathBoundary.reanchor("Family", from: "", to: "Documents") == "Documents/Family")
        // Google Drive's two-component landing folder, both directions.
        #expect(PathBoundary.reanchor("My Drive/Documents/Legal",
                                      from: "My Drive/Documents", to: "Documents") == "Documents/Legal")
        #expect(PathBoundary.reanchor("Documents/Legal",
                                      from: "Documents", to: "My Drive/Documents") == "My Drive/Documents/Legal")
        // The landing folder itself maps to the other landing folder, not to a doubled path.
        #expect(PathBoundary.reanchor("Documents", from: "Documents", to: "My Drive/Documents")
                == "My Drive/Documents")
    }

    /// **At or above the landing folder it carries the path across unchanged, rather than guessing.**
    ///
    /// A pane sitting at its account root is somewhere the sibling's anchor cannot express — there
    /// is no landing-relative reading of it — and passing it through is exactly what linked
    /// navigation did before landing folders existed. Inventing one would be the silent wrong-tree
    /// failure this function was written to stop, reintroduced from the other side.
    @Test func reanchorPassesThroughWhatTheDestinationAnchorCannotExpress() {
        // Above the source's landing folder: `Teams Recordings` sits beside Documents, not under it.
        #expect(PathBoundary.reanchor("Teams Recordings", from: "Documents", to: "") == "Teams Recordings")
        // The account root itself.
        #expect(PathBoundary.reanchor("", from: "Documents", to: "My Drive/Documents") == "")
        // Equal anchors are a no-op whatever the path — the commonest case, two sources of one type.
        #expect(PathBoundary.reanchor("Anything/At/All", from: "Documents", to: "Documents")
                == "Anything/At/All")
        // A sibling that merely shares a string prefix is NOT below the anchor — the same boundary
        // rule `relativize` carries, reached through this door.
        #expect(PathBoundary.reanchor("Documentsly/Q4", from: "Documents", to: "") == "Documentsly/Q4")
    }

    /// An EMPTY source anchor means the landing folder IS the root, not that there is no root.
    ///
    /// `relativize` answers nil for an empty root by design — `""` is the ABSENCE of a root there —
    /// so this case is handled before it rather than through it. It is iCloud's ordinary state and
    /// therefore the commonest half of every mixed pair: everything is below it, so the position
    /// passes through whole.
    @Test func anEmptySourceAnchorIsTheRootItselfNotAnAbsentRoot() {
        #expect(PathBoundary.reanchor("Family/Photos", from: "", to: "Documents")
                == "Documents/Family/Photos")
        #expect(PathBoundary.reanchor("", from: "", to: "Documents") == "Documents")
        // The control: were this routed through `relativize`, the nil would fall to the
        // pass-through branch and the path would arrive un-translated.
        #expect(PathBoundary.relativize("Family/Photos", under: "") == nil)
    }

    // MARK: Same-directory, which decides whether a file is moved

    /// Case is folded when the volume folds it, and that direction is the safe one.
    ///
    /// An automation destination template is matched case-insensitively by design, so a hand-typed
    /// `documents/inbox` naming the on-disk `Documents/Inbox` is expected input. Read exactly, the
    /// destination looked like a DIFFERENT folder from the file's parent, so the move went ahead —
    /// `fileExists` then found the file itself with case collapsed on disk, the unique-name helper
    /// stepped around it, and the file was renamed in place to "name 2" under a banner claiming it
    /// had been filed.
    @Test func namesSameDirectoryFoldsCaseOnlyWhenTheVolumeDoes() {
        #expect(PathBoundary.namesSameDirectory("/a/Documents/Inbox", "/a/documents/inbox",
                                                caseSensitive: false))
        #expect(!PathBoundary.namesSameDirectory("/a/Documents/Inbox", "/a/documents/inbox",
                                                 caseSensitive: true))
        // Exact spellings match under either answer, so the case above is the only discriminator.
        #expect(PathBoundary.namesSameDirectory("/a/Documents", "/a/Documents", caseSensitive: true))
        // Different folders stay different under both.
        #expect(!PathBoundary.namesSameDirectory("/a/Documents", "/a/Desktop", caseSensitive: false))
        // Standardization still happens — it resolves `..` and trailing slashes, just never case.
        #expect(PathBoundary.namesSameDirectory("/a/b/../Documents/", "/a/Documents",
                                                caseSensitive: true))
    }

    /// **An empty root composes to nothing, not to the relative half.**
    ///
    /// `appendingPathComponent` on `""` hands back the relative path unchanged, which is not a
    /// pane path at all: it resolves against the process working directory, so a composition that
    /// should have failed loudly instead names a real folder somewhere else entirely. And the empty
    /// root is an ordinary state here — `SettingsManager.rootPath(for:)` answers `""` for a source
    /// dropped from settings while its stale tree is still on screen, which is exactly the window
    /// several call sites guard against one at a time.
    ///
    /// The same stance `relativize` takes for the same reason, and the pair is asserted together so
    /// neither can drift: `""` is the ABSENCE of a root, and `/` is the volume root.
    @Test func anEmptyRootComposesToNothing() {
        #expect(PathBoundary.join(root: "", relative: "Documents/Family") == "")
        #expect(PathBoundary.join(root: "", relative: "") == "")
        #expect(PathBoundary.relativize("/Users/u/x", under: "") == nil)
        // The volume root is unaffected — it is a root, and a real one.
        #expect(PathBoundary.join(root: "/", relative: "Users/u") == "/Users/u")
        #expect(PathBoundary.relativize("/Users/u", under: "/") == "Users/u")
    }
}
