import Testing
import Foundation
@testable import Sync

/// Pins `PathBoundary`, the module's one boundary-safe path arithmetic. `relativize` must never
/// claim a sibling that only shares a string prefix, and must normalize exact matches, trailing
/// slashes and root "/" the same for every caller. The other members are tested directly here
/// because their rules are silent when wrong: a leading slash falls back to the bare root, a tilde
/// expands on one side only, and `reanchor` passes through what it can't express rather than guess.
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
        // "/root/abc" only string-starts-with "/root/ab"; it is not inside it.
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
        // Pure string math: relativize doesn't canonicalize its first argument. No call site
        // passes a trailing-slash path; this records the behaviour for one that might.
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

    /// An empty root is the absence of a root, not the volume root. Without the guard `""`
    /// normalizes like "/" and claims every absolute path, handing back "Users/…" as if it were
    /// root-relative. An empty path resolves against the working directory, so the shared helper
    /// must refuse it even for a caller that forgets its own check.
    @Test func emptyRootClaimsNothing() {
        #expect(PathBoundary.relativize("/Users/me/file.txt", under: "") == nil)
        #expect(PathBoundary.relativize("/", under: "") == nil)
        #expect(PathBoundary.relativize("", under: "") == nil)
        #expect(!PathBoundary.contains("/Users/me/file.txt", under: ""))
    }

    /// The guard tests the argument, not the normalized base, since "/" also reduces to an empty
    /// base. Fails if the guard is simplified to `base.isEmpty`.
    @Test func filesystemRootIsUnaffectedByTheEmptyRootGuard() {
        #expect(PathBoundary.relativize("/x/y", under: "/") == "x/y")
        #expect(PathBoundary.contains("/x/y", under: "/"))
    }

    // MARK: Unicode

    @Test func unicodeNamesCompareAsExactStrings() {
        #expect(PathBoundary.relativize("/root/résumé/août.txt", under: "/root/résumé") == "août.txt")
        #expect(PathBoundary.relativize("/root/日本語/ファイル", under: "/root/日本語") == "ファイル")
        // No canonicalization happens here, but Swift's String == compares canonical
        // equivalence, so precomposed and decomposed é still match.
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

    /// A leading slash on the relative half yields the bare root. Appending it would give
    /// `/a/b/c/d` from `/a/b` + `/c/d`, a folder nobody asked for; falling back to the root keeps
    /// a caller that built its relative half wrongly somewhere it is entitled to be.
    @Test func joinDiscardsAnAbsoluteRelativeHalfRatherThanRunningThemTogether() {
        #expect(PathBoundary.join(root: "/a/b", relative: "c") == "/a/b/c")
        #expect(PathBoundary.join(root: "/a/b", relative: "c/d") == "/a/b/c/d")
        // The rule: an absolute right-hand side is refused, not appended.
        #expect(PathBoundary.join(root: "/a/b", relative: "/c") == "/a/b")
        #expect(PathBoundary.join(root: "/a/b", relative: "/c/d") == "/a/b")
        // Empty means the root itself: a source with no `openAt` lands on its own root.
        #expect(PathBoundary.join(root: "/a/b", relative: "") == "/a/b")
        // A trailing slash on the root does not double the separator.
        #expect(PathBoundary.join(root: "/a/b/", relative: "c") == "/a/b/c")
    }

    /// The tilde is expanded on the root only, because only roots are stored abbreviated
    /// (`FolderSource.abbreviated`). Expanding both would make a folder named `~` unreachable.
    @Test func joinExpandsTheTildeOnTheRootAndNotTheRelativeHalf() {
        let home = NSHomeDirectory()
        #expect(PathBoundary.join(root: "~/Documents", relative: "Legal") == "\(home)/Documents/Legal")
        #expect(PathBoundary.join(root: "~/Documents", relative: "") == "\(home)/Documents")
        // Not expanded on the right: this names a folder called "~", not the home directory.
        #expect(PathBoundary.join(root: "/a", relative: "~") == "/a/~")
    }

    /// `joinRelative` short-circuits on either empty side, so it never yields a doubled or leading
    /// separator, and `join` never discards its output as absolute.
    @Test func joinRelativeNeverProducesAnEmptyComponent() {
        #expect(PathBoundary.joinRelative("Documents", "Family/Photos") == "Documents/Family/Photos")
        #expect(PathBoundary.joinRelative("", "Family") == "Family")
        #expect(PathBoundary.joinRelative("Documents", "") == "Documents")
        #expect(PathBoundary.joinRelative("", "") == "")
        // A rebase's output is canonical root-relative form, so `join` reaches the folder it names.
        let rebased = PathBoundary.joinRelative("", "Family")
        #expect(PathBoundary.join(root: "/a", relative: rebased) == "/a/Family")
    }

    // MARK: The key spelling

    /// Tilde expanded, trailing slashes trimmed, and nothing more. Case-folding would merge two
    /// distinct roots on a case-sensitive volume, and resolving symlinks would make a key depend on
    /// disk state that can change under a persisted pin.
    @Test func normalizedRootTrimsAndExpandsAndDoesNothingElse() {
        let home = NSHomeDirectory()
        #expect(PathBoundary.normalizedRoot("~/Documents") == "\(home)/Documents")
        #expect(PathBoundary.normalizedRoot("/a/b/") == "/a/b")
        #expect(PathBoundary.normalizedRoot("/a/b///") == "/a/b")
        // "/" must survive: trimmed to "" it would become the absence of a root, which
        // `relativize`'s empty-root guard refuses.
        #expect(PathBoundary.normalizedRoot("/") == "/")
        // NOT case-folded, and NOT symlink-resolved.
        #expect(PathBoundary.normalizedRoot("/A/B") == "/A/B")
    }

    // MARK: Re-anchoring — linked panes whose sources land in different places

    /// A position below the source anchor is re-expressed below the destination's, which linked
    /// panes need when their sources land in different places. Untranslated, OneDrive's
    /// `Documents/Family` names a missing folder in iCloud, and the reverse can name a real but
    /// different tree that Compare would diff and Sync would act on.
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

    /// At or above the landing folder the path passes through unchanged rather than guessed. A pane
    /// at its account root has no landing-relative reading, and inventing one would send the
    /// linked pane silently into the wrong tree.
    @Test func reanchorPassesThroughWhatTheDestinationAnchorCannotExpress() {
        // Above the source's landing folder: `Teams Recordings` sits beside Documents, not under it.
        #expect(PathBoundary.reanchor("Teams Recordings", from: "Documents", to: "") == "Teams Recordings")
        // The account root itself.
        #expect(PathBoundary.reanchor("", from: "Documents", to: "My Drive/Documents") == "")
        // Equal anchors are a no-op whatever the path: the commonest case, two sources of one type.
        #expect(PathBoundary.reanchor("Anything/At/All", from: "Documents", to: "Documents")
                == "Anything/At/All")
        // A sibling that only shares a string prefix is not below the anchor, as in `relativize`.
        #expect(PathBoundary.reanchor("Documentsly/Q4", from: "Documents", to: "") == "Documentsly/Q4")
    }

    /// An empty source anchor means the landing folder is the root, not that there is no root. It
    /// is iCloud's ordinary state. `relativize` answers nil for an empty root, so this case must be
    /// handled before reaching it.
    @Test func anEmptySourceAnchorIsTheRootItselfNotAnAbsentRoot() {
        #expect(PathBoundary.reanchor("Family/Photos", from: "", to: "Documents")
                == "Documents/Family/Photos")
        #expect(PathBoundary.reanchor("", from: "", to: "Documents") == "Documents")
        // The control: routed through `relativize`, this nil would take the pass-through branch.
        #expect(PathBoundary.relativize("Family/Photos", under: "") == nil)
    }

    // MARK: Same-directory, which decides whether a file is moved

    /// Case is folded when the volume folds it. Automation destinations match case-insensitively,
    /// so `documents/inbox` for the on-disk `Documents/Inbox` is expected input. Compared exactly it
    /// would look like a different folder, and the move would rename the file in place to "name 2"
    /// while reporting it filed.
    @Test func namesSameDirectoryFoldsCaseOnlyWhenTheVolumeDoes() {
        #expect(PathBoundary.namesSameDirectory("/a/Documents/Inbox", "/a/documents/inbox",
                                                caseSensitive: false))
        #expect(!PathBoundary.namesSameDirectory("/a/Documents/Inbox", "/a/documents/inbox",
                                                 caseSensitive: true))
        // Exact spellings match under either answer, so the case above is the only discriminator.
        #expect(PathBoundary.namesSameDirectory("/a/Documents", "/a/Documents", caseSensitive: true))
        // Different folders stay different under both.
        #expect(!PathBoundary.namesSameDirectory("/a/Documents", "/a/Desktop", caseSensitive: false))
        // Standardization still resolves `..` and trailing slashes, just never case.
        #expect(PathBoundary.namesSameDirectory("/a/b/../Documents/", "/a/Documents",
                                                caseSensitive: true))
    }

    /// An empty root composes to nothing, not to the relative half, which would resolve against the
    /// working directory and name a real folder elsewhere. It is an ordinary state:
    /// `SettingsManager.rootPath(for:)` answers `""` for a source dropped from settings while its
    /// tree is still on screen. Asserted beside `relativize`, which takes the same stance: `""` is
    /// the absence of a root, and `/` is the volume root.
    @Test func anEmptyRootComposesToNothing() {
        #expect(PathBoundary.join(root: "", relative: "Documents/Family") == "")
        #expect(PathBoundary.join(root: "", relative: "") == "")
        #expect(PathBoundary.relativize("/Users/u/x", under: "") == nil)
        // The volume root is unaffected — it is a root, and a real one.
        #expect(PathBoundary.join(root: "/", relative: "Users/u") == "/Users/u")
        #expect(PathBoundary.relativize("/Users/u", under: "/") == "Users/u")
    }
}
