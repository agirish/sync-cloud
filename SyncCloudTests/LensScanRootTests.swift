import Testing
import Foundation
import Sync
@testable import SyncCloud

/// The lens scan target follows where the pane is browsing, not just its comparison focus. Column
/// clicks move `PaneBrowsePath` and not the focus (browsing must not re-run the comparison), so
/// reading only the focus root would leave every lens scan and the "Scan '<folder>'" offer stuck at
/// the provider root. `PaneLogic.lensScanRoot` is the join.
@Suite struct LensScanRootTests {
    // MARK: The join

    /// `(focus root, browse trail, scan root)`.
    @Test(arguments: [
        ("/Users/me/Documents", "Finance/US", "/Users/me/Documents/Finance/US"),
        // At rest the focus root comes back untouched, trailing slash and all. Fails if the
        // `browsePath.isEmpty` guard is deleted (the join would normalize the slash away).
        ("/Users/me/Documents/", "", "/Users/me/Documents/"),
        // A trailing-slash root joins without doubling the separator.
        ("/Users/me/Documents/", "Scans", "/Users/me/Documents/Scans"),
        // An empty root (providers still resolving) never invents a target like "/Finance", which
        // keeps every scan action's `!root.isEmpty` guard meaningful.
        ("", "Finance", ""),
        // "/" normalizes to "" inside the join, so "/" + "A" is "/A", not "//A"; at rest the guard
        // hands "/" back verbatim rather than letting that normalization collapse it to "".
        ("/", "A", "/A"),
        ("/", "", "/"),
    ])
    func theScanRootIsTheFocusRootJoinedToTheBrowseTrail(root: String, trail: String, expected: String) {
        let browse = trail.isEmpty ? PaneBrowsePath() : PaneBrowsePath(relativePath: trail)
        #expect(PaneLogic.lensScanRoot(focusRootExpanded: root, browsePath: browse) == expected)
    }

    // MARK: The call site

    /// A rule extracted for testability is one revert from unused: the join stays green even if
    /// `ContentView` reads the bare focus root. As in FileExplorer's `OrganizeScopeCallSiteTests`,
    /// the scan names its file, fails if it can't read it, and bounds the body by its closing brace.
    @Test func theScanRootPropertyRoutesThroughTheBrowseAwareJoin() throws {
        let body = try declarationBody(of: "var lensScanRootExpanded: String {", in: macAppFile("ContentView.swift"))
        #expect(body.contains("PaneLogic.lensScanRoot"),
                "lensScanRootExpanded no longer routes through the browse-aware join")
        // Each ternary pinned whole: a flipped one (one pane's root with the other's trail) passes
        // the pure-function tests, which see one pane at a time.
        #expect(body.contains("lensTargetIsRight ? currentRightPath : currentLeftPath"),
                "the focus root no longer follows the targeted pane (or the ternary flipped)")
        #expect(body.contains(
                    "lensTargetIsRight ? syncManager.rightBrowsePath : syncManager.leftBrowsePath"),
                "the browse path no longer follows the targeted pane (or the ternary flipped)")
        // In Tree the stack is parked and undrawn, so joining it would scan a folder not on screen.
        // `paneDrawsColumns` takes `isLeft`: without the `!` it asks the other pane.
        #expect(body.contains("paneDrawsColumns(isLeft: !lensTargetIsRight)"),
                "the scan target no longer asks the TARGETED pane whether it draws columns")
        #expect(body.contains(": PaneBrowsePath()"),
                "a Tree pane's scan target no longer drops the parked column stack")
    }
}
