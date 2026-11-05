import Testing
import Foundation
import Sync
@testable import SyncCloud

/// `PaneLogic.organizeAimNeedsPaneSwap`, the decision behind ⌘K's "Organize shows one source at a
/// time" dialog. The rule is extracted because the dialog's `NSAlert.runModal()` would block the
/// test's main thread; `CommandPaletteRouteCallSiteTests` pins the call site's ordering.
///
/// Fixtures use real-looking paths in distinct trees, not `"left"` / `"right"`: the rule goes
/// through `OrganizeScope`, which expands tildes and respects component boundaries, and toy strings
/// couldn't tell it from a `hasPrefix`.
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

    /// The case the dialog exists for, first so the refusals below mean something: a rule that
    /// always said false would pass them all. The folder is only in the aimed (right) pane's tree,
    /// so Organize, which shows the left pane, would silently drop it and show the global view.
    @Test func aRightPaneFolderTheLeftPaneCannotSeeNeedsTheSwap() {
        #expect(Self.needsSwap(scope: Self.rightRoot + "/Legal/Immigration"))
    }

    /// Aimed at the left pane, the one Organize shows, so there is nothing to move. The common
    /// case: every ⌘K route outside Compare, and every Compare route with the left pane focused.
    @Test func aLeftPaneAimNeverSwaps() {
        // Same folder as above, so the only difference between this and the swap case is the aim.
        #expect(!Self.needsSwap(scope: Self.leftRoot + "/Legal/Immigration", aimedAtRight: false))
        #expect(!Self.needsSwap(scope: Self.rightRoot + "/Legal/Immigration", aimedAtRight: false))
    }

    /// "Organize" with no folder reads the same from either pane, so moving them would be a change
    /// the user didn't ask for.
    @Test func aScopelessRouteNeverSwaps() {
        #expect(!Self.needsSwap(scope: nil))
    }

    /// Both panes on one provider: the folder already resolves under the left root, so Organize
    /// shows it with the chip intact and a swap would move the panes for nothing.
    @Test func oneProviderInBothPanesNeedsNoSwap() {
        #expect(!Self.needsSwap(scope: Self.rightRoot + "/Legal", leftRoot: Self.rightRoot))
    }

    /// A folder in neither tree isn't a pane problem. A stale scope degrades to the global view as
    /// `OrganizeScope` documents, and no arrangement of the panes would rescue it.
    @Test func aFolderOutsideBothRootsNeedsNoSwap() {
        #expect(!Self.needsSwap(scope: "/Volumes/Archive 2019/Legal"))
    }

    /// The provider root itself is the global view: `OrganizeScope.init?` normalizes it to nil, so
    /// nothing is lost by not swapping.
    @Test func theProviderRootItselfNeedsNoSwap() {
        #expect(!Self.needsSwap(scope: Self.rightRoot))
        #expect(!Self.needsSwap(scope: Self.rightRoot + "/"))
    }

    /// The boundary is a path component, not a string prefix, on both roots. A `hasPrefix` rule
    /// fails each half the opposite way: it would place `/…/DropboxArchive/Legal` inside
    /// `/…/Dropbox` and offer a pointless swap, and decide a left root `/…/Drop` can see
    /// `/…/Dropbox/Legal` and offer nothing.
    @Test func theRootBoundaryIsAskedAtAComponent() {
        #expect(!Self.needsSwap(scope: Self.rightRoot + "Archive/Legal"),
                "a sibling folder sharing the right root's name is treated as inside it")
        #expect(Self.needsSwap(scope: Self.rightRoot + "/Legal",
                               leftRoot: String(Self.rightRoot.dropLast("box".count))),
                "a left root that merely string-prefixes the folder is treated as containing it, so no swap is offered")
    }

    /// Tilde paths are expanded before either root is asked, as `OrganizeScope` does. Settings
    /// accepts a hand-typed `~/…` source path, and comparing raw strings would place the folder
    /// outside both roots. Here the scope is absolute and the right root uses the tilde.
    @Test func aTildeRootIsExpandedBeforeTheFolderIsPlaced() {
        let home = NSHomeDirectory()
        #expect(!home.hasPrefix("~"), "the home directory is itself a tilde path — this fixture proves nothing")
        #expect(Self.needsSwap(scope: home + "/Dropbox/Legal", rightRoot: "~/Dropbox"),
                "a `~/…` source root is compared unexpanded, so a real folder inside it reads as outside")
    }

    /// An empty root (a provider dropped from Settings while its pane is on screen) places nothing:
    /// `PathBoundary` refuses it rather than letting it claim every path, so no swap is offered.
    @Test func anAbsentProviderRootPlacesNothing() {
        #expect(!Self.needsSwap(scope: Self.rightRoot + "/Legal", rightRoot: ""))
        // With the left root absent the folder really is only in the aimed pane, so the swap is
        // right: Organize on an empty root shows nothing anyway.
        #expect(Self.needsSwap(scope: Self.rightRoot + "/Legal", leftRoot: ""))
    }
}
