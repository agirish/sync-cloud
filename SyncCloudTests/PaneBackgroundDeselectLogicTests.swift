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

    /// `(left, right)` before the click; both are empty after it. The common case is the first, and
    /// why this clears both sides: a selection lives in at most one pane, so the click usually lands
    /// in the other pane's empty space, and clearing only the clicked side would leave the gesture
    /// dead exactly when the user expects it to work. The clicked pane clears too. Both populated
    /// can exist for a single frame while a cross-pane clear is in flight (`applySelectionWrite`
    /// defers the sibling half), so that must not leave one behind.
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

    /// `(stack, clicked column depth, the stack left, or nil for no change)`. Finder-exact: clicking
    /// column 0's empty space with three open closes the two to its right; the middle column closes
    /// only what is beyond it. The deepest column has nothing beyond it, so it only deselects,
    /// reported as no change so the caller skips `applyColumnNavigation` rather than re-applying
    /// (and, with the seam link on, re-mirroring) the stack it has. A resting pane has nothing to
    /// close. No depth (the dead space past the last column, Tree mode, the single-source rail)
    /// never navigates. A depth past the end can't lengthen the stack: `truncate` clamps, and a
    /// stale depth arriving after the stack shrank must not resurrect a column.
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
