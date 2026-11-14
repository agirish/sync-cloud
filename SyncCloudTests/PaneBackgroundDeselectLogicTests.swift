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

    /// `(left, right)` before the click; both are empty after it. A selection lives in at most one
    /// pane, so the click usually lands in the other pane's empty space, and clearing only the clicked
    /// side would leave the gesture dead. Both populated can exist for a frame while a cross-pane
    /// clear is in flight (`applySelectionWrite` defers the sibling half), so neither may be left.
    @Test(arguments: [
        (["/left/a", "/left/b"], []),
        ([], ["/right/a"]),
        (["/left/a"], ["/right/b"]),
    ] as [(Set<String>, Set<String>)])
    func aBackgroundClickReleasesBothSelections(left: Set<String>, right: Set<String>) {
        let state = State()
        state.selectedLeftPaths = left
        state.selectedRightPaths = right

        PaneLogic.clearBothSelections(state: state)

        #expect(state.selectedLeftPaths.isEmpty)
        #expect(state.selectedRightPaths.isEmpty)
    }

    // MARK: What the columns are left looking like

    /// `(stack, clicked column depth, the stack left, or nil for no change)`, Finder-exact: a click
    /// closes the columns beyond the clicked one. The deepest column only deselects, reported as no
    /// change so the caller doesn't re-apply (and re-mirror) the stack. No depth (dead space past the
    /// last column, Tree, the rail) never navigates, and a stale depth past the end can't lengthen
    /// the stack: `truncate` clamps, so no closed column is resurrected.
    @Test(arguments: [
        (["Documents", "Invoices"], 0, []),
        (["Documents", "Invoices", "2026"], 1, ["Documents"]),
        (["Documents", "Invoices"], 2, nil),
        ([], 0, nil),
        (["Documents", "Invoices"], nil, nil),
        ([], nil, nil),
        (["Documents"], 5, nil),
    ] as [([String], Int?, [String]?)])
    func aBackgroundClickLeavesTheColumnsItShould(stack: [String], depth: Int?, expected: [String]?) {
        let result = PaneLogic.backgroundDeselectPath(from: PaneBrowsePath(components: stack), depth: depth)
        #expect(result?.components == expected)
    }

    /// Truncating discards the forward stack, so `›` can't walk back into a column just closed.
    @Test func testClosingColumnsDiscardsTheForwardStack() {
        var path = PaneBrowsePath(components: ["Documents", "Invoices"])
        path.popLast()
        #expect(path.canAdvance, "fixture should have something to walk forward into")

        let result = PaneLogic.backgroundDeselectPath(from: path, depth: 0)
        #expect(result?.canAdvance == false)
    }
}
