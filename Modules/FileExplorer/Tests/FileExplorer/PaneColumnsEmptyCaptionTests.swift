import Testing
@testable import FileExplorer

/// The column stack's "Empty" caption must never render in the root column: an empty tree
/// already draws the pane's "Folder is empty" placeholder in the same space, and the two
/// captions used to render stacked — the column's caption clipped against the placeholder's
/// folder glyph. The caption is for columns opened *into* an empty subfolder, where the big
/// placeholder deliberately does not show.
@Suite struct PaneColumnsEmptyCaptionTests {

    @Test func rootColumnNeverCaptionsAnEmptyTree() {
        // The collision case: depth 0, no rows — the pane placeholder owns this message.
        #expect(!PaneColumnsView.showsEmptyCaption(rowsEmpty: true, depth: 0))
    }

    @Test func drilledIntoEmptySubfolderStillSaysEmpty() {
        // The caption's whole purpose: an opened column with nothing in it must say so,
        // because the pane placeholder does not show when the tree has rows.
        #expect(PaneColumnsView.showsEmptyCaption(rowsEmpty: true, depth: 1))
        #expect(PaneColumnsView.showsEmptyCaption(rowsEmpty: true, depth: 3))
    }

    @Test func populatedColumnsNeverCaption() {
        #expect(!PaneColumnsView.showsEmptyCaption(rowsEmpty: false, depth: 0))
        #expect(!PaneColumnsView.showsEmptyCaption(rowsEmpty: false, depth: 2))
    }
}
