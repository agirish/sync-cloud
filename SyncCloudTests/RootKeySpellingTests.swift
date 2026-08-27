import Testing
import Foundation
import Sync
import Settings
import Dashboard

/// The one place the root-keyed stores' spellings can be compared with each other.
///
/// `RootsMigration` re-keys two stores that file their entries under a *root*, and it does so by
/// naming their keys and their normalizer in its own words rather than reaching for theirs —
/// deliberately, and its doc says why: a migration is a statement about what was on disk at one
/// version, and one that follows a later rename stops finding the data it exists to move.
///
/// That decision costs exactly one thing, which is what this file buys back. The migration's doc
/// asserts how the stores normalize — *"`FolderJumpStore.key(forRoot:)` is this exact rule"*,
/// *"`DestinationRecents` uses `PaneBrowsePath.normalized`, which trims but does NOT expand a
/// tilde"* — and those are claims about code in two other modules, in prose, checked by nobody. A
/// migration that spells a key the store no longer uses re-keys nothing and reports success; one
/// that normalizes differently re-keys onto a key the store will never look under. Both are silent.
///
/// **It lives in the app target because nothing else can see all three.** `Settings` does not import
/// `Dashboard`, so no package's own tests can put `RootsMigration` and `FolderJumpStore` in one
/// expression — which is precisely why the claim went unchecked.
@Suite struct RootKeySpellingTests {

    /// The jump stores' key rule and the migration's are the same function, not merely similar.
    ///
    /// Tilde spellings are in the table even though the migration only ever remaps discovered
    /// CloudStorage roots, which are absolute: the claim is that these are ONE rule, and a rule
    /// that agrees only on the inputs currently reached is not one rule, it is a coincidence with
    /// a maintenance schedule.
    @Test func theJumpStoresFileUnderExactlyTheSpellingTheMigrationWrites() {
        for root in ["~/Documents", "~/Documents/", "/a/b", "/a/b/", "/a/b//", "/", "~"] {
            #expect(PathBoundary.normalizedRoot(root) == FolderJumpStore.key(forRoot: root),
                    "\(root): migration writes \(PathBoundary.normalizedRoot(root)), FolderJumpStore reads \(FolderJumpStore.key(forRoot: root))")
        }
    }

    /// `DestinationRecents` normalizes *differently*, and the migration's doc says so — this is the
    /// half that says the exception is real rather than an oversight nobody noticed.
    ///
    /// It trims trailing slashes and stops there; the jump stores' rule also expands a tilde. The
    /// two therefore disagree on exactly one class of input, and agree on every absolute path —
    /// which is every root the migration remaps, and why the difference cannot bite today.
    @Test func destinationRecentsTrimsButDoesNotExpand() {
        // The disagreement, stated rather than implied: a tilde root keys differently in the two
        // stores. If this ever stops being true the migration's doc needs rewriting, not this test.
        #expect(PaneBrowsePath.normalized("~/Documents") == "~/Documents")
        #expect(PathBoundary.normalizedRoot("~/Documents") != "~/Documents",
                "the jump-store rule stopped expanding tildes — the two rules have converged")

        // ...and the agreement that makes it harmless, over the shapes a discovered account root
        // can actually take.
        for root in ["/Users/u/Library/CloudStorage/OneDrive-Personal",
                     "/Users/u/Library/CloudStorage/OneDrive-Personal/",
                     "/a/b"] {
            #expect(PaneBrowsePath.normalized(root) == PathBoundary.normalizedRoot(root),
                    "\(root): the two root spellings differ on an ABSOLUTE path, which the migration remaps under both rules at once")
        }
    }
}
