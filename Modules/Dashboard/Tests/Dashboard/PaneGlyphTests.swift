import Testing
import AppKit
import Design

/// UX 1.2: three unrelated features used to share the ⇄ arrows. Now the link-panes toggle is a
/// chain, the pre-scan empty state reuses the toolbar Compare glyph, and ⇄ is swap-panes only.
/// These pins read the `PaneGlyph` constants the views actually render, so a typo'd or drifted
/// symbol name fails here instead of drawing a blank icon at runtime.
@Suite struct PaneGlyphTests {

    @Test func testLinkPanesGlyphIsAChainAndExistsInSFSymbols() {
        // PaneBreadcrumb's link-both-panes toggle: a chain, never arrows.
        #expect(PaneGlyph.linkBothPanes == "link")
        #expect(NSImage(systemSymbolName: PaneGlyph.linkBothPanes, accessibilityDescription: nil) != nil,
                "missing SF Symbol \(PaneGlyph.linkBothPanes)")
    }

    @Test func testCompareGlyphExistsInSFSymbols() {
        // ContentView's pre-scan empty state + toolbar Compare button share this constant.
        #expect(PaneGlyph.compare == "rectangle.split.2x1")
        #expect(NSImage(systemSymbolName: PaneGlyph.compare, accessibilityDescription: nil) != nil,
                "missing SF Symbol \(PaneGlyph.compare)")
    }

    @Test func testSwapPanesKeepsTheReservedArrows() {
        // ProviderSidebar's swap button owns the ⇄ arrows the other two glyphs moved away from.
        #expect(PaneGlyph.swapPanes == "arrow.left.arrow.right.circle")
        #expect(NSImage(systemSymbolName: PaneGlyph.swapPanes, accessibilityDescription: nil) != nil,
                "missing SF Symbol \(PaneGlyph.swapPanes)")
    }
}
