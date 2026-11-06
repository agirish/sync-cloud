import Testing
import Foundation
import Combine
@testable import Sync

/// Which panes a refresh asks to walk: the sender knows which pane moved, and must say so. Walking
/// both on every request means one pane navigating re-walks the other, which the user sees as the
/// untouched pane reloading; with the prefetch cache dropped (after a file operation, sort change
/// or force refresh) that is a full walk of a tree that was already correct.
///
/// Asserted at `refreshSubject`, where the decision is made, rather than by counting walks, which
/// would test `refreshTreesAndScan`'s scheduling; that has its own coverage, including the union
/// rule that stops a narrow request stranding a pane.
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

    /// Back and forward move a pane exactly as a click does, and are where an unscoped refresh is
    /// most visible: stepping through one pane's history would re-walk the other every time.
    @MainActor
    @Test func backAndForwardAreScopedToTheirOwnPaneToo() {
        let manager = FileSyncManager(fileManager: MockFileManager())
        manager.focusOn(relativePath: "Finance", isLeft: true)
        manager.focusOn(relativePath: "Finance/2026", isLeft: true)

        #expect(scopes(from: manager) { manager.goBack(isLeft: true, drawsColumns: true) } == [.leftOnly])
        #expect(scopes(from: manager) { manager.goForward(isLeft: true, drawsColumns: true) } == [.leftOnly])
    }

    /// Linked navigation moves both, so it walks both. The scope follows what moved, not which pane
    /// was clicked; a one-pane scope would leave the sibling at a folder whose tree never loaded.
    @MainActor
    @Test func aLinkedMoveWalksBothPanes() {
        let manager = FileSyncManager(fileManager: MockFileManager())
        let seen = scopes(from: manager) {
            manager.focusBoth(left: "Finance", right: "Reports")
        }
        #expect(seen == [.both],
                "a move that took both panes somewhere new walked only one of them")
    }

    /// A provider switch walks the pane that switched, and only that one. The narrow scope is safe
    /// only while the unmoved pane holds a usable tree: `retargetPane` drops just one pane's tree.
    /// Were both emptied, the untouched pane would render blank; the second assertion keeps that
    /// premise checked.
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

    /// The switched pane landing on the folder it was already on (a source whose Open-at names the
    /// current folder) still walks only that pane. Inferred from the paths, nothing moved and the
    /// scope would say `.both`; the pane to walk is the one whose root changed, which no path
    /// comparison can see.
    @MainActor
    @Test func aSwitchOntoTheCurrentFolderStillWalksTheSwitchedPane() {
        let manager = FileSyncManager(fileManager: MockFileManager())
        let seen = scopes(from: manager) {
            manager.retargetPane(isLeft: false, landing: "")
        }
        #expect(seen == [.rightOnly], "a switch that moved no folder widened to both panes: \(seen)")
    }

    /// `describedPanes` is a log string, and one naming the wrong panes is worse than none: it sends
    /// a reader chasing a reload to the wrong pane. Three cases, each spelled out.
    @Test func theScopeNamesThePanesItMeans() {
        #expect(FileSyncManager.PaneReloadScope.both.describedPanes == "both panes")
        #expect(FileSyncManager.PaneReloadScope.leftOnly.describedPanes == "the left pane")
        #expect(FileSyncManager.PaneReloadScope.rightOnly.describedPanes == "the right pane")
        // Not the case name, which a bare interpolation gives. The widening line keeps that
        // spelling on purpose: it is quoting a request.
        #expect(FileSyncManager.PaneReloadScope.leftOnly.describedPanes != "\(FileSyncManager.PaneReloadScope.leftOnly)")
    }

    /// Senders that aren't navigation still say both, and must: a date-tolerance change alters what
    /// a scan makes of both trees, and narrowed, one pane's differences would silently keep the old
    /// setting.
    @MainActor
    @Test func aScanConfigChangeWalksBothPanes() {
        let manager = FileSyncManager(fileManager: MockFileManager())
        #expect(scopes(from: manager) { manager.dateToleranceSeconds = 5 } == [.both])
        #expect(scopes(from: manager) { manager.autoVerifySameSizeDuringScan.toggle() } == [.both])
    }
}
