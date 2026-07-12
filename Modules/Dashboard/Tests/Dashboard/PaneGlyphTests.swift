import Testing
import AppKit

/// UX 1.2: three unrelated features used to share the ⇄ arrows. Now the link-panes toggle is a
/// chain, the pre-scan empty state reuses the toolbar Compare glyph, and ⇄ is swap-panes only.
@Suite struct PaneGlyphTests {

    @Test func testLinkPanesGlyphExistsInSFSymbols() {
        // PaneBreadcrumb's link-both-panes toggle. A typo'd symbol name renders as a blank
        // icon at runtime; pin that the name resolves.
        #expect(NSImage(systemSymbolName: "link", accessibilityDescription: nil) != nil,
                "missing SF Symbol link")
    }

    @Test func testCompareGlyphExistsInSFSymbols() {
        // ContentView's pre-scan empty state + toolbar Compare button share this symbol.
        #expect(NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: nil) != nil,
                "missing SF Symbol rectangle.split.2x1")
    }
}
