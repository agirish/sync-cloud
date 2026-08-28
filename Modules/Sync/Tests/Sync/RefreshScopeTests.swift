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

    /// **A provider switch walks the pane that switched, and only that one.**
    ///
    /// This test used to assert the opposite, and the reason it could is the whole of the bug it
    /// now guards against: `resetNavigation` emptied BOTH pane trees, so `.both` was not a
    /// preference but a repair — scoped on movement alone the untouched pane would have kept an
    /// empty tree and rendered blank. `retargetPane` drops one pane's tree, so the sibling has a
    /// real tree to contribute and the narrow scope is honest. The premise, not the rule, is what
    /// changed; the rule a narrow scope depends on is still "the unmoved pane HOLDS a usable tree",
    /// and the assertion below is what keeps that premise checkable rather than remembered.
    @MainActor
    @Test func aProviderSwitchWalksOnlyThePaneThatSwitched() {
        let manager = FileSyncManager(fileManager: MockFileManager())
        manager.focusOn(relativePath: "Reports", isLeft: false)
        let sibling = FileNode(id: "/right/Reports", name: "Reports", isDirectory: true)
        manager.rawRightTree = [sibling]
        manager.rightTree = [sibling]

        let seen = scopes(from: manager) {
            manager.retargetPane(isLeft: true, landing: "Finance")
        }
        #expect(seen == [.leftOnly],
                "a source switch on the left pane re-walked the right pane's root, which it never touched: \(seen)")
        #expect(manager.rawRightTree == [sibling],
                "the untouched pane's tree was thrown away, so a narrow scope leaves it blank — re-derive the scope rule before keeping it")
    }

    /// The same call with the switched pane landing on the folder it was already on — a source
    /// whose Open-at names the pane's current folder. **Still the switched pane**, and worth its
    /// own case because it is the one the movement booleans get wrong: nothing moved, so inferring
    /// the scope from the paths says `.both`, and the pane that needs walking is the one whose
    /// ROOT changed under it — which no path comparison can see.
    @MainActor
    @Test func aSwitchOntoTheCurrentFolderStillWalksTheSwitchedPane() {
        let manager = FileSyncManager(fileManager: MockFileManager())
        let seen = scopes(from: manager) {
            manager.retargetPane(isLeft: false, landing: "")
        }
        #expect(seen == [.rightOnly], "a switch that moved no folder widened to both panes: \(seen)")
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
