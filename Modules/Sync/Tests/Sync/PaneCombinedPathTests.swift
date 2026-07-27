import Testing
import Foundation
import Events
@testable import Sync

/// The header renders one location, but a pane holds two: its comparison scope and where it is
/// browsing inside it. Joining them is what stops the path line describing a folder the pane is not
/// showing; splitting a click back apart is what stops a crumb inside the scope triggering a
/// rescan it does not need.
@MainActor
@Suite struct PaneCombinedPathTests {

    @Test func testJoinsScopeAndBrowsePosition() {
        let m = FileSyncManager()
        #expect(m.combinedRelativePath(isLeft: true) == "")

        m.leftBrowsePath.drill(into: "Documents", atDepth: 0)
        #expect(m.combinedRelativePath(isLeft: true) == "Documents", "at the root scope, browsing is the whole path")

        m.focusOn(relativePath: "Work", isLeft: true)   // resets the stack
        #expect(m.combinedRelativePath(isLeft: true) == "Work")

        m.leftBrowsePath.drill(into: "Invoices", atDepth: 0)
        m.leftBrowsePath.drill(into: "2025", atDepth: 1)
        #expect(m.combinedRelativePath(isLeft: true) == "Work/Invoices/2025")
    }

    /// A crumb inside the scope is a browse move: it must not re-root, because re-rooting reloads
    /// the tree and re-runs the scan for a folder the pane is already showing.
    @Test func testCrumbInsideTheScopeOnlyMovesTheColumns() {
        let m = FileSyncManager()
        m.focusOn(relativePath: "Work", isLeft: true)
        m.leftBrowsePath.drill(into: "Invoices", atDepth: 0)
        m.leftBrowsePath.drill(into: "2025", atDepth: 1)

        m.navigatePane(isLeft: true, toCombinedPath: "Work/Invoices")
        #expect(m.leftRelativePath == "Work", "scope must not move")
        #expect(m.leftBrowsePath.components == ["Invoices"])

        // The scope's own crumb drops back to the resting column, still without re-rooting.
        m.navigatePane(isLeft: true, toCombinedPath: "Work")
        #expect(m.leftRelativePath == "Work")
        #expect(m.leftBrowsePath.isEmpty)
    }

    /// A crumb *above* the scope is the only way back out, so it genuinely re-roots.
    @Test func testCrumbAboveTheScopeReRoots() {
        let m = FileSyncManager()
        m.focusOn(relativePath: "Work/Invoices", isLeft: true)
        m.leftBrowsePath.drill(into: "2025", atDepth: 0)

        m.navigatePane(isLeft: true, toCombinedPath: "Work")
        #expect(m.leftRelativePath == "Work")
        #expect(m.leftBrowsePath.isEmpty, "re-rooting resets the stack")
    }

    @Test func testRootCrumbFromTheRootScopeIsABrowseMove() {
        let m = FileSyncManager()
        m.leftBrowsePath.drill(into: "Documents", atDepth: 0)

        m.navigatePane(isLeft: true, toCombinedPath: "")
        #expect(m.leftRelativePath == "")
        #expect(m.leftBrowsePath.isEmpty)
    }

    /// Prefix matching must respect the path boundary, or a sibling scope whose name merely starts
    /// the same ("Work" vs "Workshop") would be mistaken for a folder inside it.
    @Test func testSiblingScopeSharingANamePrefixIsNotTreatedAsInside() {
        let m = FileSyncManager()
        m.focusOn(relativePath: "Work", isLeft: true)
        m.leftBrowsePath.drill(into: "Invoices", atDepth: 0)

        m.navigatePane(isLeft: true, toCombinedPath: "Workshop")
        #expect(m.leftRelativePath == "Workshop", "a sibling is a re-root, not a browse move")
        #expect(m.leftBrowsePath.isEmpty)
    }

    @Test func testEachPaneJoinsItsOwnHalves() {
        let m = FileSyncManager()
        m.focusOn(relativePath: "Left", isLeft: true)
        m.focusOn(relativePath: "Right", isLeft: false)
        m.leftBrowsePath.drill(into: "A", atDepth: 0)
        m.rightBrowsePath.drill(into: "B", atDepth: 0)

        #expect(m.combinedRelativePath(isLeft: true) == "Left/A")
        #expect(m.combinedRelativePath(isLeft: false) == "Right/B")
    }
}
