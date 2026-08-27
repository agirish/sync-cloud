import Testing
import Foundation
import Combine
@testable import Sync

/// **Which panes a refresh asks to walk, and why it is a question the sender has to answer.**
///
/// `refreshSubject` carried no payload, so every request it made was honoured as "walk both panes" —
/// including the commonest request in the app, one pane navigating. The other pane's root was then
/// re-walked on a source and a focus that navigation had not touched: warm, a cache hit the user
/// still sees as the untouched pane reloading; cold — after any file operation, sort change or
/// force refresh, all of which drop the prefetch cache — a full walk of tens of thousands of nodes
/// for a tree that was already correct.
///
/// The scope is asserted at the SUBJECT rather than by watching for a walk. That is the seam where
/// the decision is made and the only one a test can hold still: a walk needs a real tree on a real
/// disk, and counting walks would be a test of `refreshTreesAndScan`'s scheduling (which has its own
/// coverage, including the union rule that stops a narrow request stranding a pane) rather than of
/// the thing that was wrong here — a sender that knew which pane moved and threw the answer away.
@Suite struct RefreshScopeTests {

    /// Every scope `refreshSubject` publishes while `body` runs, in order.
    @MainActor
    private func scopes(from manager: FileSyncManager,
                        during body: () -> Void) -> [FileSyncManager.PaneReloadScope] {
        var seen: [FileSyncManager.PaneReloadScope] = []
        let token = manager.refreshSubject.sink { seen.append($0) }
        body()
        token.cancel()
        return seen
    }

    @MainActor
    @Test func navigatingOnePaneAsksToWalkOnlyThatPane() {
        let manager = FileSyncManager(fileManager: MockFileManager())

        #expect(scopes(from: manager) { manager.focusOn(relativePath: "Finance", isLeft: true) }
                == [.leftOnly],
                "navigating the left pane asked for the right pane's root to be walked as well")

        #expect(scopes(from: manager) { manager.focusOn(relativePath: "Photos", isLeft: false) }
                == [.rightOnly],
                "navigating the right pane asked for the left pane's root to be walked as well")
    }

    /// Back and forward move a pane exactly as a click does, and are the buttons this is most
    /// visible from — a walk back and forth through one pane's history re-walked the other pane
    /// every time.
    @MainActor
    @Test func backAndForwardAreScopedToTheirOwnPaneToo() {
        let manager = FileSyncManager(fileManager: MockFileManager())
        manager.focusOn(relativePath: "Finance", isLeft: true)
        manager.focusOn(relativePath: "Finance/2026", isLeft: true)

        #expect(scopes(from: manager) { manager.goBack(isLeft: true, drawsColumns: true) } == [.leftOnly])
        #expect(scopes(from: manager) { manager.goForward(isLeft: true, drawsColumns: true) } == [.leftOnly])
    }

    /// **Linked navigation moves both, so it walks both.** The scope follows what actually moved
    /// rather than which pane was clicked — a one-pane scope here would leave the sibling pointing
    /// at a folder whose tree was never loaded.
    @MainActor
    @Test func aLinkedMoveWalksBothPanes() {
        let manager = FileSyncManager(fileManager: MockFileManager())
        let seen = scopes(from: manager) {
            manager.focusBoth(left: "Finance", right: "Reports")
        }
        #expect(seen == [.both],
                "a move that took both panes somewhere new walked only one of them")
    }

    /// **A provider switch walks both panes even though only one of them moved**, and this is the
    /// test that stops the scoping from being a regression rather than an improvement.
    ///
    /// `resetNavigation` calls `invalidateComparisonState()`, which empties BOTH pane trees, and a
    /// left-source switch then hands the right pane its own current path as its landing — so the
    /// right pane does not move. Scoped on movement alone that is `.leftOnly`, the right tree stays
    /// `[]`, and nothing downstream ever refills it: a blank pane, from a switch on the other side.
    /// The rule a narrow scope depends on is that the unmoved pane still HOLDS a usable tree, and
    /// invalidation is precisely the case where it does not.
    @MainActor
    @Test func aProviderSwitchWalksBothPanesBecauseItThrewBothTreesAway() {
        let manager = FileSyncManager(fileManager: MockFileManager())
        manager.focusOn(relativePath: "Reports", isLeft: false)

        let seen = scopes(from: manager) {
            // Exactly the shape `ContentView`'s left-provider handler uses: a landing for the pane
            // that switched, and the other pane's OWN current path for the one that did not.
            manager.resetNavigation(leftLanding: "Finance", rightLanding: manager.rightRelativePath)
        }
        #expect(seen == [.both],
                "a provider switch asked to walk one pane after emptying both trees, so the other pane keeps an empty tree and renders blank")
        #expect(manager.rawRightTree.isEmpty,
                "invalidateComparisonState no longer empties the untouched pane's tree, so the reason this test exists has changed — re-derive the scope rule before relaxing it")
    }

    /// The same call with nothing moving at all — a reset onto the folders both panes are already
    /// on. Still both, for the same reason, and worth its own case because the movement booleans
    /// take a different route to it.
    @MainActor
    @Test func aResetOntoTheCurrentFoldersStillWalksBoth() {
        let manager = FileSyncManager(fileManager: MockFileManager())
        let seen = scopes(from: manager) {
            manager.resetNavigation(leftLanding: "", rightLanding: "")
        }
        #expect(seen == [.both], "a reset that moved nothing narrowed itself: \(seen)")
    }

    /// **The senders that are not navigation still say both, and must.** A date-tolerance change
    /// alters what a scan makes of BOTH trees, so a scope narrowed here would leave one pane's
    /// differences computed under the old setting with nothing on screen saying so.
    @MainActor
    @Test func aScanConfigChangeWalksBothPanes() {
        let manager = FileSyncManager(fileManager: MockFileManager())
        #expect(scopes(from: manager) { manager.dateToleranceSeconds = 5 } == [.both])
        #expect(scopes(from: manager) { manager.autoVerifySameSizeDuringScan.toggle() } == [.both])
    }
}
