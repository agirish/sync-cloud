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

    static let leftRoot = "/Users/abhishek/Library/CloudStorage/iCloud"
    static let rightRoot = "/Users/abhishek/Library/CloudStorage/Dropbox"

    private static func needsSwap(scope: String?,
                                  aimedAtRight: Bool = true,
                                  leftRoot: String = leftRoot,
                                  rightRoot: String = rightRoot) -> Bool {
        PaneLogic.organizeAimNeedsPaneSwap(scope: scope, aimedAtRight: aimedAtRight,
                                           leftRoot: leftRoot, rightRoot: rightRoot)
    }

    /// `(scope, aimed at the right pane, left root, right root, a swap is needed)`.
    @Test(arguments: [
        // The case the dialog exists for, first so the refusals below mean something: a rule that
        // always said false would pass them all. The folder is only in the aimed (right) pane's
        // tree, so Organize, which shows the left pane, would silently drop it.
        (OrganizeAimPaneSwapTests.rightRoot + "/Legal/Immigration", true, OrganizeAimPaneSwapTests.leftRoot, OrganizeAimPaneSwapTests.rightRoot, true),
        // Aimed at the left pane, the one Organize shows, so there is nothing to move: every ⌘K
        // route outside Compare, and every Compare route with the left pane focused. The second
        // row is the swap case's folder, so the aim is the only difference.
        (OrganizeAimPaneSwapTests.leftRoot + "/Legal/Immigration", false, OrganizeAimPaneSwapTests.leftRoot, OrganizeAimPaneSwapTests.rightRoot, false),
        (OrganizeAimPaneSwapTests.rightRoot + "/Legal/Immigration", false, OrganizeAimPaneSwapTests.leftRoot, OrganizeAimPaneSwapTests.rightRoot, false),
        // "Organize" with no folder reads the same from either pane, so moving them would be a
        // change the user didn't ask for.
        (nil, true, OrganizeAimPaneSwapTests.leftRoot, OrganizeAimPaneSwapTests.rightRoot, false),
        // Both panes on one provider: the folder already resolves under the left root, so
        // Organize shows it with the chip intact and a swap would move the panes for nothing.
        (OrganizeAimPaneSwapTests.rightRoot + "/Legal", true, OrganizeAimPaneSwapTests.rightRoot, OrganizeAimPaneSwapTests.rightRoot, false),
        // A folder in neither tree isn't a pane problem: a stale scope degrades to the global view
        // as `OrganizeScope` documents, and no arrangement of the panes would rescue it.
        ("/Volumes/Archive 2019/Legal", true, OrganizeAimPaneSwapTests.leftRoot, OrganizeAimPaneSwapTests.rightRoot, false),
        // The provider root itself is the global view: `OrganizeScope.init?` normalizes it to nil,
        // so nothing is lost by not swapping.
        (OrganizeAimPaneSwapTests.rightRoot, true, OrganizeAimPaneSwapTests.leftRoot, OrganizeAimPaneSwapTests.rightRoot, false),
        (OrganizeAimPaneSwapTests.rightRoot + "/", true, OrganizeAimPaneSwapTests.leftRoot, OrganizeAimPaneSwapTests.rightRoot, false),
        // The boundary is a path component, not a string prefix, on both roots. A `hasPrefix` rule
        // fails each half the opposite way: it would place `/…/DropboxArchive/Legal` inside
        // `/…/Dropbox` and offer a pointless swap, and decide a left root `/…/Drop` can see
        // `/…/Dropbox/Legal` and offer nothing.
        (OrganizeAimPaneSwapTests.rightRoot + "Archive/Legal", true, OrganizeAimPaneSwapTests.leftRoot, OrganizeAimPaneSwapTests.rightRoot, false),
        (OrganizeAimPaneSwapTests.rightRoot + "/Legal", true, String(OrganizeAimPaneSwapTests.rightRoot.dropLast("box".count)), OrganizeAimPaneSwapTests.rightRoot, true),
        // An empty root (a provider dropped from Settings while its pane is on screen) places
        // nothing: `PathBoundary` refuses it rather than letting it claim every path. With the
        // left root absent the folder really is only in the aimed pane, so the swap is right:
        // Organize on an empty root shows nothing anyway.
        (OrganizeAimPaneSwapTests.rightRoot + "/Legal", true, OrganizeAimPaneSwapTests.leftRoot, "", false),
        (OrganizeAimPaneSwapTests.rightRoot + "/Legal", true, "", OrganizeAimPaneSwapTests.rightRoot, true),
    ] as [(String?, Bool, String, String, Bool)])
    func theSwapIsOfferedOnlyWhenOrganizeWouldDropTheFolder(scope: String?, aimedAtRight: Bool,
                                                           leftRoot: String, rightRoot: String,
                                                           expected: Bool) {
        #expect(Self.needsSwap(scope: scope, aimedAtRight: aimedAtRight, leftRoot: leftRoot,
                               rightRoot: rightRoot) == expected)
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
}
