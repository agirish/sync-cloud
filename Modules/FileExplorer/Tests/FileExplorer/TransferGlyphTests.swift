import Testing
import AppKit
@testable import FileExplorer

@Suite struct TransferGlyphTests {

    @Test func testCanonicalCopyAndMoveGlyphs() {
        // Direction-unresolved copy stays the universal duplicate glyph: menus that name their
        // target in text, and "remaining", which resolves each item its own way.
        #expect(TransferGlyph.copy == "doc.on.doc")
        // Fixed-direction copy points at the pane it targets. This used to return `copy` — the
        // Differences header now fixes its primary to left-to-right and sheds the destination
        // name first when narrow, so direction has to survive in the icon.
        #expect(TransferGlyph.copy(toRight: true) == "arrow.right")
        #expect(TransferGlyph.copy(toRight: false) == "arrow.left")

        // Move is a box-with-arrow. Non-directional default points right; the directional
        // variant points at the target pane.
        #expect(TransferGlyph.move == "arrow.right.square")
        #expect(TransferGlyph.move(toRight: true) == "arrow.right.square")
        #expect(TransferGlyph.move(toRight: false) == "arrow.left.square")
    }

    @Test func testFixedDirectionCopyAndMoveAgreeOnDirection() {
        // The modifier changes the VERB, never the direction: a bare arrow for copy and the same
        // arrow boxed for move. A pair that disagreed would make ⇧ look like it also flipped sides.
        for toRight in [true, false] {
            let side = toRight ? "right" : "left"
            #expect(TransferGlyph.copy(toRight: toRight).contains(side))
            #expect(TransferGlyph.move(toRight: toRight).contains(side))
            #expect(TransferGlyph.move(toRight: toRight) == TransferGlyph.copy(toRight: toRight) + ".square")
        }
    }

    @Test func testEveryTransferGlyphExistsInSFSymbols() {
        // A typo'd symbol name renders as a blank icon at runtime; pin that every name resolves.
        let symbols = [
            TransferGlyph.copy,
            TransferGlyph.move,
            TransferGlyph.copy(toRight: true),
            TransferGlyph.copy(toRight: false),
            TransferGlyph.move(toRight: true),
            TransferGlyph.move(toRight: false),
        ]
        for symbol in symbols {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
                    "missing SF Symbol \(symbol)")
        }
    }
}
