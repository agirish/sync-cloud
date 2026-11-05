import Testing
import Foundation
import Sync
import Settings
import Dashboard

/// The one place the root-keyed stores' spellings can be compared. `RootsMigration` re-keys two
/// stores that file entries under a root, spelling their keys and normalizer in its own words on
/// purpose: a migration describes what was on disk at one version, and one that followed a later
/// rename would stop finding its data.
///
/// The cost is that its doc's claims about how the stores normalize go unchecked. A migration that
/// spells a key the store no longer uses re-keys nothing and reports success; one that normalizes
/// differently re-keys onto a key the store never reads. Both are silent. In the app target because
/// `Settings` doesn't import `Dashboard`, so no package test can see all three.
@Suite struct RootKeySpellingTests {

    /// The jump stores' key rule and the migration's are the same function, not merely similar.
    /// Tilde spellings are included though the migration only remaps absolute CloudStorage roots:
    /// one rule must agree on every input, not just the ones reached today.
    @Test func theJumpStoresFileUnderExactlyTheSpellingTheMigrationWrites() {
        for root in ["~/Documents", "~/Documents/", "/a/b", "/a/b/", "/a/b//", "/", "~"] {
            #expect(PathBoundary.normalizedRoot(root) == FolderJumpStore.key(forRoot: root),
                    "\(root): migration writes \(PathBoundary.normalizedRoot(root)), FolderJumpStore reads \(FolderJumpStore.key(forRoot: root))")
        }
    }

    /// `DestinationRecents` normalizes differently, as the migration's doc says: it trims trailing
    /// slashes but doesn't expand a tilde. The two rules agree on every absolute path, which is
    /// every root the migration remaps, so the difference is harmless.
    @Test func destinationRecentsTrimsButDoesNotExpand() {
        // The disagreement: a tilde root keys differently in the two stores. If this stops being
        // true, rewrite the migration's doc, not this test.
        #expect(PaneBrowsePath.normalized("~/Documents") == "~/Documents")
        #expect(PathBoundary.normalizedRoot("~/Documents") != "~/Documents",
                "the jump-store rule stopped expanding tildes — the two rules have converged")

        // The agreement that makes it harmless, over the shapes a discovered account root takes.
        for root in ["/Users/u/Library/CloudStorage/OneDrive-Personal",
                     "/Users/u/Library/CloudStorage/OneDrive-Personal/",
                     "/a/b"] {
            #expect(PaneBrowsePath.normalized(root) == PathBoundary.normalizedRoot(root),
                    "\(root): the two root spellings differ on an ABSOLUTE path, which the migration remaps under both rules at once")
        }
    }
}
