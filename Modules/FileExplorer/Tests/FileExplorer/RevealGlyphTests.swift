import Testing
import AppKit
import Design

/// RevealGlyph lives in Design (both FileExplorer and Dashboard draw from it), but Design has
/// no test target, so its pins live here next to TransferGlyphTests.
@Suite struct RevealGlyphTests {

    @Test func testRevealIsTheOutwardBoxArrowNotTheMagnifier() {
        // The magnifier is reserved for search (Differences search toggle, log-viewer field);
        // Reveal in Finder is the outward box-arrow everywhere.
        #expect(RevealGlyph.inFinder == "arrow.up.forward.square")
        #expect(RevealGlyph.inFinder != "magnifyingglass")
    }

    @Test func testRevealGlyphExistsInSFSymbols() {
        // A typo'd symbol name renders as a blank icon at runtime; pin that the name resolves.
        #expect(NSImage(systemSymbolName: RevealGlyph.inFinder, accessibilityDescription: nil) != nil,
                "missing SF Symbol \(RevealGlyph.inFinder)")
    }
}
