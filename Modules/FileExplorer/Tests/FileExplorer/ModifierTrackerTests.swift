import AppKit
import Testing
@testable import FileExplorer

/// Covers the app-wide "move instead of copy" modifier rule.
///
/// These lived in `PaneDragDropRoutingTests` while cross-pane drag & drop was the second
/// consumer of the rule. That feature is gone; the differences list (`DifferencesView`, via
/// `ModifierTracker.moveModifierHeld` and the published `isMoveModifierPressed`) is now the
/// only one, so the tests moved here rather than being deleted with it.
@Suite struct ModifierTrackerMoveModifierTests {

    @Test func testShiftOrCommandCountsAsMove() {
        #expect(ModifierTracker.isMoveModifier(.shift))
        #expect(ModifierTracker.isMoveModifier(.command))
        #expect(ModifierTracker.isMoveModifier([.shift, .command]))
        // Extra flags don't disqualify as long as a move modifier is down.
        #expect(ModifierTracker.isMoveModifier([.shift, .option]))
    }

    @Test func testOtherModifiersDoNot() {
        #expect(!ModifierTracker.isMoveModifier([]))
        #expect(!ModifierTracker.isMoveModifier(.option))
        #expect(!ModifierTracker.isMoveModifier(.control))
        #expect(!ModifierTracker.isMoveModifier([.option, .control]))
    }
}
