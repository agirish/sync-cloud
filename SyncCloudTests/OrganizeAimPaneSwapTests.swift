import Testing
import Foundation
import Sync
@testable import SyncCloud

/// `PaneLogic.organizeAimNeedsPaneSwap` — the one decision behind ⌘K's "Organize shows one source
/// at a time" dialog.
///
/// The rule is extracted precisely because the dialog is not: an `NSAlert` is `runModal()`, which
/// blocks the test's own main thread on a session nothing in the harness can dismiss. So the
/// question the alert asks is answered here, on real paths, and the call site's ordering is pinned
/// separately by `CommandPaletteRouteCallSiteTests`.
///
/// **Every fixture uses paths that could exist**, and the roots are distinct trees rather than
/// suggestive strings — the rule is decided with `OrganizeScope`, which expands tildes and respects
/// path-component boundaries, and a fixture built out of `"left"` / `"right"` could not tell that
/// implementation from a `hasPrefix`.
@Suite struct OrganizeAimPaneSwapTests {

    private static let leftRoot = "/Users/abhishek/Library/CloudStorage/iCloud"
    private static let rightRoot = "/Users/abhishek/Library/CloudStorage/Dropbox"

    private static func needsSwap(scope: String?,
                                  aimedAtRight: Bool = true,
                                  leftRoot: String = leftRoot,
                                  rightRoot: String = rightRoot) -> Bool {
        PaneLogic.organizeAimNeedsPaneSwap(scope: scope, aimedAtRight: aimedAtRight,
                                           leftRoot: leftRoot, rightRoot: rightRoot)
    }

    /// **The case the dialog exists for**, and it comes first so every refusal below means
    /// something: a rule that answered false to everything would satisfy all of them at once.
    ///
    /// The folder is in the aimed (right) pane's tree and in no part of the left one, so Organize —
    /// which shows the left pane — would resolve the scope to nil, drop the chip and go back to the
    /// global view with the named folder silently discarded.
    @Test func aRightPaneFolderTheLeftPaneCannotSeeNeedsTheSwap() {
        #expect(Self.needsSwap(scope: Self.rightRoot + "/Legal/Immigration"))
    }

    /// Aimed at the LEFT pane — which is the pane Organize shows — so there is nothing to move.
    /// This is the common case: every ⌘K route outside Compare, and every Compare route with the
    /// left pane focused.
    @Test func aLeftPaneAimNeverSwaps() {
        // Same folder as above, so the only difference between this and the swap case is the aim.
        #expect(!Self.needsSwap(scope: Self.leftRoot + "/Legal/Immigration", aimedAtRight: false))
        #expect(!Self.needsSwap(scope: Self.rightRoot + "/Legal/Immigration", aimedAtRight: false))
    }

    /// "Organize" with no folder keeps no object, so both panes answer it identically and moving
    /// them would be a change the user did not ask for and could not see the point of.
    @Test func aScopelessRouteNeverSwaps() {
        #expect(!Self.needsSwap(scope: nil))
    }

    /// **Both panes on one provider.** The roots are the same tree, so the folder already resolves
    /// under the left one — Organize will show it with the chip intact. Swapping would move the
    /// panes for no gain, which is exactly the "don't move anything silently" failure in reverse.
    @Test func oneProviderInBothPanesNeedsNoSwap() {
        #expect(!Self.needsSwap(scope: Self.rightRoot + "/Legal", leftRoot: Self.rightRoot))
    }

    /// **A folder in neither tree is not a pane problem.** A stale scope, or one typed against a
    /// provider that has since been dropped, degrades to the global view exactly as `OrganizeScope`
    /// documents — and no arrangement of the two panes would rescue it, so there is nothing to ask.
    @Test func aFolderOutsideBothRootsNeedsNoSwap() {
        #expect(!Self.needsSwap(scope: "/Volumes/Archive 2019/Legal"))
    }

    /// The provider root itself is the global view — `OrganizeScope.init?` normalizes it to nil, so
    /// the scope write clears rather than sets and Organize shows everything under whichever
    /// provider it lands on. Nothing is lost by not swapping, so nothing is asked.
    @Test func theProviderRootItselfNeedsNoSwap() {
        #expect(!Self.needsSwap(scope: Self.rightRoot))
        #expect(!Self.needsSwap(scope: Self.rightRoot + "/"))
    }

    /// **The boundary is a path component, not a string prefix**, and it is asked of BOTH roots.
    ///
    /// Each half is a fixture a `hasPrefix` implementation answers wrongly, in opposite directions:
    /// `/…/Dropbox` string-prefixes `/…/DropboxArchive/Legal`, so a naive rule would place a folder
    /// that is in neither tree inside the aimed pane and offer a pointless swap; and `/…/Drop`
    /// string-prefixes `/…/Dropbox/Legal`, so a naive rule would decide the left pane can already
    /// see it and offer nothing — leaving the silent drop this whole dialog exists to stop.
    @Test func theRootBoundaryIsAskedAtAComponent() {
        #expect(!Self.needsSwap(scope: Self.rightRoot + "Archive/Legal"),
                "a sibling folder sharing the right root's name is treated as inside it")
        #expect(Self.needsSwap(scope: Self.rightRoot + "/Legal",
                               leftRoot: String(Self.rightRoot.dropLast("box".count))),
                "a left root that merely string-prefixes the folder is treated as containing it, so no swap is offered")
    }

    /// **Tilde paths are expanded before either root is asked**, because that is what `OrganizeScope`
    /// does and this rule has to answer the same way the resolver will. A source's stored path can
    /// be a hand-typed `~/…` — the Settings field accepts one verbatim — so a rule comparing the raw
    /// strings would find the folder outside both roots and quietly offer nothing.
    ///
    /// The fixture is built so an unexpanded comparison answers differently: the scope is absolute
    /// under the home directory while the right root is written with the tilde.
    @Test func aTildeRootIsExpandedBeforeTheFolderIsPlaced() {
        let home = NSHomeDirectory()
        #expect(!home.hasPrefix("~"), "the home directory is itself a tilde path — this fixture proves nothing")
        #expect(Self.needsSwap(scope: home + "/Dropbox/Legal", rightRoot: "~/Dropbox"),
                "a `~/…` source root is compared unexpanded, so a real folder inside it reads as outside")
    }

    /// An empty root — a provider dropped from Settings while its pane is still on screen — places
    /// nothing. `PathBoundary` refuses an empty root outright rather than letting it claim every
    /// path, and the answer here follows: no folder is "in" the aimed pane, so no swap is offered.
    @Test func anAbsentProviderRootPlacesNothing() {
        #expect(!Self.needsSwap(scope: Self.rightRoot + "/Legal", rightRoot: ""))
        // With the LEFT root absent the folder really is only in the aimed pane, and the swap is
        // the honest answer — Organize on an empty root shows nothing either way.
        #expect(Self.needsSwap(scope: Self.rightRoot + "/Legal", leftRoot: ""))
    }
}
