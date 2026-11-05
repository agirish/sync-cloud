import Testing
import Foundation
import Sync
@testable import SyncCloud

/// What a plain click on a pane's empty space decides: which selections let go, and what the column
/// stack is left looking like.
@MainActor
@Suite struct PaneBackgroundDeselectLogicTests {

    /// Stands in for `FileSyncManager`'s selection properties.
    private final class State: PaneSelectionState {
        var selectedLeftPaths: Set<String> = []
        var selectedRightPaths: Set<String> = []
        var lastSelectionSurface: SelectionSurface? = nil
    }

    // MARK: Letting the selection go

    /// The common case, and why this clears both sides: a selection lives in at most one pane, so
    /// the click usually lands in the other pane's empty space. Clearing only the clicked side
    /// would leave the gesture dead exactly when the user expects it to work.
    @Test func testClickingOnePanesEmptySpaceReleasesTheOtherPanesSelection() {
        let state = State()
        state.selectedLeftPaths = ["/left/a", "/left/b"]

        PaneLogic.clearBothSelections(state: state)

        #expect(state.selectedLeftPaths.isEmpty)
        #expect(state.selectedRightPaths.isEmpty)
    }

    @Test func testItClearsTheClickedPaneToo() {
        let state = State()
        state.selectedRightPaths = ["/right/a"]

        PaneLogic.clearBothSelections(state: state)

        #expect(state.selectedRightPaths.isEmpty)
    }

    /// A both-populated state can exist for a single frame while a cross-pane clear is in flight
    /// (`applySelectionWrite` defers the sibling half), so this must not leave one behind.
    @Test func testItClearsBothWhenBothAreSomehowPopulated() {
        let state = State()
        state.selectedLeftPaths = ["/left/a"]
        state.selectedRightPaths = ["/right/b"]

        PaneLogic.clearBothSelections(state: state)

        #expect(state.selectedLeftPaths.isEmpty)
        #expect(state.selectedRightPaths.isEmpty)
    }

    // MARK: What the columns are left looking like

    /// Finder-exact: clicking the empty space of column 0 while three are open closes the two to its
    /// right.
    @Test func testClickingAnOuterColumnClosesTheColumnsToItsRight() {
        let path = PaneBrowsePath(components: ["Documents", "Invoices"])
        let result = PaneLogic.backgroundDeselectPath(from: path, depth: 0)
        #expect(result?.components == [])
    }

    @Test func testClickingTheMiddleColumnClosesOnlyWhatIsBeyondIt() {
        let path = PaneBrowsePath(components: ["Documents", "Invoices", "2026"])
        let result = PaneLogic.backgroundDeselectPath(from: path, depth: 1)
        #expect(result?.components == ["Documents"])
    }

    /// The deepest column has nothing beyond it, so this only deselects. Reported as no change so
    /// the caller skips `applyColumnNavigation` rather than re-applying (and, with the seam link
    /// on, re-mirroring) the stack it already has.
    @Test func testClickingTheDeepestColumnChangesNoColumns() {
        let path = PaneBrowsePath(components: ["Documents", "Invoices"])
        #expect(PaneLogic.backgroundDeselectPath(from: path, depth: 2) == nil)
    }

    /// A resting pane is one full-width column; there is nothing to close.
    @Test func testClickingTheRestingColumnChangesNothing() {
        #expect(PaneLogic.backgroundDeselectPath(from: PaneBrowsePath(), depth: 0) == nil)
    }

    /// No depth means the dead space past the last column, Tree mode, or the single-source rail.
    /// All deselect without navigating: closing the stack from a click past it would be a move the
    /// user didn't ask for, and the other two have no stack.
    @Test func testNoDepthNeverTouchesTheColumns() {
        let path = PaneBrowsePath(components: ["Documents", "Invoices"])
        #expect(PaneLogic.backgroundDeselectPath(from: path, depth: nil) == nil)
        #expect(PaneLogic.backgroundDeselectPath(from: PaneBrowsePath(), depth: nil) == nil)
    }

    /// A depth past the end of the stack can't lengthen it. `truncate` clamps, and this pins that
    /// the clamp is relied on: a stale depth arriving after the stack shrank must not resurrect a
    /// column.
    @Test func testADepthBeyondTheStackCannotOpenColumns() {
        let path = PaneBrowsePath(components: ["Documents"])
        #expect(PaneLogic.backgroundDeselectPath(from: path, depth: 5) == nil)
    }

    /// Truncating discards the forward stack, so `›` can't walk back into a column the user just
    /// closed, as with every other branching move.
    @Test func testClosingColumnsDiscardsTheForwardStack() {
        var path = PaneBrowsePath(components: ["Documents", "Invoices"])
        path.popLast()
        #expect(path.canAdvance, "fixture should have something to walk forward into")

        let result = PaneLogic.backgroundDeselectPath(from: path, depth: 0)
        #expect(result?.canAdvance == false)
    }
}
