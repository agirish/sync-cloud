import Testing
import AppKit
@testable import FileExplorer

@Suite struct TransferGlyphTests {

    @Test func testCanonicalCopyAndMoveGlyphs() {
        // Copy is the universal duplicate glyph everywhere; the target pane rides in the label,
        // not the icon (SF Symbols has no clean left/right copy pair). `copy(toRight:)` is a thin
        // symmetry alias and stays non-directional in both directions.
        #expect(TransferGlyph.copy == "doc.on.doc")
        #expect(TransferGlyph.copy(toRight: true) == "doc.on.doc")
        #expect(TransferGlyph.copy(toRight: false) == "doc.on.doc")

        // Move is a box-with-arrow. Non-directional default points right; the directional
        // variant points at the target pane.
        #expect(TransferGlyph.move == "arrow.right.square")
        #expect(TransferGlyph.move(toRight: true) == "arrow.right.square")
        #expect(TransferGlyph.move(toRight: false) == "arrow.left.square")
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
