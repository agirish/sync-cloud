import Testing
import AppKit
import Design

/// Each pane glyph means one thing: the link-panes toggle is a chain, the pre-scan empty state
/// reuses the toolbar Compare glyph, and ⇄ is swap-panes only. These read the `PaneGlyph` constants
/// the views render, so a misspelled symbol name fails here instead of drawing a blank icon.
@Suite struct PaneGlyphTests {

    /// PaneBreadcrumb's link-both-panes toggle: a chain, never arrows. ContentView's pre-scan empty
    /// state and toolbar Compare button share the compare constant. ProviderSidebar's swap button
    /// owns the ⇄ arrows.
    @Test(arguments: [
        (PaneGlyph.linkBothPanes, "link"),
        (PaneGlyph.compare, "rectangle.split.2x1"),
        (PaneGlyph.swapPanes, "arrow.left.arrow.right.circle"),
    ])
    func testEachPaneGlyphIsItsSymbolAndExistsInSFSymbols(glyph: String, symbol: String) {
        #expect(glyph == symbol)
        #expect(NSImage(systemSymbolName: glyph, accessibilityDescription: nil) != nil,
                "missing SF Symbol \(glyph)")
    }
}
